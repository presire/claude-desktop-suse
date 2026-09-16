#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells
#
# fetch-electron-binary.bats
#
# fetch-electron-binary.js must populate node_modules/electron/dist/ with the
# Electron-maintained hardened extractor (@electron-internal/extract-zip,
# ESM-only) instead of the unmaintained extract-zip package, which carries
# two unfixed symlink-traversal advisories (GHSA-jmr9-qjv8-65gv and
# GHSA-7pqw-9j4j-h8q3).
#
# The end-to-end test drives the real script with a stubbed @electron/get so
# no network access is required, and is skipped until the build work dir (or
# a cached Electron zip) exists.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/setup/fetch-electron-binary.js"
DEPS_SH="$SCRIPT_DIR/../scripts/setup/dependencies.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# write_electron_get_stub: a @electron/get replacement whose downloadArtifact
# simply echoes $STUB_ELECTRON_ZIP, so the fetch script can run offline.
write_electron_get_stub() {
	local stub_dir="$TEST_TMP/work/node_modules/@electron/get"
	mkdir -p "$stub_dir"
	printf '{"name":"@electron/get","version":"5.1.0","main":"index.js"}\n' \
		> "$stub_dir/package.json"
	printf '%s\n' \
		"'use strict';" \
		"module.exports = { downloadArtifact: async () => process.env.STUB_ELECTRON_ZIP };" \
		> "$stub_dir/index.js"
}

# make_work_dir: minimal work_dir layout with an electron package and the
# @electron/get stub, but no extractor (tests add that when they need it).
make_work_dir() {
	mkdir -p "$TEST_TMP/work/node_modules/electron"
	printf '{"name":"claude-desktop-build","version":"0.0.1","private":true}\n' \
		> "$TEST_TMP/work/package.json"
	printf '{"name":"electron","version":"41.10.7"}\n' \
		> "$TEST_TMP/work/node_modules/electron/package.json"
	write_electron_get_stub
}

# extractor_root: prints the node_modules dir holding the hardened extractor.
extractor_root() {
	local candidate
	for candidate in \
		"$SCRIPT_DIR/../build/node_modules" \
		"$SCRIPT_DIR/../node_modules"; do
		if [[ -d "$candidate/@electron-internal/extract-zip" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

@test "fetch-electron-binary: passes node --check" {
	run node --check "$SCRIPT"
	[[ $status -eq 0 ]]
}

@test "dependencies.sh: requests the exactly pinned hardened extractor" {
	grep -qE '^[[:space:]]*if ! npm install --no-save' "$DEPS_SH"
	grep -qF "'@electron-internal/extract-zip@1.0.5'" "$DEPS_SH"
	run grep -qF '@electron/asar extract-zip' "$DEPS_SH"
	[[ $status -ne 0 ]]
}

@test "fetch-electron-binary: resolves the extractor via dynamic import" {
	grep -qF '@electron-internal/extract-zip' "$SCRIPT"
	grep -qF 'await import(' "$SCRIPT"
	run grep -qF "require('extract-zip')" "$SCRIPT"
	[[ $status -ne 0 ]]
	run grep -qF 'require("extract-zip")' "$SCRIPT"
	[[ $status -ne 0 ]]
}

@test "fetch-electron-binary: fails fast when the extractor is missing" {
	make_work_dir
	run bash -c 'cd "$1" && exec node "$2"' _ "$TEST_TMP/work" "$SCRIPT"
	[[ $status -ne 0 ]]
	[[ $output == *'Could not resolve @electron-internal/extract-zip'* ]]
}

@test "fetch-electron-binary: extracts a distribution offline end-to-end" {
	local extractor
	if ! extractor=$(extractor_root); then
		skip 'hardened extractor not installed; run a build first'
	fi

	local cached_zip
	cached_zip=$(find "$HOME/.cache/electron" \
		-name 'electron-v*-linux-x64.zip' 2>/dev/null | head -1)
	if [[ -z $cached_zip ]]; then
		skip 'no cached Electron zip under ~/.cache/electron'
	fi

	make_work_dir
	local cached_version
	cached_version=$(basename "$cached_zip" | \
		sed -E 's/^electron-v([0-9][0-9.]*)-linux.*/\1/')
	printf '{"name":"electron","version":"%s"}\n' "$cached_version" \
		> "$TEST_TMP/work/node_modules/electron/package.json"

	mkdir -p "$TEST_TMP/work/node_modules/@electron-internal"
	ln -s "$extractor/@electron-internal/extract-zip" \
		"$TEST_TMP/work/node_modules/@electron-internal/extract-zip"

	run bash -c 'cd "$1" && STUB_ELECTRON_ZIP="$2" exec node "$3"' _ \
		"$TEST_TMP/work" "$cached_zip" "$SCRIPT"

	if [[ $status -ne 0 ]]; then
		echo "$output"
		return 1
	fi

	[[ $output == *'Electron binary fetched and extracted successfully.'* ]]
	local dist="$TEST_TMP/work/node_modules/electron/dist"
	[[ -x $dist/electron ]]
	[[ -x $dist/chrome-sandbox ]]
	[[ -f $dist/resources.pak ]]
}
