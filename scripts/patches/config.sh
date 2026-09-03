#===============================================================================
# Config-related patches: preserve externally-added mcpServers across config
# writes, guard addTrustedFolder against .asar paths, and filter .asar entries
# from the --add-dir CLI dispatch and session restore.
#
# Sourced by: build.sh
# Sourced globals: project_root
# Modifies globals: (none)
#===============================================================================

patch_config_write_merge() {
	echo 'Patching config writer to preserve mcpServers from disk...'
	local index_js="$main_js"

	# Idempotency guard
	if grep -q '_cdd_dc' "$index_js"; then
		echo '  mcpServers merge already present (idempotent)'
		echo '##############################################################'
		return
	fi

	# Extract variable names from the unique anchor:
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
  '\\\\)\\\\s*,\\\\s*\\\\w+\\\\.info\\\\(\"Config file written\"\\\\)'
);
if (!anchor.test(code)) {
  console.error('  [FAIL] Config-write anchor not found');
  process.exit(1);
}

const merge =
  'try{var _cdd_dc=JSON.parse(require(\"fs\").readFileSync(' + P +
  ',\"utf8\"));if(_cdd_dc.mcpServers){' + C +
  '.mcpServers=Object.assign({},_cdd_dc.mcpServers,' + C +
  '.mcpServers||{})}}catch(_cdd_ex){}';

const matches = [...code.matchAll(new RegExp(anchor.source, 'g'))];
if (matches.length !== 1) {
  console.error('  [FAIL] Expected one config-write anchor, found ' +
    matches.length);
  process.exit(1);
}

const anchorIdx = matches[0].index;
const searchStart = Math.max(0, anchorIdx - 500);
const beforeAnchor = code.slice(searchStart, anchorIdx);
const returnMatch = /try\{return\s*$/.exec(beforeAnchor);
if (returnMatch) {
  // Newer bundles put the awaited write in a try/return expression.
  // Insert after the outer try brace so the merge remains a statement:
  // try{MERGE;return await ...}, rather than return followed by try.
  const returnIdx = searchStart + returnMatch.index;
  const insertAt = returnIdx + 'try{'.length;
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

patch_asar_trusted_folder_guard() {
	echo 'Patching addTrustedFolder to reject .asar paths...'
	local index_js="$main_js"

	# Idempotency guard
	if grep -qF 'endsWith(".asar"))return' "$index_js"; then
		echo '  .asar guard already present (idempotent)'
		echo '##############################################################'
		return
	fi

	# Anchor on the method declaration itself — the method name
	# `addTrustedFolder` is not minified and is unique in the bundle.
	# Earlier releases let us anchor on the trailing `${param}`);` of the
	# log line, but upstream now folds that log call into the comma
	# expression `if(D.info(`…${i}`),await ZOe(i)===null){…}`, so the
	# `);` no longer exists. Injecting at the function body head is both
	# more robust and semantically earlier (reject .asar on entry).
	local folder_param
	folder_param=$(grep -oP \
		'async addTrustedFolder\(\K[$\w]+(?=\)\{)' \
		"$index_js")
	if [[ -z $folder_param ]]; then
		echo '  Could not extract folder parameter — skipping' >&2
		echo '##############################################################'
		return
	fi
	echo "  Found folder parameter: $folder_param"

	if ! FOLDER_PARAM="$folder_param" INDEX_JS="$main_js" \
		node -e "
const fs = require('fs');
const p = process.env.INDEX_JS;
const F = process.env.FOLDER_PARAM;
let code = fs.readFileSync(p, 'utf8');

const anchor = 'async addTrustedFolder(' + F + '){';
const idx = code.indexOf(anchor);
if (idx === -1) {
  console.error('  [FAIL] addTrustedFolder anchor not found');
  process.exit(1);
}

const insertPoint = idx + anchor.length;
const guard = 'if(' + F + '.endsWith(\".asar\"))return;';
code = code.slice(0, insertPoint) + guard + code.slice(insertPoint);
fs.writeFileSync(p, code);
console.log('  [OK] .asar guard injected in addTrustedFolder');
"; then
		echo 'Failed to inject .asar trusted folder guard' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo '##############################################################'
}

# ---------------------------------------------------------------------------
# Patch: filter .asar paths from --add-dir CLI dispatch and session restore
#
# PR #640 guards the directory-check helper and addTrustedFolder IPC
# handler, but .asar paths in corrupted pre-#640 sessions survive
# restore (existsSync passes via Electron's ASAR VFS shim) and reach
# additionalDirectories -> --add-dir -> fatal Claude Code error.
#
# Fix: two sub-patches:
#   1. Filter at the --add-dir CLI dispatch loop (the single convergence
#      point for ALL code paths that feed additionalDirectories).
#   2. Filter at session restore to self-heal corrupted persisted state.
# ---------------------------------------------------------------------------
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
const dispatchRawRe =
    /for\s*\(\s*let\s+([\w$]+)\s+of\s+([\w$]+)\s*\)\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\1\s*\)/g;
const dispatchForEachRawRe =
    /([\w$]+)\.forEach\(\s*([\w$]+)\s*=>\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\2\s*\)\s*\)/g;
const dispatchPatchedRe =
    /for\s*\(\s*let\s+([\w$]+)\s+of\s+([\w$]+)\.filter\(\s*([\w$]+)\s*=>\s*!\s*\3\.endsWith\(\s*"\.asar"\s*\)\s*\)\s*\)\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\1\s*\)/g;
const dispatchForEachPatchedRe =
    /([\w$]+)\.filter\(\s*([\w$]+)\s*=>\s*!\s*\2\.endsWith\(\s*"\.asar"\s*\)\s*\)\.forEach\(\s*([\w$]+)\s*=>\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\3\s*\)\s*\)/g;
const sessionRawRe =
    /(\([\w$]+\.userSelectedFolders\s*\|\|\s*\[\s*\]\s*\))\s*\.\s*(filter|map)\s*\(\s*(?![\w$]+\s*=>\s*!\s*[\w$]+\.endsWith\s*\(\s*"\.asar")/g;
const sessionPatchedRe =
    /(\([\w$]+\.userSelectedFolders\s*\|\|\s*\[\s*\]\s*\))\s*\.filter\(\s*([\w$]+)\s*=>\s*!\s*\2\.endsWith\(\s*"\.asar"\s*\)\s*\)\s*\.\s*(?:filter|map)\s*\(/g;

const collect = (regex) => chunks.flatMap((chunk) => {
    regex.lastIndex = 0;
    return [...chunk.code.matchAll(regex)].map((match) => ({
        chunk,
        match,
    }));
});
const dispatchRaw = [
    ...collect(dispatchRawRe),
    ...collect(dispatchForEachRawRe),
];
const dispatchPatched = [
    ...collect(dispatchPatchedRe),
    ...collect(dispatchForEachPatchedRe),
];
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

const writes = [];
if (dispatchRaw.length === 1) {
    const { chunk, match } = dispatchRaw[0];
    const [, iterVar, arrVar, pushTarget] = match;
    const replacement = match[0].startsWith('for')
        ? 'for(let ' + iterVar + ' of ' + arrVar +
            '.filter(_d=>!_d.endsWith(".asar")))' + pushTarget +
            '.push("--add-dir",' + iterVar + ')'
        : arrVar + '.filter(_d=>!_d.endsWith(".asar")).forEach(' +
            iterVar + '=>' + pushTarget + '.push("--add-dir",' +
            iterVar + '))';
    chunk.code = chunk.code.replace(match[0], replacement);
    writes.push(chunk);
    console.log('  Filtered --add-dir dispatch in ' + path.basename(chunk.file));
} else {
    console.log('  .asar --add-dir filter already present (idempotent)');
}

const sessionRaw = collect(sessionRawRe);
const sessionPatched = collect(sessionPatchedRe);
if (sessionRaw.length > 1 || sessionPatched.length > 1 ||
    (sessionRaw.length > 0 && sessionPatched.length > 0)) {
    console.error('FATAL: session restore filter has ambiguous candidates.');
    process.exit(1);
}
if (sessionRaw.length === 1) {
    const { chunk, match } = sessionRaw[0];
    const operation = match[2];
    const replacement = match[1] +
        '.filter(_d=>!_d.endsWith(".asar")).' + operation + '(';
    chunk.code = chunk.code.replace(match[0], replacement);
    writes.push(chunk);
    console.log('  Injected .asar filter in session restore in ' +
        path.basename(chunk.file));
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
