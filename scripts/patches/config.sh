#
# @file config.sh
# @brief 設定ファイルの読み書きとフォルダ登録に関する3つのパッチをまとめる
#
# 1. 設定の読み込みに失敗しても、書き込みでmcpServersが消えないようにする
#    アプリ上で削除したサーバーは削除されたままにする
# 2. addTrustedFolderに.asarパスを拒否させる
# 3. --add-dirのCLI引き渡しとセッション復元から.asarの項目を取り除く
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : main_js、project_root
# 変更するグローバル変数 : なし
#

#
# @brief 設定の読み込みに失敗したとき、mcpServersをディスクから復元する
# @global main_js (参照のみ) パッチ対象のメインプロセス用index.js
# @global project_root (参照のみ) 異常終了時に戻る先
# @stdout 取り出した識別子と適用結果
# @note 適用済みかは_cdd_dcの有無で判定し、再実行しても二重に適用されない
# @note アンカーが1箇所に定まらない場合や識別子を取り出せない場合は
#       何も変更せずに戻る
#
patch_config_write_merge() {
	echo 'Patching config writer to keep mcpServers after a failed load...'
	local index_js="$main_js"

	# 適用済みなら何もしない (再実行しても二重に適用されない)
	if grep -q '_cdd_dc' "$index_js"; then
		echo '  mcpServers merge already present (idempotent)'
		echo '##############################################################'
		return
	fi

	# 何かを取り出す前に、一致箇所の数を明示的に確かめる
	# 挿入する場所は1箇所だけであるべきで
	# "Config file written"が2つあれば、新しい書き込み経路が増えたか
	# チャンクが統合されたことを意味し、位置が曖昧になる
	# その場合は推測せず、失敗として止める
	local anchor_count
	anchor_count=$(grep -oF '"Config file written"' "$index_js" | wc -l)
	if (( anchor_count > 1 )); then
		echo '  [FAIL] Expected one config-write anchor, found' \
			"$anchor_count" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	# 一意なアンカーから識別子を取り出す
	#   await WRITE_FN(PATH_VAR, CONFIG_VAR), LOGGER.info("Config file written")
	local write_fn path_var config_var write_fn_re path_var_re

	write_fn=$(grep -oP \
		'await \K[$\w]+(?=\([$\w]+,\s*[$\w]+\)\s*,\s*[$\w]+\.info\("Config file written"\))' \
		"$index_js")
	if [[ -z $write_fn ]]; then
		echo '  Could not extract write function name — skipping' >&2
		echo '##############################################################'
		return
	fi

	write_fn_re="${write_fn//\$/\\$}"

	path_var=$(grep -oP \
		"await ${write_fn_re}\\(\\K[\$\\w]+(?=,\\s*[\$\\w]+\\)\\s*,\\s*[\$\\w]+\\.info\\(\"Config file written\"\\))" \
		"$index_js")
	if [[ -z $path_var ]]; then
		echo '  Could not extract path variable — skipping' >&2
		echo '##############################################################'
		return
	fi

	path_var_re="${path_var//\$/\\$}"

	config_var=$(grep -oP \
		"await ${write_fn_re}\\(${path_var_re},\\s*\\K[\$\\w]+(?=\\)\\s*,\\s*[\$\\w]+\\.info\\(\"Config file written\"\\))" \
		"$index_js")
	if [[ -z $config_var ]]; then
		echo '  Could not extract config variable — skipping' >&2
		echo '##############################################################'
		return
	fi

	echo "  Write fn: $write_fn, path: $path_var, config: $config_var"

	if ! WRITE_FN="$write_fn" PATH_VAR="$path_var" CFG_VAR="$config_var" \
		INDEX_JS="$main_js" \
		node -e "
const fs = require('fs');
const p = process.env.INDEX_JS;
const W = process.env.WRITE_FN;
const P = process.env.PATH_VAR;
const C = process.env.CFG_VAR;
let code = fs.readFileSync(p, 'utf8');

const reEsc = (s) => s.replace(/[.*+?\${}()|[\\]\\\\]/g, '\\\\\$&');
const anchor = new RegExp(
  'await\\\\s+' + reEsc(W) + '\\\\(' + reEsc(P) + ',\\\\s*' + reEsc(C) +
  '\\\\)\\\\s*,\\\\s*[\\\\w\$]+\\\\.info\\\\(\"Config file written\"\\\\)'
);
if (!anchor.test(code)) {
  console.error('  [FAIL] Config-write anchor not found');
  process.exit(1);
}

// Restore mcpServers from disk only when the outgoing config has no
// mcpServers object at all: the loader falls back to an empty config
// when the read fails, and the next whole-file write would wipe every
// server. Deleting a server in Settings keeps the key with fewer
// entries, so it is written as-is. An entry-level merge must not
// return: the deleted entry is still on disk at write time, so it
// resurrects every server removed in Settings. A server added to the
// file while the app runs is overwritten, as upstream does; edit the
// file with the app closed.
const merge =
  'try{if(' + C + '.mcpServers==null){' +
  'var _cdd_dc=JSON.parse(require(\"fs\").readFileSync(' + P +
  ',\"utf8\")),_cdd_dm=_cdd_dc&&_cdd_dc.mcpServers;' +
  'if(_cdd_dm&&typeof _cdd_dm==\"object\"&&!Array.isArray(_cdd_dm))' +
  C + '.mcpServers=Object.assign({},_cdd_dm)}}catch(_cdd_ex){}';

// Assert an exact anchor count before rewriting: a second occurrence (a
// new write path, or the pattern surfacing in a merged chunk) would make
// the single replace site ambiguous and silently mis-place the merge.
const matches = [...code.matchAll(new RegExp(anchor.source, 'g'))];
if (matches.length !== 1) {
  console.error('  [FAIL] Expected one config-write anchor, found ' +
    matches.length);
  process.exit(1);
}

const anchorIdx = matches[0].index;
const searchStart = Math.max(0, anchorIdx - 500);
const beforeAnchor = code.slice(searchStart, anchorIdx);
const returnMatch = /(try\s*\{)\s*return\s*$/.exec(beforeAnchor);
if (returnMatch) {
  // Newer bundles put the awaited write in a try/return expression.
  // Insert after the outer try brace so the merge stays a statement:
  //   try{MERGE;return await WRITE(...)}
  // rather than emitting a return followed by a try statement.
  const insertAt = searchStart + returnMatch.index + returnMatch[1].length;
  code = code.slice(0, insertAt) + merge + ';' + code.slice(insertAt);
} else {
  // Older bundles use the write as a standalone statement.
  code = code.slice(0, anchorIdx) + merge + ';' + code.slice(anchorIdx);
}
fs.writeFileSync(p, code);
console.log('  [OK] mcpServers merge injected before config write');
"; then
		echo 'Failed to inject config write merge' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo '##############################################################'
}

#
# @brief addTrustedFolderが.asarパスを受け付けないようにする
# @global main_js (参照のみ) メインプロセス用index.jsの起点
# @global project_root (参照のみ) 異常終了時に戻る先
# @stdout 適用またはスキップのメッセージ
# @note 1.44121.4以降は処理本体が兄弟のチャンクへ移っているため
#       main_jsとすべてのindex.chunk-*.jsを対象にする
# @note アンカーが無い場合や候補が複数ある場合は警告を出して
#       何も変更しない
#       Windows版インストーラ由来のバンドルでは不在が
#       そのまま不具合とは限らないため、失敗にはしない
#
patch_asar_trusted_folder_guard() {
	echo 'Patching addTrustedFolder to reject .asar paths...'
	local index_js="$main_js"

	# 処理本体は解決済みのメインのチャンクから兄弟の
	# コード分割チャンクへ移っている
	# IPCルーターの登録["addTrustedFolder",[["folder",P]]]は
	# メインのチャンクに残るため、main_jsだけをアンカーにすると
	# 本体を見落とす
	# main_jsとすべてのindex.chunk-*.jsを対象にし
	# patch_asar_additional_dirs_guardと同じ探し方をする
	# アンカーが無い場合や候補が複数ある場合も、
	# 警告を出すだけで失敗にはしない
	if ! INDEX_JS="$index_js" node << 'ASAR_TRUSTED_PATCH'
const fs = require('fs');
const path = require('path');
const indexJs = process.env.INDEX_JS;
const buildDir = path.dirname(indexJs);
const chunkNameRe = /^index\.chunk-[A-Za-z0-9_-]+\.js$/;
let chunkPaths = [];
try {
    chunkPaths = fs.readdirSync(buildDir)
        .filter((name) => chunkNameRe.test(name))
        .sort()
        .map((name) => path.join(buildDir, name));
} catch (e) {
    chunkPaths = [];
}
// Monolithic (pre-split) bundles have no chunks, so $main_js itself is
// always a candidate; sibling chunks are appended de-duplicated.
const seen = new Set([path.resolve(indexJs)]);
const candidates = [indexJs];
for (const chunk of chunkPaths) {
    if (!seen.has(path.resolve(chunk))) {
        seen.add(path.resolve(chunk));
        candidates.push(chunk);
    }
}
const chunks = candidates
    .filter((file) => {
        try {
            return fs.statSync(file).isFile();
        } catch (e) {
            return false;
        }
    })
    .map((file) => ({
        file,
        code: fs.readFileSync(file, 'utf8'),
    }));
// One shape covers the legacy method head
// (`async addTrustedFolder(folder){`) and the current one
// (`async addTrustedFolder(e){` in the sibling chunk since 1.44121.4):
// the method name is not minified, only the parameter is. Each shape
// pairs the raw form with the patched form so a rerun recognises its
// own output; the raw negative lookahead keeps a patched site from
// matching as raw (the method head is a prefix of its own patched
// form). The trailing ";" in the patched `return;` is load-bearing:
// the async stat helper patched by patch_asar_path_filter injects
// `if(PARAM.endsWith(".asar"))return null;`, which must not register
// as this guard.
const guardTail =
    '\\(\\s*"\\.asar"\\s*\\)\\s*\\)\\s*return\\s*;';
const shapes = [
    {
        raw: new RegExp(
            'async\\s+addTrustedFolder\\(\\s*([\\w$]+)\\s*\\)\\s*\\{' +
            '(?!\\s*if\\(\\s*\\1\\.endsWith' + guardTail + ')', 'g'),
        patched: new RegExp(
            'async\\s+addTrustedFolder\\(\\s*([\\w$]+)\\s*\\)\\s*\\{' +
            '\\s*if\\(\\s*\\1\\.endsWith' + guardTail, 'g'),
        rewrite: (match) =>
            'async addTrustedFolder(' + match[1] + '){if(' +
            match[1] + '.endsWith(".asar"))return;',
    },
];

const collect = (key) => shapes.flatMap((shape) =>
    chunks.flatMap((chunk) => {
        shape[key].lastIndex = 0;
        return [...chunk.code.matchAll(shape[key])].map((match) => ({
            chunk,
            match,
            shape,
        }));
    }));

const rawHits = collect('raw');
const patchedHits = collect('patched');
if (rawHits.length > 1 || patchedHits.length > 1 ||
    (rawHits.length > 0 && patchedHits.length > 0)) {
    console.warn('  [WARN] addTrustedFolder anchor is ambiguous' +
        ' (raw: ' + rawHits.length + ', patched: ' + patchedHits.length +
        '); the .asar trusted-folder guard was NOT applied');
    process.exit(0);
}
if (rawHits.length === 0 && patchedHits.length === 0) {
    console.warn('  [WARN] addTrustedFolder anchor not found; the .asar' +
        ' trusted-folder guard was NOT applied');
    process.exit(0);
}
if (patchedHits.length === 1) {
    console.log('  .asar guard already present (idempotent)');
    process.exit(0);
}

const hit = rawHits[0];
hit.chunk.code = hit.chunk.code.slice(0, hit.match.index) +
    hit.shape.rewrite(hit.match) +
    hit.chunk.code.slice(hit.match.index + hit.match[0].length);
fs.writeFileSync(hit.chunk.file, hit.chunk.code);
console.log('  [OK] .asar guard injected in addTrustedFolder in ' +
    path.basename(hit.chunk.file));
ASAR_TRUSTED_PATCH
	then
		echo 'Failed to inject .asar trusted folder guard' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo '##############################################################'
}

#
# @brief --add-dirのCLI引き渡しとセッション復元から.asarパスを取り除く
# @global main_js (参照のみ) メインプロセス用index.jsの起点
# @stdout 適用またはスキップの結果
# @note PR #640はディレクトリ判定の補助関数とaddTrustedFolderのIPC
#       ハンドラーを守るが、#640より前の壊れたセッションに残る
#       .asarパスは復元され (ElectronのASAR仮想ファイルシステムにより
#       existsSyncが通る)、additionalDirectoriesから--add-dirへ渡り
#       Claude Codeの致命的なエラーになる
# @note 2つの副パッチで直す
#       1. --add-dirのCLI引き渡しループで取り除く
#          additionalDirectoriesを渡すすべての経路がここに集まるため
#       2. セッション復元時にも取り除き、壊れた保存状態を自力で直す
# @note 対象を決められない場合や形が見つからない場合は、
#       誤った箇所を書き換えないよう1で終了する (#649)
#
patch_asar_additional_dirs_guard() {
	echo 'Patching --add-dir dispatch to reject .asar paths (#649)...'
	local index_js="$main_js"

	if ! INDEX_JS="$index_js" node << 'ASAR_ADDDIR_PATCH'
const fs = require('fs');
const path = require('path');
const indexJs = process.env.INDEX_JS;
const buildDir = path.dirname(indexJs);
const chunkNameRe = /^index\.chunk-[A-Za-z0-9_-]+\.js$/;
const chunkPaths = fs.readdirSync(buildDir)
    .filter((name) => chunkNameRe.test(name))
    .sort()
    .map((name) => path.join(buildDir, name));
if (chunkPaths.length === 0) {
    console.error('FATAL: no safe main-process chunks found.');
    process.exit(1);
}

const chunks = chunkPaths.map((file) => ({
    file,
    code: fs.readFileSync(file, 'utf8'),
}));
// Each shape pairs the raw upstream form with the form this patch
// writes, so a rerun recognises its own output. 2.37337.1 wraps the
// flag in a joiner (`w.push(Y7("--add-dir",t))` -> "--add-dir=<dir>"),
// and moved session restore to `d=u?[]:l.userSelectedFolders??[]`;
// the restore shape is tied to its log message so the other
// userSelectedFolders reads in the same chunk never match.
const asarFilter = '.filter(_d=>!_d.endsWith(".asar"))';
const filterForOf = (match) =>
    match[0].replace(/(\bof\s+[\w$]+)(\s*\))/, '$1' + asarFilter + '$2');
const restoreTail =
    '(?=\\s*;[\\s\\S]{0,600}?Filtering out deleted folder from session)';
const dispatchShapes = [
    {
        raw: /for\s*\(\s*let\s+([\w$]+)\s+of\s+([\w$]+)\s*\)\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\1\s*\)/g,
        patched: /for\s*\(\s*let\s+([\w$]+)\s+of\s+([\w$]+)\.filter\(\s*([\w$]+)\s*=>\s*!\s*\3\.endsWith\(\s*"\.asar"\s*\)\s*\)\s*\)\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\1\s*\)/g,
        rewrite: filterForOf,
    },
    {
        raw: /for\s*\(\s*let\s+([\w$]+)\s+of\s+([\w$]+)\s*\)\s*([\w$]+)\.push\(\s*([\w$]+)\(\s*"--add-dir"\s*,\s*\1\s*\)\s*\)/g,
        patched: /for\s*\(\s*let\s+([\w$]+)\s+of\s+([\w$]+)\.filter\(\s*([\w$]+)\s*=>\s*!\s*\3\.endsWith\(\s*"\.asar"\s*\)\s*\)\s*\)\s*([\w$]+)\.push\(\s*([\w$]+)\(\s*"--add-dir"\s*,\s*\1\s*\)\s*\)/g,
        rewrite: filterForOf,
    },
    {
        raw: /([\w$]+)\.forEach\(\s*([\w$]+)\s*=>\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\2\s*\)\s*\)/g,
        patched: /([\w$]+)\.filter\(\s*([\w$]+)\s*=>\s*!\s*\2\.endsWith\(\s*"\.asar"\s*\)\s*\)\.forEach\(\s*([\w$]+)\s*=>\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\3\s*\)\s*\)/g,
        rewrite: (match) => match[1] + asarFilter + '.forEach(' + match[2] +
            '=>' + match[3] + '.push("--add-dir",' + match[2] + '))',
    },
];
const sessionShapes = [
    {
        raw: /(\([\w$]+\.userSelectedFolders\s*\|\|\s*\[\s*\]\s*\))\s*\.\s*(filter|map)\s*\(\s*(?![\w$]+\s*=>\s*!\s*[\w$]+\.endsWith\s*\(\s*"\.asar")/g,
        patched: /(\([\w$]+\.userSelectedFolders\s*\|\|\s*\[\s*\]\s*\))\s*\.filter\(\s*([\w$]+)\s*=>\s*!\s*\2\.endsWith\(\s*"\.asar"\s*\)\s*\)\s*\.\s*(?:filter|map)\s*\(/g,
        rewrite: (match) => match[1] + asarFilter + '.' + match[2] + '(',
    },
    {
        raw: new RegExp('(?<![\\w$.(])([\\w$]+\\.userSelectedFolders\\s*\\?\\?\\s*\\[\\s*\\])' +
            restoreTail, 'g'),
        patched: new RegExp('\\(\\s*[\\w$]+\\.userSelectedFolders\\s*\\?\\?\\s*\\[\\s*\\]\\s*\\)' +
            '\\s*\\.filter\\(\\s*([\\w$]+)\\s*=>\\s*!\\s*\\1\\.endsWith\\(\\s*"\\.asar"\\s*\\)\\s*\\)' +
            restoreTail, 'g'),
        rewrite: (match) => '(' + match[1] + ')' + asarFilter,
    },
];

const collect = (shapes, key) => shapes.flatMap((shape) =>
    chunks.flatMap((chunk) => {
        shape[key].lastIndex = 0;
        return [...chunk.code.matchAll(shape[key])].map((match) => ({
            chunk,
            match,
            shape,
        }));
    }));
const applyRewrite = ({ chunk, match, shape }) => {
    chunk.code = chunk.code.slice(0, match.index) + shape.rewrite(match) +
        chunk.code.slice(match.index + match[0].length);
    if (!writes.includes(chunk)) {
        writes.push(chunk);
    }
};

const writes = [];
const dispatchRaw = collect(dispatchShapes, 'raw');
const dispatchPatched = collect(dispatchShapes, 'patched');
if (dispatchRaw.length > 1 || dispatchPatched.length > 1 ||
    (dispatchRaw.length > 0 && dispatchPatched.length > 0)) {
    console.error('FATAL: --add-dir dispatch has ambiguous candidates.');
    process.exit(1);
}
if (dispatchRaw.length === 0 && dispatchPatched.length === 0) {
    console.error('FATAL: --add-dir dispatch loop not found.');
    console.error('  No unique raw or patched dispatch exists in safe chunks.');
    process.exit(1);
}

if (dispatchRaw.length === 1) {
    applyRewrite(dispatchRaw[0]);
    console.log('  Filtered --add-dir dispatch in ' +
        path.basename(dispatchRaw[0].chunk.file));
} else {
    console.log('  .asar --add-dir filter already present (idempotent)');
}

const sessionRaw = collect(sessionShapes, 'raw');
const sessionPatched = collect(sessionShapes, 'patched');
if (sessionRaw.length > 1 || sessionPatched.length > 1 ||
    (sessionRaw.length > 0 && sessionPatched.length > 0)) {
    console.error('FATAL: session restore filter has ambiguous candidates.');
    process.exit(1);
}
if (sessionRaw.length === 1) {
    applyRewrite(sessionRaw[0]);
    console.log('  Injected .asar filter in session restore in ' +
        path.basename(sessionRaw[0].chunk.file));
} else if (sessionPatched.length === 1) {
    console.log('  Session restore filter already present (idempotent)');
} else {
    const hasSessionData = chunks.some((chunk) =>
        chunk.code.includes('userSelectedFolders'));
    if (hasSessionData) {
        console.error('FATAL: userSelectedFolders shape is unsupported.');
        process.exit(1);
    }
    console.log('  WARNING: session restore anchor not found');
}

for (const chunk of writes) {
    fs.writeFileSync(chunk.file, chunk.code);
}
console.log('  Applied ' + writes.length +
    ' .asar additionalDirectories patch(es)');
ASAR_ADDDIR_PATCH
	then
		echo 'FATAL: .asar --add-dir filter patch failed' >&2
		echo 'Local agent mode will crash without this patch (#649).' >&2
		exit 1
	fi

	echo '##############################################################'
}
