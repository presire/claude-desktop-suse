#
# @file dependencies.sh
# @brief ビルドに必要なパッケージの導入と、作業ディレクトリ・Node.js・Electronの初期化を行う
#
# SUSE環境ではzypperで不足パッケージを導入する
# システムのNode.jsが古い場合は作業ディレクトリ配下に固定バージョンを展開する
# Electronとasarは成果物に同梱するため、作業ディレクトリに取得してパスを確定する
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : build_format, distro_family, work_dir,
#   app_staging_dir, project_root, architecture, node_pty_dir, source_dir
# 変更するグローバル変数 : chosen_electron_module_path, asar_exec,
#   PATH (setup_nodejsでexportする)
#

#
# @brief ビルドに必要なコマンドの不足を調べ、SUSE環境ではzypperで導入する
# @global build_format (参照のみ) rpmのときだけrpmbuildを要求する
# @global distro_family (参照のみ) 導入に使えるパッケージマネージャを決める
# @global node_pty_dir (参照のみ) 指定時はビルド済みのnode-ptyを外から持ち込む
# @note 導入の失敗、またはsudoの資格情報を確認できない場合はexit 1で中断する
#
check_dependencies() {
	echo 'Checking dependencies...'
	local deps_to_install=''
	local common_deps='p7zip wget wrestool icotool convert unzip'
	local all_deps="$common_deps"

	# パッケージ形式ごとにだけ必要になるコマンドを加える
	case "$build_format" in
		rpm) all_deps="$all_deps rpmbuild" ;;
	esac

	# node-ptyはnpm installの間にnode-gypでC++のネイティブモジュールを
	# ビルドする
	# gcc/g++/make/python3が無いとインストールは警告を出すだけで通過し、
	# pty_src_dirが空のままWindows向けバイナリを同梱してしまう (#401)
	# --node-pty-dirがある場合はビルド済みのnode-ptyを外から持ち込むため
	# ビルドツールを要求しない
	if [[ -z ${node_pty_dir:-} ]]; then
		all_deps="$all_deps gcc g++ make python3"
	fi

	# コマンド名からzypperに渡すパッケージ名への対応表
	declare -A suse_pkgs=(
		[p7zip]='p7zip' [wget]='wget' [wrestool]='icoutils'
		[icotool]='icoutils' [convert]='ImageMagick'
		[unzip]='unzip'
		[rpmbuild]='rpm-build'
		[gcc]='gcc' [g++]='gcc-c++'
		[make]='make' [python3]='python3'
	)

	local cmd pkg
	for cmd in $all_deps; do
		if ! check_command "$cmd"; then
			if [[ $distro_family == 'suse' ]]; then
				pkg="${suse_pkgs[$cmd]}"
				case " $deps_to_install " in
					*" $pkg "*) ;;                             # 同じパッケージを二重に数えない
					*) deps_to_install="$deps_to_install $pkg" ;;
				esac
			else
				echo "Warning: Cannot auto-install '$cmd' on unknown distro. Please install manually." >&2
			fi
		fi
	done

	if [[ -n $deps_to_install ]]; then
		echo "System dependencies needed:$deps_to_install"

		# rootで実行中ならsudoを付けずにそのまま導入する
		local sudo_cmd='sudo'
		if (( EUID == 0 )); then
			sudo_cmd=''
			echo 'Installing as root (no sudo needed)...'
		else
			echo 'Attempting to install using sudo...'
			# パスワード無しでsudoできるかを先に確かめ、
			# できない場合だけここで資格情報の入力を求める
			if sudo -n true 2>/dev/null; then
				echo 'Passwordless sudo detected.'
			elif ! sudo -v; then
				echo 'Failed to validate sudo credentials. Please ensure you can run sudo.' >&2
				exit 1
			fi
		fi

		if [[ $distro_family == 'suse' ]]; then
			# 古いメタデータで導入すると依存が解決できないことがあるため、
			# 先にリポジトリ情報を更新する
			if ! $sudo_cmd zypper refresh; then
				echo "Failed to run 'zypper refresh'." >&2
				exit 1
			fi
			# --no-recommendsで推奨パッケージを入れず、ビルドに要るものだけに絞る
			# shellcheck disable=SC2086
			if ! $sudo_cmd zypper install -y --no-recommends $deps_to_install; then
				echo "Failed to install dependencies using 'zypper install'." >&2
				exit 1
			fi
		else
			echo "Cannot auto-install dependencies on unknown distro." >&2
			echo "Please install these packages manually: $deps_to_install" >&2
			exit 1
		fi
		echo 'System dependencies installed successfully.'
	fi
}

#
# @brief 前回の成果物が混ざらないよう、作業ディレクトリを作り直す
# @global work_dir (参照のみ) 削除して作り直すディレクトリ
# @global app_staging_dir (参照のみ) 配置先として用意するディレクトリ
#
setup_work_directory() {
	rm -rf "$work_dir"
	mkdir -p "$work_dir" || exit 1
	mkdir -p "$app_staging_dir" || exit 1
}

# 下限は@electron/asarが決める
# 4.xの全てのリリースがengines.node >= 22.12.0を宣言し、
# それ未満では起動を拒否する
# npmはこの不一致をEBADENGINEの警告として流すだけなので、古いNode.jsのホストでは
# バイナリの導入だけが成功し、以降のasar呼び出しが全て失敗してパッチ適用の失敗として
# 現れていた (#839)
# 2つの値は、ビルドが解決するasar系列のengine制約と揃えて更新する
readonly NODE_MIN_VERSION='22.12.0'
readonly NODE_FALLBACK_VERSION='22.23.2'

# パッチ適用後にapp.asarを組み直すasarはバージョンを厳密に固定する
# 出力は.rpmと.AppImageに同梱されるため、壊れたasarや侵害されたasarの
# リリースがレビューを経ずに成果物へ入ってはならない
# 更新は意図的な1行の変更として行う (claude-desktop-debian #960)
readonly ASAR_PINNED_VERSION='4.3.1'

#
# @brief Node.jsのバージョンが下限以上かを判定する
# @param $1 判定するバージョン (先頭のvを含まないx.y形式)
# @param $2 下限のバージョン (先頭のvを含まないx.y形式)
# @return 0 = 下限以上、1 = 下限未満または解釈できない値
# @note パッチ番号は意図的に比較しない
#       追跡しているengine制約はmajor.minorでしか動いておらず、
#       3要素の比較は解析を増やすだけで誤りを招きやすい
#
node_version_at_least() {
	local have="$1" want="$2"

	# 解釈できない値を正しいバージョンとして扱わない
	[[ $have =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
	[[ $want =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1

	local -a have_parts want_parts
	IFS='.' read -ra have_parts <<< "$have"
	IFS='.' read -ra want_parts <<< "$want"

	# メジャーだけの指定 ("22") はマイナーを持たないため0として読む
	# これにより"22"は22.12の下限を満たさず、
	# 「ほぼ同じ」とは判定しない
	local have_major="${have_parts[0]}" have_minor="${have_parts[1]:-0}"
	local want_major="${want_parts[0]}" want_minor="${want_parts[1]:-0}"

	(( have_major > want_major )) && return 0
	(( have_major < want_major )) && return 1
	(( have_minor >= want_minor ))
}

#
# @brief Node.jsのバージョンを確認し、不足ならビルド用の固定バージョンを展開する
# @global work_dir (参照のみ) ダウンロード先と展開先に使う
# @global project_root (参照のみ) 処理の終了時に戻る先
# @global architecture (参照のみ) ログに出す対象アーキテクチャ
# @global PATH 展開したNode.jsのbinを先頭に足してexportする
# @return 0 = 利用可能なNode.jsを用意できた
# @note ダウンロード、チェックサム照合、展開のいずれかに失敗した場合は
#       exit 1で中断する
#
setup_nodejs() {
	section_header 'Node.js Setup'
	echo 'Checking Node.js version...'

	local node_version_ok=false
	if command -v node &> /dev/null; then
		local node_version
		node_version=$(node --version | cut -d'v' -f2)
		echo "System Node.js version: v$node_version"

		if node_version_at_least "$node_version" "$NODE_MIN_VERSION"; then
			echo "System Node.js version is adequate (v$node_version)"
			node_version_ok=true
		else
			echo "System Node.js version is too old (v$node_version)." \
				"Need v$NODE_MIN_VERSION+ (@electron/asar engine floor)"
		fi
	else
		echo 'Node.js not found in system'
	fi

	if [[ $node_version_ok == true ]]; then
		section_footer 'Node.js Setup'
		return 0
	fi

	# システムのNode.jsが古いため、作業ディレクトリに固定バージョンを展開する
	echo "Installing Node.js v$NODE_FALLBACK_VERSION locally in build directory..."

	local host_arch node_arch
	host_arch=$(uname -m)
	case "$host_arch" in
		x86_64) node_arch='x64' ;;    # 一般的なx86-64ホスト
		aarch64) node_arch='arm64' ;; # 64bit ARMホスト
		*)
			echo "Unsupported host architecture for Node.js: $host_arch" >&2
			exit 1
			;;
	esac

	local node_version_to_install="$NODE_FALLBACK_VERSION"
	local node_tarball="node-v${node_version_to_install}-linux-${node_arch}.tar.xz"
	local node_url="https://nodejs.org/dist/v${node_version_to_install}/${node_tarball}"
	local node_install_dir="$work_dir/node"

	echo "Downloading Node.js v${node_version_to_install} for ${node_arch} (host ${host_arch}, target ${architecture})..."
	cd "$work_dir" || exit 1
	if ! wget -O "$node_tarball" "$node_url"; then
		echo "Failed to download Node.js from $node_url" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	# 公式のSHA-256と照合し、破損や差し替えられたtarballを展開前に弾く
	local shasums_url node_expected_sha256
	shasums_url="https://nodejs.org/dist/v${node_version_to_install}/SHASUMS256.txt"
	node_expected_sha256=$(
		wget -qO- "$shasums_url" \
			| grep -F "$node_tarball" \
			| awk '{print $1}'
	) || true

	if ! verify_sha256 "$work_dir/$node_tarball" \
		"$node_expected_sha256" 'Node.js tarball'; then
		cd "$project_root" || exit 1
		exit 1
	fi

	echo 'Extracting Node.js...'
	if ! tar -xf "$node_tarball"; then
		echo 'Failed to extract Node.js tarball' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	mv "node-v${node_version_to_install}-linux-${node_arch}" "$node_install_dir" || exit 1
	export PATH="$node_install_dir/bin:$PATH"

	if command -v node &> /dev/null; then
		echo "Local Node.js installed successfully: $(node --version)"
	else
		echo 'Failed to install local Node.js' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	rm -f "$node_tarball"
	cd "$project_root" || exit 1
	section_footer 'Node.js Setup'
}

#
# @brief build.shの--archの値をElectron配布物のアーキテクチャ名に変換する
# @param $1 対象アーキテクチャ (amd64またはarm64)
# @stdout Electronの配布名 (x64またはarm64)
# @return 常に0 (未知の値では空文字を出力する)
#
_electron_arch_for() {
	case "$1" in
		amd64) echo 'x64' ;;
		arm64) echo 'arm64' ;;
		*)     echo '' ;;   # 変換できない値は空文字にして呼び出し側で扱わせる
	esac
}

#
# @brief ELFバイナリのe_machineからElectron配布物のアーキテクチャを判定する
# @param $1 判定するファイルのパス
# @stdout x64、arm64、または未知のマシン番号を表すelf-machine-<番号>
# @return 常に0 (ELFでないファイルは何も出力しない)
# @note e_machineはオフセット18のリトルエンディアン2バイトで、
#       62がx86-64、183がAArch64を表す
#
_elf_electron_arch() {
	local magic machine
	magic=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
	[[ $magic == '7f454c46' ]] || return 0
	machine=$(od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')
	case "$machine" in
		62)  echo 'x64' ;;
		183) echo 'arm64' ;;
		*)   echo "elf-machine-$machine" ;;   # 想定外の値は比較で不一致になる形で返す
	esac
}

#
# @brief 作業ディレクトリにElectronと固定バージョンのasarを用意する
# @global work_dir (参照のみ) 導入先とキャッシュの展開先に使う
# @global project_root (参照のみ) 処理の終了時に戻る先
# @global architecture (参照のみ) 同梱するElectronの対象アーキテクチャを決める
# @global source_dir (参照のみ) Electron本体を取得するスクリプトの場所
# @global chosen_electron_module_path ステージング元のElectronモジュールのパス
#       (本関数で設定する)
# @global asar_exec 使用するasar実行ファイルのパス (本関数で設定する)
# @note 導入、取得、バージョン検証のいずれかに失敗した場合はexit 1で中断する
#
setup_electron_asar() {
	section_header 'Electron & Asar Handling'

	echo "Ensuring local Electron and Asar installation in $work_dir..."
	cd "$work_dir" || exit 1

	if [[ ! -f package.json ]]; then
		echo "Creating temporary package.json in $work_dir for local install..."
		echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
	fi

	local electron_dist_path="$work_dir/node_modules/electron/dist"
	local electron_binary_path="$electron_dist_path/electron"
	local asar_bin_path="$work_dir/node_modules/.bin/asar"
	local install_needed=false
	# AnthropicがWindowsのnupkgに同梱するElectronのメジャーに合わせる
	# 3.6556.1、4.4212.0、4.23118.0はElectron 44.9.3、5.1231.2はElectron 45.2.1を同梱している
	# Electron 44 (Chromium 152) はxdg-desktop-portalのホストRegistryに
	# アプリIDを登録する最初の系列で、ランチャーが登録するポータルの
	# アプリIDはこれに依存する (docs/DECISIONS.md D-004)
	local electron_major='45'
	local installed_electron_version=''
	# Parse the Windows bundle independently of the host Node's syntax support.
	local parser_pkg="$work_dir/node_modules/acorn/package.json"
	local parser_version=''
	if [[ -f $parser_pkg ]]; then
		parser_version=$(node -p 'require(process.argv[1]).version' "$parser_pkg")
	fi
	[[ $parser_version != '8.19.0' ]] && install_needed=true

	[[ ! -x $electron_binary_path ]] && echo 'Electron distribution not found.' && install_needed=true
	[[ ! -f $asar_bin_path ]] && echo 'Asar binary not found.' && install_needed=true
	# --clean noでは作業ディレクトリを残すため、
	# 固定バージョン以外のasarが残っていれば再利用せず入れ直す
	local asar_pkg_json="$work_dir/node_modules/@electron/asar/package.json"
	local installed_asar_version=''
	if [[ -f $asar_pkg_json ]]; then
		installed_asar_version=$(node -p \
			'require(process.argv[1]).version' "$asar_pkg_json" 2>/dev/null)
	fi
	if [[ -f $asar_bin_path \
		&& $installed_asar_version != "$ASAR_PINNED_VERSION" ]]; then
		echo "Asar ${installed_asar_version:-unknown} found; @electron/asar@$ASAR_PINNED_VERSION is required."
		install_needed=true
	fi
	if [[ -x $electron_binary_path && -f $electron_dist_path/version ]]; then
		installed_electron_version=$(< "$electron_dist_path/version")
	fi
	# 作業ディレクトリが残っている場合、古いElectronを黙って
	# 再利用せずに入れ替える
	if [[ -x $electron_binary_path \
		&& ${installed_electron_version%%.*} != "$electron_major" ]]; then
		echo "Electron ${installed_electron_version:-unknown} found; Electron ${electron_major}.x is required."
		# package.jsonが既に一致しているとnpmはdist/を触らないため、
		# 消してfetch-electron-binary.jsを強制的に走らせる
		rm -rf "$electron_dist_path"
		install_needed=true
	fi
	# 同梱するElectronはビルドしたホストではなく--archで指定した対象に合わせる
	local electron_arch
	electron_arch=$(_electron_arch_for "${architecture:-}")
	local installed_electron_arch=''
	if [[ -x $electron_binary_path ]]; then
		installed_electron_arch=$(_elf_electron_arch "$electron_binary_path")
	fi
	if [[ -n $installed_electron_arch && -n $electron_arch \
		&& $installed_electron_arch != "$electron_arch" ]]; then
		echo "Electron for $installed_electron_arch found; $electron_arch is required."
		rm -rf "$electron_dist_path"
		install_needed=true
	fi

	if [[ $install_needed == true ]]; then
		echo "Installing Electron and Asar locally into $work_dir..."
		# electron@42.0.0 (2026-05-06) はdist/にバイナリを取得する
		# postinstallを廃止し、npm 12もライフサイクルスクリプトを実行しない
		# そのためdist/は下のfetch-electron-binary.jsで埋める (#584)
		#
		# 展開処理のバージョンは意図的に厳密固定にしている
		# 上流のextract-zip (2.0.1以下) には未修正のシンボリックリンク
		# 経由の攻撃に関する勧告が2件あるため
		# (GHSA-jmr9-qjv8-65gv, GHSA-7pqw-9j4j-h8q3)、展開にはElectron側が
		# 保守する堅牢化版フォークを使う
		# そのフォークはAPIをElectron内部向けと位置づけているため、
		# ^を付けずに厳密固定する
		#
		# フォークはrequire(esm)のためにnode >= 22.12.0を宣言しているが、
		# 取得スクリプトは動的import()で読み込む
		# この方法はnode 20.18.1と22.23.1で動作を確認済みで、
		# engine不一致はnpmの警告に留まる (docs/DECISIONS.md D-003)
		if ! npm install --no-save "electron@^${electron_major}" \
			"@electron/asar@$ASAR_PINNED_VERSION" \
			'@electron-internal/extract-zip@1.0.5' 'acorn@8.19.0'; then
			echo 'Failed to install Electron and/or Asar locally.' >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo 'Electron and Asar installation command finished.'
	else
		echo 'Local Electron distribution and Asar binary already present.'
	fi
	parser_version=$(node -p 'require(process.argv[1]).version' "$parser_pkg" 2>/dev/null)
	if [[ $parser_version != '8.19.0' ]]; then
		echo 'acorn@8.19.0 is required to parse the Windows bundle.' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	if [[ ! -x $electron_binary_path ]]; then
		echo 'Electron binary is missing; fetching it explicitly...'
		if ! ELECTRON_TARGET_ARCH="$electron_arch" \
			node "$source_dir/scripts/setup/fetch-electron-binary.js"; then
			echo 'Explicit Electron binary fetch failed; trying cached zip fallback.' >&2
		fi
	fi

	if [[ -x $electron_binary_path ]]; then
		echo "Found Electron distribution directory at $electron_dist_path."
		chosen_electron_module_path="$(realpath "$work_dir/node_modules/electron")"
		echo "Setting Electron module path for copying to $chosen_electron_module_path."
	else
		echo 'Explicit Electron fetch produced no binary; unpacking @electron/get cache with system unzip...'
		local electron_cache_dir="$HOME/.cache/electron"
		electron_arch=${electron_arch:-x64}
		# キャッシュには過去に取得したElectronが全て残るため、
		# 導入済みのパッケージと一致するzipだけを展開する
		local electron_pkg_version cached_zip
		electron_pkg_version=$(node -p 'require(process.argv[1]).version' \
			"$work_dir/node_modules/electron/package.json" 2>/dev/null)
		cached_zip=$(find "$electron_cache_dir" \
			-name "electron-v${electron_pkg_version:-none}-linux-${electron_arch}.zip" \
			2>/dev/null | head -1)
		if [[ -z $cached_zip ]]; then
			echo "No cached zip under $electron_cache_dir; cannot apply fallback." >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		if ! command -v unzip >/dev/null 2>&1; then
			echo "unzip not installed; cannot apply fallback. Install unzip and retry." >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		mkdir -p "$electron_dist_path"
		if ! unzip -oq "$cached_zip" -d "$electron_dist_path"; then
			echo 'unzip fallback failed.' >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo "unzip fallback populated $electron_dist_path ($(du -sh "$electron_dist_path" | awk '{print $1}'))"
		chosen_electron_module_path="$(realpath "$work_dir/node_modules/electron")"
		echo "Setting Electron module path for copying to $chosen_electron_module_path."
	fi

	installed_electron_version=''
	[[ -f $electron_dist_path/version ]] \
		&& installed_electron_version=$(< "$electron_dist_path/version")
	if [[ ${installed_electron_version%%.*} != "$electron_major" ]]; then
		echo "Electron ${installed_electron_version:-unknown} is staged;" \
			"Electron ${electron_major}.x is required." >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "Using Electron $installed_electron_version."

	if [[ -f $asar_bin_path ]]; then
		asar_exec="$(realpath "$asar_bin_path")"
		echo "Found local Asar binary at $asar_exec."
	else
		echo "Failed to find Asar binary at '$asar_bin_path' after installation attempt." >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	# 存在するだけでは不十分で、実際に起動できるかを確かめる
	# @electron/asarはenginesの下限より古いNode.jsでは起動を拒否し、
	# その拒否は放置するとずっと後の抽出処理で原因不明の失敗として現れる
	# そのため終了コードと出力の形 (先頭がバージョン文字列か) を判定し、
	# 失敗理由が入る結合出力をそのままエラーとして見せる
	local asar_report asar_probe_status asar_version
	asar_report=$("$asar_exec" --version 2>&1)
	asar_probe_status=$?
	asar_version=$("$asar_exec" --version 2>/dev/null)
	if (( asar_probe_status != 0 )) \
		|| [[ ! $asar_version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
		echo "asar is installed at '$asar_exec' but will not run:" >&2
		echo "$asar_report" >&2
		echo "This build is using Node.js" \
			"$(node --version 2>/dev/null || echo 'none')." >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	if [[ ${asar_version#v} != "$ASAR_PINNED_VERSION" ]]; then
		echo "asar at '$asar_exec' reports $asar_version;" \
			"@electron/asar@$ASAR_PINNED_VERSION is required." >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "Using asar executable: $asar_exec ($asar_version)"

	cd "$project_root" || exit 1

	if [[ -z $chosen_electron_module_path || ! -d $chosen_electron_module_path ]]; then
		echo 'Critical error: Could not resolve a valid Electron module path to copy.' >&2
		exit 1
	fi

	echo "Using Electron module path: $chosen_electron_module_path"
	echo "Using asar executable: $asar_exec"
	section_footer 'Electron & Asar Handling'
}
