#
# @file updater.sh
# @brief Linuxで自動更新と更新メタデータの取得を完全に止めるパッチ (D-001)
#
# Windowsの.nupkg由来のバンドルは、Linuxでも自動更新の判定と更新情報の
# 取得を行う。Linux向けの更新経路は存在しないため、次の3か所を塞ぐ。
#
#   1. 自動更新が有効かどうかの判定 (Oz)
#      Linuxでは常に無効を返し、起動時の更新タイマー、モダンインストーラー
#      への移行、メニューの[Check for Updates...]、更新チャネルのUIを止める
#   2. 更新チェックの入口 (Hki)
#      Linuxでは"skipped"を返し、手動チェック、低データ時のチェック、
#      autoUpdaterの呼び出しを止める
#   3. 更新メタデータの取得 (gki)
#      Linuxでは{status:204,ok:false}を返し、net.fetchによる更新情報の
#      取得を一切行わない。204は呼び出し側で{kind:"none"}として扱われる
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : main_js、project_root
# 変更するグローバル変数 : なし
#
# @note minifyされた識別子は使わず、上流の文字列と構造だけをアンカーにする
# @note 3か所のどれかが一意に定まらない場合は、何も書き換えずに失敗する
#

#
# @brief Linuxで自動更新と更新メタデータの取得を止める
# @global main_js (参照のみ) パッチ対象のメインプロセス用index.js
# @global project_root (参照のみ) 異常終了時に戻る先
# @stdout 各ガードの適用結果
# @note 適用済みのガードは再実行しても二重に挿入しない
#
patch_disable_auto_updater() {
	echo 'Patching auto-updater to stay disabled on Linux...'
	INDEX_JS="$main_js" PATCH_WORK_DIR="${work_dir:-${PATCH_WORK_DIR:-}}" \
		node << 'UPDATER_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code;
try {
    code = fs.readFileSync(indexJs, 'utf8');
} catch (e) {
    console.error('ERROR: cannot read ' + indexJs + ': ' + e.message);
    process.exit(1);
}

const q = '[`"\']';
const linuxGuard = 'if(process.platform==="linux")';
const escapeRe = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Return the index just past the balanced brace block that opens at openIdx,
// or -1 when the source ends first. Braces inside strings are rare in the
// updater region, so a plain balance is enough here.
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

// Masking keeps every offset stable while hiding comments (and, for the
// brace-balanced scan, string/template bodies). A comment that contains
// `async function fake() {` must never become the owner of a real anchor.
const maskSource = (source, withStrings) => {
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
        } else if (withStrings &&
            (source[i] === '"' || source[i] === "'" || source[i] === '`')) {
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

const codeNoComments = maskSource(code, false);
const codeMasked = maskSource(code, true);

// Return the innermost named function whose brace-balanced body contains idx.
// The anchor string alone says nothing about which function owns it: a scan
// backwards for the nearest head can stop at a function that already closed
// (Vki) and patch the wrong body. Containment, not distance, decides.
// The source passed here is the string-masked copy, so braces inside
// literals cannot shift the balance either.
const functionHeadRe =
    /(?:async\s+)?function\s+([\w$]+)\s*\(([^()]*)\)\s*\{/g;
const enclosingFunction = (source, idx) => {
    let best = null;
    functionHeadRe.lastIndex = 0;
    let match;
    while ((match = functionHeadRe.exec(source)) !== null) {
        const open = match.index + match[0].length - 1;
        const end = braceEnd(source, open);
        if (end === -1 || idx <= open || idx >= end) continue;
        if (best === null || match.index > best.start) {
            best = {
                name: match[1],
                start: match.index,
                bodyStart: open + 1,
                bodyEnd: end - 1,
                async: /^async\s/.test(match[0]),
            };
        }
    }
    return best;
};

// 1. Oz(): 自動更新の有効判定。Linuxでは常に無効にする。
//    上流はforceInstalledの判定の後で"win32以外ならapp.isPackaged"を返す。
//    Linuxの早期returnは、そのwin32判定の直前ではなく、Oz()本体の先頭に
//    置く。forceInstalledが真でもLinuxでは更新を有効にしないため。
//    起動時の更新タイマーやメニュー項目はOz()を見る。
const ozRe = new RegExp(
    '(if\\s*\\(\\s*process\\.platform\\s*!==\\s*' + q + 'win32' + q +
    '\\s*\\)\\s*return\\s+[\\w$]+\\s*\\.\\s*app\\s*\\.\\s*isPackaged\\s*;)', 'g');
const notInstalledMsg = '[updater] App is not installed, not enabling auto-updates';

// 2. Hki(): 更新チェックの入口。エンタープライズポリシーのメッセージを
//    含む非同期関数を探し、その先頭でLinuxを"skipped"にする。
//    上流のメッセージ文字列はminifyされないため、識別子に依存しない。
//    対象はメッセージを本体に含む関数そのものであり、引数の数は問わない。
//    後方へ遡って直近の零引数async functionを選ぶと、既に閉じた別の
//    関数(Vkiなど)を書き換えてしまうため、波括弧の対応で内包関係を確かめる。
const enterpriseMsg = '[updater] Skipping update check: auto-updates disabled by enterprise policy';

// 3. gki(e): 更新メタデータの取得。net.fetch(<builder>(<base>,"msix",e))
//    だけを本体に持つ非同期関数を構造で探す。
const gkiRe = new RegExp(
    '(async\\s+function\\s+)([\\w$]+)(\\s*\\(\\s*)([\\w$]+)(\\s*\\)\\s*\\{\\s*return\\s+)' +
    '([\\w$]+)(\\s*\\.\\s*net\\s*\\.\\s*fetch\\s*\\(\\s*)([\\w$]+)(\\s*\\(\\s*)([\\w$]+)' +
    '(\\s*,\\s*)(' + q + ')msix\\12' +
    '(\\s*,\\s*)([\\w$]+)(\\s*\\)\\s*\\)\\s*\\})', 'g');
const gkiAppliedRe = new RegExp(
    '(async\\s+function\\s+)([\\w$]+)(\\s*\\(\\s*)([\\w$]+)(\\s*\\)\\s*\\{\\s*)' +
    'if\\s*\\(\\s*process\\.platform\\s*===\\s*' + q + 'linux' + q +
    '\\s*\\)\\s*return\\s*\\{\\s*status\\s*:\\s*204\\s*,\\s*ok\\s*:\\s*!1\\s*\\}\\s*;\\s*' +
    'return\\s+([\\w$]+)\\s*\\.\\s*net\\s*\\.\\s*fetch\\s*\\(\\s*([\\w$]+)\\s*\\(\\s*' +
    '([\\w$]+)\\s*,\\s*' + q + 'msix' + q + '\\s*,\\s*\\4\\s*\\)\\s*\\)\\s*\\}', 'g');

const isFunctionNode = (node) => node &&
    (node.type === 'FunctionDeclaration' ||
     node.type === 'FunctionExpression' ||
     node.type === 'ArrowFunctionExpression');

const walkAst = (node, fn, visit) => {
    if (!node || typeof node.type !== 'string') return;
    const current = isFunctionNode(node) ? node : fn;
    visit(node, current);
    for (const key of Object.keys(node)) {
        if (key === 'type' || key === 'start' || key === 'end') continue;
        const value = node[key];
        if (Array.isArray(value)) {
            for (const child of value) walkAst(child, current, visit);
        } else if (value && typeof value.type === 'string') {
            walkAst(value, current, visit);
        }
    }
};

const isProcessPlatform = (node) => node &&
    node.type === 'MemberExpression' && !node.computed &&
    node.object.type === 'Identifier' && node.object.name === 'process' &&
    node.property && node.property.type === 'Identifier' &&
    node.property.name === 'platform';

const isAppIsPackaged = (node) => node &&
    node.type === 'MemberExpression' && !node.computed &&
    node.property.type === 'Identifier' && node.property.name === 'isPackaged' &&
    node.object.type === 'MemberExpression' && !node.object.computed &&
    node.object.property && node.object.property.type === 'Identifier' &&
    node.object.property.name === 'app';

const astOwner = (fn) => {
    if (!fn || !fn.body || fn.body.type !== 'BlockStatement') return null;
    return {
        name: fn.id && fn.id.name ? fn.id.name : '(anonymous)',
        bodyStart: fn.body.start + 1,
        bodyEnd: fn.body.end - 1,
        async: fn.async === true,
    };
};

const locateWithAcorn = (tree) => {
    const ozHits = [];
    let notInstalledAt = -1;
    let notInstalledCount = 0;
    walkAst(tree, null, (node, fn) => {
        if (node.type === 'Literal' && node.value === notInstalledMsg) {
            notInstalledCount += 1;
            if (notInstalledAt === -1) notInstalledAt = node.start;
        }
        if (node.type !== 'IfStatement' || !fn) return;
        const test = node.test;
        if (!test || test.type !== 'BinaryExpression' ||
            test.operator !== '!==' || !isProcessPlatform(test.left) ||
            !(test.right.type === 'Literal' && test.right.value === 'win32')) {
            return;
        }
        const consequent = node.consequent;
        const returns = consequent.type === 'BlockStatement'
            ? consequent.body.filter((s) => s.type === 'ReturnStatement')
            : (consequent.type === 'ReturnStatement' ? [consequent] : []);
        if (!returns.some((r) => isAppIsPackaged(r.argument))) return;
        const owner = astOwner(fn);
        if (owner !== null) ozHits.push({ owner, ifNode: node });
    });
    let oz = null;
    if (ozHits.length === 0) {
        oz = { error: 'Oz() auto-update gate (process.platform!=="win32" ... app.isPackaged not found)' };
    } else if (ozHits.length > 1) {
        oz = { error: 'Oz() auto-update gate (ambiguous: ' + ozHits.length + ' sites)' };
    } else if (notInstalledCount !== 1 || notInstalledAt < 0 ||
        ozHits[0].ifNode.start - notInstalledAt > 800 ||
        ozHits[0].ifNode.start < notInstalledAt) {
        oz = { error: 'Oz() auto-update gate (not next to the "not installed" updater message)' };
    } else {
        oz = { owner: ozHits[0].owner };
    }

    const hkiHits = [];
    walkAst(tree, null, (node, fn) => {
        if (node.type !== 'CallExpression' || !fn) return;
        if (!node.arguments.some((arg) => arg.type === 'Literal' &&
            arg.value === enterpriseMsg)) return;
        const owner = astOwner(fn);
        if (owner !== null) hkiHits.push(owner);
    });
    let hki = null;
    if (hkiHits.length === 0) {
        hki = { error: 'Hki() update-check entry (' + enterpriseMsg + ' not found)' };
    } else if (hkiHits.length > 1) {
        hki = { error: 'Hki() update-check entry (anchor is ambiguous: ' + hkiHits.length + ' sites)' };
    } else {
        hki = { owner: hkiHits[0] };
    }

    const gkiHits = [];
    walkAst(tree, null, (node, fn) => {
        if (node.type !== 'ReturnStatement' || !fn || !fn.async) return;
        const call = node.argument;
        if (!call || call.type !== 'CallExpression') return;
        const callee = call.callee;
        if (!callee || callee.type !== 'MemberExpression' || callee.computed ||
            !callee.property || callee.property.type !== 'Identifier' ||
            callee.property.name !== 'fetch') return;
        const net = callee.object;
        if (!net || net.type !== 'MemberExpression' || net.computed ||
            !net.property || net.property.type !== 'Identifier' ||
            net.property.name !== 'net') return;
        const args = call.arguments;
        if (!args || args.length !== 1) return;
        const builder = args[0];
        if (!builder || builder.type !== 'CallExpression') return;
        if (builder.callee.type !== 'Identifier') return;
        const builderArgs = builder.arguments;
        if (!builderArgs || builderArgs.length !== 3) return;
        if (!(builderArgs[1] && builderArgs[1].type === 'Literal' &&
            builderArgs[1].value === 'msix')) return;
        if (!builderArgs[2] || builderArgs[2].type !== 'Identifier') return;
        const param = fn.params && fn.params[0];
        if (!param || param.type !== 'Identifier' ||
            param.name !== builderArgs[2].name) return;
        const owner = astOwner(fn);
        if (owner !== null) gkiHits.push(owner);
    });
    let gki = null;
    if (gkiHits.length === 0) {
        gki = { error: 'gki() update-metadata fetch (net.fetch(...,"msix",...) not found)' };
    } else if (gkiHits.length > 1) {
        gki = { error: 'gki() update-metadata fetch (inconsistent or ambiguous Linux guard)' };
    } else {
        gki = { owner: gkiHits[0] };
    }
    return { oz, hki, gki };
};

const locateWithTokens = () => {
    const ozMatches = [...codeNoComments.matchAll(ozRe)];
    const notInstalledAt = codeNoComments.indexOf(notInstalledMsg);
    const notInstalledCount = [...codeNoComments.matchAll(
        new RegExp(escapeRe(notInstalledMsg), 'g'))].length;
    let oz = null;
    if (ozMatches.length === 0) {
        oz = { error: 'Oz() auto-update gate (process.platform!=="win32" ... app.isPackaged not found)' };
    } else if (ozMatches.length > 1) {
        oz = { error: 'Oz() auto-update gate (ambiguous: ' + ozMatches.length + ' sites)' };
    } else if (notInstalledCount !== 1 || notInstalledAt < 0 ||
        ozMatches[0].index - notInstalledAt > 800 ||
        ozMatches[0].index < notInstalledAt) {
        oz = { error: 'Oz() auto-update gate (not next to the "not installed" updater message)' };
    } else {
        const owner = enclosingFunction(codeMasked, ozMatches[0].index);
        oz = owner === null
            ? { error: 'Oz() auto-update gate (no enclosing function for the win32 check)' }
            : { owner };
    }

    const msgAt = codeNoComments.indexOf(enterpriseMsg);
    const msgCount = [...codeNoComments.matchAll(
        new RegExp(escapeRe(enterpriseMsg), 'g'))].length;
    let hki = null;
    if (msgAt === -1) {
        hki = { error: 'Hki() update-check entry (' + enterpriseMsg + ' not found)' };
    } else if (msgCount !== 1) {
        hki = { error: 'Hki() update-check entry (anchor is ambiguous: ' + msgCount + ' sites)' };
    } else {
        const owner = enclosingFunction(codeMasked, msgAt);
        hki = owner === null
            ? { error: 'Hki() update-check entry (no enclosing async function)' }
            : { owner };
    }

    const applied = [...codeNoComments.matchAll(gkiAppliedRe)];
    const matches = [...codeNoComments.matchAll(gkiRe)];
    let gki = null;
    if (applied.length === 1 && matches.length === 0) {
        gki = { applied: true };
    } else if (applied.length > 1 ||
        (applied.length === 1 && matches.length > 0)) {
        gki = { error: 'gki() update-metadata fetch (inconsistent or ambiguous Linux guard)' };
    } else if (matches.length === 0) {
        gki = { error: 'gki() update-metadata fetch (net.fetch(...,"msix",...) not found)' };
    } else if (matches.length > 1) {
        gki = { error: 'gki() update-metadata fetch (ambiguous: ' + matches.length + ' sites)' };
    } else {
        const m = matches[0];
        const open = m.index + m[0].indexOf('{');
        const end = braceEnd(codeMasked, open);
        if (end === -1) {
            gki = { error: 'gki() update-metadata fetch (unbalanced function body)' };
        } else {
            gki = { owner: {
                name: m[2],
                bodyStart: open + 1,
                bodyEnd: end - 1,
                async: true,
            } };
        }
    }
    return { oz, hki, gki };
};

let located = null;
const acorn = loadAcorn();
if (acorn !== null) {
    try {
        located = locateWithAcorn(acorn.parse(code,
            { ecmaVersion: 'latest', sourceType: 'script' }));
    } catch (e) {
        located = null;
    }
}
if (located === null) located = locateWithTokens();

let changed = 0;
const failures = [];
const replacements = [];

// ---- 1. Oz() ----
{
    if (located.oz.error) {
        failures.push(located.oz.error);
    } else {
        const owner = located.oz.owner;
        const bodyStart = owner.bodyStart;
        const bodyEnd = owner.bodyEnd;
        const body = code.slice(bodyStart, bodyEnd);
        const insert = linuxGuard + 'return!1;';
        const at = body.indexOf(insert);
        if (at === 0) {
            console.log('  Oz(): Linux auto-update gate already present');
        } else if (at > 0) {
            // Move an older misplaced guard (inserted before the win32
            // check) to the head so forceInstalled cannot re-enable
            // updates on Linux.
            replacements.push({
                start: bodyStart,
                end: bodyEnd,
                text: insert + body.slice(0, at) +
                    body.slice(at + insert.length),
            });
            changed += 1;
            console.log('  Oz(): Linux auto-update gate moved to the function start');
        } else {
            replacements.push({
                start: bodyStart,
                end: bodyStart,
                text: insert,
            });
            changed += 1;
            console.log('  Oz(): Linux returns false before the forceInstalled/win32 checks');
        }
    }
}

// ---- 2. Hki() ----
{
    if (located.hki.error) {
        failures.push(located.hki.error);
    } else if (!located.hki.owner.async) {
        failures.push('Hki() update-check entry (no enclosing async function)');
    } else {
        const owner = located.hki.owner;
        const bodyStart = owner.bodyStart;
        const body = code.slice(bodyStart, owner.bodyEnd);
        const guard = linuxGuard + 'return"skipped";';
        if (body.startsWith(guard)) {
            console.log('  Hki(): Linux early return already present');
        } else if (body.includes(guard)) {
            failures.push('Hki() update-check entry (Linux guard found away from the function head)');
        } else {
            replacements.push({ start: bodyStart, end: bodyStart, text: guard });
            changed += 1;
            console.log('  Hki(): Linux returns "skipped" at the entry point (fn: ' + owner.name + ')');
        }
    }
}

// ---- 3. gki() ----
{
    if (located.gki.error) {
        failures.push(located.gki.error);
    } else if (located.gki.applied) {
        console.log('  gki(): Linux 204 short-circuit already present');
    } else {
        const owner = located.gki.owner;
        const bodyStart = owner.bodyStart;
        const guard = linuxGuard + 'return{status:204,ok:!1};';
        const body = code.slice(bodyStart, bodyStart + 120);
        if (body.startsWith(guard)) {
            console.log('  gki(): Linux 204 short-circuit already present');
        } else if (body.includes(guard)) {
            failures.push('gki() update-metadata fetch (Linux guard found away from the function head)');
        } else {
            replacements.push({ start: bodyStart, end: bodyStart, text: guard });
            changed += 1;
            console.log('  gki(): Linux returns {status:204,ok:false} before net.fetch');
        }
    }
}

if (failures.length > 0) {
    for (const failure of failures) {
        console.error('ERROR: updater patch anchor failed: ' + failure);
    }
    console.error('Refusing to ship a bundle that still reaches the updater on Linux.');
    process.exit(1);
}

replacements.sort((a, b) => b.start - a.start);
for (const replacement of replacements) {
    code = code.slice(0, replacement.start) + replacement.text +
        code.slice(replacement.end);
}

if (changed === 0) {
    console.log('  Auto-updater is already disabled on Linux');
} else {
    fs.writeFileSync(indexJs, code);
    console.log('  Applied ' + changed + ' Linux auto-updater guard(s)');
}
UPDATER_PATCH
	local status=$?
	if (( status != 0 )); then
		echo 'ERROR: Linux auto-updater patch failed; refusing to ship a partial patch.' >&2
		cd "$project_root" 2>/dev/null || true
		return 1
	fi
}
