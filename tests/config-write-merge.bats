#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells

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
