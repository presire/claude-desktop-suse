#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2154  # literal stub scripts; ASAR_BIN/asar_bin cross the sourced resolver
#
# resolve_asar_bin in scripts/verify-patches.sh.
#
# The failure this exists to prevent is not "asar is missing" — it is
# "asar is present and does not run". @electron/asar 4.x declares
# engines.node >=22.12.0 and refuses to start below it, npm downgrades
# that to an EBADENGINE warning, and the wrapper lands on disk anyway.
# Callers then fail on an extract that never produced a tree (#839).
#
# verify-patches.sh also has to work offline: it replaced
# `npx --yes @electron/asar`, which resolved an unpinned package from
# the network on every .asar input. Every test here is network-free.
#
# Resolution order under test: ASAR_BIN, <build>/node_modules/.bin/asar,
# asar on PATH, then a named failure that still mentions the Node floor.

setup() {
	# shellcheck source=scripts/verify-patches.sh
	source "$BATS_TEST_DIRNAME/../scripts/verify-patches.sh"

	stub_bin="$BATS_TEST_TMPDIR/bin"
	build_dir="$BATS_TEST_TMPDIR/build"
	out="$BATS_TEST_TMPDIR/output"
	mkdir -p "$stub_bin" "$build_dir"
	orig_path="$PATH"
	PATH="$stub_bin:$PATH"
	export PATH
	unset ASAR_BIN
}

# $1 = path, $2 = body after the shebang. Executable unless $3 = 'noexec'.
_make_asar() {
	local path="$1" body="$2" mode="${3:-exec}"
	mkdir -p "$(dirname "$path")"
	printf '%s\n' '#!/usr/bin/env bash' "$body" > "$path"
	if [[ $mode == 'exec' ]]; then
		chmod +x "$path"
	fi
}

_working_body() {
	printf '%s\n' 'case "$1" in' \
		'  --version) echo "4.3.0" ;;' \
		'  *) exit 1 ;;' \
		'esac'
}

_refusal_body() {
	printf '%s\n' 'echo "CANNOT RUN WITH NODE 20.19.2" >&2' \
		'exit 1'
}

# Run the resolver without letting a non-zero status abort the test.
_run_resolve() {
	rc=0
	resolve_asar_bin "$build_dir" >"$out" 2>&1 || rc=$?
	output=$(<"$out")
}

@test "resolve: ASAR_BIN wins over the build copy and PATH" {
	local override="$BATS_TEST_TMPDIR/override/asar"
	_make_asar "$build_dir/node_modules/.bin/asar" "$(_working_body)"
	_make_asar "$stub_bin/asar" "$(_working_body)"
	_make_asar "$override" "$(_working_body)"

	ASAR_BIN="$override"
	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$override" ]]
	[[ $output == *'Using asar executable:'* ]]
}

@test "resolve: a dead ASAR_BIN fails instead of being ignored" {
	local override="$BATS_TEST_TMPDIR/override/asar"
	_make_asar "$build_dir/node_modules/.bin/asar" "$(_working_body)"
	_make_asar "$override" "$(_refusal_body)"

	ASAR_BIN="$override"
	_run_resolve

	[[ $rc -ne 0 ]]
	[[ $output == *"ASAR_BIN='$override'"* ]]
	[[ $output == *'22.12.0'* ]]
}

@test "resolve: ASAR_BIN must be executable" {
	local override="$BATS_TEST_TMPDIR/override/asar"
	_make_asar "$override" "$(_working_body)" noexec

	ASAR_BIN="$override"
	_run_resolve

	[[ $rc -ne 0 ]]
	[[ $output == *'not executable'* ]]
}

@test "resolve: the build's node_modules/.bin/asar beats PATH" {
	local local_asar="$build_dir/node_modules/.bin/asar"
	_make_asar "$local_asar" "$(_working_body)"
	_make_asar "$stub_bin/asar" "$(_working_body)"

	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$local_asar" ]]
}

@test "resolve: a dead build asar falls through to a working PATH asar" {
	_make_asar "$build_dir/node_modules/.bin/asar" "$(_refusal_body)"
	_make_asar "$stub_bin/asar" "$(_working_body)"

	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$stub_bin/asar" ]]
	[[ $output == *"will not run"* ]]
}

@test "resolve: PATH is the last working source" {
	_make_asar "$stub_bin/asar" "$(_working_body)"

	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$stub_bin/asar" ]]
}

@test "resolve: a refusal that exits zero is still rejected" {
	_make_asar "$stub_bin/asar" 'echo "CANNOT RUN WITH NODE 20.19.2"'

	_run_resolve

	[[ $rc -ne 0 ]]
	[[ $output == *'no runnable asar'* ]]
}

@test "resolve: a non-executable PATH asar is rejected" {
	_make_asar "$stub_bin/asar" "$(_working_body)" noexec

	_run_resolve

	[[ $rc -ne 0 ]]
	[[ $output == *'no runnable asar'* ]]
}

@test "resolve: no asar anywhere names the Node floor and zypper" {
	PATH="$stub_bin"
	export PATH

	_run_resolve

	PATH="$orig_path"
	export PATH

	[[ $rc -ne 0 ]]
	[[ $output == *'no runnable asar'* ]]
	[[ $output == *'22.12.0'* ]]
	[[ $output == *'zypper'* ]]
	[[ $output == *"$build_dir/node_modules/.bin/asar"* ]]
}

@test "resolve: the build's asar runs under build/node when system Node is too old" {
	# System Node below the floor, as on a host where build.sh had to
	# bootstrap its own Node into build/node.
	printf '%s\n' '#!/usr/bin/env bash' 'echo v20.19.2' > "$stub_bin/node"
	chmod +x "$stub_bin/node"
	mkdir -p "$build_dir/node/bin"
	printf '%s\n' '#!/usr/bin/env bash' 'echo v22.23.2' > "$build_dir/node/bin/node"
	chmod +x "$build_dir/node/bin/node"
	# The wrapper refuses to start unless the Node it finds clears the floor.
	_make_asar "$build_dir/node_modules/.bin/asar" \
		'[[ $(node --version) == v22.23.2 ]] || { echo "CANNOT RUN WITH NODE $(node --version)" >&2; exit 1; }
echo 4.3.0'

	_run_resolve

	[[ $rc -eq 0 ]]
	[[ $asar_bin == "$build_dir/node_modules/.bin/asar" ]]
	# extract runs later in this shell, so the local Node must stay first.
	[[ $(command -v node) == "$build_dir/node/bin/node" ]]
}
