#!/usr/bin/env bats
# shellcheck disable=SC2317,SC2329 # wgetのスタブは読み込んだsetup側スクリプトから呼ばれる(shellcheck 0.10未満ではSC2317)
#
# @file claude-version-pin.bats
# @brief 既定のClaude固定バージョン(D-005)の解決とハッシュ検証を確認する
#
# --claude-version も --claude-sha256 も指定しない場合、
# resolve_latest_urlは検証済みのバージョンとアーキテクチャごとのSHA-256を採用する
# download_claude_installerは、そこで決まったハッシュを実際のダウンロードに適用する
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../scripts" && pwd)"  # 対象スクリプトがあるディレクトリ

#
# @brief 検証に使う状態を用意し、対象スクリプトとwgetのスタブを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global architecture 対象アーキテクチャ (amd64から始める)
# @global local_exe_path --exe で指定された実行ファイルのパス (本関数で設定する)
# @global claude_version_override --claude-version の指定値 (既定は空)
# @global claude_sha256_override --claude-sha256 の指定値 (既定は空)
# @global claude_nupkg_sha256 解決したnupkgのSHA-256 (未解決なら空)
# @global claude_nupkg_sha1 RELEASESから読んだSHA-1 (未読なら空)
# @global releases_fixture RELEASESの代わりに返す固定データのパス (本関数で設定する)
# @global releases_fail trueにするとRELEASESの取得が失敗する (本関数で設定する)
# @global wget_log スタブが受け取った引数の記録先 (本関数で設定する)
# @note wgetはネットワークを使わず、RELEASESの取得と直接ダウンロードの両方をスタブで置き換える
#
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
		# 直接ダウンロード
		# wget -O <ファイル> <URL> の形で呼ばれる
		printf 'not the pinned nupkg\n' > "$2"
	}
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
teardown() {
	rm -rf "$TEST_TMP"
}

@test "pin constants are a version and two distinct SHA-256 hashes" {
	[[ $CLAUDE_PINNED_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
	[[ $CLAUDE_PINNED_SHA256_AMD64 =~ ^[0-9a-f]{64}$ ]]
	[[ $CLAUDE_PINNED_SHA256_ARM64 =~ ^[0-9a-f]{64}$ ]]
	[[ $CLAUDE_PINNED_SHA256_AMD64 != "$CLAUDE_PINNED_SHA256_ARM64" ]]
}

@test "CI workflows build exactly the pinned Claude version" {
	# ビルドワークフローのCLAUDE_DESKTOP_VERSIONは固定バージョンと一致しなければならない
	# さらに、そこにあるbuild.shの呼び出しはすべてこの値を渡す必要がある
	# そうしないとCIがRELEASESの最新版に追随してしまう
	local workflows="$SCRIPT_DIR/../.github/workflows" wf pinned calls
	for wf in test-artifacts.yml release.yml; do
		pinned=$(sed -n 's/^  CLAUDE_DESKTOP_VERSION: "\(.*\)"$/\1/p' "$workflows/$wf")
		[[ $pinned == "$CLAUDE_PINNED_VERSION" ]] || {
			echo "$wf pins '$pinned', detect-host.sh pins $CLAUDE_PINNED_VERSION" >&2
			false
		}
		calls=$(grep -c 'bash build.sh --build' "$workflows/$wf")
		(( calls > 0 ))
		# shellcheck disable=SC2016 # ワークフローの文字列をそのまま扱う、ここでは展開しない
		[[ $(grep -A1 'bash build.sh --build' "$workflows/$wf" \
			| grep -c -- '--claude-version "$CLAUDE_DESKTOP_VERSION"') -eq $calls ]]
		run ! grep -q -- '--claude-version latest' "$workflows/$wf"
	done
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
