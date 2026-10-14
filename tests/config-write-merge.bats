#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells
#
# config-write-merge.bats
#
# patch_config_write_merge injects a guard immediately before
# claude_desktop_config.json is written, without breaking the
# surrounding minified JavaScript. Two upstream shapes exist: the legacy
# standalone writer and the newer return-shaped writer (1.44121.4) whose
# write is `return await Wr(...)` directly inside the outer `try{`.
#
# The guard restores mcpServers from disk only when the outgoing config
# has no mcpServers key (a failed load); a server deleted in Settings
# must stay deleted. The behavior tests drive real writes through the
# patched writer.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
CONFIG_SH="$SCRIPT_DIR/../scripts/patches/config.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/config.sh
	source "$CONFIG_SH"
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "config merge: latest return-shaped writer remains valid JavaScript" {
	printf '%s' \
		'function cg(e){return I3e.runExclusive((async()=>{let t=ng();try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}))}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	grep -qF 'try{try{if(e.mcpServers==null){var _cdd_dc=' "$main_js"
	grep -qF '}catch(_cdd_ex){};return await Wr(t,e)' "$main_js"
	node --check "$main_js"
}

@test "config merge: spaced return-shaped writer with a dollar-sign logger stays valid JavaScript" {
	printf '%s' \
		'async function cg(e){let t=ng();try { return await Wr(t, e), N$.info("Config file written"), "written" } catch (x) { return "failed" }}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	grep -qF 'try {try{if(e.mcpServers==null)' "$main_js"
	node --check "$main_js"
}

@test "config merge: legacy standalone writer is patched before the write" {
	printf '%s' \
		'function old(){try{return x()}catch{}}async function cg(){let t=ng(),e={};await Wr(t,e),N.info("Config file written");return e}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	grep -qF '}catch(_cdd_ex){};await Wr(t,e)' "$main_js"
	node --check "$main_js"
}

@test "config merge: the merge block is inserted exactly once" {
	printf '%s' \
		'function cg(e){return I3e.runExclusive((async()=>{let t=ng();try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}))}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	[[ $(grep -cF 'var _cdd_dc=' "$main_js") -eq 1 ]]
}

@test "config merge: patching twice is byte-idempotent" {
	printf '%s' \
		'function cg(e){return I3e.runExclusive((async()=>{let t=ng();try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}))}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_config_write_merge >/dev/null
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "config merge: zero anchors leaves the bundle byte-identical" {
	printf '%s' \
		'function noref(){return 1}' \
		> "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_config_write_merge
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "config merge: multiple anchors fails closed without corrupting the bundle" {
	printf '%s' \
		'function a(){try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}function b(){try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}' \
		> "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_config_write_merge
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
	[[ $status -ne 0 ]]
}

# Patch a runnable return-shaped writer and expose helpers that model
# the app: launch() loads the file once into the live config object the
# app keeps mutating, write(cfg) performs one real config write and
# resolves to "written" or "failed", failNextWrite() makes the next
# write throw like a full disk, and onDisk() lists the persisted
# servers ("missing" when the key is absent).
_setup_writer() {
	printf '%s' \
		'const fs=require("fs"),N={info(){}};async function Wr(t,e){if(globalThis.__failNextWrite){globalThis.__failNextWrite=!1;throw new Error("ENOSPC")}fs.writeFileSync(t,JSON.stringify(e))}async function cg(t,e){try{return await Wr(t,e),N.info("Config file written"),"written"}catch(x){return"failed"}}module.exports=cg;' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	cat > "$TEST_TMP/harness.js" << 'HARNESS'
const fs = require('fs');
const p = process.env.CONFIG_JSON;
const cg = require(process.env.WRITER_JS);
const servers = (names) =>
	Object.fromEntries(names.map((n) => [n, { command: n }]));
exports.disk = (names) =>
	fs.writeFileSync(p, JSON.stringify({ mcpServers: servers(names) }));
exports.launch = () => JSON.parse(fs.readFileSync(p, 'utf8'));
exports.write = (cfg) => cg(p, cfg);
exports.failNextWrite = () => {
	globalThis.__failNextWrite = true;
};
exports.onDisk = () => {
	const m = JSON.parse(fs.readFileSync(p, 'utf8')).mcpServers;
	return m === undefined ? 'missing' : Object.keys(m).join(',');
};
HARNESS
	export WRITER_JS="$main_js"
	export CONFIG_JSON="$TEST_TMP/claude_desktop_config.json"
	export HARNESS_JS="$TEST_TMP/harness.js"
}

@test "config merge: server deleted in Settings stays deleted across later writes" {
	_setup_writer
	run node -e '
const h = require(process.env.HARNESS_JS);
(async () => {
	h.disk(["context7", "fetch"]);
	const cfg = h.launch();
	const r = [await h.write(cfg)];
	delete cfg.mcpServers.context7;
	r.push(await h.write(cfg), await h.write(cfg));
	console.log(r.join(",") + "|" + h.onDisk());
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'written,written,written|fetch' ]]
}

@test "config merge: deleting the last server writes an empty mcpServers" {
	_setup_writer
	run node -e '
const h = require(process.env.HARNESS_JS);
(async () => {
	h.disk(["context7"]);
	const cfg = h.launch();
	delete cfg.mcpServers.context7;
	const r = await h.write(cfg);
	console.log(r + "|[" + h.onDisk() + "]");
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'written|[]' ]]
}

@test "config merge: deletion retried after a failed write stays deleted" {
	_setup_writer
	run node -e '
const h = require(process.env.HARNESS_JS);
(async () => {
	h.disk(["context7", "fetch"]);
	const cfg = h.launch();
	delete cfg.mcpServers.context7;
	h.failNextWrite();
	const r = [await h.write(cfg), h.onDisk()];
	r.push(await h.write(cfg), h.onDisk());
	console.log(r.join("|"));
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'failed|context7,fetch|written|fetch' ]]
}

@test "config merge: a config loaded without mcpServers keeps the servers on disk" {
	_setup_writer
	# A failed load leaves the live object without mcpServers; the
	# restore lands in that object, so a later deletion still sticks.
	run node -e '
const h = require(process.env.HARNESS_JS);
(async () => {
	h.disk(["context7", "fetch"]);
	const cfg = { preferences: {} };
	const r = [await h.write(cfg), h.onDisk()];
	delete cfg.mcpServers.context7;
	r.push(await h.write(cfg), h.onDisk());
	console.log(r.join("|"));
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'written|context7,fetch|written|fetch' ]]
}
