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

# ---------------------------------------------------------------------
# @electron/asar pin (claude-desktop-debian #960)
# ---------------------------------------------------------------------

# Stage a work dir whose Electron 44 is present and whose asar reports
# $1, so setup_electron_asar only has the asar decision left to make.
_stage_asar_work_dir() {
	local asar_version="$1"
	local dist="$work_dir/node_modules/electron/dist"
	mkdir -p "$dist" "$work_dir/node_modules/.bin" \
		"$work_dir/node_modules/@electron/asar"
	printf '#!/bin/sh\n' > "$dist/electron"
	chmod +x "$dist/electron"
	echo '44.9.3' > "$dist/version"
	_write_asar "$asar_version"
}

_write_asar() {
	printf '#!/bin/sh\necho v%s\n' "$1" > "$work_dir/node_modules/.bin/asar"
	chmod +x "$work_dir/node_modules/.bin/asar"
	printf '{"version":"%s"}\n' "$1" \
		> "$work_dir/node_modules/@electron/asar/package.json"
}

@test "asar pin: the pin is an exact version, not a range" {
	[[ $ASAR_PINNED_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "setup_electron_asar: an unpinned asar in a kept work dir is reinstalled at the pin" {
	_stage_asar_work_dir '4.0.0'
	_stub_command npm "printf '%s\n' \"\$*\" > '$BATS_TEST_TMPDIR/npm.args'
printf '#!/bin/sh\necho v$ASAR_PINNED_VERSION\n' > '$work_dir/node_modules/.bin/asar'
printf '{\"version\":\"$ASAR_PINNED_VERSION\"}\n' > '$work_dir/node_modules/@electron/asar/package.json'"

	rc=0
	(setup_electron_asar) >"$out" 2>&1 || rc=$?
	output=$(<"$out")

	[[ $rc -eq 0 ]]
	[[ $output == *"Asar 4.0.0 found"* ]]
	[[ $(<"$BATS_TEST_TMPDIR/npm.args") == *"@electron/asar@$ASAR_PINNED_VERSION"* ]]
	[[ $output == *"(v$ASAR_PINNED_VERSION)"* ]]
}

@test "setup_electron_asar: the pinned asar in a kept work dir is reused" {
	_stage_asar_work_dir "$ASAR_PINNED_VERSION"
	_stub_command npm "touch '$BATS_TEST_TMPDIR/npm.called'"

	rc=0
	(setup_electron_asar) >"$out" 2>&1 || rc=$?

	[[ $rc -eq 0 ]]
	[[ ! -e $BATS_TEST_TMPDIR/npm.called ]]
}

@test "setup_electron_asar: an asar that still reports another version fails the build" {
	_stage_asar_work_dir '4.0.0'
	_stub_command npm 'exit 0'

	rc=0
	(setup_electron_asar) >"$out" 2>&1 || rc=$?
	output=$(<"$out")

	[[ $rc -ne 0 ]]
	[[ $output == *"reports v4.0.0; @electron/asar@$ASAR_PINNED_VERSION is required"* ]]
}

# ---------------------------------------------------------------------
# Electron target arch (--arch arm64 on an x64 host)
# ---------------------------------------------------------------------

# _write_elf_stub PATH MACHINE: an executable whose ELF header carries
# e_machine MACHINE (62 or 183, little-endian at offset 18).
_write_elf_stub() {
	local machine_bytes
	case "$2" in
		62)  machine_bytes='\x3e\x00' ;;
		183) machine_bytes='\xb7\x00' ;;
		*)   return 1 ;;
	esac
	{
		printf '\x7fELF'
		head -c 14 /dev/zero
		printf '%b' "$machine_bytes"
	} > "$1"
	chmod +x "$1"
}

# A fake fetch script under source_dir that records ELECTRON_TARGET_ARCH
# and drops an arm64 Electron into dist/.
_stage_fake_fetch() {
	source_dir="$BATS_TEST_TMPDIR/src"
	mkdir -p "$source_dir/scripts/setup"
	cat > "$source_dir/scripts/setup/fetch-electron-binary.js" <<JS
const fs = require('node:fs');
fs.writeFileSync('$BATS_TEST_TMPDIR/target.arch', process.env.ELECTRON_TARGET_ARCH ?? '<unset>');
fs.mkdirSync('node_modules/electron/dist', { recursive: true });
JS
}

@test "_elf_electron_arch: reads x86-64 and AArch64 from e_machine" {
	_write_elf_stub "$BATS_TEST_TMPDIR/x" 62
	_write_elf_stub "$BATS_TEST_TMPDIR/a" 183
	printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/s"
	[[ $(_elf_electron_arch "$BATS_TEST_TMPDIR/x") == 'x64' ]]
	[[ $(_elf_electron_arch "$BATS_TEST_TMPDIR/a") == 'arm64' ]]
	[[ -z $(_elf_electron_arch "$BATS_TEST_TMPDIR/s") ]]
}

@test "setup_electron_asar: an x64 Electron in a kept work dir is replaced for --arch arm64" {
	_stage_asar_work_dir "$ASAR_PINNED_VERSION"
	_write_elf_stub "$work_dir/node_modules/electron/dist/electron" 62
	_stage_fake_fetch
	_stub_command npm 'exit 0'
	architecture='arm64'

	rc=0
	(setup_electron_asar) >"$out" 2>&1 || rc=$?
	output=$(<"$out")

	[[ $output == *'Electron for x64 found; arm64 is required.'* ]]
	[[ $(<"$BATS_TEST_TMPDIR/target.arch") == 'arm64' ]]
	[[ ! -e $work_dir/node_modules/electron/dist/version ]]
}

@test "setup_electron_asar: a matching-arch Electron is reused" {
	_stage_asar_work_dir "$ASAR_PINNED_VERSION"
	_write_elf_stub "$work_dir/node_modules/electron/dist/electron" 183
	_stage_fake_fetch
	_stub_command npm "touch '$BATS_TEST_TMPDIR/npm.called'"
	architecture='arm64'

	rc=0
	(setup_electron_asar) >"$out" 2>&1 || rc=$?

	[[ $rc -eq 0 ]]
	[[ ! -e $BATS_TEST_TMPDIR/npm.called ]]
	[[ ! -e $BATS_TEST_TMPDIR/target.arch ]]
}
