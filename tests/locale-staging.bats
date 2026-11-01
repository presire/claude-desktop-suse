#!/usr/bin/env bats
#
# @file locale-staging.bats
# @brief Windowsのnupkgに含まれるロケールファイルの配置のテスト
#
# nupkgには地域付き(ja-JP.json)と地域なし(ru.json、da.jsonなど)の両方のロケールファイルが入っている
# 2か所の配置処理がどちらも全件をコピーしなければならない
# 対象はscripts/staging/locales.sh(Electronのresources)と
# scripts/patches/app-asar.sh(app.asarのresources/i18n)である
#
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルがあるディレクトリ

#
# @brief 配置元と配置先のディレクトリを作り、ロケールファイルを並べておく
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global claude_extract_dir nupkgを展開した先 (地域付きと地域なしのロケールが入る)
# @global electron_resources_dest locales.shの配置先 (本関数で設定する)
# @global app_staging_dir app.asarを組み立てるステージング先 (本関数で設定する)
#
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

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
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
	run grep -nE 'lib/net45/resources/"\*\.json\)' "$asar_script"
	[[ $status -eq 0 ]]
	run grep -nE 'cp "\$\{locale_jsons\[@\]\}" app\.asar\.contents/resources/i18n/' \
		"$asar_script"
	[[ $status -eq 0 ]]
}

@test "copy_locale_files: 4.x layout without loose locale JSON is not an error" {
	command rm -f "$claude_extract_dir/lib/net45/resources/"*.json

	run copy_locale_files
	[[ $status -eq 0 ]]
	[[ $output == *'ships them inside app.asar'* ]]

	local -a dst=("$electron_resources_dest/"*.json)
	[[ ! -e ${dst[0]} ]]
}
