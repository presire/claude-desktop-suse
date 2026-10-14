#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells
#
# cowork-bwrap-config.bats
# Tests for configurable bwrap mount points
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

NODE_PREAMBLE='
const path = require("path");
const os = require("os");
const fs = require("fs");

const {
    FORBIDDEN_MOUNT_PATHS,
    CRITICAL_MOUNTS,
    validateMountPath,
    loadBwrapMountsConfig,
    buildDefaultBwrapArgs,
    mergeBwrapArgs,
    isUnderHome,
    resolveExistingPrefix,
    validateSessionMount,
    parseMountMode,
    buildHideArgs,
    buildMountMap,
    buildMountRecords,
    revalidateHostMount,
    openMountFd,
    detectBindFdSupport,
    bwrapSupportsBindFd,
    _resetBwrapBindFdCache,
    _setBwrapBindFdCache,
    buildSessionMountArgs,
    buildSpawnEnv,
    BwrapBackend,
} = require("'"${SCRIPT_DIR}"'/../scripts/cowork-vm-service.js");

function loadBwrapMountsConfigWithLog(configPath, logFn) {
    return loadBwrapMountsConfig(configPath, logFn);
}

function assert(condition, msg) {
    if (!condition) {
        process.stderr.write("ASSERTION FAILED: " + msg + "\n");
        process.exit(1);
    }
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

setup() {
	TEST_TMP=$(mktemp -d -p "${BATS_TEST_TMPDIR:-/tmp}")
	export TEST_TMP
	unset XDG_CONFIG_HOME
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# validateMountPath
# =============================================================================

@test "validateMountPath: rejects non-absolute paths" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('relative/path');
assertDeepEqual(result, { valid: false, reason: 'Path must be absolute' }, 'relative');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /' }, 'root');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /proc" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/proc');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /proc' }, 'proc');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /dev" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/dev');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /dev' }, 'dev');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /sys" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/sys');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /sys' }, 'sys');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects subpaths of forbidden paths" {
	run node -e "${NODE_PREAMBLE}
const r1 = validateMountPath('/proc/self');
assertDeepEqual(r1, { valid: false, reason: 'Path is under forbidden path: /proc' }, 'proc/self');
const r2 = validateMountPath('/dev/shm');
assertDeepEqual(r2, { valid: false, reason: 'Path is under forbidden path: /dev' }, 'dev/shm');
const r3 = validateMountPath('/sys/class');
assertDeepEqual(r3, { valid: false, reason: 'Path is under forbidden path: /sys' }, 'sys/class');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects RW paths outside HOME" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/opt/tools', { readWrite: true });
assertDeepEqual(result,
    { valid: false, reason: 'Read-write mounts must be under \$HOME' },
    'rw outside home');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts RW paths under HOME" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const result = validateMountPath(home + '/projects/data', { readWrite: true });
assertDeepEqual(result, { valid: true }, 'rw under home');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts RO paths anywhere (not forbidden)" {
	run node -e "${NODE_PREAMBLE}
const r1 = validateMountPath('/opt/my-tools');
assertDeepEqual(r1, { valid: true }, 'opt ro');
const r2 = validateMountPath('/nix/store');
assertDeepEqual(r2, { valid: true }, 'nix ro');
const r3 = validateMountPath('/media/shared');
assertDeepEqual(r3, { valid: true }, 'media ro');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects empty string" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('');
assertDeepEqual(result, { valid: false, reason: 'Path must be absolute' }, 'empty');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: normalizes path before checking" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/opt/../proc');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /proc' }, 'traversal to proc');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects symlink to forbidden path" {
	local link_path="${TEST_TMP}/sneaky-link"
	ln -s /proc "$link_path"
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('${link_path}');
assert(!result.valid, 'symlink to /proc should be rejected');
assert(result.reason.includes('forbidden'), 'reason: ' + result.reason);
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts symlink to safe path" {
	local link_path="${TEST_TMP}/safe-link"
	ln -s /opt "$link_path"
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('${link_path}');
assertDeepEqual(result, { valid: true }, 'symlink to /opt should be accepted');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# loadBwrapMountsConfig
# =============================================================================

@test "loadBwrapMountsConfig: returns empty config when file does not exist" {
	run node -e "${NODE_PREAMBLE}
const result = loadBwrapMountsConfig('/nonexistent/path/config.json');
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'missing file');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: returns empty config when JSON has no preferences" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({ mcpServers: {} }));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'no preferences');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: returns empty config when coworkBwrapMounts is absent" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({ preferences: {} }));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'no coworkBwrapMounts');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: parses valid configuration" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/tools', '/nix/store'],
            additionalBinds: [os.homedir() + '/shared-data'],
            disabledDefaultBinds: ['/etc']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: ['/opt/tools', '/nix/store'],
    additionalBinds: [os.homedir() + '/shared-data'],
    disabledDefaultBinds: ['/etc']
}, 'valid config');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: returns empty config on invalid JSON" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, '{ invalid json }');
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'invalid json');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: filters out invalid paths from additionalROBinds" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/tools', '/proc', 'relative', '/dev', '/nix/store']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, ['/opt/tools', '/nix/store'],
    'filtered ro binds');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: filters out RW paths outside HOME" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
const home = os.homedir();
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalBinds: [home + '/valid', '/opt/invalid', home + '/also-valid']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalBinds, [home + '/valid', home + '/also-valid'],
    'filtered rw binds');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: ignores non-array values" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: 'not-an-array',
            additionalBinds: 42,
            disabledDefaultBinds: { bad: true }
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'non-array values');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: filters non-string entries from arrays" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/tools', 42, null, '/nix/store', true]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, ['/opt/tools', '/nix/store'],
    'non-string entries filtered');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: normalizes disabledDefaultBinds paths" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            disabledDefaultBinds: ['/etc/../usr', '/tmp/./']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.disabledDefaultBinds, ['/usr', '/tmp'],
    'paths should be normalized');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects critical mounts in disabledDefaultBinds" {
	run node -e "${NODE_PREAMBLE}
const warnings = [];
function logWarn() { warnings.push(Array.from(arguments).join(' ')); }

const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            disabledDefaultBinds: ['/', '/dev', '/proc', '/etc']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath, logWarn);
assertDeepEqual(result.disabledDefaultBinds, ['/etc'],
    'only /etc should survive');
assertEqual(warnings.length, 3, 'three critical mount warnings');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects relative disabledDefaultBinds" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            disabledDefaultBinds: ['relative/path', '/etc']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.disabledDefaultBinds, ['/etc'],
    'relative path should be rejected');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# mergeBwrapArgs — disabled default binds
# =============================================================================

@test "mergeBwrapArgs: returns default args when config is empty" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr', '--ro-bind', '/etc', '/etc',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [], disabledDefaultBinds: []
});
assertDeepEqual(result, defaults, 'unchanged');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: removes disabled default ro-bind" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr', '--ro-bind', '/etc', '/etc',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [], disabledDefaultBinds: ['/etc']
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
assertDeepEqual(result, expected, 'etc removed');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: refuses to disable --tmpfs /, --dev /dev, --proc /proc" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [],
    disabledDefaultBinds: ['/', '/dev', '/proc']
});
assertDeepEqual(result, defaults, 'critical mounts preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: can disable /tmp and /run" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [],
    disabledDefaultBinds: ['/tmp', '/run']
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc'];
assertDeepEqual(result, expected, 'tmp and run removed');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: appends additional RO binds" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: ['/opt/tools', '/nix/store'],
    additionalBinds: [],
    disabledDefaultBinds: []
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dir', '/opt', '--ro-bind', '/opt/tools', '/opt/tools',
    '--dir', '/nix', '--ro-bind', '/nix/store', '/nix/store'];
assertDeepEqual(result, expected, 'ro appended');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: appends additional RW binds" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [],
    additionalBinds: [home + '/data'],
    disabledDefaultBinds: []
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dir', home, '--bind', home + '/data', home + '/data'];
assertDeepEqual(result, expected, 'rw appended');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: combined disable + add" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr', '--ro-bind', '/etc', '/etc',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: ['/opt/tools'],
    additionalBinds: [home + '/shared'],
    disabledDefaultBinds: ['/etc']
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run',
    '--dir', '/opt', '--ro-bind', '/opt/tools', '/opt/tools',
    '--dir', home, '--bind', home + '/shared', home + '/shared'];
assertDeepEqual(result, expected, 'combined');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: handles extended bwrap flags correctly" {
	run node -e "${NODE_PREAMBLE}
const defaults = [
    '--ro-bind', '/usr', '/usr',
    '--ro-bind-try', '/opt/lib', '/opt/lib',
    '--dev-bind', '/dev/dri', '/dev/dri',
    '--setenv', 'DISPLAY', ':0',
    '--chdir', '/home/user',
    '--unshare-pid', '--die-with-parent',
];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [],
    disabledDefaultBinds: ['/opt/lib']
});
const expected = [
    '--ro-bind', '/usr', '/usr',
    '--dev-bind', '/dev/dri', '/dev/dri',
    '--setenv', 'DISPLAY', ':0',
    '--chdir', '/home/user',
    '--unshare-pid', '--die-with-parent',
];
assertDeepEqual(result, expected, 'extended flags parsed correctly');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# buildBwrapArgsWithConfig (integration)
# =============================================================================

@test "buildBwrapArgsWithConfig: includes user mounts in final args" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
const home = os.homedir();
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/my-sdk'],
            additionalBinds: [home + '/workspace'],
            disabledDefaultBinds: []
        }
    }
}));
const config = loadBwrapMountsConfig(configPath);
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc'];
const result = mergeBwrapArgs(defaults, config);

const roIdx = result.indexOf('--ro-bind', result.indexOf('/usr') + 1);
assertEqual(result[roIdx + 1], '/opt/my-sdk', 'ro-bind src');
assertEqual(result[roIdx + 2], '/opt/my-sdk', 'ro-bind dest');

const rwIdx = result.indexOf('--bind');
assertEqual(result[rwIdx + 1], home + '/workspace', 'bind src');
assertEqual(result[rwIdx + 2], home + '/workspace', 'bind dest');
"
	[[ "$status" -eq 0 ]]
}

@test "buildBwrapArgsWithConfig: user RO mounts come before session mounts" {
	run node -e "${NODE_PREAMBLE}
const config = {
    additionalROBinds: ['/opt/tools'],
    additionalBinds: [],
    disabledDefaultBinds: []
};
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr'];
const merged = mergeBwrapArgs(defaults, config);

const fullArgs = [...merged, '--bind', '/home/user/project', '/sessions/s/mnt/project',
    '--unshare-pid', '--die-with-parent', '--new-session'];

const optIdx = fullArgs.indexOf('/opt/tools');
const sessionBindIdx = fullArgs.indexOf('--bind');
assert(optIdx < sessionBindIdx,
    'user RO mount (' + optIdx + ') before session bind (' + sessionBindIdx + ')');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# loadBwrapMountsConfig: logging
# =============================================================================

@test "loadBwrapMountsConfig: logs rejected paths" {
	run node -e "${NODE_PREAMBLE}
const warnings = [];
function logWarn() { warnings.push(Array.from(arguments).join(' ')); }

const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/proc', '/opt/ok'],
            additionalBinds: ['/outside/home']
        }
    }
}));
const result = loadBwrapMountsConfigWithLog(configPath, logWarn);
assertEqual(result.additionalROBinds.length, 1, 'one valid ro');
assertEqual(warnings.length, 2, 'two warnings logged');
assert(warnings[0].includes('/proc'), 'warns about /proc');
assert(warnings[1].includes('/outside/home'), 'warns about rw outside home');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# --doctor integration (bash)
# =============================================================================

@test "doctor: reports custom bwrap mounts" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local home_tmp="${TEST_TMP}"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	cat > "$config_file" <<-ENDJSON
	{
	    "preferences": {
	        "coworkBwrapMounts": {
	            "additionalROBinds": ["/opt/tools"],
	            "additionalBinds": ["${home_tmp}/data"],
	            "disabledDefaultBinds": ["/etc"]
	        }
	    }
	}
	ENDJSON

	# Source launcher-common.sh and run the doctor check function
	# shellcheck source=scripts/launcher-common.sh
	source "${SCRIPT_DIR}/../scripts/launcher-common.sh"
	# Override HOME for config path resolution (unset XDG_CONFIG_HOME so
	# the doctor falls back to HOME/.config rather than the CI runner's).
	unset XDG_CONFIG_HOME
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	[[ "$output" == *"/opt/tools"* ]]
	[[ "$output" == *"data"* ]]
	[[ "$output" == *"/etc"* ]]
	[[ "$output" == *"WARN"* ]]
}

@test "doctor: warns about disabled critical mount /usr" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	cat > "$config_file" <<-ENDJSON
	{
	    "preferences": {
	        "coworkBwrapMounts": {
	            "disabledDefaultBinds": ["/usr"]
	        }
	    }
	}
	ENDJSON

	# shellcheck source=scripts/launcher-common.sh
	source "${SCRIPT_DIR}/../scripts/launcher-common.sh"
	unset XDG_CONFIG_HOME
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	[[ "$output" == *"WARN"* ]]
	[[ "$output" == *"/usr"* ]]
}

@test "doctor: no output when no custom mounts configured" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	echo '{}' > "$config_file"

	# shellcheck source=scripts/launcher-common.sh
	source "${SCRIPT_DIR}/../scripts/launcher-common.sh"
	unset XDG_CONFIG_HOME
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	# Should just show info that no custom mounts are configured
	[[ "$output" != *"FAIL"* ]]
}

# =============================================================================
# Ported mount-hardening fixes (Debian v3.3.1 / v3.3.3 / v3.3.7 / v3.3.8)
# =============================================================================

@test "validateMountPath: rejects a dot-dot segment after a symlink" {
	mkdir -p "${TEST_TMP}/home"
	ln -s /etc "${TEST_TMP}/home/etclink"
	ln -s / "${TEST_TMP}/home/rootlink"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const h = os.homedir();
const r1 = validateMountPath(h + '/etclink/../etc', { readWrite: true });
assert(!r1.valid && r1.reason.includes('segments'),
    'rw bind of /etc through ~/etclink/..: ' + r1.reason);
const r2 = validateMountPath(h + '/rootlink/../proc');
assert(!r2.valid && r2.reason.includes('segments'),
    'ro bind of /proc through ~/rootlink/..: ' + r2.reason);
const r3 = validateMountPath(h + '/a..b', { readWrite: true });
assertDeepEqual(r3, { valid: true }, 'name containing .. is not a segment');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: resolves a not-yet-created path through its existing parent" {
	mkdir -p "${TEST_TMP}/home" "${TEST_TMP}/outside"
	ln -s "${TEST_TMP}/outside" "${TEST_TMP}/home/outlink"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const h = os.homedir();
const rw = (p) => validateMountPath(p, { readWrite: true }).valid;
assert(!rw(h + '/outlink/not-yet'), 'missing leaf under symlink out of HOME');
assert(!rw(h + '/outlink/not-yet/deeper'), 'missing chain under symlink out of HOME');
assert(rw(h + '/not-yet/deeper'), 'missing chain under HOME stays valid');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: follows a dangling symlink to where it will land" {
	mkdir -p "${TEST_TMP}/home" "${TEST_TMP}/outside"
	ln -s /proc/not-yet-ever "${TEST_TMP}/home/dangle-proc"
	ln -s "${TEST_TMP}/outside/newdir" "${TEST_TMP}/home/dangle-out"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const h = os.homedir();
const r1 = validateMountPath(h + '/dangle-proc');
assert(!r1.valid && r1.reason.includes('forbidden'),
    'dangling link toward /proc: ' + r1.reason);
const r2 = validateMountPath(h + '/dangle-out', { readWrite: true });
assert(!r2.valid, 'dangling link out of HOME as rw: ' + JSON.stringify(r2));
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts paths under the resolved HOME (/home -> /var/home)" {
	mkdir -p "${TEST_TMP}/var/home/user"
	ln -s "${TEST_TMP}/var/home/user" "${TEST_TMP}/home"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const realHome = fs.realpathSync(home);
const r1 = validateMountPath(home + '/proj', { readWrite: true });
assertDeepEqual(r1, { valid: true }, 'unresolved HOME form');
const r2 = validateMountPath(realHome + '/proj', { readWrite: true });
assertDeepEqual(r2, { valid: true }, 'resolved HOME form');
const r3 = validateMountPath('/opt/tools', { readWrite: true });
assert(!r3.valid, 'outside both forms still rejected');
"
	[[ "$status" -eq 0 ]]
}

@test "BwrapBackend spawn: off-home missing path is skipped, never created" {
	mkdir -p "${TEST_TMP}/home" "${TEST_TMP}/mnt/storage"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const offMissing = '${TEST_TMP}/mnt/storage/missing';
const fresh = home + '/fresh-missing';
(async () => {
    _setBwrapBindFdCache(false);
    const b = new BwrapBackend(() => {});
    b.mountBinds.set('gone', offMissing);
    b.mountBinds.set('fresh', fresh);
    let captured = null;
    b._spawnLocal = (id, cmd, args) => { captured = args; };
    await b.spawn({ id: 'p1', name: 's1', command: process.execPath, args: [] });
    assert(captured !== null, 'spawn did not reach _spawnLocal');
    assert(!captured.includes(offMissing),
        'off-home missing must not be bound: ' + JSON.stringify(captured));
    assert(!fs.existsSync(offMissing), 'off-home missing must not be created');
    assert(fs.existsSync(fresh), 'in-HOME missing dir is still created');
    const bi = captured.indexOf('--bind');
    assert(bi >= 0 && captured[bi + 1] === fresh, 'in-HOME dir bound rw');
})().catch(e => { console.error(e); process.exit(1); });
"
	[[ "$status" -eq 0 ]]
}

@test "BwrapBackend spawn: ro+hide mount is bound read-only with hides after it" {
	mkdir -p "${TEST_TMP}/home/proj/.ssh"
	echo key > "${TEST_TMP}/home/proj/.ssh/id_ed25519"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const proj = home + '/proj';
const guest = '/sessions/s1/mnt/proj';
const sub = (abs) => path.relative('/', abs);
function indexOfTriple(args, a, b, c) {
    for (let i = 0; i + 2 < args.length; i++) {
        if (args[i] === a && args[i + 1] === b && args[i + 2] === c) return i;
    }
    return -1;
}
(async () => {
    _setBwrapBindFdCache(false);
    const b = new BwrapBackend(() => {});
    let captured = null;
    b._spawnLocal = (id, cmd, args) => { captured = args; };
    await b.spawn({ id: 'p1', name: 's1', command: process.execPath, args: [],
        additionalMounts: { proj: { path: sub(proj), mode: 'ro+hide',
            hide: [{ path: '.ssh' }] } } });
    assert(captured !== null, 'spawn did not reach _spawnLocal');
    const ro = indexOfTriple(captured, '--ro-bind', proj, guest);
    assert(ro >= 0, 'ro+hide must be --ro-bind: ' + JSON.stringify(captured));
    assert(indexOfTriple(captured, '--bind', proj, guest) === -1,
        'ro+hide must not be --bind');
    const hide = captured.indexOf('--tmpfs', ro);
    assert(hide > ro && captured[hide + 1] === guest + '/.ssh',
        '.ssh tmpfs must follow the bind');
})().catch(e => { console.error(e); process.exit(1); });
"
	[[ "$status" -eq 0 ]]
}

@test "BwrapBackend spawn: HOME is the session home unless the app sends one" {
	mkdir -p "${TEST_TMP}/home/proj"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const proj = os.homedir() + '/proj';
const mounts = { proj: { path: path.relative('/', proj), mode: 'rw' } };
(async () => {
    _setBwrapBindFdCache(false);
    const b = new BwrapBackend(() => {});
    let env = null;
    b._spawnLocal = (id, cmd, args, cwd, spawnEnv) => { env = spawnEnv; };
    await b.spawn({ id: 'p1', name: 'rcw-abc', command: 'bash',
        args: ['-c', 'true'], cwd: '/sessions/rcw-abc',
        additionalMounts: mounts, oneShot: true });
    assertEqual(env && env.HOME, '/sessions/rcw-abc', 'no app env');
    await b.spawn({ id: 'p2', name: 'rcw-abc', command: 'bash',
        args: ['-c', 'true'], env: { FOO: '1' }, additionalMounts: mounts });
    assertEqual(env.HOME, '/sessions/rcw-abc', 'app env without HOME');
    assertEqual(env.FOO, '1', 'app env still applied');
    await b.spawn({ id: 'p3', name: 'rcw-abc', command: 'bash',
        args: ['-c', 'true'], env: { HOME: '/sessions/rcw-abc/custom' },
        additionalMounts: mounts });
    assertEqual(env.HOME, '/sessions/rcw-abc/custom', 'app-sent HOME wins');
})().catch(e => { console.error(e); process.exit(1); });
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: deletes CLAUDE_CONFIG_DIR when no mapping exists" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    { CLAUDE_CONFIG_DIR: '/sessions/abc/mnt/.claude/config' },
    {}
);
assert(!('CLAUDE_CONFIG_DIR' in env),
    'unmapped config dir must be deleted, not null: ' + JSON.stringify(env));
"
	[[ "$status" -eq 0 ]]
}

@test "buildDefaultBwrapArgs: binds /nix and /.host-etc only when present" {
	run node -e "${NODE_PREAMBLE}
function fakeFs(present) {
    return {
        existsSync: (p) => present.includes(p),
        readlinkSync: (p) => { throw Object.assign(new Error('EINVAL: ' + p), { code: 'EINVAL' }); },
    };
}
function hasBind(args, flag, src, dst) {
    for (let i = 0; i + 2 < args.length; i++) {
        if (args[i] === flag && args[i + 1] === src && args[i + 2] === dst) return true;
    }
    return false;
}
const withBoth = buildDefaultBwrapArgs(fakeFs(['/nix', '/.host-etc']));
assert(hasBind(withBoth, '--ro-bind', '/nix', '/nix'), 'ro-bind /nix');
assert(!hasBind(withBoth, '--bind', '/nix', '/nix'), '/nix never writable');
assert(hasBind(withBoth, '--ro-bind', '/.host-etc', '/.host-etc'), 'ro-bind /.host-etc');
const absent = buildDefaultBwrapArgs(fakeFs([]));
assert(!absent.includes('/nix'), 'no /nix when absent');
assert(!absent.includes('/.host-etc'), 'no /.host-etc when absent');
const dropped = mergeBwrapArgs(buildDefaultBwrapArgs(fakeFs(['/nix', '/.host-etc'])), {
    additionalROBinds: [], additionalBinds: [], disabledDefaultBinds: ['/nix'],
});
 assert(!dropped.includes('/nix'), '/nix droppable via disabledDefaultBinds');
 assert(hasBind(dropped, '--ro-bind', '/.host-etc', '/.host-etc'), '/.host-etc kept');
 "
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# Finding #1: rejected additional mounts must not override stored mode/hide
# =============================================================================

@test "buildMountRecords: rejected additional mount keeps stored mode and hide" {
	mkdir -p "${TEST_TMP}/home/proj"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const proj = home + '/proj';
const mountBinds = new Map([['proj', proj]]);
const mountOptions = new Map([['proj', { mode: 'ro+hide', hide: [{ path: '.ssh' }] }]]);
const recs = buildMountRecords({ proj: { path: 'proc', mode: 'rw' } }, mountBinds, mountOptions);
assertEqual(recs.proj.hostPath, proj, 'hostPath stays stored');
assertEqual(recs.proj.mode, 'ro+hide', 'mode stays stored');
assertDeepEqual(recs.proj.hide, [{ path: '.ssh' }], 'hide stays stored');
const map = buildMountMap({ proj: { path: 'proc', mode: 'rw' } }, mountBinds);
assertEqual(map.proj, proj, 'mountMap keeps stored path');
"
	[[ "$status" -eq 0 ]]
}

@test "BwrapBackend spawn: rejected additional rw mount keeps stored ro+hide bind" {
	mkdir -p "${TEST_TMP}/home/proj/.ssh"
	echo key > "${TEST_TMP}/home/proj/.ssh/id_ed25519"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const proj = home + '/proj';
const guest = '/sessions/s1/mnt/proj';
function indexOfTriple(args, a, b, c) {
    for (let i = 0; i + 2 < args.length; i++) {
        if (args[i] === a && args[i + 1] === b && args[i + 2] === c) return i;
    }
    return -1;
}
(async () => {
    _setBwrapBindFdCache(false);
    const b = new BwrapBackend(() => {});
    b.mountBinds.set('proj', proj);
    b.mountOptions.set('proj', { mode: 'ro+hide', hide: [{ path: '.ssh' }] });
    let captured = null;
    b._spawnLocal = (id, cmd, args) => { captured = args; };
    await b.spawn({ id: 'p1', name: 's1', command: process.execPath, args: [],
        additionalMounts: { proj: { path: 'proc', mode: 'rw' } } });
    assert(captured !== null, 'spawn did not reach _spawnLocal');
    const ro = indexOfTriple(captured, '--ro-bind', proj, guest);
    assert(ro >= 0, 'stored ro+hide must stay --ro-bind: ' + JSON.stringify(captured));
    assert(indexOfTriple(captured, '--bind', proj, guest) === -1,
        'rejected rw mode must not become --bind');
    assert(captured.includes(guest + '/.ssh'),
        'stored hide must survive: ' + JSON.stringify(captured));
})().catch(e => { console.error(e); process.exit(1); });
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# Finding #2: spawn-time revalidation and --bind-fd hardening
# =============================================================================

@test "buildSessionMountArgs: symlink swap to forbidden path is dropped (fallback)" {
	mkdir -p "${TEST_TMP}/home/proj"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const proj = home + '/proj';
const guestMnt = '/sessions/s1/mnt';
const recs = { proj: { hostPath: proj, mode: 'rw' } };
const before = buildSessionMountArgs(recs, guestMnt,
    { fsApi: fs, supportsFd: false, logFn: () => {} });
assert(before.args.includes(proj), 'valid dir is bound before swap');
assertEqual(before.boundMounts.proj, proj, 'bound before swap');
fs.rmSync(proj, { recursive: true, force: true });
fs.symlinkSync('/proc', proj);
const after = buildSessionMountArgs(recs, guestMnt,
    { fsApi: fs, supportsFd: false, logFn: () => {} });
assert(!after.args.includes(proj), 'swapped symlink must not be bound');
assert(!after.args.includes('/proc'), 'forbidden target must not be bound');
assert(!('proj' in after.boundMounts), 'swapped mount must not be in boundMounts');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSessionMountArgs: fallback mode revalidates and uses --bind/--ro-bind" {
	mkdir -p "${TEST_TMP}/home/rwproj" "${TEST_TMP}/home/roproj"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const guestMnt = '/sessions/s1/mnt';
const recs = {
    rwproj: { hostPath: home + '/rwproj', mode: 'rw' },
    roproj: { hostPath: home + '/roproj', mode: 'ro' },
};
const built = buildSessionMountArgs(recs, guestMnt,
    { fsApi: fs, supportsFd: false, logFn: () => {} });
function hasTriple(args, a, b, c) {
    for (let i = 0; i + 2 < args.length; i++) {
        if (args[i] === a && args[i + 1] === b && args[i + 2] === c) return true;
    }
    return false;
}
assert(hasTriple(built.args, '--bind', home + '/rwproj', guestMnt + '/rwproj'),
    'rw uses --bind: ' + JSON.stringify(built.args));
assert(hasTriple(built.args, '--ro-bind', home + '/roproj', guestMnt + '/roproj'),
    'ro uses --ro-bind: ' + JSON.stringify(built.args));
assert(!built.args.some((a) => a.endsWith('-fd')),
    'fallback must not emit fd flags');
assertDeepEqual(built.fdList, [], 'fallback opens no fds');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSessionMountArgs: fd mode emits --bind-fd/--ro-bind-fd with fd numbers" {
	mkdir -p "${TEST_TMP}/home/rwproj" "${TEST_TMP}/home/roproj"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const guestMnt = '/sessions/s1/mnt';
const recs = {
    rwproj: { hostPath: home + '/rwproj', mode: 'rw' },
    roproj: { hostPath: home + '/roproj', mode: 'ro' },
};
const built = buildSessionMountArgs(recs, guestMnt,
    { fsApi: fs, supportsFd: true, firstFd: 3, logFn: () => {} });
try {
    function hasTriple(args, a, b, c) {
        for (let i = 0; i + 2 < args.length; i++) {
            if (args[i] === a && args[i + 1] === b && args[i + 2] === c) return true;
        }
        return false;
    }
    assert(hasTriple(built.args, '--bind-fd', '3', guestMnt + '/rwproj'),
        'rw uses --bind-fd 3: ' + JSON.stringify(built.args));
    assert(hasTriple(built.args, '--ro-bind-fd', '4', guestMnt + '/roproj'),
        'ro uses --ro-bind-fd 4: ' + JSON.stringify(built.args));
    assertEqual(built.fdList.length, 2, 'two fds opened');
    assertEqual(built.fdList[0].childFd, 3, 'first child fd');
    assertEqual(built.fdList[1].childFd, 4, 'second child fd');
    const stdio = ['pipe', 'pipe', 'pipe', ...built.fdList.map((e) => e.hostFd)];
    assertEqual(stdio[3], built.fdList[0].hostFd, 'stdio[3] carries first fd');
    assertEqual(stdio[4], built.fdList[1].hostFd, 'stdio[4] carries second fd');
} finally {
    for (const e of built.fdList) { try { fs.closeSync(e.hostFd); } catch (_) {} }
}
"
	[[ "$status" -eq 0 ]]
}

@test "openMountFd: rejects fd whose target differs from the validated realpath" {
	run node -e "${NODE_PREAMBLE}
let closed = false;
const fakeFs = {
    statSync: () => ({ isDirectory: () => true, dev: 11, ino: 22 }),
    openSync: () => 99,
    readlinkSync: () => '/some/other/path',
    fstatSync: () => ({ dev: 11, ino: 22 }),
    closeSync: () => { closed = true; },
    constants: fs.constants,
};
const r = openMountFd('/home/user/proj', fakeFs);
assert(!r.ok, 'mismatched fd target must be rejected');
assert(r.reason.includes('mismatch'), 'reason names mismatch: ' + r.reason);
assert(closed, 'rejected fd must be closed');
"
	[[ "$status" -eq 0 ]]
}

@test "detectBindFdSupport: matches --bind-fd in bwrap help text" {
	run node -e "${NODE_PREAMBLE}
assert(detectBindFdSupport('--bind-fd FD DEST  Bind open directory or path fd'),
    'help with --bind-fd');
assert(!detectBindFdSupport('--bind SRC DEST  Bind a file or directory'),
    'help without --bind-fd');
_resetBwrapBindFdCache();
assertEqual(bwrapSupportsBindFd(() => '--bind-fd FD DEST'), true, 'exec reports support');
assertEqual(bwrapSupportsBindFd(() => '--bind SRC DEST'), true, 'cached value wins');
_resetBwrapBindFdCache();
assertEqual(bwrapSupportsBindFd(() => { throw new Error('no bwrap'); }), false,
    'probe failure means no support');
_resetBwrapBindFdCache();
"
	[[ "$status" -eq 0 ]]
}

@test "BwrapBackend spawn: fd mode passes fds via stdio and closes them" {
	mkdir -p "${TEST_TMP}/home/proj"
	export HOME="${TEST_TMP}/home"
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const proj = home + '/proj';
const guest = '/sessions/s1/mnt/proj';
(async () => {
    _setBwrapBindFdCache(true);
    const b = new BwrapBackend(() => {});
    b.mountBinds.set('proj', proj);
    b.mountOptions.set('proj', { mode: 'ro' });
    let captured = null;
    let capturedExtra = null;
    b._spawnLocal = (id, cmd, args, wd, env, extra) => {
        captured = args;
        capturedExtra = extra;
    };
    await b.spawn({ id: 'p1', name: 's1', command: process.execPath, args: [] });
    _setBwrapBindFdCache(null);
    assert(captured !== null, 'spawn did not reach _spawnLocal');
    let fdIdx = -1;
    for (let i = 0; i + 2 < captured.length; i++) {
        if (captured[i] === '--ro-bind-fd' && captured[i + 1] === '3'
            && captured[i + 2] === guest) fdIdx = i;
    }
    assert(fdIdx >= 0, '--ro-bind-fd 3 must be emitted: ' + JSON.stringify(captured));
    assert(Array.isArray(capturedExtra) && capturedExtra.length === 1,
        'one fd through stdio: ' + JSON.stringify(capturedExtra));
    assertEqual(typeof capturedExtra[0], 'number', 'stdio fd is a number');
    let closed = false;
    try { fs.fstatSync(capturedExtra[0]); } catch (_) { closed = true; }
    assert(closed, 'parent fd must be closed after spawn');
})().catch(e => { console.error(e); process.exit(1); });
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# Finding #8: buildHideArgs drops hides under another hidden directory
# =============================================================================

@test "buildHideArgs: drops child file under hidden parent dir" {
	mkdir -p "${TEST_TMP}/hide/proj/.ssh"
	echo key > "${TEST_TMP}/hide/proj/.ssh/id_ed25519"
	run node -e "${NODE_PREAMBLE}
const root = '${TEST_TMP}/hide/proj';
const guest = '/sessions/s1/mnt/proj';
const r = buildHideArgs(root, guest,
    [{ path: '.ssh' }, { path: '.ssh/id_ed25519' }]);
assert(r.ok, 'hide must succeed');
assertDeepEqual(r.hidden, ['.ssh'], 'child file dropped');
assertDeepEqual(r.args, ['--tmpfs', guest + '/.ssh', '--remount-ro', guest + '/.ssh'],
    'only the parent tmpfs');
"
	[[ "$status" -eq 0 ]]
}

@test "buildHideArgs: drops child dir under hidden parent dir" {
	mkdir -p "${TEST_TMP}/hide/proj/.ssh/sub"
	run node -e "${NODE_PREAMBLE}
const root = '${TEST_TMP}/hide/proj';
const guest = '/sessions/s1/mnt/proj';
const r = buildHideArgs(root, guest,
    [{ path: '.ssh/sub' }, { path: '.ssh' }]);
assert(r.ok, 'hide must succeed');
assertDeepEqual(r.hidden, ['.ssh'], 'child dir dropped');
assertEqual(r.args.filter((a) => a === '--tmpfs').length, 1, 'single parent tmpfs');
"
	[[ "$status" -eq 0 ]]
}

@test "buildHideArgs: keeps .ssh2 alongside .ssh (no string-prefix match)" {
	mkdir -p "${TEST_TMP}/hide/proj/.ssh" "${TEST_TMP}/hide/proj/.ssh2"
	run node -e "${NODE_PREAMBLE}
const root = '${TEST_TMP}/hide/proj';
const guest = '/sessions/s1/mnt/proj';
const r = buildHideArgs(root, guest,
    [{ path: '.ssh' }, { path: '.ssh2' }]);
assert(r.ok, 'hide must succeed');
assertDeepEqual(r.hidden, ['.ssh', '.ssh2'], 'siblings both kept');
assert(r.args.includes(guest + '/.ssh'), '.ssh covered');
assert(r.args.includes(guest + '/.ssh2'), '.ssh2 covered');
"
	[[ "$status" -eq 0 ]]
}
