#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells
#
# claude-native-stub.bats
#
# The Windows bundle calls @ant/claude-native for the cloud-sync folder
# lookup (registry), safe-fs containment (openRootDir + *Beneath) and
# process memory. These tests drive the Linux stub through the same call
# shapes the bundle uses.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
STUB_JS="$SCRIPT_DIR/../scripts/claude-native-stub.js"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP STUB_JS
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "native stub: registry enumerators are iterable for the folder picker" {
	run node -e '
		const n = require(process.env.STUB_JS);
		const found = [];
		for (const hive of ["HKCU", "HKLM"])
			for (const key of n.enumRegistrySubkeys(hive, "SOFTWARE\\SyncEngines\\Providers"))
				for (const v of n.enumRegistryValues(hive, key)) found.push(v.data);
		console.log(JSON.stringify(found));
	'
	[[ $status -eq 0 ]]
	[[ $output == '[]' ]]
}

@test "native stub: safe-fs round trip below an opened root" {
	run node -e '
		const fs = require("fs");
		const c = fs.constants;
		const n = require(process.env.STUB_JS);
		(async () => {
			const root = await n.openRootDir(process.env.TEST_TMP);
			await n.mkdirBeneath(root, ["state"], 0o700);
			const fd = await n.openBeneath(root, ["state", "w.json.tmp"],
				c.O_WRONLY | c.O_CREAT | c.O_EXCL, 0o600);
			fs.writeSync(fd, "{}");
			fs.closeSync(fd);
			await n.renameBeneath(root, ["state", "w.json.tmp"], ["state", "w.json"]);
			const st = await n.statBeneath(root, ["state", "w.json"]);
			const dir = await n.openBeneath(root, ["state"], c.O_RDONLY | c.O_DIRECTORY, 0);
			const dirIsDir = fs.fstatSync(dir).isDirectory();
			fs.closeSync(dir);
			const body = fs.readFileSync(process.env.TEST_TMP + "/state/w.json", "utf8");
			await n.unlinkBeneath(root, ["state", "w.json"]);
			await n.rmdirBeneath(root, ["state"]);
			fs.closeSync(root);
			console.log([typeof root, st.size, dirIsDir, body,
				fs.existsSync(process.env.TEST_TMP + "/state")].join(","));
		})().catch((e) => { console.error(e); process.exit(1); });
	'
	[[ $status -eq 0 ]]
	[[ $output == 'number,2,true,{},false' ]]
}

@test "native stub: safe-fs refuses symlinks and parent escapes with CODE: errors" {
	mkdir -p "$TEST_TMP/root/real" "$TEST_TMP/outside"
	ln -s ../outside "$TEST_TMP/root/dirlink"
	ln -s ../outside/secret "$TEST_TMP/root/leaflink"
	printf 'x' > "$TEST_TMP/outside/secret"
	run node -e '
		const c = require("fs").constants;
		const n = require(process.env.STUB_JS);
		const code = (e) => /^([A-Z]{3,12}): /.exec(String(e.message))?.[1];
		(async () => {
			const root = await n.openRootDir(process.env.TEST_TMP + "/root");
			const out = [];
			for (const segs of [["dirlink", "secret"], ["leaflink"], ["..", "outside"], ["real", ""]]) {
				try {
					await n.openBeneath(root, segs, c.O_RDONLY, 0);
					out.push("opened");
				} catch (e) {
					out.push(code(e) === e.code ? e.code : "bad-message");
				}
			}
			console.log(out.join(","));
		})().catch((e) => { console.error(e); process.exit(1); });
	'
	[[ $status -eq 0 ]]
	[[ $output == 'ENOTDIR,ELOOP,EXDEV,EINVAL' ]]
}

@test "native stub: openRootDir on a missing directory rejects with a code" {
	run node -e '
		const n = require(process.env.STUB_JS);
		n.openRootDir(process.env.TEST_TMP + "/missing")
			.then(() => console.log("opened"), (e) => console.log(e.code));
	'
	[[ $status -eq 0 ]]
	[[ $output == 'ENOENT' ]]
}

@test "native stub: readProcessTree returns the root and its children" {
	run node -e '
		const { spawn } = require("child_process");
		const n = require(process.env.STUB_JS);
		const child = spawn("sleep", ["5"]);
		(async () => {
			const rows = await n.readProcessTree(process.pid);
			child.kill();
			const self = rows.find((r) => r.pid === process.pid);
			const kid = rows.find((r) => r.pid === child.pid);
			console.log([rows[0].pid === process.pid,
				typeof self.workingSetBytes, typeof self.cpuSeconds,
				typeof self.creationTime, kid?.parentPid === process.pid,
				rows.every((r) => r.pid === process.pid || rows.some((p) => p.pid === r.parentPid))
			].join(","));
		})().catch((e) => { child.kill(); console.error(e); process.exit(1); });
	'
	[[ $status -eq 0 ]]
	[[ $output == 'true,number,number,number,true,true' ]]
}

@test "native stub: readProcessFootprints keeps order and nulls gone pids" {
	run node -e '
		const n = require(process.env.STUB_JS);
		(async () => {
			const [self, gone] = await n.readProcessFootprints([process.pid, 2147483646]);
			const [again] = await n.readProcessFootprints([process.pid]);
			console.log([typeof self.footprintBytes, self.commitBytes,
				self.creationTime === again.creationTime, gone].join(","));
		})().catch((e) => { console.error(e); process.exit(1); });
	'
	[[ $status -eq 0 ]]
	[[ $output == 'number,,true,' ]]
}
