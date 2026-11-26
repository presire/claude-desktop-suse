#
# @file electron.sh
# @brief app.asarの組み直しと、Electron本体のステージングディレクトリへの複製を行う
#
# ネイティブモジュールを展開したまま同梱するためasarは--unpack付きで詰め直し、
# ネイティブ関連のスタブとcoworkのデーモンをunpacked側へ置く
# Electron本体は権限を保ったまま複製する
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : asar_exec, app_staging_dir, source_dir,
#   node_pty_dir, node_pty_build_dir, node_pty_native_rel,
#   chosen_electron_module_path
# 変更するグローバル変数 : electron_resources_dest, pe_native_modules
#   (pe_native_modulesは関数内の走査結果を保持する配列)
#

#
# @brief 指定ディレクトリ配下の*.nodeのうちWindowsのPE形式のものを集める
# @param $@ 走査するディレクトリ
# @global pe_native_modules WindowsのPE形式だった*.nodeを設定する (ディレクトリごとに整列)
# @return 0 = 走査できた、1 = 一覧の取得やヘッダの読み取りに失敗した
# @note WindowsのnupkgにはLinuxがdlopenできないwin32向けのビルドが入っている
#       (node-ptyのconpty.nodeとconpty_console_list.node、差し替える
#       claude-nativeのバインディング、office365-mcpのmsal-node-runtime.node)
#       msal-node-runtime.nodeはtry/catchで読み込まれ、無い場合も同じように
#       機能を落とすだけで済む
#       ELFとバイナリでないファイルは残すため、結果は対象アーキテクチャに依存しない
# @note パスは最後までNUL区切りで扱う (名前に改行があっても別のパスに
#       分割されないようにするため)
#       一覧の取得やヘッダの読み取りに失敗した場合は「PEが無い」と報告せず、
#       その場で失敗を返す
#
_list_pe_native_modules() {
	local root file magic list
	local -a found=()
	pe_native_modules=()
	list=$(mktemp) || return 1
	for root in "$@"; do
		[[ -d $root ]] || continue
		if ! (set -o pipefail
			find "$root" -type f -name '*.node' -print0 \
				| LC_ALL=C sort -z) > "$list"; then
			echo "Cannot list native modules under: $root" >&2
			rm -f -- "$list"
			return 1
		fi
		mapfile -d '' -t found < "$list"
		for file in "${found[@]}"; do
			if ! magic=$(set -o pipefail
				LC_ALL=C head -c 2 -- "$file" | tr -d '\0'); then
				echo "Cannot read native module header: $file" >&2
				rm -f -- "$list"
				return 1
			fi
			[[ $magic == 'MZ' ]] && pe_native_modules+=("$file")
		done
	done
	rm -f -- "$list"
	return 0
}

#
# @brief _list_pe_native_modulesが見つけたWindows向け*.nodeを削除する
# @param $@ 走査するディレクトリ
# @global pe_native_modules (参照のみ) 削除対象の一覧
# @return 0 = 削除できた、1 = 一覧の取得か削除に失敗した
# @note 削除の結果ディレクトリが空になった場合はそのディレクトリも消す
#       (prebuilds/win32-*がこれに当たる)
#       2回目以降の実行では対象が無いため、何度呼んでも同じ結果になる
#
_prune_windows_native_modules() {
	local file
	_list_pe_native_modules "$@" || return 1
	for file in "${pe_native_modules[@]}"; do
		rm -f -- "$file" || return 1
		rmdir --ignore-fail-on-non-empty -- "$(dirname -- "$file")" \
			|| return 1
		echo "Removed Windows-only native module: $file"
	done
	echo "Windows-only native modules removed: ${#pe_native_modules[@]}"
}

#
# @brief ディレクトリ配下の通常ファイルを、そのディレクトリからの相対パスで集める
# @param $1 走査するディレクトリ (存在しない場合は空の一覧)
# @global unpacked_files 相対パスを設定する (整列済み)
# @return 0 = 走査できた、1 = 一覧の取得に失敗した
#
_list_unpacked_files() {
	local root="${1:-}" list file
	unpacked_files=()
	[[ -d $root ]] || return 0
	list=$(mktemp) || return 1
	if ! (set -o pipefail
		find "$root" -type f -print0 | LC_ALL=C sort -z) > "$list"; then
		echo "Cannot list files under: $root" >&2
		rm -f -- "$list"
		return 1
	fi
	while IFS= read -r -d '' file; do
		unpacked_files+=("${file#"$root/"}")
	done < "$list"
	rm -f -- "$list"
	return 0
}

#
# @brief app.asarを組み直し、unpacked側の内容が期待どおりかを検証する
# @global asar_exec (参照のみ) asarの実行ファイル
# @global app_staging_dir (参照のみ) app.asarとunpacked側の置き場所
# @global source_dir (参照のみ) スタブとデーモンのコピー元
# @global node_pty_dir, node_pty_build_dir, node_pty_native_rel (参照のみ)
#       node-ptyのネイティブバイナリの配置を決める
# @global unpacked_files (_list_unpacked_filesが設定する) 走査結果
# @note ネイティブモジュールの欠落、PE形式の混入、asarの失敗、
#       上流がunpacked側に置いたファイルのasar本体への取り込みではexit 1で中断する
#
finalize_app_asar() {
	# 詰め直しの入力は2つの系統から来る
	# asarの展開でapp.asar.contentsへ出た.nodeと、
	# 上流が同梱していたapp.asar.unpackedをそのまま複製したもの
	_prune_windows_native_modules app.asar.contents \
		"$app_staging_dir/app.asar.unpacked" || exit 1

	# 上流がunpacked側に置いたファイルは、詰め直した後もunpacked側に残す
	# 実行ファイルやdlopenする対象はasarの中からは使えないため、
	# *.node以外も上流の一覧から--unpackの対象に加える
	# (*.nodeは**/*.nodeで展開され、下のPEとnode-ptyの検査が受け持つ)
	# 複製しただけの古いunpacked側は消し、asar packに作り直させる
	# こうすると、作り直した結果だけで取り込まれたかどうかを判定できる
	# 詰め直した後に毎回置き直すスタブとデーモンは、上流の一覧に含めない
	local unpacked_dir="$app_staging_dir/app.asar.unpacked"
	local expected_files=(
		"node_modules/@ant/claude-native/index.js"
		"cowork-vm-service.js"
	)
	local -a upstream_unpacked=()
	local unpack_glob='**/*.node' rel
	_list_unpacked_files "$unpacked_dir" || exit 1
	for rel in "${unpacked_files[@]}"; do
		[[ $rel == *.node || $rel == "${expected_files[0]}" ||
			$rel == "${expected_files[1]}" ]] && continue
		upstream_unpacked+=("$rel")
	done
	for rel in "${upstream_unpacked[@]}"; do
		if [[ $rel == *[][*?{},!\\]* || $rel == *$'\n'* ]]; then
			echo "Repack invariance check FAILED: upstream unpacked path" \
				"contains glob syntax: $rel" >&2
			exit 1
		fi
		if [[ ! -f app.asar.contents/$rel ]]; then
			echo "Repack invariance check FAILED: upstream unpacked file" \
				"is missing from app.asar.contents: $rel" >&2
			exit 1
		fi
		unpack_glob+=",**/$rel"
	done
	# SUSEが後から置く2ファイルもunpackedとしてヘッダに記録させる
	# packの後に実体を置き直すだけではヘッダがpackedのままになり、
	# asarの中を読む経路と実体の所在が食い違う
	for rel in "${expected_files[@]}"; do
		unpack_glob+=",**/$rel"
	done
	[[ $unpack_glob == *,* ]] && unpack_glob="{$unpack_glob}"

	# V8のcompile-cacheはビルド環境の絶対パスやコードキャッシュを含み、
	# 別の環境へ配布すると壊れたキャッシュとして読み込まれる
	# 上流のnupkgには混ざっているため、詰め直す前に必ず落とす
	# 古いバンドルには無いので、無いこと自体は失敗にしない
	local compile_cache='app.asar.contents/compile-cache'
	if [[ -e $compile_cache || -L $compile_cache ]]; then
		local cache_files=0
		if ! cache_files=$(set -o pipefail
			find "$compile_cache" -type f -print | LC_ALL=C wc -l); then
			echo "Cannot count files under $compile_cache" >&2
			exit 1
		fi
		rm -rf -- app.asar.contents/compile-cache || exit 1
		echo "Removed V8 compile-cache ($cache_files files): $compile_cache"
	else
		echo "No V8 compile-cache found: $compile_cache"
	fi

	rm -rf -- "$unpacked_dir" || exit 1

	"$asar_exec" pack app.asar.contents app.asar \
		--unpack "$unpack_glob" || exit 1

	# 詰め直した後は、compile-cacheがcontents側にもasar本体にも
	# 戻っていないことを確かめる
	# 戻っていれば、削除かpackの手順が変わったということである
	if [[ -e $compile_cache || -L $compile_cache ]]; then
		echo "Repack invariance check FAILED: $compile_cache was" \
			'recreated during asar pack' >&2
		exit 1
	fi
	local asar_entries=''
	if ! asar_entries=$("$asar_exec" list app.asar); then
		echo 'Repack invariance check FAILED: cannot list app.asar' \
			'to verify compile-cache removal' >&2
		exit 1
	fi
	if grep -qE '^[/\\]compile-cache([/\\]|$)' <<< "$asar_entries"; then
		echo 'Repack invariance check FAILED: compile-cache is packed' \
			'in app.asar' >&2
		exit 1
	fi
	echo 'Repack check passed: no compile-cache in app.asar'

	local inline=0
	for rel in "${upstream_unpacked[@]}"; do
		if [[ ! -f $unpacked_dir/$rel ]]; then
			echo "Repack invariance check FAILED: upstream unpacked file" \
				"was packed into app.asar: $rel" >&2
			inline=1
		fi
	done
	if (( inline == 1 )); then
		exit 1
	fi
	echo "Upstream unpacked files kept unpacked: ${#upstream_unpacked[@]}"

	mkdir -p "$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native" || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		"$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native/index.js" || exit 1

	echo 'Copying cowork VM service daemon to unpacked directory...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		"$app_staging_dir/app.asar.unpacked/cowork-vm-service.js" || exit 1
	echo 'Cowork VM service daemon copied to unpacked'

	# install_node_ptyは用意した配置 (build/Releaseまたはprebuilds/linux-<arch>) を
	# node_pty_native_relに残す
	# その値を使えばここでアーキテクチャを推測し直さずに済み、
	# 別アーキテクチャ向けのprebuildを複製する事故も防げる
	local pty_unpacked_root="$app_staging_dir/app.asar.unpacked"
	local pty_unpacked_dir="$pty_unpacked_root/node_modules/node-pty"
	local pty_src_root=''
	if [[ -n $node_pty_dir ]]; then
		pty_src_root="$node_pty_dir"
	elif [[ -n $node_pty_build_dir ]]; then
		pty_src_root="$node_pty_build_dir/node_modules/node-pty"
	fi
	local pty_native_rel="${node_pty_native_rel:-}"
	if [[ -z $pty_native_rel && -f $pty_src_root/build/Release/pty.node ]]; then
		pty_native_rel='build/Release'
	fi

	if [[ -n $pty_native_rel && -f $pty_src_root/$pty_native_rel/pty.node ]]; then
		echo 'Copying node-pty native binaries to unpacked directory...'
		mkdir -p "$pty_unpacked_dir/$(dirname "$pty_native_rel")" || exit 1
		cp -r --no-preserve=mode "$pty_src_root/$pty_native_rel" \
			"$pty_unpacked_dir/$(dirname "$pty_native_rel")/" || exit 1
		chmod +x "$pty_unpacked_dir/$pty_native_rel/"* 2>/dev/null || true
		echo "node-pty $pty_native_rel copied to unpacked"
	fi

	local pty_shipped='' pty_cand=''
	for pty_cand in "$pty_unpacked_dir"/build/*/pty.node "$pty_unpacked_dir"/prebuilds/*/pty.node; do
		if [[ -f $pty_cand ]]; then
			pty_shipped="${pty_cand#"$pty_unpacked_root/"}"
			break
		fi
	done
	if [[ -n $pty_shipped ]]; then
		echo "node-pty native binary unpacked: $pty_shipped"
	else
		echo 'node-pty native binaries not found - terminal features may not work'
	fi

	# 詰め直しの前後でunpacked側の中身が変わっていないかを確かめる
	# 期待するファイルの欠落やWindows向けPEの混入は、
	# asarの詰め方かステージングの手順が変わったことを意味するため、
	# 警告で流さず失敗として扱う
	local missing=0 ef
	for ef in "${expected_files[@]}"; do
		if [[ ! -f "$unpacked_dir/$ef" ]]; then
			echo "Repack invariance check FAILED: expected unpacked file missing: $ef" >&2
			missing=1
		fi
	done
	if ! _list_pe_native_modules "$unpacked_dir"; then
		echo 'Repack invariance check FAILED: cannot scan app.asar.unpacked' \
			'for Windows PE native modules' >&2
		missing=1
	fi
	for ef in "${pe_native_modules[@]}"; do
		echo "Repack invariance check FAILED: Windows PE native module unpacked: ${ef#"$unpacked_dir/"}" >&2
		missing=1
	done
	if (( missing == 1 )); then
		echo 'The app.asar.unpacked fileset drifted from expectations.' >&2
		echo 'This usually means asar pack or a staging step changed.' >&2
		exit 1
	fi
	echo 'Repack invariance check passed (all expected unpacked files present, no Windows PE native modules)'
}

#
# @brief 用意したElectron一式をステージングディレクトリへ複製する
# @global chosen_electron_module_path (参照のみ) 複製元のElectronモジュール
# @global app_staging_dir (参照のみ) 複製先のAppDir
# @global electron_resources_dest 複製したElectronのresourcesディレクトリを設定する
# @note 複製に失敗した場合はexit 1で中断する
#
stage_electron() {
	echo 'Copying chosen electron installation to staging area...'
	mkdir -p "$app_staging_dir/node_modules/" || exit 1
	local electron_dir_name
	electron_dir_name=$(basename "$chosen_electron_module_path")
	echo "Copying from $chosen_electron_module_path to $app_staging_dir/node_modules/"
	cp -a "$chosen_electron_module_path" "$app_staging_dir/node_modules/" || exit 1

	local staged_electron_bin="$app_staging_dir/node_modules/$electron_dir_name/dist/electron"
	if [[ -f $staged_electron_bin ]]; then
		echo "Setting executable permission on staged Electron binary: $staged_electron_bin"
		chmod +x "$staged_electron_bin" || exit 1
	else
		echo "Warning: Staged Electron binary not found at expected path: $staged_electron_bin"
	fi

	# Electronのロケール資源を複製する
	# 言語パックが欠けるとアプリの表記が英語に固定されるため、
	# dist/resourcesの中身をそのまま持っていく
	local electron_resources_src="$chosen_electron_module_path/dist/resources"
	electron_resources_dest="$app_staging_dir/node_modules/$electron_dir_name/dist/resources"
	if [[ -d $electron_resources_src ]]; then
		echo 'Copying Electron locale resources...'
		mkdir -p "$electron_resources_dest" || exit 1
		cp -a "$electron_resources_src"/* "$electron_resources_dest/" || exit 1
		echo 'Electron locale resources copied'
	else
		echo "Warning: Electron resources directory not found at $electron_resources_src"
	fi
}
