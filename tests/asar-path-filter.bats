#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Batsはテストごとにサブシェルで動くため、環境変数の変更は意図したもの
#
# @file asar-path-filter.bats
# @brief patch_asar_path_filterがapp.asar配下のパスを拒否する様子を確認する
#
# ワークスペースのフォルダが展開済みのツリーを指すよう、
# app.asarの中にあるパスはディレクトリとして扱わない
# 上流には2種類の形があり、1つは従来の同期版ディレクトリ判定、
# もう1つは1.44121.4で追加された共有の非同期stat処理である
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"          # このテストファイルがあるディレクトリ
COWORK_SH="$SCRIPT_DIR/../scripts/patches/cowork.sh"                   # 検証対象のcowork向けパッチ

#
# @brief テスト用の一時ディレクトリとパッチ対象のindex.jsを用意し、cowork.shを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global main_js パッチ対象のメインプロセス側バンドル (本関数で設定する)
# @global project_root リポジトリのルート (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/cowork.sh
	source "$COWORK_SH"
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

@test "asar path filter: patches legacy synchronous directory helper" {
	printf '%s' \
		'function wFA(e){try{return ee.statSync(e).isDirectory()}catch{return!1}}' \
		> "$main_js"
	patch_asar_path_filter >/dev/null
	grep -qF \
		'function wFA(e){try{return!e.endsWith(".asar")&&ee.statSync(e).isDirectory()' \
		"$main_js"
}

@test "asar path filter: patches latest shared async stat helper" {
	printf '%s' \
		'async function r8(e){try{return await(0,y.stat)(e)}catch{return null}}' \
		> "$main_js"
	patch_asar_path_filter >/dev/null
	grep -qF \
		'async function r8(e){if(e.endsWith(".asar"))return null;try{return await(0,y.stat)(e)}catch{return null}}' \
		"$main_js"
}

@test "asar path filter: legacy helper patch is idempotent" {
	printf '%s' \
		'function wFA(e){try{return ee.statSync(e).isDirectory()}catch{return!1}}' \
		> "$main_js"
	patch_asar_path_filter >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_asar_path_filter >/dev/null
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "asar path filter: latest helper patch is idempotent" {
	printf '%s' \
		'async function r8(e){try{return await(0,y.stat)(e)}catch{return null}}' \
		> "$main_js"
	patch_asar_path_filter >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_asar_path_filter >/dev/null
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "asar path filter: unknown shape fails fast without corrupting the bundle" {
	printf '%s' \
		'function totallyDifferent(e){return e}' \
		> "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_asar_path_filter
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
	[[ $status -ne 0 ]]
}
