#!/usr/bin/env bats
# shellcheck disable=SC2034  # architecture/project_root are read by the sourced dependencies.sh
#
# The build's Node floor is not ours to pick: @electron/asar 4.x declares
# engines.node >=22.12.0 and refuses to start below it, while npm only
# emits an EBADENGINE *warning* and installs the wrapper anyway. On an
# older Node host that combination used to produce an asar that existed,
# never ran, and surfaced later as a patch failure rather than as a
# toolchain error (#839).
#
# Two things are pinned here: node_version_at_least must reject the
# 22.0-22.11 band that a major-only comparison waves through, and
# setup_nodejs must actually call it before deciding to download.

setup() {
	# shellcheck source=scripts/_common.sh
	source "$BATS_TEST_DIRNAME/../scripts/_common.sh"
	# shellcheck source=scripts/setup/dependencies.sh
	source "$BATS_TEST_DIRNAME/../scripts/setup/dependencies.sh"

	stub_bin="$BATS_TEST_TMPDIR/bin"
	work_dir="$BATS_TEST_TMPDIR/work"
	out="$BATS_TEST_TMPDIR/output"
	mkdir -p "$stub_bin" "$work_dir"
	PATH="$stub_bin:$PATH"
	export PATH
	architecture='x86_64'
	project_root="$BATS_TEST_TMPDIR"
}

_stub_command() {
	local name="$1" body="$2"
	printf '%s\n' '#!/usr/bin/env bash' "$body" > "$stub_bin/$name"
	chmod +x "$stub_bin/$name"
}

# ---------------------------------------------------------------------
# node_version_at_least
# ---------------------------------------------------------------------

@test "node floor: the shipped fallback download satisfies the floor" {
	node_version_at_least "$NODE_FALLBACK_VERSION" "$NODE_MIN_VERSION"
}

@test "node floor: the floor is the asar engine constraint" {
	[[ $NODE_MIN_VERSION == '22.12.0' ]]
}

@test "node version: the reported Node 20 host is rejected" {
	run node_version_at_least '20.19.2' "$NODE_MIN_VERSION"
	[[ $status -ne 0 ]]
}

@test "node version: the 22.0-22.11 band is rejected" {
	run node_version_at_least '22.11.9' "$NODE_MIN_VERSION"
	[[ $status -ne 0 ]]
	run node_version_at_least '22.0.0' "$NODE_MIN_VERSION"
	[[ $status -ne 0 ]]
}

@test "node version: exactly the floor is accepted" {
	node_version_at_least '22.12.0' "$NODE_MIN_VERSION"
	node_version_at_least '22.12.1' "$NODE_MIN_VERSION"
}

@test "node version: newer majors and minors are accepted" {
	node_version_at_least '22.13.0' "$NODE_MIN_VERSION"
	node_version_at_least '23.0.0' "$NODE_MIN_VERSION"
	node_version_at_least '24.1.0' "$NODE_MIN_VERSION"
}

@test "node version: a bare major cannot clear a minor floor" {
	run node_version_at_least '22' "$NODE_MIN_VERSION"
	[[ $status -ne 0 ]]
}

@test "node version: malformed versions are not trusted" {
	run node_version_at_least 'v22.12.0' "$NODE_MIN_VERSION"
	[[ $status -ne 0 ]]
	run node_version_at_least '' "$NODE_MIN_VERSION"
	[[ $status -ne 0 ]]
	run node_version_at_least '22.x' "$NODE_MIN_VERSION"
	[[ $status -ne 0 ]]
}

# ---------------------------------------------------------------------
# setup_nodejs wiring
# ---------------------------------------------------------------------

@test "setup_nodejs: a Node at the floor does not download" {
	_stub_command node 'echo "v22.12.0"'
	_stub_command wget 'exit 1'

	rc=0
	(setup_nodejs) >"$out" 2>&1 || rc=$?
	output=$(<"$out")

	[[ $rc -eq 0 ]]
	[[ $output == *'adequate (v22.12.0)'* ]]
	[[ $output != *'Installing Node.js'* ]]
}

@test "setup_nodejs: Node 22.11 is refused with the floor in the message" {
	_stub_command node 'echo "v22.11.9"'
	_stub_command wget 'exit 1'

	rc=0
	(setup_nodejs) >"$out" 2>&1 || rc=$?
	output=$(<"$out")

	[[ $rc -ne 0 ]]
	[[ $output == *'Need v22.12.0+'* ]]
	[[ $output == *'Installing Node.js v22.23.2 locally'* ]]
}
