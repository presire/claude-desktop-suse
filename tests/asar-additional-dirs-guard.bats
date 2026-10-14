#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031  # Literal JS; Bats uses subshells
#
# asar-additional-dirs-guard.bats
#
# patch_asar_additional_dirs_guard filters .asar paths out of the
# --add-dir CLI dispatch and the session-restore folder list (#649).
# Upstream has shipped three dispatch shapes and two restore shapes:
#
#   dispatch : for(let t of e)w.push("--add-dir",t)        (<= 1.44121.4)
#              e.forEach(t=>w.push("--add-dir",t))
#              for(let t of e)w.push(Y7("--add-dir",t))    (2.37337.1)
#   restore  : (o.userSelectedFolders||[]).map(...)         (<= 1.44121.4)
#              d=u?[]:l.userSelectedFolders??[];...Filtering out deleted
#              folder from session                          (2.37337.1)
#
# Every shape must patch exactly once, rerun as a no-op, and fail closed
# when the dispatch is missing or ambiguous.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
CONFIG_SH="$SCRIPT_DIR/../scripts/patches/config.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	printf '%s' 'require("./index.chunk-Main0001.js");' > "$main_js"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/config.sh
	source "$CONFIG_SH"
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

chunk() {
	printf '%s' "$2" > "$TEST_TMP/index.chunk-$1.js"
}

sha_all() {
	cat "$TEST_TMP"/index.chunk-*.js | sha256sum | cut -d' ' -f1
}

LEGACY_RESTORE='async function r(o){let p=(await Promise.all((o.userSelectedFolders||[]).map((async e=>await a(e)?(j.info(`Filtering out deleted folder from session ${o.sessionId}: ${e}`),null):e)))).filter(Boolean);return p}'
CURRENT_RESTORE='async function r(c,t){let n=ll(c)&&h.n(c.userSelectedFolders??[]),w=new Set(c.userSelectedFolders??[]);let l=Fh(c,t.tG),u=l.sessionType===t.HK,d=u?[]:l.userSelectedFolders??[];t.Qn(d.length);let p=(await Promise.all(d.map((async e=>await a(e)?(t.j6.info(`Filtering out deleted folder from session ${l.sessionId}: ${e}`),null):e)))).filter(Boolean);return[n,w,p]}'

@test "add-dir guard: legacy for-of dispatch and legacy restore are filtered" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--add-dir",t);return w}'
	chunk Rest0001 "$LEGACY_RESTORE"

	run patch_asar_additional_dirs_guard
	[[ $status -eq 0 ]]
	[[ $output == *'Filtered --add-dir dispatch in index.chunk-Main0001.js'* ]]
	[[ $output == *'Injected .asar filter in session restore in index.chunk-Rest0001.js'* ]]
	grep -qF 'for(let t of e.filter(_d=>!_d.endsWith(".asar")))w.push("--add-dir",t)' \
		"$TEST_TMP/index.chunk-Main0001.js"
	grep -qF '(o.userSelectedFolders||[]).filter(_d=>!_d.endsWith(".asar")).map(' \
		"$TEST_TMP/index.chunk-Rest0001.js"
	node --check "$TEST_TMP/index.chunk-Main0001.js"
	node --check "$TEST_TMP/index.chunk-Rest0001.js"
}

@test "add-dir guard: forEach dispatch is filtered" {
	chunk Main0001 'function b(e,w){e.forEach(t=>w.push("--add-dir",t));return w}'

	run patch_asar_additional_dirs_guard
	[[ $status -eq 0 ]]
	grep -qF 'e.filter(_d=>!_d.endsWith(".asar")).forEach(t=>w.push("--add-dir",t))' \
		"$TEST_TMP/index.chunk-Main0001.js"
	[[ $output == *'WARNING: session restore anchor not found'* ]]
}

@test "add-dir guard: 2.37337.1 joiner dispatch and ?? restore are filtered" {
	chunk Main0001 'function Y7(e,t){return`${e}=${t}`}function b(e,w){for(let t of e)w.push(Y7("--add-dir",t));return w}'
	chunk Rest0001 "$CURRENT_RESTORE"

	run patch_asar_additional_dirs_guard
	[[ $status -eq 0 ]]
	grep -qF 'for(let t of e.filter(_d=>!_d.endsWith(".asar")))w.push(Y7("--add-dir",t))' \
		"$TEST_TMP/index.chunk-Main0001.js"
	grep -qF 'd=u?[]:(l.userSelectedFolders??[]).filter(_d=>!_d.endsWith(".asar"));t.Qn(' \
		"$TEST_TMP/index.chunk-Rest0001.js"
	# The unrelated reads earlier in the chunk stay untouched.
	grep -qF 'h.n(c.userSelectedFolders??[]),w=new Set(c.userSelectedFolders??[])' \
		"$TEST_TMP/index.chunk-Rest0001.js"
	node --check "$TEST_TMP/index.chunk-Main0001.js"
	node --check "$TEST_TMP/index.chunk-Rest0001.js"
}

@test "add-dir guard: patched output reruns as a no-op for every shape" {
	local dispatch
	for dispatch in \
		'function b(e,w){for(let t of e)w.push("--add-dir",t)}' \
		'function b(e,w){e.forEach(t=>w.push("--add-dir",t))}' \
		'function b(e,w){for(let t of e)w.push(Y7("--add-dir",t))}'; do
		chunk Main0001 "$dispatch"
		chunk Rest0001 "$CURRENT_RESTORE"
		patch_asar_additional_dirs_guard > /dev/null
		local before
		before=$(sha_all)

		run patch_asar_additional_dirs_guard
		[[ $status -eq 0 ]]
		[[ $output == *'.asar --add-dir filter already present (idempotent)'* ]]
		[[ $output == *'Session restore filter already present (idempotent)'* ]]
		[[ $(sha_all) == "$before" ]]
	done
}

@test "add-dir guard: legacy restore reruns as a no-op" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--add-dir",t)}'
	chunk Rest0001 "$LEGACY_RESTORE"
	patch_asar_additional_dirs_guard > /dev/null
	local before
	before=$(sha_all)

	run patch_asar_additional_dirs_guard
	[[ $status -eq 0 ]]
	[[ $output == *'Session restore filter already present (idempotent)'* ]]
	[[ $(sha_all) == "$before" ]]
}

@test "add-dir guard: missing dispatch fails closed" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--other",t)}'

	run patch_asar_additional_dirs_guard
	[[ $status -ne 0 ]]
	[[ $output == *'FATAL: --add-dir dispatch loop not found.'* ]]
}

@test "add-dir guard: two dispatch sites fail closed without writing" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--add-dir",t)}'
	chunk Main0002 'function c(e,w){for(let t of e)w.push(Y7("--add-dir",t))}'
	local before
	before=$(sha_all)

	run patch_asar_additional_dirs_guard
	[[ $status -ne 0 ]]
	[[ $output == *'FATAL: --add-dir dispatch has ambiguous candidates.'* ]]
	[[ $(sha_all) == "$before" ]]
}

@test "add-dir guard: unknown userSelectedFolders shape fails closed" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--add-dir",t)}'
	chunk Rest0001 'function r(l){let d=l.userSelectedFolders;return d}'

	run patch_asar_additional_dirs_guard
	[[ $status -ne 0 ]]
	[[ $output == *'FATAL: userSelectedFolders shape is unsupported.'* ]]
}
