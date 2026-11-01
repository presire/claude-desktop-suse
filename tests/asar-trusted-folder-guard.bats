#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # JavaScriptは文字列リテラルとして渡す、Batsはテストごとにサブシェルで動く
#
# @file asar-trusted-folder-guard.bats
# @brief patch_asar_trusted_folder_guardがaddTrustedFolderの先頭に.asar判定を差し込む様子を確認する
#
# パッチはaddTrustedFolderのハンドラ先頭に、引数が.asarで終わる場合に何もせず戻る一行を差し込む
# 再適用の判定は、同じ実行の中で先にpatch_asar_path_filterが差し込む非同期stat処理と取り違えてはならない
#
#   非同期stat側 : if(引数.endsWith(".asar"))return null;
#   このパッチ   : if(引数.endsWith(".asar"))return;
#
# 短い判定文字列 endsWith(".asar"))return は両方に一致するため、以前は未適用でも
# "already present (idempotent)" と報告してガードを黙って飛ばしていた
# ここでは両者を区別できることと、上流のアンカーが無い場合に正直にスキップすることを固定する
# 1.44121.4でaddTrustedFolderはIPCルーターの登録処理へ移った
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"          # このテストファイルがあるディレクトリ
CONFIG_SH="$SCRIPT_DIR/../scripts/patches/config.sh"                   # 検証対象のconfig向けパッチ

#
# @brief テスト用の一時ディレクトリとパッチ対象のindex.jsを用意し、config.shを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global main_js パッチ対象のメインプロセス側バンドル (本関数で設定する)
# @global project_root リポジトリのルート (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/config.sh
	source "$CONFIG_SH"
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
# @note setupが途中で失敗してTEST_TMPが未定義でも失敗しないよう、存在を確認してから削除する
#
teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief ファイルの内容からSHA-256を求める
# @param $1 対象のファイル
# @stdout 内容のSHA-256
# @note パッチが何も書き換えていないことを、実行前後の値の比較で確認するために使う
#
sha() {
	sha256sum "$1" | cut -d' ' -f1
}

@test "trusted folder guard: injects the guard for the legacy handler shape" {
	printf '%s' \
		'const o={async addTrustedFolder(folder){await ZOe(folder)}};async function r8(e){try{return await(0,y.stat)(e)}catch{return null}}' \
		> "$main_js"
	patch_asar_trusted_folder_guard >/dev/null
	grep -qF 'addTrustedFolder(folder){if(folder.endsWith(".asar"))return;' \
		"$main_js"
	node --check "$main_js"
}

@test "trusted folder guard: injects the guard when the async stat filter is already applied" {
	printf '%s' \
		'const o={async addTrustedFolder(folder){await ZOe(folder)}};async function r8(e){try{if(e.endsWith(".asar"))return null;return await(0,y.stat)(e)}catch{return null}}' \
		> "$main_js"
	patch_asar_trusted_folder_guard >/dev/null
	grep -qF 'addTrustedFolder(folder){if(folder.endsWith(".asar"))return;' \
		"$main_js"
	[[ $(grep -cF 'if(e.endsWith(".asar"))return null;' "$main_js") -eq 1 ]]
	node --check "$main_js"
}

@test "trusted folder guard: patching twice is byte-idempotent" {
	printf '%s' \
		'const o={async addTrustedFolder(folder){await ZOe(folder)}}' \
		> "$main_js"
	patch_asar_trusted_folder_guard >/dev/null
	local before
	before=$(sha "$main_js")
	run patch_asar_trusted_folder_guard
	[[ $status -eq 0 ]]
	[[ $output == *'already present (idempotent)'* ]]
	[[ $before == "$(sha "$main_js")" ]]
}

@test "trusted folder guard: reports an honest skip when the anchor is absent" {
	printf '%s' \
		'const r=["addTrustedFolder",[["folder",P]]];' \
		> "$main_js"
	local before
	before=$(sha "$main_js")
	run patch_asar_trusted_folder_guard
	[[ $status -eq 0 ]]
	[[ $output == *'trusted-folder guard was NOT applied'* ]]
	[[ $output != *'already present'* ]]
	[[ $before == "$(sha "$main_js")" ]]
}

@test "trusted folder guard: injects the guard into the sibling chunk (2.37337.1 shape)" {
	printf '%s' \
		'const r=["addTrustedFolder",[["folder",F]]];' \
		> "$main_js"
	printf '%s' \
		'async function X(e){return e}const o={async addTrustedFolder(e){t.j6.info(`LocalAgentModeSessions.addTrustedFolder: ${e}`);let n=await Fn(e);if(n===null)return}};' \
		> "$TEST_TMP/index.chunk-DhN98CRk.js"
	patch_asar_trusted_folder_guard >/dev/null
	grep -qF 'addTrustedFolder(e){if(e.endsWith(".asar"))return;' \
		"$TEST_TMP/index.chunk-DhN98CRk.js"
	# メインのチャンクはIPCの登録だけを持つため、書き換えない
	[[ $(sha "$main_js") == "$(printf '%s' 'const r=["addTrustedFolder",[["folder",F]]];' | sha256sum | cut -d' ' -f1)" ]]
	node --check "$TEST_TMP/index.chunk-DhN98CRk.js"
}

@test "trusted folder guard: injects the guard into the sibling chunk (1.44121.4 shape)" {
	printf '%s' \
		'const r=["addTrustedFolder",[["folder",P]]];' \
		> "$main_js"
	printf '%s' \
		'const o={async addTrustedFolder(e){t.JA.info(`LocalAgentModeSessions.addTrustedFolder: ${e}`);let n=await o.m(e);if(n===null)return}};' \
		> "$TEST_TMP/index.chunk-BaCGxvUV.js"
	patch_asar_trusted_folder_guard >/dev/null
	grep -qF 'addTrustedFolder(e){if(e.endsWith(".asar"))return;' \
		"$TEST_TMP/index.chunk-BaCGxvUV.js"
	node --check "$TEST_TMP/index.chunk-BaCGxvUV.js"
}

@test "trusted folder guard: sibling-chunk patching twice is byte-idempotent" {
	printf '%s' \
		'const r=["addTrustedFolder",[["folder",F]]];' \
		> "$main_js"
	printf '%s' \
		'const o={async addTrustedFolder(e){t.j6.info(`x: ${e}`);}};' \
		> "$TEST_TMP/index.chunk-DhN98CRk.js"
	patch_asar_trusted_folder_guard >/dev/null
	local before
	before=$(sha "$TEST_TMP/index.chunk-DhN98CRk.js")
	run patch_asar_trusted_folder_guard
	[[ $status -eq 0 ]]
	[[ $output == *'already present (idempotent)'* ]]
	[[ $before == "$(sha "$TEST_TMP/index.chunk-DhN98CRk.js")" ]]
}

@test "trusted folder guard: reports an honest skip when the anchor is ambiguous" {
	printf '%s' \
		'const o={async addTrustedFolder(a){await x(a)}}' \
		> "$TEST_TMP/index.chunk-AAAA.js"
	printf '%s' \
		'const o={async addTrustedFolder(b){await y(b)}}' \
		> "$TEST_TMP/index.chunk-BBBB.js"
	printf '%s' \
		'stub' \
		> "$main_js"
	run patch_asar_trusted_folder_guard
	[[ $status -eq 0 ]]
	[[ $output == *'trusted-folder guard was NOT applied'* ]]
	[[ $output != *'already present'* ]]
	[[ $(grep -c 'endsWith(".asar")' "$TEST_TMP/index.chunk-AAAA.js") -eq 0 ]]
	[[ $(grep -c 'endsWith(".asar")' "$TEST_TMP/index.chunk-BBBB.js") -eq 0 ]]
}
