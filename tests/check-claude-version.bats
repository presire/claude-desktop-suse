#!/usr/bin/env bats
#
# @file check-claude-version.bats
# @brief scripts/check-claude-version.shをネットワークを使わずに検証する
#
# RELEASESの解析(UTF-8のBOMがある場合と無い場合)、固定バージョンとの比較、異常系を対象にする
# 依存はすべてテスト用の固定データから供給し、リポジトリ側の実際のCLAUDE_PINNED_VERSIONは参照しない
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"  # 検証対象のスクリプトがあるディレクトリ
CHECK_SCRIPT="$SCRIPT_DIR/check-claude-version.sh"                        # 検証対象のバージョン検査スクリプト

#
# @brief 固定バージョンとアーキテクチャ別のRELEASESをテスト用の一時ディレクトリに用意する
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global PIN_FILE 固定バージョンを宣言したファイル (本関数で設定する)
# @global X64_FILE x64向けRELEASESの代わりに使うファイル (本関数で設定する)
# @global ARM64_FILE arm64向けRELEASESの代わりに使うファイル (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	PIN_FILE="$TEST_TMP/detect-host.sh"
	printf "CLAUDE_PINNED_VERSION='2.42304.2'\n" > "$PIN_FILE"

	X64_FILE="$TEST_TMP/RELEASES-x64"
	ARM64_FILE="$TEST_TMP/RELEASES-arm64"

	# 上流のRELEASESファイルは先頭にUTF-8のBOM(EF BB BF)を持つ
	printf '\xEF\xBB\xBF%s %s %s' \
		'8C3E85877244773341132BAD6E0DB4035524BA67' \
		'AnthropicClaude-3.6556.1-full.nupkg' \
		'250490503' > "$X64_FILE"
	printf '\xEF\xBB\xBF%s %s %s' \
		'771B2A790896B0865B9D1918D210A549FC5DA1D5' \
		'AnthropicClaude-3.6556.1-full.nupkg' \
		'244773984' > "$ARM64_FILE"
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
teardown() {
	rm -rf "$TEST_TMP"
}

# 入力をすべてテスト用の固定データへ向けてから解析処理を実行する
#
# @brief 入力を固定データへ向け直した状態で検査スクリプトを実行する
# @global PIN_FILE 固定バージョンを宣言したファイル (参照のみ)
# @global X64_FILE x64向けRELEASESの代わりに使うファイル (参照のみ)
# @global ARM64_FILE arm64向けRELEASESの代わりに使うファイル (参照のみ)
# @note 内部でrunを使うため、呼び出し側のoutputとstatusに結果が入る
#
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
