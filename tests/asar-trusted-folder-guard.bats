#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031  # Literal JS; Bats uses subshells
#
# asar-trusted-folder-guard.bats
#
# patch_asar_trusted_folder_guard injects
# `if(PARAM.endsWith(".asar"))return;` at the head of the addTrustedFolder
# handler. Its idempotency probe must not be confused by the async stat
# helper that patch_asar_path_filter injects earlier in the same run:
#
#   async filter : if(PARAM.endsWith(".asar"))return null;
#   this patch   : if(PARAM.endsWith(".asar"))return;
#
# The shorter probe `endsWith(".asar"))return` matches both, which used to
# report "already present (idempotent)" and silently skip the guard even
# when it had never been applied. These tests pin the discrimination and
# the honest-skip behaviour when the upstream anchor is absent (1.44121.4
# moved addTrustedFolder into an IPC router registration).

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

sha() {
	sha256sum "$1" | cut -d' ' -f1
}

@test "trusted folder guard: injects the guard for the legacy handler shape" {
	printf '%s' \
		'const o={async addTrustedFolder(folder){await ZOe(folder)}};async function r8(e){try{return await(0,y.stat)(e)}catch{return null}}' \
		> "$main_js"
	patch_asar_trusted_folder_guard >/dev/null
	grep -qF 'addTrustedFolder(folder){if(folder.endsWith(".asar"))return;' \
		"$main_js"
	node --check "$main_js"
}

@test "trusted folder guard: injects the guard when the async stat filter is already applied" {
	printf '%s' \
		'const o={async addTrustedFolder(folder){await ZOe(folder)}};async function r8(e){try{if(e.endsWith(".asar"))return null;return await(0,y.stat)(e)}catch{return null}}' \
		> "$main_js"
	patch_asar_trusted_folder_guard >/dev/null
	grep -qF 'addTrustedFolder(folder){if(folder.endsWith(".asar"))return;' \
		"$main_js"
	[[ $(grep -cF 'if(e.endsWith(".asar"))return null;' "$main_js") -eq 1 ]]
	node --check "$main_js"
}

@test "trusted folder guard: patching twice is byte-idempotent" {
	printf '%s' \
		'const o={async addTrustedFolder(folder){await ZOe(folder)}}' \
		> "$main_js"
	patch_asar_trusted_folder_guard >/dev/null
	local before
	before=$(sha "$main_js")
	run patch_asar_trusted_folder_guard
	[[ $status -eq 0 ]]
	[[ $output == *'already present (idempotent)'* ]]
	[[ $before == "$(sha "$main_js")" ]]
}

@test "trusted folder guard: reports an honest skip when the anchor is absent" {
	printf '%s' \
		'const r=["addTrustedFolder",[["folder",P]]];' \
		> "$main_js"
	local before
	before=$(sha "$main_js")
	run patch_asar_trusted_folder_guard
	[[ $status -eq 0 ]]
	[[ $output == *'trusted-folder guard was NOT applied'* ]]
	[[ $output != *'already present'* ]]
	[[ $before == "$(sha "$main_js")" ]]
}

@test "trusted folder guard: injects the guard into the sibling chunk (2.37337.1 shape)" {
	printf '%s' \
		'const r=["addTrustedFolder",[["folder",F]]];' \
		> "$main_js"
	printf '%s' \
		'async function X(e){return e}const o={async addTrustedFolder(e){t.j6.info(`LocalAgentModeSessions.addTrustedFolder: ${e}`);let n=await Fn(e);if(n===null)return}};' \
		> "$TEST_TMP/index.chunk-DhN98CRk.js"
	patch_asar_trusted_folder_guard >/dev/null
	grep -qF 'addTrustedFolder(e){if(e.endsWith(".asar"))return;' \
		"$TEST_TMP/index.chunk-DhN98CRk.js"
	# The main chunk (IPC registration only) is left untouched.
	[[ $(sha "$main_js") == "$(printf '%s' 'const r=["addTrustedFolder",[["folder",F]]];' | sha256sum | cut -d' ' -f1)" ]]
	node --check "$TEST_TMP/index.chunk-DhN98CRk.js"
}

@test "trusted folder guard: injects the guard into the sibling chunk (1.44121.4 shape)" {
	printf '%s' \
		'const r=["addTrustedFolder",[["folder",P]]];' \
		> "$main_js"
	printf '%s' \
		'const o={async addTrustedFolder(e){t.JA.info(`LocalAgentModeSessions.addTrustedFolder: ${e}`);let n=await o.m(e);if(n===null)return}};' \
		> "$TEST_TMP/index.chunk-BaCGxvUV.js"
	patch_asar_trusted_folder_guard >/dev/null
	grep -qF 'addTrustedFolder(e){if(e.endsWith(".asar"))return;' \
		"$TEST_TMP/index.chunk-BaCGxvUV.js"
	node --check "$TEST_TMP/index.chunk-BaCGxvUV.js"
}

@test "trusted folder guard: sibling-chunk patching twice is byte-idempotent" {
	printf '%s' \
		'const r=["addTrustedFolder",[["folder",F]]];' \
		> "$main_js"
	printf '%s' \
		'const o={async addTrustedFolder(e){t.j6.info(`x: ${e}`);}};' \
		> "$TEST_TMP/index.chunk-DhN98CRk.js"
	patch_asar_trusted_folder_guard >/dev/null
	local before
	before=$(sha "$TEST_TMP/index.chunk-DhN98CRk.js")
	run patch_asar_trusted_folder_guard
	[[ $status -eq 0 ]]
	[[ $output == *'already present (idempotent)'* ]]
	[[ $before == "$(sha "$TEST_TMP/index.chunk-DhN98CRk.js")" ]]
}

@test "trusted folder guard: reports an honest skip when the anchor is ambiguous" {
	printf '%s' \
		'const o={async addTrustedFolder(a){await x(a)}}' \
		> "$TEST_TMP/index.chunk-AAAA.js"
	printf '%s' \
		'const o={async addTrustedFolder(b){await y(b)}}' \
		> "$TEST_TMP/index.chunk-BBBB.js"
	printf '%s' \
		'stub' \
		> "$main_js"
	run patch_asar_trusted_folder_guard
	[[ $status -eq 0 ]]
	[[ $output == *'trusted-folder guard was NOT applied'* ]]
	[[ $output != *'already present'* ]]
	[[ $(grep -c 'endsWith(".asar")' "$TEST_TMP/index.chunk-AAAA.js") -eq 0 ]]
	[[ $(grep -c 'endsWith(".asar")' "$TEST_TMP/index.chunk-BBBB.js") -eq 0 ]]
}
