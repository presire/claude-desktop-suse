#
# @file patches/_common.sh
# @brief パッチ処理で共通に使う関数と、パッチが効いたかの検証をまとめる
#
# メインプロセスのチャンク解決、検知用の仕掛け (tripwire)、
# minify済み変数名の動的な抽出、複数のパッチが前提にする修正を提供する
# 実行するスクリプトではなく、パッチのスクリプトからsourceして使う
#
# 読み込み元 : build.sh (patches/app-asar.sh経由)、scripts/verify-patches.sh
# 参照するグローバル変数 : project_root (ビルド時のみ)
# 変更するグローバル変数 : electron_var、electron_var_re、patch_noop_declared、
#                          _ANCHOR_Q、_PATCH_EFFECT_ALLOWLIST
#

#
# @brief index.jsのパスから、メインプロセス本体のJavaScriptを特定する
# @param $1 index.jsのパス
# @stdout 解決したパス (index.js自身か、index.jsがrequireするチャンク)
# @stderr 失敗した理由
# @return 0 = 解決できた、1 = 解決できなかった
# @note 上流1.19367.0以降、バンドルは分割され、index.jsは本体のチャンクを
#       requireするだけの小さなスタブになった
#       本体チャンクはindex.chunk-<ハッシュ>.jsで、名前はリリースごとに変わる
#       新しいバンドルは、本体より先に小さなランタイムのチャンクを読むこともある
#       そのためスタブのrequireをたどり、複数ある場合はLinux向けパッチが使う
#       menuBarEnabled設定を持つチャンクを1つだけ選ぶ
#       分割前の構成ではindex.jsをそのまま返す
#
# 安全のため、次の条件を守る
#   - 直接の相対CommonJS参照 (require("./...")) だけをたどる
#     素のモジュール名や、コメント・文字列の中のrequireは無視する
#   - 取り出したファイル名はindex.chunk-[A-Za-z0-9_-]+.jsに完全一致させる
#     パス区切り、".."、任意のパスは許可しない
#   - チャンクらしい参照が壊れた形で存在する場合は、旧形式とみなさず失敗する
#   - 直接のチャンク参照が複数ある場合は、menuBarEnabled設定を持つ本体チャンクが
#     ちょうど1つでなければならない
#   - 参照先が存在しない、または0バイトの場合は失敗する
#
_resolve_main_js() {
	local index_js_path="${1:-}"

	if [[ -z $index_js_path ]]; then
		echo '_resolve_main_js: index.js path is required' >&2
		return 1
	fi

	if [[ ! -f $index_js_path ]]; then
		echo "_resolve_main_js: not found: $index_js_path" >&2
		return 1
	fi

	if [[ ! -s $index_js_path ]]; then
		echo "_resolve_main_js: zero-byte file: $index_js_path" >&2
		return 1
	fi

	local build_dir
	build_dir="${index_js_path%/*}"

	# スタブがrequireしている相対パスの引数を全て取り出す
	# require("./...")とrequire('./...')の両方を対象にし、
	# requireと引数の間の空白は許す
	# 後方参照で、閉じるクォートが開いたクォートと同じ種類であることを保証する
	local -a require_paths
	mapfile -t require_paths < <(
		grep -oP "require\s*\(\s*([\"'])\./\K[^\"']+(?=\1\s*\))" \
			"$index_js_path" || true
	)

	# チャンクらしい参照を、安全なものと危険なものに分ける
	# チャンクらしい : ファイル名がindex.chunk-で始まる
	# 安全 : ^index\.chunk-[A-Za-z0-9_-]+\.js$ に完全一致する
	# 危険 : チャンクらしいが安全な形に一致しない
	#        (パス遡り、"/"を含む、ハッシュが空など)
	local -a safe_chunks=()
	local -a unsafe_refs=()
	local rp
	for rp in "${require_paths[@]}"; do
		if [[ $rp == index.chunk-* ]]; then
			if [[ $rp =~ ^index\.chunk-[A-Za-z0-9_-]+\.js$ ]]; then
				safe_chunks+=("$rp")
			else
				unsafe_refs+=("$rp")
			fi
		fi
	done

	# 危険なチャンク参照が1つでもあれば、判断せずに失敗する
	if (( ${#unsafe_refs[@]} > 0 )); then
		local joined
		joined="$(IFS=', '; printf '%s' "${unsafe_refs[*]}")"
		echo "_resolve_main_js: malformed/unsafe chunk" \
			"reference(s): $joined" >&2
		return 1
	fi

	# チャンク参照が無い場合は、分割前の単一バンドルとみなす
	if (( ${#safe_chunks[@]} == 0 )); then
		printf '%s\n' "$index_js_path"
		return 0
	fi

	# チャンクが1つだけの形は、分割が始まった最初のリリースの構成
	# index.jsと本体チャンク1つだけという並びになる
	if (( ${#safe_chunks[@]} == 1 )); then
		local chunk_path="$build_dir/${safe_chunks[0]}"
		if [[ ! -f $chunk_path ]]; then
			echo "_resolve_main_js: referenced chunk not" \
				"found: $chunk_path" >&2
			return 1
		fi
		if [[ ! -s $chunk_path ]]; then
			echo "_resolve_main_js: zero-byte chunk:" \
				"$chunk_path" >&2
			return 1
		fi

		printf '%s\n' "$chunk_path"
		return 0
	fi

	# Claude 1.44121.4で、起動用の小さなチャンクがもう1つ増えた
	# (本体チャンクより先に読み込まれる)
	# 内容を見る前に、参照先が全て実在し0バイトでないことを確認する
	# そのうえでmenuBarEnabled設定を持つチャンクを本体とみなして選ぶ
	# ハッシュ、requireの順序、相対的なファイルサイズに依存しない選び方になる
	local -a main_chunks=()
	local chunk_name chunk_path
	for chunk_name in "${safe_chunks[@]}"; do
		chunk_path="$build_dir/$chunk_name"
		if [[ ! -f $chunk_path ]]; then
			echo "_resolve_main_js: referenced chunk not" \
				"found: $chunk_path" >&2
			return 1
		fi
		if [[ ! -s $chunk_path ]]; then
			echo "_resolve_main_js: zero-byte chunk:" \
				"$chunk_path" >&2
			return 1
		fi
		if LC_ALL=C grep -aqE \
			'menuBarEnabled:[[:space:]]*' "$chunk_path"; then
			main_chunks+=("$chunk_path")
		fi
	done

	if (( ${#main_chunks[@]} == 1 )); then
		printf '%s\n' "${main_chunks[0]}"
		return 0
	fi

	# 本体チャンクを1つに絞れない場合、設定を持つチャンクが無いか複数ある
	# どちらも曖昧なので、推測せずに失敗する
	local joined
	joined="$(IFS=', '; printf '%s' "${safe_chunks[*]}")"
	echo "_resolve_main_js: multiple main chunk" \
		"references found without a unique application chunk:" \
		"$joined" >&2
	return 1
}

#
# @brief MB-1の検知用の仕掛け (tripwire) として、menuBarEnabled:!0が
#        メインプロセスのJavaScriptに残っているかを確認する
# @param $1 メインプロセスのJavaScriptのパス
# @stderr 見つからない場合の診断メッセージ
# @return 0 = 見つかった、1 = 見つからない
# @note この設定は、メニューバーを表示したままにする既定値で、
#       トレイのパッチが前提にしている
#       上流が既定値を反転させると、Linuxではメニューバーが既定で
#       非表示になってしまう
#
_check_mb1_tripwire() {
	local main_js_path="${1:-}"

	if [[ -z $main_js_path || ! -f $main_js_path ]]; then
		echo '_check_mb1_tripwire: main JS path is required' \
			'and must exist' >&2
		return 1
	fi

	if ! LC_ALL=C grep -aqE \
		'menuBarEnabled:[[:space:]]*!0' "$main_js_path"; then
		echo 'Tripwire (MB-1): "menuBarEnabled:!0" is gone from' \
			'the bundle — upstream may have flipped the menu-bar' \
			'default. Re-evaluate the tray patches before' \
			'shipping.' >&2
		return 1
	fi
	return 0
}

#
# @brief minify済みバンドルからelectronモジュールの変数名を取り出す
# @global main_js (参照のみ)
# @global electron_var 取り出した変数名 (本関数で設定する)
# @global electron_var_re sed/PCREで使えるよう$をエスケープした名前
#                         (本関数で設定する)
# @note 取り出せない場合は、project_rootに戻ってから終了コード1で終了する
#
extract_electron_variable() {
	echo 'Extracting electron module variable name...'

	electron_var=$(grep -oP '[$\w]+(?=\s*=\s*require\("electron"\))' \
		"$main_js" | head -1)
	if [[ -z $electron_var ]]; then
		electron_var=$(grep -oP '(?<=new )[$\w]+(?=\.Tray\b)' \
			"$main_js" | head -1)
	fi
	if [[ -z $electron_var ]]; then
		echo 'Failed to extract electron variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	electron_var_re="${electron_var//\$/\\$}"
	echo "  Found electron variable: $electron_var"
	_declare_patch_noop
	echo '##############################################################'
}

#
# @brief nativeThemeを誤った変数から参照している箇所をelectron変数に直す
# @global main_js (参照のみ)
# @global electron_var (参照のみ)
# @global electron_var_re (参照のみ)
# @note 直す箇所が無い場合は、何も変更しない処理として記録する
#
fix_native_theme_references() {
	echo 'Fixing incorrect nativeTheme variable references...'

	local wrong_refs
	mapfile -t wrong_refs < <(
		grep -oP '[$\w]+(?=\.nativeTheme)' "$main_js" \
			| sort -u \
			| grep -Fxv "$electron_var" || true
	)

	if (( ${#wrong_refs[@]} == 0 )); then
		echo '  All nativeTheme references are correct'
		_declare_patch_noop
		echo '##############################################################'
		return
	fi

	local ref ref_re
	for ref in "${wrong_refs[@]}"; do
		echo "  Replacing: $ref.nativeTheme -> $electron_var.nativeTheme"
		ref_re="${ref//\$/\\$}"
		sed -i -E \
			"s/${ref_re}\.nativeTheme/${electron_var_re}.nativeTheme/g" \
			"$main_js"
	done
	echo '##############################################################'
}

# minify済みのJavaScriptのアンカーに使うクォートの集合
# 上流がminifierを入れ替え (Debian #820)、ほぼ全ての文字列リテラルを
# バッククォートのテンプレートとして出力し直した
# そのため半角二重引用符だけで書いたアンカーは、新しいバンドルに一致しない
# アンカーの区切りは必ず_ANCHOR_Qで表す
_ANCHOR_Q='[`"'"'"']'

#
# @brief アンカーがファイル内で一致する件数を数える
# @param $1 対象のファイル
# @param $2 検索するPCRE
# @stdout 一致件数 (ファイルが無い、または読めない場合は0)
# @return 常に0
#
_count_anchor_matches() {
	local file="${1:-}"
	local pattern="${2:-}"
	local count

	if [[ -z $file || -z $pattern || ! -f $file ]]; then
		printf '0\n'
		return 0
	fi
	count=$(grep -oP -- "$pattern" "$file" 2>/dev/null | wc -l)
	count=$(printf '%s' "$count" | tr -d '[:space:]')
	if [[ -z $count ]]; then
		count=0
	fi
	printf '%s\n' "$count"
	return 0
}

#
# @brief アンカーがファイル内の1箇所だけに一致することを確認する
# @param $1 対象のファイル
# @param $2 検索するPCRE
# @param $3 診断メッセージに出すアンカーの名前
# @stderr 一致件数が1でない場合の警告
# @return 0 = 1箇所だけ一致した、1 = それ以外
# @note 2箇所以上に一致したまま最初の箇所を書き換えると、
#       意図しない場所を壊すため、呼び出し側は警告を出してパッチを飛ばす
#       一致0件もアンカーの見落としとして警告するが、
#       Windowsのインストーラ由来のバンドルに無いことが不具合とは限らないため、
#       失敗にはせず飛ばすだけにする
#
_assert_single_anchor_match() {
	local file="${1:-}"
	local pattern="${2:-}"
	local label="${3:-anchor}"
	local count

	count=$(_count_anchor_matches "$file" "$pattern")
	if [[ $count -eq 1 ]]; then
		return 0
	fi
	if [[ $count -eq 0 ]]; then
		echo "  WARNING: anchor '$label' not found in" \
			"$(basename "$file") — skipping" >&2
	else
		echo "  WARNING: anchor '$label' matched $count sites" \
			'in '"$(basename "$file")"'(expected 1) — skipping' \
			'to avoid patching the wrong one' >&2
	fi
	return 1
}

#
# @brief app.asar.contents/.vite/build配下の全ファイルのダイジェストを取る
# @stdout 16進数のダイジェスト
# @return 0 = 取得できた、1 = ディレクトリが無い、または空
# @note パッチはこのディレクトリに書き込む前提なので、
#       別の場所に書き込むパッチはこの検査では検出できない
#       対象が無いときに定数へ丸めると、再実行時に両辺が一致して
#       誤って合格するため、その場合は失敗させる
#       相対パスはパッチ適用時のカレントディレクトリ (ステージング先) を基準にする
#
_patch_bundle_digest() {
	local build_dir='app.asar.contents/.vite/build'
	local probe

	if [[ ! -d $build_dir ]]; then
		return 1
	fi
	probe=$(find "$build_dir" -type f -print -quit)
	if [[ -z $probe ]]; then
		return 1
	fi
	find "$build_dir" -type f -print0 | LC_ALL=C sort -z \
		| xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

#
# @brief パッチ段階を再実行する前後で、バンドルのバイト列が変わらないことを確認する
# @param $1 再実行前のダイジェスト
# @param $2 再実行後のダイジェスト
# @stderr ダイジェストが異なる場合の診断メッセージ
# @return 0 = 変化なし、1 = 変化あり
# @note 1バイトでも変わった場合は、パッチの冪等性ガードが自分の出力を
#       見落として二重に適用している
#       再実行はPATCH_STAGE_RERUN=1を指定したときだけ行う
#
_check_patch_stage_idempotent() {
	local before="${1:-}"
	local after="${2:-}"

	if [[ -z $before || -z $after ]]; then
		echo 'Idempotency: missing bundle digest — cannot' \
			'verify the re-run left the bundle unchanged' >&2
		return 1
	fi
	if [[ $before == "$after" ]]; then
		return 0
	fi
	echo 'Idempotency: second patch pass over the already-patched' \
		'bundle changed bytes — a patch guard misses its own' \
		'output and re-applies. Refuse to ship.' >&2
	return 1
}

# 何も変更しないことが意図的で、レビュー済みのパッチ関数を並べる
# それ以外の関数は、最初の実行で必ず.vite/buildを変更しなければならない
# ダイジェストが変わらない場合はアンカーがずれた可能性が高く、
# そのままでは上流の挙動のまま静かに出荷されてしまう
# 各項目には根拠を1行で添え、固定バージョンを更新するたびに見直す
#
# ここに書いてよいのは、そのパッチ自身が想定した分岐として何も変更しない場合だけ
# 上流の形が変わって修正が不要になった場合か、ファイルに書き込まない関数に限る
# 適用されるはずのパッチが適用されなかった場合は、許可リストに足すのではなく
# 調査すべき問題として扱う
# -gを付けるのは、Batsがsetup()からこのファイルをsourceするため
# 単なるdeclareでは関数内のローカル配列になってしまう
declare -gA _PATCH_EFFECT_ALLOWLIST=(
	[extract_electron_variable]='records the minified electron identifier in globals only; writes no file'
	[fix_native_theme_references]='5.1231.2 emits only the correct nativeTheme owner, so there is nothing to rewrite'
	[patch_tray_menu_handler]='5.1231.2 already updates the Tray in place, making the DBus mutex and delay obsolete'
	[patch_tray_inplace_update]='5.1231.2 already has the in-place setImage path this fast path would inject'
	[patch_menu_bar_default]='5.1231.2 already defaults menuBarEnabled:!0 in its defaults map'
	[patch_linux_claude_code]='5.1231.2 already maps linux-x64/linux-arm64 to the bundled Claude Code binary'
	[patch_virtiofsd_probe]='the Windows-derived 5.1231.2 bundle contains no virtiofsd probe to un-gate'
)

# パッチがレビュー済みの「何も変更しない」分岐に入ったことを示すフラグ
# _run_suse_patch_functionが各パッチの実行前に空にする
patch_noop_declared=''

#
# @brief レビュー済みの「何も変更しない」分岐に入ったことを記録する
# @global patch_noop_declared フラグ (本関数で設定する)
# @note _check_patch_effectが、アンカーのずれと意図した無変更を区別するために使う
#
_declare_patch_noop() {
	patch_noop_declared='1'
}

#
# @brief 実行したパッチがバンドルを実際に変更したかを判定する
# @param $1 パッチ関数の名前
# @param $2 実行前のダイジェスト
# @param $3 実行後のダイジェスト
# @param $4 何も変更しない分岐に入ったことを示すフラグ (1のとき宣言済み)
# @stderr 判定に失敗した場合、関数名を含む診断メッセージ
# @return 0 = 変更した、または宣言済みの許可リスト内の無変更、1 = それ以外
# @note ダイジェストが変われば有効とみなす
#       変わらない場合は_PATCH_EFFECT_ALLOWLISTに載っている関数だけを許可し、
#       それ以外はアンカーがずれた可能性があるため、パッチ段階を失敗させる
#       許可リスト内の関数でも_declare_patch_noopを呼んでいなければ、
#       アンカーを見落として素通りしたことになるため失敗させる
#
_check_patch_effect() {
	local fn="${1:-}"
	local before="${2:-}"
	local after="${3:-}"
	local declared="${4:-}"

	if [[ -z $fn || -z $before || -z $after ]]; then
		echo "Patch effect: missing digest for '${fn:-<unknown>}' —" \
			'cannot prove the patch changed the bundle' >&2
		return 1
	fi
	if [[ $before != "$after" ]]; then
		echo "Patch effect: $fn changed the bundle (effective)"
		return 0
	fi
	if [[ -n ${_PATCH_EFFECT_ALLOWLIST[$fn]:-} && $declared == '1' ]]; then
		echo "Patch effect: $fn is an allowlisted no-op —" \
			"${_PATCH_EFFECT_ALLOWLIST[$fn]}"
		return 0
	fi
	if [[ -n ${_PATCH_EFFECT_ALLOWLIST[$fn]:-} ]]; then
		echo "Patch effect: '$fn' is allowlisted but did not reach" \
			'its reviewed no-op branch (_declare_patch_noop), so' \
			'its anchor most likely drifted.' >&2
		return 1
	fi
	echo "Patch effect: '$fn' left" \
		'app.asar.contents/.vite/build byte-identical.' \
		'Its anchor may have drifted, or it is a new intentional' \
		'no-op that needs a reviewed entry in' \
		'_PATCH_EFFECT_ALLOWLIST (scripts/patches/_common.sh).' >&2
	return 1
}
