#!/usr/bin/env bats
#
# @file cowork-resources-staging.bats
# @brief scripts/staging/cowork-resources.shのテスト
#
# 配置されたcowork-plugin-shim.shの改行がLFになっていることを確認する
# 上流のWindows向け.exeから何が展開されても、その影響を受けない
# (issue #499)
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

#
# @brief スクリプトが期待するステージング用のディレクトリ構成を一時領域に作る
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global claude_extract_dir 展開済みパッケージを模したディレクトリ (本関数で設定する)
# @global electron_resources_dest リソースの配置先を模したディレクトリ (本関数で設定する)
# @global architecture 対象のアーキテクチャ (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# スクリプトが前提とするステージング構成を再現する
	claude_extract_dir="$TEST_TMP/extract"
	electron_resources_dest="$TEST_TMP/dest"
	architecture='x64'
	mkdir -p "$claude_extract_dir/lib/net45/resources" \
		"$electron_resources_dest"

	# shellcheck source=scripts/_common.sh
	source "$SCRIPT_DIR/../scripts/_common.sh"
	# shellcheck source=scripts/staging/cowork-resources.sh
	source "$SCRIPT_DIR/../scripts/staging/cowork-resources.sh"
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

#
# @brief 上流の展開先に、指定した改行形式のshimを作る
# @param $1 改行形式 (crlfならCRLF、それ以外はLF)
# @global claude_extract_dir shimを書き込む展開先ディレクトリ (参照のみ)
#
# 中身はbashとして最小限の有効なスクリプトにする
write_shim_src() {
	local style="$1"
	local shim="$claude_extract_dir/lib/net45/resources/cowork-plugin-shim.sh"
	printf '#!/bin/bash\n# Cowork plugin shim.\ncowork_require_token() {\n\treturn 0\n}\n' \
		> "$shim"
	if [[ $style == 'crlf' ]]; then
		sed -i 's/$/\r/' "$shim"
	fi
}

# CRLFの正規化 (issue #499)

@test "copy_cowork_resources: strips CRLF from Windows-encoded shim" {
	write_shim_src crlf

	# ステージングを実行する前に、元のファイルが本当にCRLFであることを確認する
	run grep -c $'\r$' \
		"$claude_extract_dir/lib/net45/resources/cowork-plugin-shim.sh"
	[[ "$status" -eq 0 ]]
	[[ "$output" -gt 0 ]]

	run copy_cowork_resources
	[[ "$status" -eq 0 ]]

	local dest="$electron_resources_dest/cowork-plugin-shim.sh"
	[[ -f "$dest" ]]

	# 配置した複製にキャリッジリターンが1つも残っていないこと
	run grep -c $'\r' "$dest"
	[[ "$status" -eq 1 ]]
}

@test "copy_cowork_resources: staged shim is executable and bash-parsable" {
	write_shim_src crlf

	run copy_cowork_resources
	[[ "$status" -eq 0 ]]

	local dest="$electron_resources_dest/cowork-plugin-shim.sh"
	[[ -x "$dest" ]]

	# CRLFが残っているとbash -nは $'\r': command not found で失敗していた
	run bash -n "$dest"
	[[ "$status" -eq 0 ]]
}

@test "copy_cowork_resources: LF-only shim passes through unchanged" {
	write_shim_src lf

	local src="$claude_extract_dir/lib/net45/resources/cowork-plugin-shim.sh"
	local src_sum _
	read -r src_sum _ < <(sha256sum "$src")

	run copy_cowork_resources
	[[ "$status" -eq 0 ]]

	local dest="$electron_resources_dest/cowork-plugin-shim.sh"
	local dest_sum
	read -r dest_sum _ < <(sha256sum "$dest")
	[[ "$src_sum" == "$dest_sum" ]]
}

@test "copy_cowork_resources: missing shim emits warning without failing" {
	run copy_cowork_resources
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'cowork-plugin-shim.sh not found'* ]]
}

# ブラウザ連携用のshim (Claude 3.x)

@test "copy_cowork_resources: stages claude-browser-shim.js when shipped" {
	printf '// shim\n' \
		> "$claude_extract_dir/lib/net45/resources/claude-browser-shim.js"

	run copy_cowork_resources
	[[ "$status" -eq 0 ]]
	[[ -f "$electron_resources_dest/claude-browser-shim.js" ]]
}

@test "copy_cowork_resources: missing claude-browser-shim.js is not an error" {
	run copy_cowork_resources
	[[ "$status" -eq 0 ]]
	[[ ! -e "$electron_resources_dest/claude-browser-shim.js" ]]
}

# ion-distのウェブページ (3.xはディレクトリ、4.xはion-dist.asar)

@test "copy_cowork_resources: stages 4.x ion-dist.asar as a regular file" {
	printf 'asar-bytes' > "$claude_extract_dir/lib/net45/resources/ion-dist.asar"

	run copy_cowork_resources
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'Copied ion-dist.asar'* ]]
	[[ -f "$electron_resources_dest/ion-dist.asar" && ! -L "$electron_resources_dest/ion-dist.asar" ]]
	cmp -s "$claude_extract_dir/lib/net45/resources/ion-dist.asar" \
		"$electron_resources_dest/ion-dist.asar"
}

@test "copy_cowork_resources: stages 3.x ion-dist directory" {
	mkdir -p "$claude_extract_dir/lib/net45/resources/ion-dist"
	printf '<html>' > "$claude_extract_dir/lib/net45/resources/ion-dist/index.html"

	run copy_cowork_resources
	[[ "$status" -eq 0 ]]
	[[ -f "$electron_resources_dest/ion-dist/index.html" ]]
}

@test "copy_cowork_resources: missing ion-dist warns without failing" {
	run copy_cowork_resources
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'ion-dist not found'* ]]
}
