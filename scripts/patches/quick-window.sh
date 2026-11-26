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
		echo '  [FAIL] Could not locate the quick window setAlwaysOnTop' \
			'anchor; refusing to leave Part 1 unapplied.' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	if ! _assert_single_anchor_match "$index_js" "$anchor_re" \
		"$anchor_label"; then
		echo '  [FAIL] Quick window anchor is ambiguous; refusing to' \
			'guess which site to patch.' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	local quick_var
	quick_var=$(grep -oP -- "$anchor_re" "$index_js" | head -1)
	if [[ -z $quick_var ]]; then
		echo '  [FAIL] Could not extract quick window variable name' >&2
		cd "$project_root" || exit 1
		exit 1
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
	local hide_re="\|\|\s*${quick_var_re}\.hide\(\)"
	local hide_hits patched_hits
	hide_hits=$(grep -oP -- "$hide_re" "$index_js" | wc -l)
	patched_hits=$(grep -oF "${quick_var}.blur(),${quick_var}.hide()" \
		"$index_js" | wc -l)
	if (( patched_hits == 1 && hide_hits == 0 )); then
		echo '  Quick window blur already patched'
	elif (( hide_hits == 1 && patched_hits == 0 )); then
		sed -i -E \
			"s/\|\|\s*${quick_var_re}\.hide\(\)/||(${de_check}?(${quick_var}.blur(),${quick_var}.hide()):${quick_var}.hide())/g" \
			"$index_js"
		hide_hits=$(grep -oP -- "$hide_re" "$index_js" | wc -l)
		patched_hits=$(grep -oF "${quick_var}.blur(),${quick_var}.hide()" \
			"$index_js" | wc -l)
		if (( patched_hits != 1 || hide_hits != 0 )); then
			echo '  [FAIL] KDE blur injection did not produce exactly one' \
				'patched hide() site.' >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo '  Added KDE-gated blur() before hide() on quick window'
	else
		echo '  [FAIL] Expected exactly one unpatched quick window' \
			"hide() site (found $hide_hits raw, $patched_hits patched);" \
			'refusing to continue.' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	# 第2部 : クイックエントリで送信したあとメインウィンドウが
	# 表示されない問題を直す
	# KDEでは非表示にした後もisFocused()がtrueのまま残ることがあり
	# FOCUS_CHECK()||Lt.show()がshowを飛ばしてしまう
	# 可視性チェックへの置き換えもKDEに限定する
	# GNOMEでは元のフォーカス判定が正しく働き
	# 置き換えるとクイックエントリが壊れる (#393)
	#
	# 第1部とは独立に検証する。第1部がバイトを変更しても、第2部の
	# 検証結果を覆い隠せないようにするため(D-006)。
	# 7.37095.0では送信ログの文字列が2箇所に現れるため、その文字列を
	# アンカーにした注入は行わない。代わりにQuick Entryモジュールの
	# 構造(showMainWindowForSendの公開、無条件のshow()、DISMISSからの
	# 呼び出し、添付送信時のshowがdismissより先)を証明する。
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
		submit_js="$main_js"
	fi
	if ! MAIN_JS="$main_js" SUBMIT_JS="$submit_js" \
		PATCH_WORK_DIR="${work_dir:-}" node << 'QUICK_WINDOW_PATCH'
const fs = require('fs');
const mainPath = process.env.MAIN_JS;
const submitPath = process.env.SUBMIT_JS || mainPath;
const literal = 'Creating new chat with submit_quick_entry';
let code = fs.readFileSync(submitPath, 'utf8');
const countOf = (hay, needle) => hay.split(needle).length - 1;

const win = String.raw`(?<![\w$])(?<!\.\s*)[\w$]+(?:\s*\.\s*[\w$]+)*`;
const norm = (s) => s.replace(/\s+/g, '');
const ws = String.raw`\s*`;
const call = (name) => name + ws + String.raw`\(` + ws + String.raw`\)`;
const member = (obj, prop) => obj + ws + String.raw`\.` + ws + prop;

const rawRe = new RegExp(call(`(${win})`) + ws + String.raw`\|\|` + ws +
    call(member(`(${win})`, 'show')), 'g');
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

let legacyOk = false;
const anchorCount = countOf(code, literal);
if (anchorCount === 1) {
    const anchorIdx = code.indexOf(literal);
    const region = code.substring(anchorIdx, anchorIdx + 1500);
    const rawMatches = [...region.matchAll(rawRe)];
    const patchedMatches = [...region.matchAll(patchedRe)].filter(
        (m) => norm(m[1]) === norm(m[2]) && norm(m[2]) === norm(m[3]) &&
            norm(m[3]) === norm(m[5]));
    if (rawMatches.length === 0 && patchedMatches.length === 1) {
        console.log('  Quick entry show() already patched near "' +
            literal.substring(0, 30) + '..."');
        legacyOk = true;
    } else if (rawMatches.length === 1 && patchedMatches.length === 0) {
        const oldStr = rawMatches[0][0];
        const focusCall = norm(rawMatches[0][1]);
        const mainWin = norm(rawMatches[0][2]);
        const deCheck = '(process.env.XDG_CURRENT_DESKTOP||"")' +
            '.toLowerCase().includes("kde")';
        const visible = '(!' + mainWin + '||' + mainWin +
            '.isDestroyed()?!1:' + mainWin + '.isVisible())';
        const newStr = '(' + deCheck + '?' + visible + ':' +
            focusCall + '())||' + mainWin + '.show()';
        const absIdx = anchorIdx + rawMatches[0].index;
        code = code.substring(0, absIdx) + newStr +
            code.substring(absIdx + oldStr.length);
        fs.writeFileSync(submitPath, code);
        console.log('  Patched 1 quick entry show() calls: KDE-gated ' +
            focusCall + '()/' + mainWin + '.isVisible()');
        legacyOk = true;
    } else {
        console.log('  Legacy quick entry shape is ambiguous: ' +
            rawMatches.length + ' raw and ' + patchedMatches.length +
            ' patched show() sites near the anchor.');
    }
} else {
    if (anchorCount > 1) {
        console.log('  Submit anchor occurs more than once (' +
            anchorCount + '); verifying the modern Quick Entry contract' +
            ' instead.');
    } else {
        console.log('  Legacy single-site submit anchor not present;' +
            ' verifying the modern Quick Entry contract instead.');
    }
}
if (legacyOk) process.exit(0);

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const defWindow = (text, name, len) => {
    const m = new RegExp('function\\s+' + esc(name) + '\\s*\\(').exec(text);
    return m ? text.slice(m.index, m.index + len) : null;
};

// The attachment proof must look inside the whole function that logs
// "Quick entry submitted", not a fixed-width prefix: the real show call is
// before the log and the real dismiss call is after it. Mask comments and
// string bodies so `N.info(` can never be mistaken for a bare `o()`.
const maskCode = (source) => {
    const out = source.split('');
    const blank = (from, to) => {
        for (let i = from; i < to; i += 1) {
            if (out[i] !== '\n') out[i] = ' ';
        }
    };
    let i = 0;
    while (i < source.length) {
        if (source[i] === '/' && source[i + 1] === '/') {
            const end = source.indexOf('\n', i + 2);
            const stop = end === -1 ? source.length : end;
            blank(i, stop);
            i = stop;
        } else if (source[i] === '/' && source[i + 1] === '*') {
            const end = source.indexOf('*/', i + 2);
            const stop = end === -1 ? source.length : end + 2;
            blank(i, stop);
            i = stop;
        } else if (source[i] === '"' || source[i] === "'" || source[i] === '`') {
            const quote = source[i];
            let j = i + 1;
            while (j < source.length) {
                if (source[j] === '\\') {
                    j += 2;
                    continue;
                }
                if (source[j] === quote) {
                    j += 1;
                    break;
                }
                j += 1;
            }
            blank(i, j);
            i = j;
        } else {
            i += 1;
        }
    }
    return out.join('');
};

const braceEnd = (source, openIdx) => {
    let depth = 0;
    for (let pos = openIdx; pos < source.length; pos += 1) {
        if (source[pos] === '{') {
            depth += 1;
        } else if (source[pos] === '}') {
            depth -= 1;
            if (depth === 0) return pos + 1;
        }
    }
    return -1;
};

const functionRangeAt = (masked, index) => {
    const headRe = /(?:async\s+)?function\s+([\w$]+)\s*\(([^()]*)\)\s*\{/g;
    let best = null;
    let m;
    while ((m = headRe.exec(masked)) !== null) {
        const open = m.index + m[0].length - 1;
        const end = braceEnd(masked, open);
        if (end === -1 || index <= open || index >= end) continue;
        if (best === null || m.index > best.start) {
            best = { name: m[1], start: m.index, bodyStart: open + 1, end };
        }
    }
    return best;
};

const attachmentLocals = (text) => {
    const dismissFirst = new RegExp(
        '\\{\\s*requestQuickWindowDismissWithPayload\\s*:\\s*([\\w$]+)' +
        '\\s*,\\s*showMainWindowForSend\\s*:\\s*([\\w$]+)[^}]*\\}' +
        '\\s*=\\s*await').exec(text);
    if (dismissFirst) {
        return { dismiss: dismissFirst[1], show: dismissFirst[2] };
    }
    const showFirst = new RegExp(
        '\\{\\s*showMainWindowForSend\\s*:\\s*([\\w$]+)\\s*,\\s*' +
        'requestQuickWindowDismissWithPayload\\s*:\\s*([\\w$]+)' +
        '[^}]*\\}\\s*=\\s*await').exec(text);
    if (showFirst) {
        return { show: showFirst[1], dismiss: showFirst[2] };
    }
    return null;
};

const loadAcorn = () => {
    try {
        return require('acorn');
    } catch (e) {
        // PATCH_WORK_DIR carries the build-time acorn below.
    }
    const paths = [process.env.PATCH_WORK_DIR, process.env.NODE_PATH]
        .filter((p) => typeof p === 'string' && p !== '')
        .flatMap((p) => p.split(':'));
    if (paths.length === 0) return null;
    try {
        return require(require.resolve('acorn',
            { paths: paths.concat([__dirname]) }));
    } catch (e) {
        return null;
    }
};

// The attachment gate is only correct when show() runs exactly when the
// submit carries at least one file. A `filePaths` local or a direct
// `<param>.filePaths.length` expression proves presence; a negated flag or
// a `=== 0` / `<= 0` test proves absence and must never be accepted.
const filePathsBinding = (fn) => {
    const param = fn.params && fn.params[0];
    if (!param) return null;
    if (param.type === 'Identifier') {
        return { kind: 'member', param: param.name };
    }
    if (param.type === 'ObjectPattern') {
        for (const prop of param.properties) {
            if (!prop || prop.type === 'RestElement') continue;
            const key = prop.key;
            const keyName = key && key.type === 'Identifier' ? key.name :
                (key && key.type === 'Literal' ? key.value : null);
            if (keyName !== 'filePaths') continue;
            let value = prop.value;
            if (value && value.type === 'AssignmentPattern') value = value.left;
            if (value && value.type === 'Identifier') {
                return { kind: 'name', name: value.name };
            }
        }
    }
    return null;
};

const isFilePathsLength = (node, binding) => {
    if (!node || node.type !== 'MemberExpression' || node.computed) return false;
    if (!node.property || node.property.type !== 'Identifier' ||
        node.property.name !== 'length') return false;
    const object = node.object;
    if (binding.kind === 'name') {
        return object.type === 'Identifier' && object.name === binding.name;
    }
    return object.type === 'MemberExpression' && !object.computed &&
        object.object.type === 'Identifier' &&
        object.object.name === binding.param &&
        object.property.type === 'Identifier' &&
        object.property.name === 'filePaths';
};

const isZeroLiteral = (node) => node && node.type === 'Literal' &&
    node.value === 0;

const isPositiveAttachment = (node, binding) => {
    if (!node) return false;
    if (node.type === 'CallExpression' &&
        node.callee.type === 'Identifier' && node.callee.name === 'Boolean' &&
        node.arguments.length === 1 &&
        isFilePathsLength(node.arguments[0], binding)) {
        return true;
    }
    if (node.type !== 'BinaryExpression') return false;
    const leftLength = isFilePathsLength(node.left, binding);
    const rightLength = isFilePathsLength(node.right, binding);
    if (node.operator === '>') return leftLength && isZeroLiteral(node.right);
    if (node.operator === '<') return isZeroLiteral(node.left) && rightLength;
    if (node.operator === '!==') {
        return (leftLength && isZeroLiteral(node.right)) ||
            (isZeroLiteral(node.left) && rightLength);
    }
    return false;
};

const proveAttachmentWithAcorn = (source, acorn, logIndex) => {
    let tree;
    try {
        tree = acorn.parse(source,
            { ecmaVersion: 'latest', sourceType: 'script' });
    } catch (e) {
        return null;
    }
    let logFn = null;
    const parents = new WeakMap();
    const walk = (node, fn, parent) => {
        if (!node || typeof node.type !== 'string') return;
        let current = fn;
        if (node.type === 'FunctionDeclaration' ||
            node.type === 'FunctionExpression' ||
            node.type === 'ArrowFunctionExpression') {
            current = node;
        }
        parents.set(node, parent);
        if (node.type === 'CallExpression' && node.callee) {
            const callee = node.callee;
            const isInfo = (callee.type === 'Identifier' &&
                callee.name === 'info') ||
                (callee.type === 'MemberExpression' && callee.property &&
                 callee.property.type === 'Identifier' &&
                 callee.property.name === 'info');
            if (isInfo && node.arguments.length > 0 &&
                node.arguments[0].type === 'Literal' &&
                node.arguments[0].value === 'Quick entry submitted') {
                logFn = current;
            }
        }
        for (const key of Object.keys(node)) {
            if (key === 'type' || key === 'start' || key === 'end') continue;
            const value = node[key];
            if (Array.isArray(value)) {
                for (const child of value) walk(child, current, node);
            } else if (value && typeof value.type === 'string') {
                walk(value, current, node);
            }
        }
    };
    walk(tree, null, null);
    if (!logFn || logFn.type === 'Program') {
        return { error: 'attachment log is not inside a named function' };
    }
    const locals = attachmentLocals(source.slice(logFn.start, logFn.end));
    if (!locals) {
        return { error: 'attachment entry does not destructure the' +
            ' Quick Entry export pair' };
    }
    const binding = filePathsBinding(logFn);
    if (!binding) {
        return { error: 'attachment show() is not gated on attached files' };
    }
    const calls = { show: [], dismiss: [] };
    const collect = (node) => {
        if (!node || typeof node.type !== 'string') return;
        if (node !== logFn &&
            (node.type === 'FunctionDeclaration' ||
             node.type === 'FunctionExpression' ||
             node.type === 'ArrowFunctionExpression')) {
            return;
        }
        if (node.type === 'CallExpression' &&
            node.callee && node.callee.type === 'Identifier') {
            if (node.callee.name === locals.show &&
                node.arguments.length === 0) {
                calls.show.push(node);
            }
            if (node.callee.name === locals.dismiss) {
                calls.dismiss.push(node);
            }
        }
        for (const key of Object.keys(node)) {
            if (key === 'type' || key === 'start' || key === 'end') continue;
            const value = node[key];
            if (Array.isArray(value)) {
                for (const child of value) collect(child);
            } else if (value && typeof value.type === 'string') {
                collect(value);
            }
        }
    };
    collect(logFn);
    if (calls.show.length !== 1 || calls.dismiss.length !== 1) {
        return { error: 'attachment entry does not contain exactly one' +
            ' show call and one dismiss call' };
    }
    const positive = new Map();
    const collectPositive = (node) => {
        if (!node || typeof node.type !== 'string') return;
        if (node !== logFn &&
            (node.type === 'FunctionDeclaration' ||
             node.type === 'FunctionExpression' ||
             node.type === 'ArrowFunctionExpression')) {
            return;
        }
        if (node.type === 'VariableDeclarator' &&
            node.id.type === 'Identifier' && node.init &&
            isPositiveAttachment(node.init, binding)) {
            positive.set(node.id.name, node.start);
        }
        for (const key of Object.keys(node)) {
            if (key === 'type' || key === 'start' || key === 'end') continue;
            const value = node[key];
            if (Array.isArray(value)) {
                for (const child of value) collectPositive(child);
            } else if (value && typeof value.type === 'string') {
                collectPositive(value);
            }
        }
    };
    collectPositive(logFn);
    const provenGuard = (test, showNode) => {
        if (test.type === 'Identifier') {
            const at = positive.get(test.name);
            return at !== undefined && at < showNode.start;
        }
        return isPositiveAttachment(test, binding);
    };
    const showNode = calls.show[0];
    const dismissNode = calls.dismiss[0];
    if (!(showNode.start < dismissNode.start)) {
        return { error: 'attachment entry does not show before dismissing' };
    }
    let guarded = false;
    let node = showNode;
    while (node && node !== logFn) {
        const parent = parents.get(node);
        if (!parent) break;
        if (parent.type === 'LogicalExpression' &&
            parent.operator === '&&' && parent.right === node) {
            guarded = provenGuard(parent.left, showNode);
            break;
        }
        if (parent.type === 'IfStatement' && parent.consequent &&
            parent.consequent.start <= showNode.start &&
            showNode.end <= parent.consequent.end) {
            guarded = provenGuard(parent.test, showNode);
            break;
        }
        if (parent.type === 'IfStatement' && parent.alternate &&
            parent.alternate.start <= showNode.start &&
            showNode.end <= parent.alternate.end) {
            break;
        }
        node = parent;
    }
    if (!guarded) {
        return { error: 'attachment show() is not gated on attached files' };
    }
    let node2 = dismissNode;
    while (node2 && node2 !== logFn) {
        const parent = parents.get(node2);
        if (!parent) break;
        if (parent.type === 'IfStatement' && parent.alternate &&
            parent.alternate.start <= dismissNode.start &&
            dismissNode.end <= parent.alternate.end &&
            !(parent.alternate.start <= showNode.start &&
              showNode.end <= parent.alternate.end)) {
            return { error: 'attachment dismiss() runs on the branch where' +
                ' attachments are absent' };
        }
        node2 = parent;
    }
    return { show: locals.show, dismiss: locals.dismiss };
};

const filePathsBindingFromHeader = (header) => {
    const open = header.indexOf('(');
    const close = header.lastIndexOf(')');
    if (open === -1 || close <= open) return null;
    const params = header.slice(open + 1, close);
    if (/^\s*[\w$]+\s*$/.test(params)) {
        return { kind: 'member', param: params.trim() };
    }
    const match = new RegExp('(?:^|[,{])\\s*filePaths\\s*:\\s*([\\w$]+)')
        .exec(params);
    if (match) return { kind: 'name', name: match[1] };
    return null;
};

const filePathsLengthSource = (binding) => binding.kind === 'name'
    ? '(?<![\\w$.])' + esc(binding.name) + '\\.length'
    : '(?<![\\w$.])' + esc(binding.param) + '\\.filePaths\\.length';

const positiveConditionText = (text, positive, showAt, fpLength) => {
    const trimmed = text.trim();
    for (const name of positive.keys()) {
        if (positive.get(name) >= showAt) continue;
        if (new RegExp('(?:^|[^\\w$.!&|])' + esc(name) + '$').test(trimmed)) {
            return true;
        }
    }
    const anchored = (source) =>
        new RegExp('(?:^|[^\\w$.!&|])' + source + '$').test(trimmed);
    return anchored(fpLength + '\\s*>\\s*0') ||
        anchored('0\\s*<\\s*' + fpLength) ||
        anchored('Boolean\\s*\\(\\s*' + fpLength + '\\s*\\)') ||
        anchored(fpLength + '\\s*!==\\s*0') ||
        anchored('0\\s*!==\\s*' + fpLength);
};

const proveAttachmentByTokens = (source, logIndex) => {
    const masked = maskCode(source);
    const fn = functionRangeAt(masked, logIndex);
    if (!fn) {
        return { error: 'attachment log is not inside a named function' };
    }
    const fnStart = fn.bodyStart;
    const fnEnd = fn.end - 1;
    const locals = attachmentLocals(source.slice(fnStart, fnEnd));
    if (!locals) {
        return { error: 'attachment entry does not destructure the' +
            ' Quick Entry export pair' };
    }
    const binding = filePathsBindingFromHeader(
        masked.slice(fn.start, fn.bodyStart));
    if (!binding) {
        return { error: 'attachment show() is not gated on attached files' };
    }
    const fnMasked = masked.slice(fnStart, fnEnd);
    const showCalls = [...fnMasked.matchAll(new RegExp(
        '(?<![\\w$.])' + esc(locals.show) + '\\s*\\(\\s*\\)', 'g'))];
    const dismissCalls = [...fnMasked.matchAll(new RegExp(
        '(?<![\\w$.])' + esc(locals.dismiss) + '\\s*\\(', 'g'))];
    if (showCalls.length !== 1 || dismissCalls.length !== 1) {
        return { error: 'attachment entry does not contain exactly one' +
            ' show call and one dismiss call' };
    }
    if (!(showCalls[0].index < dismissCalls[0].index)) {
        return { error: 'attachment entry does not show before dismissing' };
    }
    const fpLength = filePathsLengthSource(binding);
    const positive = new Map();
    const positiveRes = [
        new RegExp('([\\w$]+)\\s*=\\s*' + fpLength + '\\s*>\\s*0', 'g'),
        new RegExp('([\\w$]+)\\s*=\\s*0\\s*<\\s*' + fpLength, 'g'),
        new RegExp('([\\w$]+)\\s*=\\s*Boolean\\s*\\(\\s*' + fpLength +
            '\\s*\\)', 'g'),
        new RegExp('([\\w$]+)\\s*=\\s*' + fpLength + '\\s*!==\\s*0', 'g'),
        new RegExp('([\\w$]+)\\s*=\\s*0\\s*!==\\s*' + fpLength, 'g'),
    ];
    for (const re of positiveRes) {
        let match;
        while ((match = re.exec(fnMasked)) !== null) {
            positive.set(match[1], match.index);
        }
    }
    const gate = fnMasked.slice(Math.max(0, showCalls[0].index - 160),
        showCalls[0].index);
    let guarded = false;
    if (/&&\s*$/.test(gate)) {
        guarded = positiveConditionText(gate.replace(/&&\s*$/, ''),
            positive, showCalls[0].index, fpLength);
    } else {
        const ifMatch = /if\s*\(\s*([^()]*)\s*\)\s*\{\s*$/.exec(gate);
        if (ifMatch) {
            const inner = ifMatch[1].trim();
            guarded = positiveConditionText(inner,
                positive, showCalls[0].index, fpLength);
            if (!guarded && positive.has(inner) &&
                positive.get(inner) < showCalls[0].index) {
                guarded = true;
            }
        }
    }
    if (!guarded) {
        return { error: 'attachment show() is not gated on attached files' };
    }
    return { show: locals.show, dismiss: locals.dismiss };
};

const proveAttachmentOrder = (source, logIndex) => {
    const acorn = loadAcorn();
    if (acorn !== null) {
        const proof = proveAttachmentWithAcorn(source, acorn, logIndex);
        if (proof !== null) return proof;
    }
    return proveAttachmentByTokens(source, logIndex);
};

const candidates = [];
if (submitPath !== mainPath) {
    candidates.push({ path: mainPath, text: fs.readFileSync(mainPath, 'utf8') });
}
candidates.push({ path: submitPath, text: code });

const reasons = [];
let proof = null;
for (const candidate of candidates) {
    const text = candidate.text;
    const exportRe = new RegExp(
        'requestQuickWindowDismissWithPayload\\s*:\\s*' +
        '\\(\\s*\\)\\s*=>\\s*([\\w$]+)\\s*,[^}]*?' +
        'showMainWindowForSend\\s*:\\s*' +
        '\\(\\s*\\)\\s*=>\\s*([\\w$]+)', 'g');
    const exportsFound = [...text.matchAll(exportRe)];
    if (exportsFound.length !== 1) {
        reasons.push(candidate.path + ': showMainWindowForSend export' +
            ' pair count=' + exportsFound.length);
        continue;
    }
    const dismissName = exportsFound[0][1];
    const showName = exportsFound[0][2];
    if (dismissName === showName) {
        reasons.push(candidate.path + ': export pair aliases the same' +
            ' function');
        continue;
    }
    const showDef = defWindow(text, showName, 800);
    if (!showDef) {
        reasons.push(candidate.path + ': no function definition for ' +
            showName);
        continue;
    }
    if (/isFocused\s*\(/.test(showDef)) {
        reasons.push(candidate.path + ': ' + showName + ' is focus-gated' +
            ' before it shows the main window');
        continue;
    }
    let helperName = '';
    let winArg = '';
    const callRe = /(?<![\w$.])([\w$]+)\s*\(\s*([\w$]+)\s*\)/g;
    for (const cm of showDef.matchAll(callRe)) {
        const helper = cm[1];
        const arg = cm[2];
        const helperDef = defWindow(text, helper, 300);
        if (!helperDef) continue;
        const helperSig = new RegExp('function\\s+' + esc(helper) +
            '\\s*\\(\\s*([\\w$]+)').exec(helperDef);
        const helperParam = helperSig ? helperSig[1] : arg;
        const showCall = new RegExp('(?<![\\w$])' + esc(helperParam) +
            '\\s*\\.\\s*show\\s*\\(');
        if (showCall.test(helperDef) && !/isFocused\s*\(/.test(helperDef)) {
            helperName = helper;
            winArg = arg;
            break;
        }
    }
    if (helperName === '') {
        reasons.push(candidate.path + ': ' + showName + ' has no helper' +
            ' that calls show() without an isFocused() skip');
        continue;
    }
    const dismissDef = defWindow(text, dismissName, 1500);
    const dismissCallsShow = new RegExp('(?<![\\w$])' + esc(showName) +
        '\\s*\\(');
    if (!dismissDef || !dismissCallsShow.test(dismissDef)) {
        reasons.push(candidate.path + ': ' + dismissName + ' does not' +
            ' call ' + showName);
        continue;
    }
    const logRe = /["'`]Quick entry submitted["'`]/g;
    const logMatches = [...text.matchAll(logRe)];
    if (logMatches.length !== 1) {
        reasons.push(candidate.path + ': "Quick entry submitted"' +
            ' count=' + logMatches.length);
        continue;
    }
    const order = proveAttachmentOrder(text, logMatches[0].index);
    if (order.error) {
        reasons.push(candidate.path + ': ' + order.error);
        continue;
    }
    proof = {
        path: candidate.path,
        showName,
        dismissName,
        helperName,
        winArg,
        attachShow: order.show,
        attachDismiss: order.dismiss,
    };
    break;
}
if (!proof) {
    console.error('  [FAIL] Neither the legacy single-site shape nor the');
    console.error('         modern unconditional showMainWindowForSend');
    console.error('         contract could be proven:');
    for (const reason of reasons) {
        console.error('           - ' + reason);
    }
    process.exit(1);
}
console.log('  Modern Quick Entry contract verified in ' + proof.path +
    ': showMainWindowForSend -> ' + proof.showName + ' -> ' +
    proof.helperName + '(' + proof.winArg + ').show() with no' +
    ' isFocused() skip; ' + proof.dismissName + ' -> ' + proof.showName +
    '; attachment entry shows before dismiss');
process.exit(0);
QUICK_WINDOW_PATCH
	then
		echo '  [FAIL] Quick window Part 2 could not be proven; refusing' \
			'to ship a possibly broken Quick Entry submit path.' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo '##############################################################'
}
