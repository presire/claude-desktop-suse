#
# @file patches/tray.sh
# @brief トレイのメニューとアイコンをLinuxで正しく動くようにする
#
# トレイのメニュー再構築の排他制御、テーマに応じたアイコンの選択、
# Linuxでのコンテキストメニューの維持、menuBarEnabledの既定値を扱う
#
# 読み込み元 : build.sh (patches/app-asar.shのパッチ段階から呼ばれる)
# 参照するグローバル変数 : project_root、electron_var、electron_var_re、main_js
# 変更するグローバル変数 : なし
#

#
# @brief トレイのメニュー再構築を排他制御し、DBusの後始末を待つようにする
# @global main_js (参照のみ: メインプロセスのJavaScriptのパス)
# @global project_root (参照のみ: 失敗したときに戻るディレクトリ)
# @note 上流が既にその場で更新する形になっている場合は何も変更しない
#       アンカーはmenuBarEnabledの監視関数の形で、関数名はリリースごとに変わる
#       名前を取り出せない場合は、ビルドを止める
#
patch_tray_menu_handler() {
	echo 'Patching tray menu handler...'
	local index_js="$main_js"

	local tray_func tray_func_re tray_var tray_var_re
	tray_func=$(grep -oP \
		'on\("menuBarEnabled",\(*\(\)=>\{\K[\w$]+(?=\(\)\})' "$index_js")
	if [[ -z $tray_func ]]; then
		echo 'Failed to extract tray menu function name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found tray function: $tray_func"

	# minifierはi$Aのような$を含む識別子を出力する
	# PCREとsed -Eでは$が行末の指定として働いてしまうため
	# パターンに埋め込む前にエスケープする
	tray_func_re="${tray_func//\$/\\$}"

	tray_var=$(grep -oP \
		'[$\w]+(?=\s*=\s*new\s+[$\w]+\.Tray\()' "$index_js" | head -1)
	if [[ -z $tray_var ]]; then
		echo 'Failed to extract tray variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found tray variable: $tray_var"
	tray_var_re="${tray_var//\$/\\$}"

	# Claude 1.44121.4は、トレイの画像をその場で更新して
	# 破棄と作成の経路を通らずに戻る
	# この排他制御と待ち時間は、DBusの後始末の競合を抑えるために入れていた
	# 新しい経路ではその競合が起きないため、
	# 古いバンドル向けのパッチは残しつつ、
	# 新しい同期更新の経路には手を入れない
	if grep -qP \
		"${tray_var_re}&&!${tray_var_re}\.isDestroyed\(\)\)\{[^{}]{0,500}${tray_var_re}\.setImage\(" \
		"$index_js"; then
		echo '  Upstream tray updater already updates in place; no mutex needed'
		echo 'Tray menu handler patch not needed'
		_declare_patch_noop
		echo '##############################################################'
		return
	fi

	# 上流が既に関数をasync付きで出している場合がある (1.8089.1がそう)
	# そのままsedを再適用するとasync async functionになり、
	# (?:async )?function NAMEを照合する後続のパッチが壊れる
	if ! grep -q "async function ${tray_func}(){" "$index_js"; then
		sed -i -E "s/function\s+${tray_func_re}\s*\(\s*\)\s*\{/async function ${tray_func}(){/g" \
			"$index_js"
	fi

	# 後から来た要求を拾う排他制御
	# 再構築の途中に来た要求を取りこぼさず、終わった時点で1度だけ再実行するため
	# 最後のnativeThemeの値が勝つ
	# 単純に先着を捨てる方式でも再入による再構築は防げる
	# 遅い経路のDBus待ち250ミリ秒の間に他の要求が割り込むため
	# ただし捨てる方式では、起動直後の値を固定してしまう
	# 起動直後はshouldUseDarkColorsが約50ミリ秒falseを返し、
	# その後に"updated"イベントがまとめて届いてtrueに変わる
	# 捨てる方式だと最初の誤った値を残し、
	# 暗いパネルでトレイアイコンが黒いまま止まる
	# 詳しくはdocs/learnings/tray-rebuild-race.mdを参照する
	if ! grep -q "${tray_func}._running" "$index_js"; then
		sed -i -E "s/async\s+function\s+${tray_func_re}\s*\(\s*\)\s*\{/async function ${tray_func}(){if(${tray_func}._running){${tray_func}._pending=true;return}${tray_func}._running=true;setTimeout(()=>{${tray_func}._running=false;if(${tray_func}._pending){${tray_func}._pending=false;${tray_func}()}},1500);/g" \
			"$index_js"
		echo "  Added trailing-edge mutex guard to ${tray_func}()"
	fi

	# トレイを破棄した後に、DBusの後始末が終わるまで待つ
	if ! grep -q "await new Promise.*setTimeout.*${tray_var_re}" "$index_js"; then
		sed -i -E "s/${tray_var_re}\s*\&\&\s*\(\s*${tray_var_re}\.destroy\(\)\s*,\s*${tray_var_re}\s*=\s*null\s*\)/${tray_var}\&\&(${tray_var}.destroy(),${tray_var}=null,await new Promise(r=>setTimeout(r,250)))/g" \
			"$index_js"
		echo "  Added DBus cleanup delay after $tray_var.destroy()"
	fi

	echo 'Tray menu handler patched'
	echo '##############################################################'
}

#
# @brief Linuxでも見えるトレイアイコンを選ぶよう、アイコンの種類とテーマ対応を直す
# @global main_js (参照のみ)
# @global electron_var_re (参照のみ: nativeThemeを持つelectronの変数名)
# @note 上流が既にLinuxを扱っている場合は何も変更しない
#       上流の書式は複数あるため、適用済みかどうかを先に確認する
#
patch_tray_icon_selection() {
	echo 'Patching tray icon selection for Linux visibility...'
	local index_js="$main_js"
	local dark_check="${electron_var_re}.nativeTheme.shouldUseDarkColors"
	local icon_type_count

	if grep -qF 'switch(process.platform==="win32"?"ico":"png")' \
		"$index_js"; then
		echo 'Tray icon type already uses PNG on Linux'
	elif [[ $(grep -oF 'switch("ico")' "$index_js" | wc -l) -eq 1 ]]; then
		# Claude 1.44121.4でトレイの種類の指定が代入からリテラルのswitchに変わった
		# Linuxでは既にあるPNGの分岐を選ぶ
		sed -i \
			's/switch("ico")/switch(process.platform==="win32"?"ico":"png")/' \
			"$index_js"
		echo 'Patched tray icon switch to use PNG on Linux'
	else
		icon_type_count=$(grep -oP '[$\w]+="ico"' "$index_js" | wc -l)
	fi

	if [[ -n ${icon_type_count:-} && $icon_type_count -eq 1 ]]; then
		sed -i -E \
			's/([[:alnum:]_\$]+)="ico"/\1=process.platform==="win32"?"ico":"png"/' \
			"$index_js"
		echo 'Patched tray icon type to use PNG on Linux'
	elif [[ -n ${icon_type_count:-} ]] && \
		grep -qF 'process.platform==="win32"?"ico":"png"' "$index_js"; then
		echo 'Tray icon type already uses PNG on Linux'
	elif [[ -n ${icon_type_count:-} ]]; then
		echo "WARNING: expected exactly 1 tray icon type assignment" \
			"\`=\"ico\"\`, found ${icon_type_count}; PNG tray" \
			"type patch not applied" >&2
	fi

	# テーマに応じた選択には、上流の書式が2つある
	# 古い書式 (1.44121.4より前) は、:X="TrayIconTemplate.png"という代入で、
	# 暗い版をnativeTheme.shouldUseDarkColorsで選ぶ
	# 現在の書式 (1.44121.4以降、2.37337.1を含む) では、
	# 種類を選ぶ関数の"png"分岐が既にTrayIconLinux-Dark.pngと
	# TrayIconLinux.pngを選び分ける
	# 選び分けには強制の引数、GNOMEかどうかの判定、
	# nativeTheme.shouldUseDarkColorsを使う
	# 例 : case"png":return e||pxn()==="gnome"||a.nativeTheme
	#      .shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png"
	# 上の種類の判定を直せばLinuxはこの分岐に入り、
	# template-imageの分岐はmacOS専用なので関係しない
	# SUSE版の--darkは成果物の段階でファイルを差し替えるため
	# (scripts/staging/icons.sh)、コードの変更は要らない
	# それでもこの形を認識しておくのは、ビルドログを正直に保つため
	# (docs/CONFIGURATION.md : トレイアイコンは実行時に
	# デスクトップのテーマから選ばれる)
	# 適用済みかどうかの確認を先に行う
	# 差し込む三項演算子は明るい側としてTrayIconTemplate.pngを再度出力するため、
	# 古いアンカーを先に試すと自分の出力に再び一致してしまう
	if grep -qF "${dark_check}?\"TrayIconTemplate-Dark.png\":\"TrayIconTemplate.png\"" \
		"$index_js"; then
		echo 'Tray icon selection already patched for Linux theme support'
	elif grep -qP ':[$\w]+="TrayIconTemplate\.png"' "$index_js"; then
		sed -i -E \
			"s/:([[:alnum:]_\$]+)=\"TrayIconTemplate\.png\"/:\1=${dark_check}?\"TrayIconTemplate-Dark.png\":\"TrayIconTemplate.png\"/g" \
			"$index_js"
		echo 'Patched tray icon selection for Linux theme support'
	# パターン末尾の\)?は、patch_tray_icon_env_overrideが条件を包む
	# 閉じ括弧を許すため
	# そのためPATCH_STAGE_RERUNの再実行でも、警告ではなく
	# 三項演算子として認識できる
	elif grep -qP "nativeTheme\.shouldUseDarkColors\s*\)?\s*\?\s*[\"'\x60]TrayIconLinux-Dark\.png[\"'\x60]\s*:\s*[\"'\x60]TrayIconLinux\.png[\"'\x60]" \
		"$index_js"; then
		echo 'Upstream tray icon selection already handles Linux' \
			'theme (TrayIconLinux-Dark.png vs TrayIconLinux.png);' \
			'no patch needed'
	else
		echo 'WARNING: tray icon theme-selection anchor not found' \
			'(neither legacy TrayIconTemplate assignment nor' \
			'TrayIconLinux ternary) — theme patch not applied' >&2
	fi
	echo '##############################################################'
}

#
# @brief 上流のLinux向けトレイアイコンの三項演算子に
#        CLAUDE_TRAY_USE_DARK_ICONを組み込む
# @global main_js (参照のみ: アンカーを探す起点)
# @global project_root (参照のみ: 失敗したときに戻るディレクトリ)
# @stderr アンカーが無い場合や、対象が複数ある場合のメッセージ
# @return 0 = 何も変更しない場合を含めて正常、1 = 失敗 (ビルドを止める)
# @note claude-desktop-debianの#604と#820から移植した
#       上流のデスクトップ環境の判定はkde、gnome、otherしか知らないため、
#       Cinnamonの暗いパネルと明るいGTKテーマの組み合わせでは
#       黒いTrayIconLinux.pngが選ばれてしまう
#       ランチャーのsetup_tray_icon_envがこの環境変数をexportする
#       値は3通りで、"1"はTrayIconLinux-Dark.png、"0"はTrayIconLinux.png、
#       それ以外は上流の選択をそのまま使う
#       読み取りはnativeThemeの"updated"で再実行される選択関数の中にあるため、
#       テーマの再構築をまたいでも効き続ける
#       TrayIconLinuxのリテラルが無いバンドル (古いTrayIconTemplateの形) では
#       警告を出して飛ばし、この環境変数は何もしない
#       リテラルがあるのに三項演算子の形が変わった場合は、
#       ドキュメントで案内しているのに効かない状態を出荷しないよう、
#       ビルドを失敗させる
#
patch_tray_icon_env_override() {
	echo 'Patching Linux tray icon selection (CLAUDE_TRAY_USE_DARK_ICON)...'
	local literal_re
	literal_re='[`"'"'"']TrayIconLinux-Dark\.png[`"'"'"']\s*:\s*'
	literal_re+='[`"'"'"']TrayIconLinux\.png[`"'"'"']'

	# アンカーは通常main_jsにあるが、以前のリリースでは入口のファイルへ
	# 移ったことがあるため (#820)、内容から探す
	local index_js='' candidate
	local -a hits=()
	# -zはファイル全体を1つのレコードとして読むため、
	# 整形されて行をまたぐ三項演算子にも一致する
	if grep -qPz -- "$literal_re" "$main_js"; then
		hits=("$main_js")
	else
		for candidate in "${main_js%/*}"/*.js; do
			[[ -f $candidate ]] || continue
			grep -qPz -- "$literal_re" "$candidate" && hits+=("$candidate")
		done
	fi
	if [[ ${#hits[@]} -eq 0 ]]; then
		echo 'WARNING: TrayIconLinux literals not found (legacy tray' \
			'shape?) — CLAUDE_TRAY_USE_DARK_ICON is inert in this' \
			'build' >&2
		echo '##############################################################'
		return 0
	fi
	if [[ ${#hits[@]} -ne 1 ]]; then
		echo "ERROR: TrayIconLinux literals found in ${#hits[@]}" \
			"files (${hits[*]}); refusing to guess" >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	index_js=${hits[0]}

	if ! INDEX_JS="$index_js" node << 'TRAY_ICON_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

const flag = 'process.env.CLAUDE_TRAY_USE_DARK_ICON';
const applied = flag + '==="1"||' + flag + '!=="0"&&(';

// The retained prefix must END an expression, so its last token has to
// be an allowlisted punctuator or `return`. A denylist would let
// `await lt()` / `this.#lt()` through and splice into the middle of an
// expression (the Debian #820 mispatch: p.process.env.CLAUDE_...).
// `&` is absent on purpose: an `a&&` prefix would be absorbed by the
// injected ||-chain. `||` is admitted because upstream ships
// `e||<callee>()`; there "0" cannot override a truthy `e` (upstream's
// own force-dark argument), which this patch cannot reach. A lone `|`
// is a bitwise operator, and a `=` only counts as an assignment when no
// `=!<>` precedes it: `===`, `!=`, `<=`, `>=` end a comparison operand,
// so splicing after them changes the comparison's meaning.
const spliceSafe = i => {
    const tail = code.slice(0, i).replace(/\s+$/, '');
    return tail === '' ||
        /(?:[(,;:?{[]|=>|\|\||(?<![=!<>])=)$/.test(tail) ||
        /(?:^|[^\w$.])return$/.test(tail);
};

// Idempotency keys on the identifier-free injected prefix, and every
// occurrence must start an expression: a copy glued to an identifier
// means a prior run spliced mid-expression, i.e. a corrupt bundle.
const seen = [];
for (let i = code.indexOf(applied); i !== -1;
        i = code.indexOf(applied, i + 1)) {
    seen.push(i);
}
if (seen.length) {
    if (seen.every(spliceSafe)) {
        console.log('  Tray icon env override already applied');
        process.exit(0);
    }
    console.log('  ERROR: the injected tri-state does not start an ' +
        'expression (e.g. p.' + flag + '); the bundle is corrupt. ' +
        'Re-extract a pristine asar and re-run.');
    process.exit(1);
}

// <callee>()==="gnome"||<electron>.nativeTheme.shouldUseDarkColors
//   ?"TrayIconLinux-Dark.png":"TrayIconLinux.png"
// The callee accepts the bundler indirect-call shape ((0,i.oPe)()) and
// a plain property chain (p.lt()); q() accepts any string delimiter
// because minifiers re-emit literals as backtick templates.
const q = s => '[`"\']' + s + '[`"\']';
const ternRe = new RegExp(
    String.raw`((?:\(0,\s*[\w$]+(?:\.[\w$]+)*\)|[\w$]+(?:\.[\w$]+)*))` +
    `\\(\\)\\s*===\\s*${q('gnome')}\\s*\\|\\|\\s*` +
    String.raw`([\w$]+(?:\.[\w$]+)*)\.nativeTheme\.shouldUseDarkColors` +
    `\\s*\\?\\s*${q('TrayIconLinux-Dark\\.png')}` +
    `\\s*:\\s*${q('TrayIconLinux\\.png')}`,
    'g');
const matches = [...code.matchAll(ternRe)];
if (matches.length !== 1) {
    console.log('  ERROR: expected exactly 1 TrayIconLinux ternary, ' +
        'found ' + matches.length);
    process.exit(1);
}

const m = matches[0];
if (!spliceSafe(m.index)) {
    console.log('  ERROR: TrayIconLinux ternary matched mid-expression' +
        ' (prefix ends "' + code.slice(0, m.index).slice(-16) + '"); ' +
        'widen the callee capture in scripts/patches/tray.sh');
    process.exit(1);
}

// Built by concatenation so no `$` lands in a replace() pattern.
const cond = applied +
    m[1] + '()==="gnome"||' +
    m[2] + '.nativeTheme.shouldUseDarkColors)';
const replacement =
    cond + '?"TrayIconLinux-Dark.png":"TrayIconLinux.png"';
code = code.substring(0, m.index) + replacement +
    code.substring(m.index + m[0].length);
fs.writeFileSync(indexJs, code);
console.log('  Tray icon ternary (' + m[1] + '/' + m[2] +
    ') now honors CLAUDE_TRAY_USE_DARK_ICON (1=dark-panel, 0=plain)');
TRAY_ICON_PATCH
	then
		echo 'ERROR: tray icon env-override patch failed; without it' \
			'CLAUDE_TRAY_USE_DARK_ICON is inert. Re-derive the anchor' \
			'in scripts/patches/tray.sh against the new bundle, or' \
			'retire the patch if upstream learned about Cinnamon.' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo 'Tray icon env override applied'
	echo '##############################################################'
}

#
# @brief テーマが変わったときにトレイをその場で更新する高速な経路を差し込む
# @global main_js (参照のみ)
# @global electron_var (参照のみ)
# @global project_root (参照のみ)
# @note 上流が既にその場で更新している場合や、前提となる名前を取り出せない場合は
#       何も変更しない
#       高速な経路が入らないと#515のアイコン重複の競合が再発するため、
#       取り出せなかった場合は警告を出す
#
patch_tray_inplace_update() {
	echo 'Patching tray rebuild to update in-place on theme change...'
	local index_js="$main_js"

	# patch_tray_menu_handlerはトレイの変数名をlocalで宣言するため、
	# ここからは見えない
	# 同じパターンでもう一度取り出す
	local tray_func local_tray_var tray_var_re
	local menu_func menu_var menu_var_re path_var enabled_var enabled_count
	tray_func=$(grep -oP \
		'on\("menuBarEnabled",\(*\(\)=>\{\K[\w$]+(?=\(\)\})' "$index_js")
	if [[ -z $tray_func ]]; then
		echo '  Could not find tray function — skipping'
		echo '##############################################################'
		return
	fi
	local_tray_var=$(grep -oP \
		'[$\w]+(?=\s*=\s*new\s+[$\w]+\.Tray\()' "$index_js" | head -1)
	if [[ -z $local_tray_var ]]; then
		echo '  Could not extract tray variable name — skipping'
		echo '##############################################################'
		return
	fi
	echo "  Found tray variable: $local_tray_var"

	tray_var_re="${local_tray_var//\$/\\$}"

	# 新しいバンドルは既にトレイの実体を保持したまま、
	# 解決したアイコンのパスが変わったときにsetImage()を呼ぶ
	# そのため、別々に分かれた更新と作成の関数には
	# 古い高速な経路を差し込まない
	if grep -qP \
		"${tray_var_re}&&!${tray_var_re}\.isDestroyed\(\)\)\{[^{}]{0,500}${tray_var_re}\.setImage\(" \
		"$index_js"; then
		echo '  Upstream tray updater already has an in-place setImage path'
		_declare_patch_noop
		echo '##############################################################'
		return
	fi

	# コンテキストメニューの組み立て方には、上流の書式が2つある
	# 古い書式は、トレイ変数.setContextMenu(BUILDER())で組み立てをその場で呼ぶ
	# 新しい書式は、M=BUILDER()で先に組み立てたメニューを渡す
	# どちらの書式でもBUILDERの名前を解決する
	# 差し込む高速な経路はsetContextMenu(BUILDER())を出力するため、
	# メニューのオブジェクトMを選んでしまうとsetContextMenu(M())になり、
	# 実行時に例外になる (MはMenuの実体で関数ではない)
	menu_func=$(grep -oP "${tray_var_re}\.setContextMenu\(\K[\$\w]+(?=\(\))" \
		"$index_js" | head -1)
	if [[ -z $menu_func ]]; then
		# 先に組み立てたメニューを渡す書式
		# 素朴にhead -1を使うと、1.13576以降のバンドルで2つのはまり所がある
		# 1つ目は、最初のsetContextMenuの呼び出しがメニューの消去
		# (無効化時のsetContextMenu(null)) なので、
		# 最初の引数を取ると文字列nullを得てしまうこと
		# 2つ目は、メニューのオブジェクトが組み立て関数の戻り値として
		# 名前で代入される (M=BUILDER()) ため、
		# 組み立て関数まで1段たどる必要があること
		# そこでsetContextMenuの引数を全て順に見てnullの消去を飛ばし、
		# VAR=BUILDER()の代入として解決できる最初のものを取る
		# 単語境界の後読みを付けると、区切りの後でも宣言子の後でも
		# (letやconstの後は変数の前に空白が残る) 代入を解決できる
		while IFS= read -r menu_var; do
			[[ -z $menu_var || $menu_var == 'null' ]] && continue
			menu_var_re="${menu_var//\$/\\$}"
			menu_func=$(grep -oP \
				"(?<![\$\w])${menu_var_re}=\K[\$\w]+(?=\(\))" \
				"$index_js" | head -1)
			[[ -n $menu_func ]] && break
		done < <(grep -oP \
			"${tray_var_re}\.setContextMenu\(\K[\$\w]+(?=\))" "$index_js")
	fi
	if [[ -z $menu_func ]]; then
		# その場で探す検索も、メニューの変数からのフォールバックも空だった
		# ここで黙って飛ばすと、以前に#515のアイコン重複の競合が再発した
		# 次に黙って壊れたときにCIのログで分かるよう、stderrに出す
		# ただしビルドは最後まで進める
		echo "WARNING: could not resolve tray menu function" \
			"(inline + fallback both failed) — in-place" \
			"fast-path NOT applied; duplicate-icon race" \
			"(#515) may regress" >&2
		echo '##############################################################'
		return
	fi
	echo "  Found menu function: $menu_func"

	# 元の呼び出しで使われているアイコンのパスのローカル変数を取り出す
	#   Nh = new pA.Tray(pA.nativeImage.createFromPath(X))
	# そのXは、関数の前半でpath.join(resourcesDir(), suffix)を
	# 代入されたconst
	# minifierがリリースごとに名前を変えるため、直書きせず取り出す
	path_var=$(grep -oP \
		"${tray_var_re}=new ${electron_var_re}\.Tray\(${electron_var_re}\.nativeImage\.createFromPath\(\K[\$\w]+(?=\))" \
		"$index_js" | head -1)
	if [[ -z $path_var ]]; then
		echo '  Could not extract icon-path var — skipping'
		echo '##############################################################'
		return
	fi
	echo "  Found icon-path var: $path_var"

	# menuBarEnabledのローカル変数を取り出す
	# 差し込む高速な経路は、遅い経路の破棄と再作成の処理が調べるのと
	# 同じローカル変数を読む必要があり、別の箇所に結び付けると黙って壊れる
	# 上流が2箇所以上で宣言するようになった場合は、
	# 最初の1つを取らずに中断する
	enabled_count=$(grep -cP \
		'const [$\w]+\s*=\s*[$\w]+\("menuBarEnabled"\)' "$index_js")
	if [[ $enabled_count -ne 1 ]]; then
		echo "  Expected 1 menuBarEnabled declaration, found" \
			"${enabled_count} — skipping"
		echo '##############################################################'
		return
	fi
	enabled_var=$(grep -oP \
		'const \K[$\w]+(?=\s*=\s*[$\w]+\("menuBarEnabled"\))' "$index_js")
	if [[ -z $enabled_var ]]; then
		echo '  Could not extract menuBarEnabled var — skipping'
		echo '##############################################################'
		return
	fi
	echo "  Found menuBarEnabled var: $enabled_var"

	# 冪等性のための確認
	# 高速な経路が入った後は、再実行しても何も変わらない
	# 目印は、名前を解決した後のsetImage(EL.nativeImage.createFromPath(PATH_VAR))
	# という並びにする
	# 破棄と再作成の遅い経路は後ろに残るため、
	# setImageの出現回数を数えるだけでは判定できない
	local fast_path_marker
	fast_path_marker="${local_tray_var}.setImage(${electron_var}.nativeImage.createFromPath(${path_var}))"
	if grep -qF "$fast_path_marker" "$index_js"; then
		echo '  In-place fast-path already present (idempotent)'
		echo '##############################################################'
		return
	fi

	# 既存の破棄と再作成の処理の前に、高速な経路を差し込む
	# トレイが既にあり、無効化されていない場合は、
	# setImageとsetContextMenuでその場で更新する
	# これにより、Plasmaが古い項目 (まだ登録が解除されていない) と
	# 新しいStatusNotifierItemを一時的に両方表示するDBusの競合を避ける
	# 破棄と再作成の遅い経路は、初回の作成とトレイの無効化のために残す
	if ! TRAY_VAR="$local_tray_var" EL_VAR="$electron_var" \
		MENU_FUNC="$menu_func" PATH_VAR="$path_var" \
		ENABLED_VAR="$enabled_var" INDEX_JS="$main_js" \
		node -e "
const fs = require('fs');
const p = process.env.INDEX_JS;
const T = process.env.TRAY_VAR;
const E = process.env.EL_VAR;
const M = process.env.MENU_FUNC;
const P = process.env.PATH_VAR;
const V = process.env.ENABLED_VAR;
let code = fs.readFileSync(p, 'utf8');

const fastPath =
  'if(' + T + '&&' + V + '!==false){' +
    T + '.setImage(' + E + '.nativeImage.createFromPath(' + P + '));' +
    'process.platform!==\"darwin\"&&' + T + '.setContextMenu(' + M + '());' +
    'return' +
  '}';

// Inject the fast-path just before the destroy+recreate statement.
// Locate the TRAY.destroy() call, then walk back to the ';if(' that
// opens its statement, so the fast-path lands on a clean statement
// boundary. Robust across both block shapes: the old
//   ;if(TRAY&&(TRAY.destroy()...
// and the 1.13576+ shape with leading state resets
//   ;if(X=[],Y=!1,TRAY&&(TRAY.destroy()...
const destroyMark = T + '.destroy()';
// Assert the anchor is unique before trusting indexOf's first hit: a
// second TRAY.destroy() (a new teardown path, or the string surfacing in
// a merged chunk) would silently mis-place the injection. Bail loudly so
// a future upstream surfaces here instead of shipping a wrong fast-path.
const destroyCount = code.split(destroyMark).length - 1;
if (destroyCount !== 1) {
  console.error('  [FAIL] expected exactly 1 ' + destroyMark +
    ', found ' + destroyCount);
  process.exit(1);
}
const di = code.indexOf(destroyMark);
const ifIdx = code.lastIndexOf(';if(', di);
if (ifIdx === -1) {
  console.error('  [FAIL] enclosing destroy-recreate if( not found');
  process.exit(1);
}
// Insert after the ';' so the existing if-statement stays intact.
code = code.slice(0, ifIdx + 1) + fastPath + code.slice(ifIdx + 1);
fs.writeFileSync(p, code);
console.log('  [OK] Fast-path injected before destroy-recreate');
"; then
		echo 'Failed to inject tray in-place fast-path' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo '##############################################################'
}

#
# @brief Linuxでトレイのコンテキストメニューを残し、使用量の取得を再開させる
# @global main_js (参照のみ)
# @global project_root (参照のみ)
# @stderr アンカーの数が想定と違う場合のメッセージ
# @return 0 = 完了 (適用済みの場合を含む)、1 = 適用できなかった
# @note 上流2.37337.1は、トレイの使用量の行 (プランと使用率) を
#       サーバー側のフラグで切り替える
#       フラグが有効なときはコンテキストメニューを付けず、
#       更新のたびにif(GATE()){…setContextMenu(null)…}を実行し、
#       作成時もGATE()||(setContextMenu(MENU),…)で飛ばす
#       メニューは"right-click"の処理からpopUpContextMenu()で表示し、
#       そのときにバックグラウンドの使用量の取得が要求する
#       「トレイを開いた時刻」も記録する
#       どちらもElectronではmacOSとWindows専用で、
#       LinuxのStatusNotifierItemは空のdbusmenuしか公開しない
#       そのため右クリックでは何も表示されず、取得も止まったままになる
#       LinuxではsetContextMenuの2箇所でフラグの判定を飛ばし、
#       上流の使用量の更新がメニューを付け続けるようにする
#       トレイを開いた記録は"click" (SNIのActivate、左クリック) の処理で行う
#       grepとsedの-zはバンドル全体を1つのレコードとして読むため、
#       整形されて改行を含むバンドルにも一致する
#
patch_tray_linux_context_menu() {
	echo 'Patching tray usage menu to stay on the Linux context menu...'
	local index_js="$main_js"
	local -a gate_funcs tray_vars mark_calls
	local gate_func gate_re tray_var tray_re mark_call
	local linux_off='process\.platform\s*!==\s*"linux"\s*&&\s*'
	local call_shape='^[$[:alnum:]_]+\(\{[[:alnum:]_:!,]*\}\)$'
	local clear_re clear_done_re attach_re attach_done_re click_re click_done_re
	local clear_total clear_done attach_total attach_done
	local click_total click_done

	# 使用量の行のフラグはサーバー側で決まるため、
	# 書き換える対象は、メニューを外す処理と付け直す処理の2箇所
	mapfile -t gate_funcs < <(grep -zoP \
		'if\s*\(\s*(?:'"$linux_off"')?\K[$\w]+(?=\s*\(\s*\)\s*\)\s*\{[^{}]{0,120}\.setContextMenu\s*\(\s*null\s*\))' \
		"$index_js" | tr '\0' '\n' | sort -u)
	mapfile -t tray_vars < <(grep -zoP \
		'(?<![$\w.])[$\w]+(?=\s*=\s*new\s+[$\w]+\s*\.\s*Tray\s*\()' \
		"$index_js" | tr '\0' '\n' | sort -u)
	if [[ ${#gate_funcs[@]} -ne 1 || ${#tray_vars[@]} -ne 1 ]]; then
		echo "WARNING: expected exactly 1 gated tray setContextMenu(null)" \
			"clear and 1 Tray variable, found ${#gate_funcs[@]} and" \
			"${#tray_vars[@]} — Linux tray context menu patch not applied" >&2
		echo '##############################################################'
		return 1
	fi
	gate_func=${gate_funcs[0]}
	tray_var=${tray_vars[0]}
	gate_re="${gate_func//\$/\\$}"
	tray_re="${tray_var//\$/\\$}"
	echo "  Found tray usage-menu gate: $gate_func (tray: $tray_var)"

	clear_re='if\s*\(\s*(?:'"$linux_off"')?'"$gate_re"'\s*\(\s*\)\s*\)\s*\{[^{}]{0,120}\.setContextMenu\s*\(\s*null\s*\)'
	clear_done_re='if\s*\(\s*'"$linux_off$gate_re"'\s*\(\s*\)\s*\)\s*\{[^{}]{0,120}\.setContextMenu\s*\(\s*null\s*\)'
	attach_re='(?<![$\w.])(?:'"$linux_off"')?'"$gate_re"'\s*\(\s*\)\s*\|\|\s*\(\s*'"$tray_re"'\s*\.\s*setContextMenu\s*\('
	attach_done_re='(?<![$\w.])'"$linux_off$gate_re"'\s*\(\s*\)\s*\|\|\s*\(\s*'"$tray_re"'\s*\.\s*setContextMenu\s*\('
	clear_total=$(grep -zoP "$clear_re" "$index_js" | tr -cd '\0' | wc -c)
	attach_total=$(grep -zoP "$attach_re" "$index_js" | tr -cd '\0' | wc -c)
	if [[ $clear_total -ne 1 || $attach_total -ne 1 ]]; then
		echo "WARNING: expected exactly 1 gated menu clear and 1 gated" \
			"${tray_var}.setContextMenu attach, found ${clear_total} and" \
			"${attach_total} — Linux tray context menu patch not applied" >&2
		echo '##############################################################'
		return 1
	fi

	clear_done=$(grep -zoP "$clear_done_re" "$index_js" | tr -cd '\0' | wc -c)
	attach_done=$(grep -zoP "$attach_done_re" "$index_js" | tr -cd '\0' | wc -c)
	if [[ $clear_done -eq 1 && $attach_done -eq 1 ]]; then
		echo '  Tray context menu already kept on Linux (idempotent)'
	else
		if [[ $clear_done -eq 0 ]]; then
			sed -z -i -E \
				"s/(if[[:space:]]*\([[:space:]]*)(${gate_re}[[:space:]]*\([[:space:]]*\)[[:space:]]*\)[[:space:]]*\{[^{}]{0,120}\.setContextMenu[[:space:]]*\([[:space:]]*null[[:space:]]*\))/\1process.platform!==\"linux\"\&\&\2/" \
				"$index_js"
		fi
		if [[ $attach_done -eq 0 ]]; then
			sed -z -i -E \
				"s/(^|[^[:alnum:]_\$.])(${gate_re}[[:space:]]*\([[:space:]]*\)[[:space:]]*\|\|[[:space:]]*\([[:space:]]*${tray_re}[[:space:]]*\.[[:space:]]*setContextMenu[[:space:]]*\()/\1process.platform!==\"linux\"\&\&\2/" \
				"$index_js"
		fi
		clear_done=$(grep -zoP "$clear_done_re" "$index_js" | tr -cd '\0' | wc -c)
		attach_done=$(grep -zoP "$attach_done_re" "$index_js" | tr -cd '\0' | wc -c)
		if [[ $clear_done -ne 1 || $attach_done -ne 1 ]]; then
			echo "WARNING: rewrite of the gated ${tray_var}.setContextMenu" \
				"sites did not apply — Linux tray context menu patch" \
				"incomplete" >&2
			echo '##############################################################'
			return 1
		fi
		echo '  Kept tray context menu attached on Linux (usage gate skipped)'
	fi

	click_re='(?<![$\w.])'"$tray_re"'\s*\.\s*on\s*\(\s*"click"\s*,\s*\(?\s*\([^()]*\)\s*=>\s*\{'
	click_done_re="${click_re}"'\s*process\.platform\s*===\s*"linux"\s*&&\s*'"$gate_re"'\s*\(\s*\)\s*&&\s*[$\w]+\s*\(\s*\{[^{}]*\binteraction\s*:\s*!0'
	click_done=$(grep -zoP "$click_done_re" "$index_js" | tr -cd '\0' | wc -c)
	if [[ $click_done -eq 1 ]]; then
		echo '  Tray left-click already records tray open on Linux (idempotent)'
		echo '##############################################################'
		return 0
	fi
	click_total=$(grep -zoP "$click_re" "$index_js" | tr -cd '\0' | wc -c)
	# NUL区切りで読む : 整形された呼び出しは行をまたぐことがある
	mapfile -t -d '' mark_calls < <(grep -zoP \
		'(?<![$\w.])'"$tray_re"'\s*\.\s*on\s*\(\s*"right-click"\s*,\s*\(?\s*\([^()]*\)\s*=>\s*\{\s*'"$gate_re"'\s*\(\s*\)\s*&&\s*\K[$\w]+\s*\(\s*\{[^{}]*\binteraction\s*:\s*!0[^{}]*\}\s*\)' \
		"$index_js" | sort -zu)
	mark_call=${mark_calls[0]:-}
	mark_call=${mark_call//[[:space:]]/}
	if [[ $click_total -ne 1 || ${#mark_calls[@]} -ne 1 ]] ||
		! [[ $mark_call =~ $call_shape ]]; then
		echo "WARNING: expected exactly 1 ${tray_var} 'click' handler and" \
			"1 'right-click' tray-open call, found ${click_total} and" \
			"${#mark_calls[@]} — Linux tray usage poll stays paused" >&2
		echo '##############################################################'
		return 1
	fi

	sed -z -i -E \
		"s/(^|[^[:alnum:]_\$.])(${tray_re}[[:space:]]*\.[[:space:]]*on[[:space:]]*\([[:space:]]*\"click\"[[:space:]]*,[[:space:]]*\(?[[:space:]]*\([^()]*\)[[:space:]]*=>[[:space:]]*\{)/\1\2process.platform===\"linux\"\&\&${gate_func}()\&\&${mark_call};/" \
		"$index_js"
	click_done=$(grep -zoP "$click_done_re" "$index_js" | tr -cd '\0' | wc -c)
	if [[ $click_done -ne 1 ]]; then
		echo "WARNING: rewrite of the ${tray_var} 'click' handler did not" \
			"apply — Linux tray usage poll stays paused" >&2
		echo '##############################################################'
		return 1
	fi
	echo "  Tray left-click records tray open on Linux (${mark_call})"
	echo 'Patched tray usage menu for the Linux context menu'
	echo '##############################################################'
}

#
# @brief menuBarEnabledが未設定のときにtrueになるようにする
# @global main_js (参照のみ)
# @note 上流が既定値のマップで既にtrueにしている場合は何も変更しない
#       古い書式の!!による判定は未設定がfalseになるため、
#       var!==falseに変えて未設定をtrueにする
#       どちらの形も見つからない場合は、入れた直後の環境で
#       トレイが既定で無効になる可能性を警告する
#
patch_menu_bar_default() {
	echo 'Patching menuBarEnabled to default to true when unset...'
	local index_js="$main_js"

	# 現在のバンドルはこの設定を既定値のマップで解決するため、
	# 呼び出し側に古い形のローカル宣言は残っていない
	if grep -qP 'menuBarEnabled:[ \t]*!0\b' "$index_js"; then
		echo '  menuBarEnabled already defaults to true upstream' \
			'(defaults map) — no patch needed'
		_declare_patch_noop
		echo '##############################################################'
		return
	fi

	local menu_bar_var
	menu_bar_var=$(grep -oP \
		'const \K[$\w]+(?=\s*=\s*[$\w]+\("menuBarEnabled"\))' \
		"$index_js" | head -1)
	if [[ -z $menu_bar_var ]]; then
		echo '  Could not extract menuBarEnabled variable name'
		echo '##############################################################'
		return
	fi
	echo "  Found menuBarEnabled variable: $menu_bar_var"

	# 未設定をtrueにするため、!!varをvar!==falseに変える
	if grep -qP ",\s*!!${menu_bar_var}\s*\)" "$index_js"; then
		sed -i -E \
			"s/,\s*!!${menu_bar_var}\s*\)/,${menu_bar_var}!==false)/g" \
			"$index_js"
		echo '  Patched menuBarEnabled to default to true'
	else
		echo "WARNING: menuBarEnabled neither carries the legacy" \
			"!!-default anchor nor the upstream defaults-map" \
			"\`menuBarEnabled:!0\` — the tray may default OFF on a" \
			"fresh install; the default shape likely changed" >&2
	fi
	echo '##############################################################'
}
