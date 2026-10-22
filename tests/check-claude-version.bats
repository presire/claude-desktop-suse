#!/usr/bin/env bats
#
# check-claude-version.bats
# Offline coverage for scripts/check-claude-version.sh: RELEASES parsing
# (with and without a UTF-8 BOM), the pin comparison, and error paths.
# Every dependency comes from a fixture; the repository's real
# CLAUDE_PINNED_VERSION is never consulted.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-claude-version.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	PIN_FILE="$TEST_TMP/detect-host.sh"
	printf "CLAUDE_PINNED_VERSION='2.42304.2'\n" > "$PIN_FILE"

	X64_FILE="$TEST_TMP/RELEASES-x64"
	ARM64_FILE="$TEST_TMP/RELEASES-arm64"

	# Upstream RELEASES files start with a UTF-8 BOM (EF BB BF).
	printf '\xEF\xBB\xBF%s %s %s' \
		'8C3E85877244773341132BAD6E0DB4035524BA67' \
		'AnthropicClaude-3.6556.1-full.nupkg' \
		'250490503' > "$X64_FILE"
	printf '\xEF\xBB\xBF%s %s %s' \
		'771B2A790896B0865B9D1918D210A549FC5DA1D5' \
		'AnthropicClaude-3.6556.1-full.nupkg' \
		'244773984' > "$ARM64_FILE"
}

teardown() {
	rm -rf "$TEST_TMP"
}

# Run the parser with every input pointed at the fixtures.
run_check() {
	export CCV_DETECT_HOST_FILE="$PIN_FILE"
	export CCV_RELEASES_X64_FILE="$X64_FILE"
	export CCV_RELEASES_ARM64_FILE="$ARM64_FILE"
	run "$CHECK_SCRIPT"
}

@test "fixtures reproduce the upstream UTF-8 BOM byte sequence" {
	local bom_hex

	bom_hex=$(head -c 3 "$X64_FILE" | od -An -tx1 | tr -d ' \n')
	[[ $bom_hex == 'efbbbf' ]]
	bom_hex=$(head -c 3 "$ARM64_FILE" | od -An -tx1 | tr -d ' \n')
	[[ $bom_hex == 'efbbbf' ]]
}

@test "up to date: pin equals the newest BOM-prefixed release" {
	printf "CLAUDE_PINNED_VERSION='3.6556.1'\n" > "$PIN_FILE"

	run_check
	[[ $status -eq 0 ]]
	[[ $output == *'pinned=3.6556.1'* ]]
	[[ $output == *'latest=3.6556.1'* ]]
	[[ $output == *'latest_x64=3.6556.1'* ]]
	[[ $output == *'latest_arm64=3.6556.1'* ]]
	[[ $output == *'arch_match=true'* ]]
	[[ $output == *'status=up-to-date'* ]]
}

@test "newer available: exits 10 and reports the newest release" {
	run_check
	[[ $status -eq 10 ]]
	[[ $output == *'pinned=2.42304.2'* ]]
	[[ $output == *'latest=3.6556.1'* ]]
	[[ $output == *'arch_match=true'* ]]
	[[ $output == *'status=newer-available'* ]]
}

@test "newer available: parses a RELEASES file without a BOM" {
	printf '%s %s %s' \
		'8C3E85877244773341132BAD6E0DB4035524BA67' \
		'AnthropicClaude-3.6556.1-full.nupkg' \
		'250490503' > "$X64_FILE"
	printf '%s %s %s' \
		'771B2A790896B0865B9D1918D210A549FC5DA1D5' \
		'AnthropicClaude-3.6556.1-full.nupkg' \
		'244773984' > "$ARM64_FILE"

	run_check
	[[ $status -eq 10 ]]
	[[ $output == *'latest=3.6556.1'* ]]
	[[ $output == *'status=newer-available'* ]]
}

@test "newer available: picks the highest entry from multiple releases" {
	printf '%s\n%s\n%s\n' \
		'AAAA1111 AnthropicClaude-3.6000.0-full.nupkg 100' \
		'BBBB2222 AnthropicClaude-3.6556.10-full.nupkg 200' \
		'CCCC3333 AnthropicClaude-3.6556.2-full.nupkg 150' > "$X64_FILE"
	cp "$X64_FILE" "$ARM64_FILE"

	run_check
	[[ $status -eq 10 ]]
	[[ $output == *'latest=3.6556.10'* ]]
}

@test "malformed RELEASES: exits non-zero and prints no status" {
	printf '%s\n' 'this is not a RELEASES file' > "$X64_FILE"

	run_check
	[[ $status -ne 0 ]]
	[[ $status -ne 10 ]]
	[[ $output == *'Error:'* ]]
	[[ $output == *'x64 RELEASES file'* ]]
	[[ $output != *'status='* ]]
}

@test "missing pin declaration: exits non-zero" {
	printf '%s\n' '# no pin here' > "$PIN_FILE"

	run_check
	[[ $status -ne 0 ]]
	[[ $status -ne 10 ]]
	[[ $output == *'CLAUDE_PINNED_VERSION'* ]]
}

@test "pin ahead of the feed: exits 0 with status=pin-ahead" {
	printf "CLAUDE_PINNED_VERSION='9.9.9'\n" > "$PIN_FILE"

	run_check
	[[ $status -eq 0 ]]
	[[ $output == *'status=pin-ahead'* ]]
}

@test "unreadable RELEASES override: exits non-zero" {
	export CCV_DETECT_HOST_FILE="$PIN_FILE"
	export CCV_RELEASES_X64_FILE="$TEST_TMP/does-not-exist"
	export CCV_RELEASES_ARM64_FILE="$ARM64_FILE"

	run "$CHECK_SCRIPT"
	[[ $status -ne 0 ]]
	[[ $status -ne 10 ]]
	[[ $output == *'not readable'* ]]
}
