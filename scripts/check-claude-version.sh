#!/usr/bin/env bash
#
# @file check-claude-version.sh
# @brief 固定バージョンと上流の最新リリースを比べて差分を報告する
#
# 固定バージョン(以下pin)は、SUSE向けビルドが入力に使うnupkgの版で、
# scripts/setup/detect-host.shの[CLAUDE_PINNED_VERSION]に手動で記録する
# 本スクリプトはpinが古くなっていないかを調べるだけで、pinは書き換えない
# SHA-256の値も手動更新のままとする (docs/DECISIONS.md D-005)
#
# 比較に使うのはアーキテクチャ別のRELEASESフィード
#   https://downloads.claude.ai/releases/win32/{x64,arm64}/RELEASES
# で、scripts/setup/detect-host.shのresolve_latest_url()と同じ配布元を使う
# フィードはUTF-8のBOMを付けて配信されるため、BOMとCRを取り除いてから
# 最新のnupkgバージョンを取り出し、pinと比べる
#
# 使い方 : check-claude-version.sh
# 終了コード :
#   0  = pinが最新 (またはpinがフィードより新しい)
#   10 = フィードにpinより新しいリリースがある
#   1  = 取得、読み込み、解析のいずれかでエラー
#
# 標準出力は機械的に読み取れるkey=value形式で、次の項目を1行ずつ出す
#   pinned=2.42304.2
#   latest_x64=3.6556.1
#   latest_arm64=3.6556.1
#   latest=3.6556.1
#   arch_match=true
#   status=up-to-date|newer-available|pin-ahead
# [status]の値は、最新ならup-to-date、新しい版があればnewer-available、
# pinが先行していればpin-aheadを返す
#
# テスト用に次の環境変数で入力を差し替えられる (すべて任意)
#   [CCV_DETECT_HOST_FILE]    pinを読み取るdetect-host.shのパス
#   [CCV_RELEASES_X64_FILE]   x64のフィード取得の代わりに読むローカルRELEASES
#   [CCV_RELEASES_ARM64_FILE] arm64のフィード取得の代わりに読むローカルRELEASES
#   [CCV_RELEASES_BASE_URL]   フィードの取得元のベースURL
#

#
# @brief エラーメッセージを標準エラーに出力して異常終了する
# @param $* エラーメッセージ
# @stderr 受け取ったエラーメッセージ
# @note 呼び出し元には戻らず、終了コード1でスクリプトを終える
#
fail() {
	echo "Error: $*" >&2
	exit 1
}

#
# @brief 指定したアーキテクチャのRELEASESフィードのURLを組み立てる
# @param $1 フィードのパス要素 (x64 または arm64)
# @stdout フィードのURL
# @note 取得元は環境変数[CCV_RELEASES_BASE_URL]で差し替えられる
#
releases_url() {
	printf '%s/%s/RELEASES' \
		"${CCV_RELEASES_BASE_URL:-https://downloads.claude.ai/releases/win32}" "$1"
}

#
# @brief RELEASESファイルからUTF-8のBOMとCRを取り除いて別ファイルに保存する
# @param $1 読み込み元のRELEASESファイル
# @param $2 取り除いた結果を書き出すファイル
# @note 上流のフィードは先頭にBOM (EF BB BF) が付き、改行はCR付きのことがある
#       行頭に固定した正規表現で版を取り出すとき、これらが残ると一致しない
#
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

#
# @brief RELEASESの内容から最新のnupkgバージョンを取り出す
# @param $1 対象アーキテクチャのRELEASESファイル
# @stdout 最新のバージョン番号
# @return 0 = 取得成功、1 = AnthropicClaude-*-full.nupkgの記載がない
# @note 版の比較はsort -Vで行い、数値の並びとして新しい方を選ぶ
#
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

#
# @brief RELEASESの内容をローカルファイルから複製するか、フィードから取得して配置する
# @param $1 フィードのパス要素 (x64 または arm64)
# @param $2 ローカルのRELEASESファイル (空ならフィードから取得する)
# @param $3 内容を書き出す先のファイル
# @global CCV_RELEASES_BASE_URL (参照のみ)
# @stderr エラー時のメッセージ
# @return 0 = 配置成功 (失敗時はfailで終了する)
# @note 取得にはcurlを優先して使い、なければwgetを使う
#       どちらも入っていない場合はエラーにして、黙って続行しない
#
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

#
# @brief pinと最新リリースを比較し、結果をkey=value形式で出力する
# @global CCV_DETECT_HOST_FILE、CCV_RELEASES_X64_FILE、CCV_RELEASES_ARM64_FILE (参照のみ)
# @stdout pinned=、latest_x64=、latest_arm64=、latest=、arch_match=、status=
# @stderr 警告とエラーのメッセージ
# @note x64とarm64で最新版が食い違う場合は新しい方を採用し、警告を出す
#       pinがフィードより新しい場合も警告だけ出して成功扱いにする
#       終了コードは比較結果に応じて0または10になる
#
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
	# shellcheck disable=SC2064  # tmp_dirはこの時点の値を展開して埋め込むため、意図して即時展開する
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
