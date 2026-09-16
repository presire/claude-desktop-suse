#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells
#
# asar-path-filter.bats
#
# patch_asar_path_filter must reject paths that live inside app.asar so
# workspace folders resolve to the unpacked tree. Two upstream shapes
# exist: the legacy synchronous directory helper and the newer shared
# async stat helper (added in 1.44121.4).

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
COWORK_SH="$SCRIPT_DIR/../scripts/patches/cowork.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/cowork.sh
	source "$COWORK_SH"
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "asar path filter: patches legacy synchronous directory helper" {
	printf '%s' \
		'function wFA(e){try{return ee.statSync(e).isDirectory()}catch{return!1}}' \
		> "$main_js"
	patch_asar_path_filter >/dev/null
	grep -qF \
		'function wFA(e){try{return!e.endsWith(".asar")&&ee.statSync(e).isDirectory()' \
		"$main_js"
}

@test "asar path filter: patches latest shared async stat helper" {
	printf '%s' \
		'async function r8(e){try{return await(0,y.stat)(e)}catch{return null}}' \
		> "$main_js"
	patch_asar_path_filter >/dev/null
	grep -qF \
		'async function r8(e){if(e.endsWith(".asar"))return null;try{return await(0,y.stat)(e)}catch{return null}}' \
		"$main_js"
}

@test "asar path filter: legacy helper patch is idempotent" {
	printf '%s' \
		'function wFA(e){try{return ee.statSync(e).isDirectory()}catch{return!1}}' \
		> "$main_js"
	patch_asar_path_filter >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_asar_path_filter >/dev/null
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "asar path filter: latest helper patch is idempotent" {
	printf '%s' \
		'async function r8(e){try{return await(0,y.stat)(e)}catch{return null}}' \
		> "$main_js"
	patch_asar_path_filter >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_asar_path_filter >/dev/null
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "asar path filter: unknown shape fails fast without corrupting the bundle" {
	printf '%s' \
		'function totallyDifferent(e){return e}' \
		> "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_asar_path_filter
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
	[[ $status -ne 0 ]]
}
