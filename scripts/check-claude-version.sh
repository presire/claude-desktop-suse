#!/usr/bin/env bash
#===============================================================================
# Compare the newest Claude Desktop Windows release with the SUSE build pin.
#
# Reads the per-arch RELEASES feeds served at
#   https://downloads.claude.ai/releases/win32/{x64,arm64}/RELEASES
# (the same feeds resolve_latest_url() uses in scripts/setup/detect-host.sh),
# strips the UTF-8 BOM the feeds carry, extracts the newest nupkg version,
# and compares it with CLAUDE_PINNED_VERSION from
# scripts/setup/detect-host.sh.
#
# The pin and its SHA-256 values stay manual (docs/DECISIONS.md D-005).
# This script only reports drift; it never edits the pin.
#
# Exit codes:
#   0  pinned version is up to date (or already ahead of the feed)
#   10 a release newer than the pin is available
#   1  any fetch, read, or parse error
#
# Machine-readable stdout (one key=value per line):
#   pinned=2.42304.2
#   latest_x64=3.6556.1
#   latest_arm64=3.6556.1
#   latest=3.6556.1
#   arch_match=true
#   status=up-to-date|newer-available|pin-ahead
#
# Test overrides (all optional):
#   CCV_DETECT_HOST_FILE     file to read CLAUDE_PINNED_VERSION from
#   CCV_RELEASES_X64_FILE    local RELEASES file instead of fetching x64
#   CCV_RELEASES_ARM64_FILE  local RELEASES file instead of fetching arm64
#   CCV_RELEASES_BASE_URL    base URL for the feeds
#===============================================================================

fail() {
	echo "Error: $*" >&2
	exit 1
}

releases_url() {
	printf '%s/%s/RELEASES' \
		"${CCV_RELEASES_BASE_URL:-https://downloads.claude.ai/releases/win32}" "$1"
}

# Copy a RELEASES file without its UTF-8 BOM (EF BB BF) and without CR
# characters. The upstream feeds start with a BOM; a plain grep for a
# leading SHA-1 still works, but a version anchored at the start of the
# line would not.
strip_bom() {
	local source_file="$1"
	local destination="$2"
	local first_bytes

	first_bytes=$(head -c 3 "$source_file" | od -An -tx1 | tr -d ' \n')
	if [[ $first_bytes == 'efbbbf' ]]; then
		tail -c +4 "$source_file" | tr -d '\r' > "$destination"
	else
		tr -d '\r' < "$source_file" > "$destination"
	fi
}

# Print the newest version named by an AnthropicClaude-<ver>-full.nupkg
# entry. Exits 1 when the file names no such entry.
parse_latest_version() {
	local releases_file="$1"
	local versions

	versions=$(grep -oE 'AnthropicClaude-[0-9]+(\.[0-9]+)+-full\.nupkg' \
		"$releases_file" \
		| sed -e 's/^AnthropicClaude-//' -e 's/-full\.nupkg$//')
	if [[ -z $versions ]]; then
		return 1
	fi
	printf '%s\n' "$versions" | sort -V | tail -n 1
}

# Place a raw RELEASES file at $3, either by copying a local override or
# by fetching it from the feed.
acquire_releases() {
	local arch_path="$1"
	local local_file="$2"
	local destination="$3"
	local url

	if [[ -n $local_file ]]; then
		[[ -r $local_file ]] || fail "RELEASES file is not readable: $local_file"
		cp -- "$local_file" "$destination"
		return 0
	fi

	url=$(releases_url "$arch_path")
	if command -v curl > /dev/null 2>&1; then
		curl --fail --silent --show-error --location --max-time 30 \
			--output "$destination" "$url" \
			|| fail "failed to fetch $url"
	elif command -v wget > /dev/null 2>&1; then
		wget --quiet --output-document="$destination" "$url" \
			|| fail "failed to fetch $url"
	else
		fail 'neither curl nor wget is available'
	fi
}

main() {
	local script_dir detect_host_file tmp_dir
	local pinned_version latest_x64 latest_arm64 latest arch_match
	local status exit_code newest

	script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
	detect_host_file="${CCV_DETECT_HOST_FILE:-${script_dir}/setup/detect-host.sh}"
	[[ -r $detect_host_file ]] \
		|| fail "cannot read $detect_host_file"

	pinned_version=$(sed -n \
		"s/^CLAUDE_PINNED_VERSION='\([^']*\)'.*/\1/p" \
		"$detect_host_file" | tail -n 1)
	[[ $pinned_version =~ ^[0-9]+(\.[0-9]+)+$ ]] \
		|| fail "no valid CLAUDE_PINNED_VERSION in $detect_host_file"

	tmp_dir=$(mktemp -d) || fail 'mktemp failed'
	# shellcheck disable=SC2064  # tmp_dir is expanded now on purpose
	trap "rm -rf '$tmp_dir'" EXIT

	acquire_releases x64 "${CCV_RELEASES_X64_FILE:-}" "$tmp_dir/x64.raw"
	acquire_releases arm64 "${CCV_RELEASES_ARM64_FILE:-}" "$tmp_dir/arm64.raw"

	strip_bom "$tmp_dir/x64.raw" "$tmp_dir/x64"
	strip_bom "$tmp_dir/arm64.raw" "$tmp_dir/arm64"

	latest_x64=$(parse_latest_version "$tmp_dir/x64") \
		|| fail 'no AnthropicClaude-*-full.nupkg entry in the x64 RELEASES file'
	latest_arm64=$(parse_latest_version "$tmp_dir/arm64") \
		|| fail 'no AnthropicClaude-*-full.nupkg entry in the arm64 RELEASES file'

	if [[ $latest_x64 == "$latest_arm64" ]]; then
		latest="$latest_x64"
		arch_match='true'
	else
		latest=$(printf '%s\n%s\n' "$latest_x64" "$latest_arm64" \
			| sort -V | tail -n 1)
		arch_match='false'
		echo "Warning: x64 ($latest_x64) and arm64 ($latest_arm64)" \
			'RELEASES disagree; reporting the newer one.' >&2
	fi

	if [[ $latest == "$pinned_version" ]]; then
		status='up-to-date'
		exit_code=0
	else
		newest=$(printf '%s\n%s\n' "$pinned_version" "$latest" \
			| sort -V | tail -n 1)
		if [[ $newest == "$latest" ]]; then
			status='newer-available'
			exit_code=10
		else
			status='pin-ahead'
			exit_code=0
			echo "Warning: pinned version $pinned_version is newer than" \
				"the RELEASES feed ($latest)." >&2
		fi
	fi

	printf 'pinned=%s\n' "$pinned_version"
	printf 'latest_x64=%s\n' "$latest_x64"
	printf 'latest_arm64=%s\n' "$latest_arm64"
	printf 'latest=%s\n' "$latest"
	printf 'arch_match=%s\n' "$arch_match"
	printf 'status=%s\n' "$status"

	exit "$exit_code"
}

main "$@"
