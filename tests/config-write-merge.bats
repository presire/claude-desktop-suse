#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells
#
# config-write-merge.bats
#
# patch_config_write_merge must merge the runtime endpoint block into
# the config object immediately before claude_desktop_config.json is
# written, without breaking the surrounding minified JavaScript. Two
# upstream shapes exist: the legacy standalone writer and the newer
# return-shaped writer (1.44121.4) whose write is `return await Wr(...)`
# directly inside the outer `try{`.

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
	grep -qF 'try{try{var _cdd_dc=' "$main_js"
	grep -qF '}catch(_cdd_ex){};return await Wr(t,e)' "$main_js"
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
