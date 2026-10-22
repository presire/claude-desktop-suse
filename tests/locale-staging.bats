#!/usr/bin/env bats
#
# locale-staging.bats
# The Windows nupkg ships both region-qualified (ja-JP.json) and
# region-less (ru.json, da.json, ...) locale files. Both staging sites
# must copy all of them: scripts/staging/locales.sh (Electron resources)
# and scripts/patches/app-asar.sh (app.asar resources/i18n).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	claude_extract_dir="$TEST_TMP/extract"
	electron_resources_dest="$TEST_TMP/dest"
	app_staging_dir="$TEST_TMP/staging"
	mkdir -p "$claude_extract_dir/lib/net45/resources" \
		"$electron_resources_dest" "$app_staging_dir"

	local name
	for name in en-US ja-JP zh-Hans am da ru fil; do
		printf '{"locale":"%s"}\n' "$name" \
			> "$claude_extract_dir/lib/net45/resources/$name.json"
	done

	# shellcheck source=scripts/staging/locales.sh
	source "$SCRIPT_DIR/../scripts/staging/locales.sh"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "copy_locale_files: copies region-less locales as well" {
	run copy_locale_files
	[[ $status -eq 0 ]]

	local name
	for name in en-US ja-JP zh-Hans am da ru fil; do
		[[ -f $electron_resources_dest/$name.json ]] || {
			echo "missing $name.json"
			return 1
		}
	done
}

@test "copy_locale_files: staged count matches the nupkg source count" {
	run copy_locale_files
	[[ $status -eq 0 ]]

	local -a src dst
	src=("$claude_extract_dir/lib/net45/resources/"*.json)
	dst=("$electron_resources_dest/"*.json)
	[[ ${#src[@]} -eq ${#dst[@]} ]]
}

@test "app-asar.sh: i18n copy does not use the region-only *-*.json glob" {
	local asar_script="$SCRIPT_DIR/../scripts/patches/app-asar.sh"
	run grep -nE 'resources/"?\*-\*\.json' "$asar_script"
	[[ $status -ne 0 ]]
	run grep -nE 'lib/net45/resources/"\*\.json app\.asar\.contents/resources/i18n/' \
		"$asar_script"
	[[ $status -eq 0 ]]
}
