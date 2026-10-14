#!/usr/bin/env bats
# shellcheck disable=SC2317,SC2329  # the wget stub is called by the sourced setup scripts (SC2317 on shellcheck < 0.10)
#
# claude-version-pin.bats
# Default Claude release pin (D-005): resolve_latest_url() picks the
# verified version and its per-arch SHA-256 unless --claude-version or
# --claude-sha256 says otherwise, and download_claude_installer() enforces
# the resulting hash.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# shellcheck source=scripts/_common.sh
	source "$SCRIPT_DIR/_common.sh"
	# shellcheck source=scripts/setup/detect-host.sh
	source "$SCRIPT_DIR/setup/detect-host.sh"
	# shellcheck source=scripts/setup/download.sh
	source "$SCRIPT_DIR/setup/download.sh"

	architecture='amd64'
	local_exe_path=''
	claude_version_override=''
	claude_sha256_override=''
	claude_nupkg_sha256=''
	claude_nupkg_sha1=''
	releases_fixture="$TEST_TMP/RELEASES"
	printf '%s\n' \
		'AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111 AnthropicClaude-9.1.0-full.nupkg 100' \
		> "$releases_fixture"
	releases_fail=false
	wget_log="$TEST_TMP/wget.log"

	wget() {
		printf '%s\n' "$*" >> "$wget_log"
		if [[ $1 == '-qO-' ]]; then
			[[ $releases_fail == true ]] && return 4
			cat "$releases_fixture"
			return 0
		fi
		# Direct download: wget -O <file> <url>
		printf 'not the pinned nupkg\n' > "$2"
	}
}

teardown() {
	rm -rf "$TEST_TMP"
}

@test "pin constants are a version and two distinct SHA-256 hashes" {
	[[ $CLAUDE_PINNED_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
	[[ $CLAUDE_PINNED_SHA256_AMD64 =~ ^[0-9a-f]{64}$ ]]
	[[ $CLAUDE_PINNED_SHA256_ARM64 =~ ^[0-9a-f]{64}$ ]]
	[[ $CLAUDE_PINNED_SHA256_AMD64 != "$CLAUDE_PINNED_SHA256_ARM64" ]]
}

@test "default build fetches the pinned version with the amd64 SHA-256" {
	resolve_latest_url > /dev/null 2>&1
	[[ $claude_nupkg_filename == "AnthropicClaude-${CLAUDE_PINNED_VERSION}-full.nupkg" ]]
	[[ $claude_nupkg_url == "https://downloads.claude.ai/releases/win32/x64/$claude_nupkg_filename" ]]
	[[ $claude_nupkg_sha256 == "$CLAUDE_PINNED_SHA256_AMD64" ]]
}

@test "default arm64 build uses the arm64 feed, the -full name and the arm64 hash" {
	architecture='arm64'
	resolve_latest_url > /dev/null 2>&1
	[[ $claude_nupkg_url == "https://downloads.claude.ai/releases/win32/arm64/AnthropicClaude-${CLAUDE_PINNED_VERSION}-full.nupkg" ]]
	[[ $claude_nupkg_sha256 == "$CLAUDE_PINNED_SHA256_ARM64" ]]
}

@test "explicit --claude-version equal to the pin keeps the pinned hash" {
	claude_version_override="$CLAUDE_PINNED_VERSION"
	resolve_latest_url > /dev/null 2>&1
	[[ $claude_nupkg_sha256 == "$CLAUDE_PINNED_SHA256_AMD64" ]]
}

@test "--claude-sha256 replaces the pinned hash" {
	claude_sha256_override="$(printf 'b%.0s' {1..64})"
	resolve_latest_url > /dev/null 2>&1
	[[ $claude_nupkg_sha256 == "$claude_sha256_override" ]]
}

@test "other version without a checksum warns and carries no SHA-256" {
	claude_version_override='1.2.3'
	run resolve_latest_url
	[[ $status -eq 0 ]]
	[[ $output == *'Using pinned Claude version: 1.2.3'* ]]
	[[ $output == *'download will not be checksum-verified'* ]]
	[[ $output != *'Expected SHA-256'* ]]
}

@test "latest takes the newest RELEASES entry with its SHA-1 and no pinned hash" {
	claude_version_override='latest'
	resolve_latest_url > /dev/null 2>&1
	[[ $claude_nupkg_filename == 'AnthropicClaude-9.1.0-full.nupkg' ]]
	[[ $claude_nupkg_sha1 == 'AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111' ]]
	[[ -z $claude_nupkg_sha256 ]]
}

@test "RELEASES outage keeps the pinned default but fails latest" {
	releases_fail=true
	run resolve_latest_url
	[[ $status -eq 0 ]]
	[[ $output == *"Expected SHA-256: $CLAUDE_PINNED_SHA256_AMD64"* ]]
	[[ $output != *'will not be checksum-verified'* ]]

	claude_version_override='latest'
	run resolve_latest_url
	[[ $status -eq 1 ]]
	[[ $output == *'Failed to fetch RELEASES'* ]]
}

@test "--exe uses only an explicit --claude-sha256, never the pin" {
	local_exe_path="$TEST_TMP/Claude-Setup.exe"
	resolve_latest_url > /dev/null 2>&1
	[[ -z $claude_nupkg_sha256 ]]

	claude_sha256_override="$(printf 'c%.0s' {1..64})"
	resolve_latest_url > /dev/null 2>&1
	[[ $claude_nupkg_sha256 == "$claude_sha256_override" ]]
}

@test "download aborts when the nupkg does not match the pinned SHA-256" {
	resolve_latest_url > /dev/null 2>&1
	work_dir="$TEST_TMP/build"
	project_root="$TEST_TMP"
	mkdir -p "$work_dir"
	claude_nupkg_sha1=''

	run download_claude_installer
	[[ $status -eq 1 ]]
	[[ $output == *'SHA-256 mismatch for Claude nupkg'* ]]
	[[ $output != *'Detected Claude version'* ]]
}

@test "parse_arguments accepts latest and rejects other words" {
	cd "$TEST_TMP"
	cleanup_action='yes'
	distro_family='suse'
	run parse_arguments --claude-version latest
	[[ $status -eq 0 ]]

	run parse_arguments --claude-version newest
	[[ $status -eq 1 ]]
	[[ $output == *"or 'latest'"* ]]
}
