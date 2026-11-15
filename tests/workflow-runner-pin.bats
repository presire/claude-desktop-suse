#!/usr/bin/env bats

WORKFLOWS="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.github/workflows" && pwd)"

@test "workflow runners use ubuntu-24.04 rather than floating images" {
	local lines
	lines=$(grep -hE '^[[:space:]]*runs-on:' "$WORKFLOWS"/*.yml)
	[[ -n $lines ]]
	while IFS= read -r line; do
		[[ $line =~ ^[[:space:]]*runs-on:[[:space:]]*ubuntu-24\.04[[:space:]]*$ ]] || return 1
	done <<< "$lines"
}

@test "remote workflow actions use immutable commit SHAs" {
	local lines value
	lines=$(grep -hE '^[[:space:]]*(-[[:space:]]*)?uses:' "$WORKFLOWS"/*.yml)
	[[ -n $lines ]]
	while IFS= read -r line; do
		value=${line#*uses:}
		value=${value%%#*}
		value=${value//[[:space:]]/}
		[[ $value == ./* || $value =~ ^[^@]+@[0-9a-f]{40}$ ]] || return 1
	done <<< "$lines"
}
