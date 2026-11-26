#!/usr/bin/env bats
#
# @file cowork-path-translation.bats
# @brief cowork-vm-service.jsにあるゲスト側パスの変換関数のテスト
#
# 各テストはサービス本体のexportをrequireして直接呼ぶ (Debian 1a703a6)
# サービスはrequire.mainのときだけソケットサーバーを起動するため
# requireでは待ち受けない
# 読み込み時にログ用の~/.config/Claude/logsが作られるので
# setupでHOMEを一時領域へ隔離し、実ユーザーのファイルに触れない
#

# テスト対象の関数を読み込むNode.jsの前置き
# 各テストの先頭に付けられるよう変数に入れておく

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

NODE_PREAMBLE='
const path = require("path");
const os = require("os");

// サービス本体をrequireする。ソケットサーバーはrequire.mainのときだけ
// 起動するため、requireでは待ち受けも副作用も起きない (ログ用の
// ~/.config/Claude/logsだけは作られるので、setupでHOMEを隔離する)。
const {
    translateGuestPath,
    buildMountMap,
    resolvePluginRoot,
    cleanSpawnArgs,
    resolveWorkDir,
    buildBaseSpawnEnv,
    buildSpawnEnv,
    resolveSubpath,
} = require("'"${SCRIPT_DIR}"'/../scripts/cowork-vm-service.js");

// Helper: simple assertion
function assert(condition, msg) {
    if (!condition) {
        process.stderr.write("ASSERTION FAILED: " + msg + "\n");
        process.exit(1);
    }
}

function assertNull(val, msg) {
    assert(val === null, msg + " (got: " + JSON.stringify(val) + ")");
}

function assertEqual(actual, expected, msg) {
    assert(actual === expected,
        msg + " expected=" + JSON.stringify(expected) +
        " actual=" + JSON.stringify(actual));
}

function assertDeepEqual(actual, expected, msg) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    assert(a === e, msg + " expected=" + e + " actual=" + a);
}
'

#
# @brief テスト用の一時ディレクトリを用意し、Node.js側からも使えるよう環境変数へ出す
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# require時に~/.config/Claude/logsを作るため、HOMEは必ず隔離する
	export HOME="$TEST_TMP/home"
	mkdir -p "$HOME"
	unset XDG_CONFIG_HOME COWORK_VM_DEBUG
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ゲストパスの変換 (translateGuestPath)

@test "translateGuestPath: returns null for null input" {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath(null, {'.skills': '/x'}), 'null input');
assertNull(translateGuestPath(undefined, {'.skills': '/x'}), 'undefined input');
assertNull(translateGuestPath('', {'.skills': '/x'}), 'empty input');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: returns null for non-/sessions/ paths" {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath('/home/user/file', {'.skills': '/x'}),
    'regular path');
assertNull(translateGuestPath('/tmp/sessions/abc/mnt/skills/f', {'.skills': '/x'}),
    'tmp prefix');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: returns null for empty mountMap" {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath('/sessions/abc/mnt/skills/file', null),
    'null map');
assertNull(translateGuestPath('/sessions/abc/mnt/skills/file', {}),
    'empty map');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: translates with exact mount name match" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/abc/mnt/.skills/somefile',
    {'.skills': '/home/user/.config/Claude/skills'}
);
assertEqual(result, '/home/user/.config/Claude/skills/somefile',
    'exact match');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: matches mount name without leading dot" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/x/mnt/skills/file',
    {'skills': '/home/user/skills'}
);
assertEqual(result, '/home/user/skills/file',
    'no-dot mount name');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: dot-prefix fallback matches stripped name" {
	run node -e "${NODE_PREAMBLE}
// mountMap has '.skills' but path has 'skills' (no dot)
const result = translateGuestPath(
    '/sessions/x/mnt/skills/file',
    {'.skills': '/home/user/.config/Claude/skills'}
);
assertEqual(result, '/home/user/.config/Claude/skills/file',
    'dot-prefix fallback');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: returns hostBase when no rest path" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/abc/mnt/skills',
    {'skills': '/home/user/skills'}
);
assertEqual(result, '/home/user/skills',
    'no rest path');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: returns null when mount name not in map" {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath(
    '/sessions/abc/mnt/unknown/file',
    {'skills': '/home/user/skills'}
), 'unknown mount');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: handles deeply nested rest path" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/abc/mnt/data/a/b/c/d.txt',
    {'data': '/opt/data'}
);
assertEqual(result, '/opt/data/a/b/c/d.txt', 'deep rest');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: blocks path traversal via .." {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath(
    '/sessions/abc/mnt/data/../../../etc/passwd',
    {'data': '/home/user/data'}
), 'traversal blocked');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: normalizes path with ./ segments" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/abc/mnt/data/./subdir/./file',
    {'data': '/home/user/data'}
);
assertEqual(result, '/home/user/data/subdir/file', 'normalized dots');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: dot-stripped fallback matches dotted path to plain key" {
	run node -e "${NODE_PREAMBLE}
// Guest path has .skills (with dot), map key is skills (no dot)
const result = translateGuestPath(
    '/sessions/x/mnt/.skills/file',
    {'skills': '/home/user/skills'}
);
assertEqual(result, '/home/user/skills/file', 'dot-stripped fallback');
"
	[[ "$status" -eq 0 ]]
}

# マウントマップの構築 (buildMountMap)

@test "buildMountMap: returns empty object when both args null" {
	run node -e "${NODE_PREAMBLE}
assertDeepEqual(buildMountMap(null, null), {}, 'both null');
assertDeepEqual(buildMountMap(undefined, undefined), {}, 'both undefined');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: builds from mountBinds Map only" {
	run node -e "${NODE_PREAMBLE}
const binds = new Map([['skills', '/host/skills'], ['data', '/host/data']]);
const result = buildMountMap(null, binds);
assertDeepEqual(result, {'skills': '/host/skills', 'data': '/host/data'},
    'mountBinds only');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: builds from additionalMounts only" {
	run node -e "${NODE_PREAMBLE}
const additional = {
    '.skills': { path: '.config/Claude/skills', mode: 'ro' },
    '.claude': { path: '.claude', mode: 'rw' }
};
const result = buildMountMap(additional, null);
const home = os.homedir();
assertEqual(result['.skills'],
    path.join(home, '.config/Claude/skills'),
    'skills path');
assertEqual(result['.claude'],
    path.join(home, '.claude'),
    'claude path');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: additionalMounts takes precedence over mountBinds" {
	run node -e "${NODE_PREAMBLE}
const binds = new Map([['skills', '/host/old-skills']]);
const additional = {
    'skills': { path: 'new-skills', mode: 'ro' }
};
const result = buildMountMap(additional, binds);
const expected = path.join(os.homedir(), 'new-skills');
assertEqual(result['skills'], expected, 'precedence');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: rejects paths that escape home directory" {
	run node -e "${NODE_PREAMBLE}
const additional = {
    'good': { path: '.config/Claude/skills', mode: 'ro' },
    'bad': { path: '../../etc', mode: 'rw' }
};
const result = buildMountMap(additional, null);
assert(Object.keys(result).length === 1, 'only good entry');
assert('good' in result, 'good present');
assert(!('bad' in result), 'bad rejected');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: skips entries without .path" {
	run node -e "${NODE_PREAMBLE}
const additional = {
    'good': { path: 'valid/path', mode: 'ro' },
    'bad1': { mode: 'rw' },
    'bad2': null
};
const result = buildMountMap(additional, null);
assert(Object.keys(result).length === 1, 'only one entry');
assert('good' in result, 'good entry present');
assert(!('bad1' in result), 'bad1 excluded');
assert(!('bad2' in result), 'bad2 excluded');
"
	[[ "$status" -eq 0 ]]
}

# 起動引数の整形 (cleanSpawnArgs)

@test "cleanSpawnArgs: passes through args with no guest paths" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--flag', 'value', '--other'],
    {'skills': '/host/skills'}
);
assertDeepEqual(result, ['--flag', 'value', '--other'],
    'passthrough');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: translates --plugin-dir with valid mapping" {
	# resolvePluginRootに見つけさせるため、一時的なプラグイン構成を作る
	mkdir -p "${TEST_TMP}/skills/.claude-plugin"
	printf '{}' > "${TEST_TMP}/skills/.claude-plugin/plugin.json"

	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--plugin-dir', '/sessions/abc/mnt/skills'],
    {'skills': '${TEST_TMP}/skills'}
);
assertDeepEqual(result,
    ['--plugin-dir', '${TEST_TMP}/skills'],
    'plugin-dir translated');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: translates --add-dir with valid mapping" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--add-dir', '/sessions/abc/mnt/data/subdir'],
    {'data': '/host/data'}
);
assertDeepEqual(result,
    ['--add-dir', '/host/data/subdir'],
    'add-dir translated');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: strips --plugin-dir when no mapping found" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--plugin-dir', '/sessions/abc/mnt/unknown/dir'],
    {'skills': '/host/skills'}
);
assertDeepEqual(result, [], 'stripped');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: passes through --plugin-dir with non-/sessions/ paths" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--plugin-dir', '/usr/local/plugins'],
    {'skills': '/host/skills'}
);
assertDeepEqual(result,
    ['--plugin-dir', '/usr/local/plugins'],
    'non-sessions passthrough');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: handles multiple --add-dir and --plugin-dir flags" {
	mkdir -p "${TEST_TMP}/plug/.claude-plugin"
	printf '{}' > "${TEST_TMP}/plug/.claude-plugin/plugin.json"

	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    [
        '--add-dir', '/sessions/s/mnt/data/a',
        '--plugin-dir', '/sessions/s/mnt/plug',
        '--add-dir', '/sessions/s/mnt/data/b',
        '--plugin-dir', '/sessions/s/mnt/missing'
    ],
    {'data': '/host/data', 'plug': '${TEST_TMP}/plug'}
);
assertDeepEqual(result,
    [
        '--add-dir', '/host/data/a',
        '--plugin-dir', '${TEST_TMP}/plug',
        '--add-dir', '/host/data/b'
    ],
    'multiple flags');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: preserves other args around translated flags" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--verbose', '--add-dir', '/sessions/s/mnt/data/x', '--output', 'json'],
    {'data': '/host/data'}
);
assertDeepEqual(result,
    ['--verbose', '--add-dir', '/host/data/x', '--output', 'json'],
    'surrounding args preserved');
"
	[[ "$status" -eq 0 ]]
}

# プラグインルートの解決 (resolvePluginRoot)

@test "resolvePluginRoot: returns path when .claude-plugin/plugin.json exists at that level" {
	mkdir -p "${TEST_TMP}/plugin/.claude-plugin"
	printf '{}' > "${TEST_TMP}/plugin/.claude-plugin/plugin.json"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot('${TEST_TMP}/plugin'),
    '${TEST_TMP}/plugin',
    'same level');
"
	[[ "$status" -eq 0 ]]
}

@test "resolvePluginRoot: walks up to parent with .claude-plugin/plugin.json" {
	mkdir -p "${TEST_TMP}/plugin/.claude-plugin"
	printf '{}' > "${TEST_TMP}/plugin/.claude-plugin/plugin.json"
	mkdir -p "${TEST_TMP}/plugin/skills/subdir"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot('${TEST_TMP}/plugin/skills'),
    '${TEST_TMP}/plugin',
    'walked up one');
"
	[[ "$status" -eq 0 ]]
}

@test "resolvePluginRoot: walks up to grandparent with manifest.json" {
	printf '{}' > "${TEST_TMP}/manifest.json"
	mkdir -p "${TEST_TMP}/a/b"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot('${TEST_TMP}/a/b'),
    '${TEST_TMP}',
    'walked up two');
"
	[[ "$status" -eq 0 ]]
}

@test "resolvePluginRoot: returns original path when no plugin root found" {
	mkdir -p "${TEST_TMP}/empty/dir"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot('${TEST_TMP}/empty/dir'),
    '${TEST_TMP}/empty/dir',
    'no root found');
"
	[[ "$status" -eq 0 ]]
}

@test "resolvePluginRoot: stops at 3 levels" {
	# plugin.jsonが4階層上にある場合は見つけてはいけない
	mkdir -p "${TEST_TMP}/root/.claude-plugin"
	printf '{}' > "${TEST_TMP}/root/.claude-plugin/plugin.json"
	mkdir -p "${TEST_TMP}/root/a/b/c/d"

	run node -e "${NODE_PREAMBLE}
// Starting from root/a/b/c/d: checks d, c, b (3 levels). root is 4th.
assertEqual(
    resolvePluginRoot('${TEST_TMP}/root/a/b/c/d'),
    '${TEST_TMP}/root/a/b/c/d',
    'too deep');
"
	[[ "$status" -eq 0 ]]
}

# 作業ディレクトリの解決 (resolveWorkDir)

@test "resolveWorkDir: returns translated path when cwd is guest path with valid mapping" {
	mkdir -p "${TEST_TMP}/workspace"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc/mnt/project',
        null,
        {'project': '${TEST_TMP}/workspace'}
    ),
    '${TEST_TMP}/workspace',
    'translated cwd');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: falls back to homedir when cwd is guest path with no mapping" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc/mnt/nomatch/dir',
        null,
        {'other': '/host/other'}
    ),
    os.homedir(),
    'fallback to homedir');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: uses sharedCwdPath when provided" {
	# 実際のホームディレクトリを汚さないよう、HOMEをTEST_TMPに向ける
	mkdir -p "${TEST_TMP}/resolveWorkDir-bats-test"

	HOME="${TEST_TMP}" run node -e "${NODE_PREAMBLE}
const result = resolveWorkDir(
    '/sessions/abc/mnt/whatever',
    'resolveWorkDir-bats-test',
    {'whatever': '/host/whatever'}
);
assertEqual(result,
    path.join(os.homedir(), 'resolveWorkDir-bats-test'),
    'sharedCwdPath takes priority');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: falls back to homedir when sharedCwdPath is non-existent" {
	HOME="${TEST_TMP}" run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc/mnt/whatever',
        'nonexistent-dir-bats-test',
        {'whatever': '/host/whatever'}
    ),
    os.homedir(),
    'nonexistent sharedCwdPath falls back');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: returns homedir for non-existent translated path" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc/mnt/project/deep/missing',
        null,
        {'project': '/nonexistent-bats-test-path'}
    ),
    os.homedir(),
    'nonexistent falls back');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: returns homedir when cwd is null" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(null, null, {}),
    os.homedir(),
    'null cwd -> homedir');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: returns real local path unchanged when it exists" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir('/tmp', null, {}),
    '/tmp',
    'local path passthrough');
"
	[[ "$status" -eq 0 ]]
}

# 起動環境変数の組み立て (buildSpawnEnv)

@test "buildSpawnEnv: translates CLAUDE_CONFIG_DIR guest path" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    { CLAUDE_CONFIG_DIR: '/sessions/abc/mnt/.claude/config' },
    { '.claude': '/home/user/.claude' }
);
assertEqual(env.CLAUDE_CONFIG_DIR,
    '/home/user/.claude/config',
    'translated config dir');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: deletes CLAUDE_CONFIG_DIR when no mapping" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    { CLAUDE_CONFIG_DIR: '/sessions/abc/mnt/.claude/config' },
    {}
);
assert(!('CLAUDE_CONFIG_DIR' in env),
    'config dir deleted');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: preserves non-guest CLAUDE_CONFIG_DIR" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    { CLAUDE_CONFIG_DIR: '/home/user/.claude' },
    {}
);
assertEqual(env.CLAUDE_CONFIG_DIR,
    '/home/user/.claude',
    'local config dir preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: strips CLAUDECODE and ELECTRON vars from appEnv" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    {
        CLAUDECODE: '1',
        ELECTRON_RUN_AS_NODE: '1',
        ELECTRON_NO_ASAR: '1',
        GOOD_VAR: 'keep'
    },
    {}
);
assert(!('CLAUDECODE' in env), 'CLAUDECODE stripped');
assert(!('ELECTRON_RUN_AS_NODE' in env), 'ELECTRON_RUN_AS_NODE stripped');
assert(!('ELECTRON_NO_ASAR' in env), 'ELECTRON_NO_ASAR stripped');
assertEqual(env.GOOD_VAR, 'keep', 'non-blocked kept');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: forces TERM to xterm-256color" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv({ TERM: 'dumb' }, {});
assertEqual(env.TERM, 'xterm-256color', 'TERM forced');
"
	[[ "$status" -eq 0 ]]
}

# 起動引数の整形の境界条件 (cleanSpawnArgs)

@test "cleanSpawnArgs: dangling flag at end of args is preserved" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--verbose', '--plugin-dir'],
    {'skills': '/host/skills'}
);
assertDeepEqual(result, ['--verbose', '--plugin-dir'], 'dangling flag');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: empty args returns empty array" {
	run node -e "${NODE_PREAMBLE}
assertDeepEqual(cleanSpawnArgs([], {}), [], 'empty args');
"
	[[ "$status" -eq 0 ]]
}

# プラグインルート解決のマウント基点の境界 (resolvePluginRoot)

@test "resolvePluginRoot: respects mountBase boundary" {
	# plugin.jsonがTEST_TMP直下にあり、マウント基点はその1階層下である場合
	mkdir -p "${TEST_TMP}/.claude-plugin"
	printf '{}' > "${TEST_TMP}/.claude-plugin/plugin.json"
	mkdir -p "${TEST_TMP}/mount/sub"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot(
        '${TEST_TMP}/mount/sub',
        '${TEST_TMP}/mount'
    ),
    '${TEST_TMP}/mount/sub',
    'mountBase boundary respected');
"
	[[ "$status" -eq 0 ]]
}

# サブパスはルート基準であり、ホームディレクトリと連結してはいけない (resolveSubpath)

# app.asarはpath.relative('/', abs)の形でサブパスを送ってくる
# resolveSubpath()がそれを単一の絶対パスへ戻すことを確認する
# (#373の修正 : ホームディレクトリが二重に連結されていた問題)

@test "resolveSubpath: root-relative subpath resolves to absolute path, not double-nested" {
	run node -e "${NODE_PREAMBLE}
// Simulate what the caller sends: path.relative('/', abs)
const expected = path.join(os.homedir(), '.config', 'Claude');
const subpath = path.relative('/', expected);
assertEqual(resolveSubpath(subpath), expected,
    'root-relative subpath should resolve to a single absolute path');
assertEqual(resolveSubpath(subpath), expected,
    'root-relative subpath should not be joined to home twice');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveSubpath: empty subpath resolves to home" {
	run node -e "${NODE_PREAMBLE}
assertEqual(resolveSubpath(''), os.homedir(),
    'empty subpath -> home');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveSubpath: subpath with nested directories resolves correctly" {
	run node -e "${NODE_PREAMBLE}
const expected = path.join(
    os.homedir(), '.config', 'Claude',
    'local-agent-mode-sessions', 'outputs');
const subpath = path.relative('/', expected);
assertEqual(resolveSubpath(subpath), expected,
    'nested subpath should not double the home prefix');
"
	[[ "$status" -eq 0 ]]
}
