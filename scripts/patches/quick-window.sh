#
# @file quick-window.sh
# @brief クイックウィンドウのポップアップメニューに、KDE限定の
#        blurとフォーカス判定の回避策を当てる
#
# クイックエントリで送信したあとメインウィンドウが再表示されない
# 問題への対処
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : main_js (アンカーを探すメインのチャンク)、
#                          project_root (異常終了時に戻る先)
# 変更するグローバル変数 : なし
#

# アンカーに使う引用符クラス(バッククォート出力にも一致させる、Debian #820)
_QW_Q='[`"'"'"']'

#
# @brief クイックウィンドウ用パッチ1つ分の対象ファイルを特定する
# @param $1 ログとエラー表示に使う対象の名前
# @param $2 メインのチャンクのパス
# @param $3... アンカーの正規表現(先に一致したものから順に試す)
# @stdout パッチ対象のファイルパス
# @return 0 = 特定できた、1 = アンカーが無い、2 = 候補が複数あり決められない
# @note アンカーがメインのチャンクにあれば、そのファイルを対象にする
#       固定したバンドルでは両方のアンカーがここに残るため
#       従来と同じファイルが選ばれる
# @note メインのチャンクに無い場合は、アンカーを持つ兄弟の*.jsチャンクが
#       1つだけならそれを対象にする
#       複数ある場合は推測せず、呼び出し元に失敗させる
# @note パッチ後の形もアンカーを残すため、再実行しても同じファイルに解決される
#       (第1部はhide()、第2部はshow()を書き換える)
#
_qw_resolve_anchor_file() {
	local label="${1:-}"
	local main_file="${2:-}"
	shift 2
	local pattern

	if [[ -f $main_file ]]; then
		for pattern in "$@"; do
			if grep -qP -- "$pattern" "$main_file" 2>/dev/null; then
				printf '%s\n' "$main_file"
				return 0
			fi
		done
	fi

	local dir="${main_file%/*}"
	local candidate
	local -a hits=()
	if [[ -d $dir ]]; then
		for candidate in "$dir"/*.js; do
			[[ -f $candidate ]] || continue
			[[ $candidate == "$main_file" ]] && continue
			for pattern in "$@"; do
				if grep -qP -- "$pattern" "$candidate" 2>/dev/null; then
					hits+=("$candidate")
					break
				fi
			done
		done
	fi
	if (( ${#hits[@]} == 1 )); then
		printf '%s\n' "${hits[0]}"
		return 0
	fi
	if (( ${#hits[@]} > 1 )); then
		echo "Error: anchor '$label' matched ${#hits[@]} sibling" \
			"chunks (${hits[*]}) — refusing to guess which one" \
			'to patch.' >&2
		return 2
	fi
	return 1
}

#
# @brief クイックウィンドウのhide()とメインウィンドウのshow()へ
#        KDE限定の回避策を当てる
# @global main_js (参照のみ) アンカーを探すメインのチャンク
# @global project_root (参照のみ) 候補が曖昧なときに戻る先
# @stdout 適用またはスキップのメッセージ
# @note 候補が複数あって対象を決められない場合は、リポジトリのルートへ
#       戻って1で終了する
#
patch_quick_window() {
	echo 'Patching quick window for Linux...'
	local index_js

	# setAlwaysOnTopの呼び出し全体をアンカーにし
	# "pop-up-menu"という文字列だけでは絞らない
	# その文字列だけなら、書き換える対象の呼び出しを持たない
	# 兄弟チャンクにも現れる可能性があるため
	# QUICK_ENTRYタグ(呼び出しの直前に渡されるウィンドウ種別の
	# 列挙キー)がある場合は必須にする
	# プロパティ名なのでminifyされても残る
	# 新しいバンドルは、同じsetAlwaysOnTop呼び出しを持つ
	# 2つ目のポップアップウィンドウを同梱している (Debian #919)
	# タグと書き換え対象の間には別の呼び出しが挟まってもよいが
	# 文の境界はまたがない
	local tagged_re="QUICK_ENTRY\\)[^;]{0,200}?"
	tagged_re+="\\K[\$\\w]+(?=\\.setAlwaysOnTop\\(\\s*!0\\s*,\\s*"
	tagged_re+="${_QW_Q}pop-up-menu${_QW_Q}\\s*\\))"
	# QUICK_ENTRYタグより前の古いバンドル向けのフォールバック
	# 引用符クラスと空白の揺れを許した呼び出しの形だけを見る
	# タグ付きの形が無い場合にだけ使う
	local bare_re="[\$\\w]+(?=\\.setAlwaysOnTop\\(\\s*!0\\s*,\\s*"
	bare_re+="${_QW_Q}pop-up-menu${_QW_Q}\\s*\\))"

	# クイックウィンドウの変数名を取り出す
	# 取り出した名前は、以降の書き換えで識別子として使う
	# 対象の例 :
	#   tagged: Li.QUICK_ENTRY),Sa.setAlwaysOnTop(!0,`pop-up-menu`)
	#   legacy: Sa.setAlwaysOnTop(!0,"pop-up-menu")
	local anchor_re=''
	local anchor_label=''
	local resolve_rc=0
	index_js=$(_qw_resolve_anchor_file \
		'quick-window setAlwaysOnTop (QUICK_ENTRY-tagged)' \
		"$main_js" "$tagged_re")
	resolve_rc=$?
	if (( resolve_rc == 0 )); then
		anchor_re="$tagged_re"
		anchor_label='quick-window setAlwaysOnTop (QUICK_ENTRY-tagged)'
	elif (( resolve_rc == 1 )); then
		index_js=$(_qw_resolve_anchor_file \
			'quick-window setAlwaysOnTop (legacy)' \
			"$main_js" "$bare_re")
		resolve_rc=$?
		if (( resolve_rc == 0 )); then
			anchor_re="$bare_re"
			anchor_label='quick-window setAlwaysOnTop (legacy)'
		fi
	fi
	if (( resolve_rc == 2 )); then
		cd "$project_root" || exit 1
		exit 1
	fi
	if (( resolve_rc != 0 )); then
		echo 'WARNING: Could not extract quick window variable name'
		echo '##############################################################'
		return
	fi
	if ! _assert_single_anchor_match "$index_js" "$anchor_re" \
		"$anchor_label"; then
		echo '##############################################################'
		return
	fi
	local quick_var
	quick_var=$(grep -oP -- "$anchor_re" "$index_js" | head -1)
	if [[ -z $quick_var ]]; then
		echo 'WARNING: Could not extract quick window variable name'
		echo '##############################################################'
		return
	fi
	echo "  Found quick window variable: $quick_var"

	local quick_var_re="${quick_var//\$/\\$}"

	# 第1部 : クイックウィンドウのhide()の前にblur()を挟み
	# 非表示にした後のisFocused()がfalseを返すようにする
	# KDEでのElectronのLinux固有の不具合への対処
	# hideの呼び出しは||の後ろにある(例 : GUARD()||VAR.hide())ため
	# 短絡評価の意味を保つには両方の呼び出しを()で囲む必要がある
	# KDEに限定する理由 :
	# GNOMEやUbuntuではblur()がクイックエントリを壊し (#393)
	# そちらではフォーカスが古いまま残る不具合も起きない
	local de_check='(process.env.XDG_CURRENT_DESKTOP||"")'
	de_check+='.toLowerCase().includes("kde")'
	if grep -qF "${quick_var}.blur(),${quick_var}.hide()" "$index_js"; then
		echo '  Quick window blur already patched'
	elif grep -qP "\|\|\s*${quick_var_re}\.hide\(\)" "$index_js"; then
		sed -i -E \
			"s/\|\|\s*${quick_var_re}\.hide\(\)/||(${de_check}?(${quick_var}.blur(),${quick_var}.hide()):${quick_var}.hide())/g" \
			"$index_js"
		echo '  Added KDE-gated blur() before hide() on quick window'
	else
		echo '  WARNING: Could not find quick window hide() call'
	fi

	# 第2部 : クイックエントリで送信したあとメインウィンドウが
	# 表示されない問題を直す
	# KDEでは非表示にした後もisFocused()がtrueのまま残ることがあり
	# FOCUS_CHECK()||Lt.show()がshowを飛ばしてしまう
	# 可視性チェックへの置き換えもKDEに限定する
	# GNOMEでは元のフォーカス判定が正しく働き
	# 置き換えるとクイックエントリが壊れる (#393)
	#
	# 第1部とは別に解決する
	# QuickEntryの送信処理は独立した仕組みで
	# 上流が別のチャンクへ分割する可能性があるため
	local submit_js=''
	local submit_rc=0
	submit_js=$(_qw_resolve_anchor_file 'quick-entry submit' \
		"$main_js" 'Creating new chat with submit_quick_entry')
	submit_rc=$?
	if (( submit_rc == 2 )); then
		cd "$project_root" || exit 1
		exit 1
	fi
	if (( submit_rc != 0 )); then
		# アンカーが無い場合は、ファイルを特定する前の動作に戻し
		# 後段のnodeパッチにメインのチャンクを対象にさせる
		# そうすると従来どおりの警告が出る
		submit_js="$main_js"
	fi
	if INDEX_JS="$submit_js" node << 'QUICK_WINDOW_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');
let patchCount = 0;

// Both the focus check and the window handle are captured from the
// call site itself — the only place both are spelled the way they are
// used. An earlier revision resolved them definition-side: find
// `isWindowFocused:()=>!!X()`, then hunt a sibling visibility helper
// `function Y(){return!...isVisible()}` within 500 chars of X's
// definition. That broke on 2.37337.1: the sibling sits at offset 497
// with a body longer than the remaining window (`function PSe(){
// return!B||B.isDestroyed()?!1:B.isVisible()}` — a "near ko"
// near-miss), and the helper additionally exists as an arrow property
// (`isWindowVisible:()=>!!(B&&!B.isDestroyed()&&B.isVisible())`)
// that no `function`-declaration regex can name. Capturing at the
// call site drops both fragile lookups (the same conclusion Debian
// reached for 1.26832.0, where the pair moved into a shared module
// and the call site sees only import bindings).
// Whitespace is allowed around the dots of a dotted handle and the
// lookbehinds forbid starting inside one, so `exports . focused ()`
// is captured whole instead of as its trailing `focused` member.
// Captures are whitespace-stripped (norm) before being compared or
// written back.
const win = String.raw`(?<![\w$])(?<!\.\s*)[\w$]+(?:\s*\.\s*[\w$]+)*`;
const norm = (s) => s.replace(/\s+/g, '');

// Anchor on the unique QuickEntry log string to patch only the right
// site. The second anchor this script used to carry, 'Navigating to
// existing chat', is absent from both 1.44121.4 and 2.37337.1 (and
// from Debian's 1.24012.11/1.26832.0), so it only ever produced a
// standing WARNING — dropped rather than kept as noise.
const anchors = [
    'Creating new chat with submit_quick_entry',
];
// Sites already carrying the gate from a previous run. Counted
// separately from patchCount so a re-run over a fully patched bundle
// stays silent instead of emitting a WARNING that nothing was patched —
// there was nothing left to patch, which is success, not a miss.
let alreadyCount = 0;
// `\s*` between every token: a re-minified or prettified bundle may
// write `ko () || B.show ()` with the same meaning.
const ws = String.raw`\s*`;
const call = (name) => name + ws + String.raw`\(` + ws + String.raw`\)`;
const member = (obj, prop) => obj + ws + String.raw`\.` + ws + prop;
// matches: <focusCall>()||<win>.show(). Both sides are captured:
// <focusCall> is `ko` on 2.37337.1 and `za` on 1.44121.4; <win>
// is the bare local `B` / `z` there, but the capture tolerates
// dotted handles too (exports.mainWindow, or a module binding
// like i.f — capture the whole handle so the rewrite keeps the
// .show() call pointed at the real window).
const rawRe = new RegExp(call(`(${win})`) + ws + String.raw`\|\|` + ws +
    call(member(`(${win})`, 'show')), 'g');
// The complete gate a previous run injected (see newStr below), with
// the window handle captured at all four uses so they can be required
// to agree. Recognising the whole shape, instead of any mention of
// XDG_CURRENT_DESKTOP near the anchor, keeps an unrelated mention from
// passing for "already patched" while the raw call stays unpatched.
const patchedRe = new RegExp(
    String.raw`\(` + ws + String.raw`\(` + ws +
    member(member('process', 'env'), 'XDG_CURRENT_DESKTOP') + ws +
    String.raw`\|\|` + ws + '""' + ws + String.raw`\)` + ws +
    call(String.raw`\.` + ws + 'toLowerCase') + ws +
    String.raw`\.` + ws + 'includes' + ws + String.raw`\(` + ws +
    '"kde"' + ws + String.raw`\)` + ws + String.raw`\?` + ws +
    String.raw`\(` + ws + '!' + ws + `(${win})` + ws + String.raw`\|\|` +
    ws + call(member(`(${win})`, 'isDestroyed')) + ws + String.raw`\?` +
    ws + '!1' + ws + ':' + ws + call(member(`(${win})`, 'isVisible')) +
    ws + String.raw`\)` + ws + ':' + ws + call(`(${win})`) + ws +
    String.raw`\)` + ws + String.raw`\|\|` + ws +
    call(member(`(${win})`, 'show')), 'g');
for (const anchor of anchors) {
    const anchorIdx = code.indexOf(anchor);
    if (anchorIdx === -1) {
        console.log('  WARNING: anchor not found: ' + anchor);
        continue;
    }
    if (code.indexOf(anchor, anchorIdx + 1) !== -1) {
        console.log('  WARNING: anchor "' + anchor + '" occurs more than' +
            ' once — skipping to avoid patching the wrong site');
        continue;
    }
    // Search region after anchor (1500 chars covers promise chains)
    const region = code.substring(anchorIdx, anchorIdx + 1500);
    const rawMatches = [...region.matchAll(rawRe)];
    const patchedMatches = [...region.matchAll(patchedRe)].filter(
        (m) => norm(m[1]) === norm(m[2]) && norm(m[2]) === norm(m[3]) &&
            norm(m[3]) === norm(m[5]));
    if (rawMatches.length === 0 && patchedMatches.length === 1) {
        console.log('  Quick entry show() already patched near "' +
            anchor.substring(0, 30) + '..."');
        alreadyCount++;
        continue;
    }
    // Exactly one raw site and no patched one: patching the first of
    // several would hit an arbitrary location, and a mix of raw and
    // patched sites is a shape this patch was not written for, so both
    // warn and skip instead (same policy as the shell-side anchor
    // assertions above).
    if (rawMatches.length === 1 && patchedMatches.length === 0) {
        const oldStr = rawMatches[0][0];
        const focusCall = norm(rawMatches[0][1]);
        const mainWin = norm(rawMatches[0][2]);
        // Gate the visibility check to KDE only; fall back to original
        // focus check on GNOME/other so #390 doesn't regress them (#393).
        // The visibility test is inlined from the captured handle
        // rather than calling upstream's helper, which is no longer
        // nameable from here (arrow property on 2.37337.1). Inlining
        // `(!win||win.isDestroyed()?!1:win.isVisible())` runs the same
        // test against the window being shown: a hidden window whose
        // webContents still reports focus now gets show() instead of
        // being skipped, which is the safe direction for the #390
        // symptom (show() skipped), and the null/destroyed case never
        // reaches it — the surrounding upstream guard
        // (`!win||win.isDestroyed()||(...)`) short-circuits first.
        const deCheck = '(process.env.XDG_CURRENT_DESKTOP||"")' +
            '.toLowerCase().includes("kde")';
        const visible = '(!' + mainWin + '||' + mainWin +
            '.isDestroyed()?!1:' + mainWin + '.isVisible())';
        // Built by concatenation, never through String.replace(): a
        // captured handle can contain `$`, which replace() would
        // reinterpret as a substitution pattern.
        const newStr = '(' + deCheck + '?' + visible + ':' +
            focusCall + '())||' + mainWin + '.show()';
        const absIdx = anchorIdx + rawMatches[0].index;
        code = code.substring(0, absIdx) + newStr +
            code.substring(absIdx + oldStr.length);
        console.log('  KDE-gated ' + focusCall + '()/' + mainWin +
            '.isVisible() for show() near "' + anchor.substring(0, 30) + '..."');
        patchCount++;
    } else if (rawMatches.length === 0 && patchedMatches.length === 0) {
        console.log('  WARNING: show() pattern not found near "' +
            anchor + '"');
    } else {
        console.log('  WARNING: ' + rawMatches.length + ' raw and ' +
            patchedMatches.length + ' patched show() sites near "' +
            anchor + '" — skipping to avoid patching the wrong one');
    }
}

if (patchCount > 0) {
    fs.writeFileSync(indexJs, code);
    console.log('  Patched ' + patchCount +
        ' quick entry show() calls to use visibility check');
} else if (alreadyCount === anchors.length) {
    console.log('  Quick entry show() calls already patched (' +
        alreadyCount + '/' + anchors.length + ')');
} else {
    console.log('  WARNING: No quick entry show() calls patched');
}
QUICK_WINDOW_PATCH
	then
		echo 'Quick window patches applied'
	else
		echo 'WARNING: Quick window show patch failed' >&2
	fi
	echo '##############################################################'
}
