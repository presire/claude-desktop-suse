#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Batsはテストごとにサブシェルで動かすため
#
# @file fetch-electron-binary.bats
# @brief fetch-electron-binary.jsがElectronの展開に使うパッケージのテスト
#
# node_modules/electron/dist/を埋めるのは、Electron側が保守する
# 強化済みの展開処理(@electron-internal/extract-zip、ESM専用)である
# 保守が止まったextract-zipは使わない
# こちらには未修正のシンボリックリンク経由の脆弱性が2件ある
# (GHSA-jmr9-qjv8-65gv と GHSA-7pqw-9j4j-h8q3)
#
# 通しのテストは実際のスクリプトを動かし、@electron/getだけをスタブに差し替える
# そのためネットワークへは接続しない
# ビルド用の作業ディレクトリもキャッシュ済みのElectronのzipも無い場合はSKIPする

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルがあるディレクトリ
SCRIPT="$SCRIPT_DIR/../scripts/setup/fetch-electron-binary.js"         # 検証対象の取得スクリプト
DEPS_SH="$SCRIPT_DIR/../scripts/setup/dependencies.sh"  # 依存関係の導入スクリプト

#
# @brief テスト用の一時ディレクトリを用意し、Node.js側からも参照できるよう環境変数へ出す
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
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
# @brief @electron/getの代替スタブを置く
# @global TEST_TMP スタブを作る一時ディレクトリ (参照のみ)
#
# downloadArtifactは環境変数STUB_ELECTRON_ZIPの値を返すだけなので、
# 取得スクリプトはネットワークを使わずに動く
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

#
# @brief ESM専用の@electron/getと展開用パッケージのスタブを置く
# @global TEST_TMP スタブを作る一時ディレクトリ (参照のみ)
#
# 形は@electron/get 5.xに合わせる
# ローダーが完全にオフラインで動くことを確かめるためのもの
write_esm_stubs() {
	local get_dir="$TEST_TMP/work/node_modules/@electron/get"
	local ext_dir="$TEST_TMP/work/node_modules/@electron-internal/extract-zip"
	mkdir -p "$get_dir" "$ext_dir"
	printf '%s\n' \
		'{"name":"@electron/get","version":"5.1.0","type":"module",' \
		' "main":"index.js","exports":{".":"./index.js"}}' \
		> "$get_dir/package.json"
	printf '%s\n' \
		'export async function downloadArtifact() {' \
		'	return process.env.STUB_ELECTRON_ZIP;' \
		'}' \
		> "$get_dir/index.js"
	printf '%s\n' \
		'{"name":"@electron-internal/extract-zip","version":"1.0.5",' \
		' "type":"module","main":"index.js","exports":{".":"./index.js"}}' \
		> "$ext_dir/package.json"
	printf '%s\n' \
		"import { writeFileSync } from 'node:fs';" \
		"import { join } from 'node:path';" \
		'export async function extract(zip, { dir }) {' \
		"	writeFileSync(join(dir, 'electron'), zip);" \
		'}' \
		> "$ext_dir/index.js"
}

#
# @brief ESMをrequire()できるNodeで、その機能を切るためのフラグを出力する
# @stdout 該当するフラグ (このNodeが知らない場合は何も出力しない)
#
# Node 22.12以降はESMをrequire()できるため、
# ビルドに使うNode 20が出すERR_REQUIRE_ESMを隠してしまう
# どの環境でも同じように失敗させるためにフラグを出す
node_esm_require_off() {
	if node --no-experimental-require-module -e '' 2> /dev/null; then
		printf '%s\n' '--no-experimental-require-module'
	fi
}

#
# @brief electronパッケージと@electron/getのスタブだけを持つ最小の作業ディレクトリを作る
# @global TEST_TMP 作業ディレクトリを作る一時ディレクトリ (参照のみ)
#
# 展開用のパッケージは入れない
# 必要とするテストが自分で追加する
make_work_dir() {
	mkdir -p "$TEST_TMP/work/node_modules/electron"
	printf '{"name":"claude-desktop-build","version":"0.0.1","private":true}\n' \
		> "$TEST_TMP/work/package.json"
	printf '{"name":"electron","version":"41.10.7"}\n' \
		> "$TEST_TMP/work/node_modules/electron/package.json"
	write_electron_get_stub
}

#
# @brief 強化済みの展開用パッケージがあるnode_modulesを出力する
# @stdout 見つかったnode_modulesのパス
# @return 0 = 見つかった場合, 1 = 見つからなかった場合
#
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

@test "fetch-electron-binary: loads an ESM-only @electron/get" {
	make_work_dir
	write_esm_stubs
	local -a node_args=()
	mapfile -t node_args < <(node_esm_require_off)

	run bash -c 'cd "$1" && shift && STUB_ELECTRON_ZIP=stub.zip exec node "$@"' \
		_ "$TEST_TMP/work" "${node_args[@]}" "$SCRIPT"

	if [[ $status -ne 0 ]]; then
		echo "$output"
		return 1
	fi
	[[ $output != *'ERR_REQUIRE_ESM'* ]]
	local electron_bin="$TEST_TMP/work/node_modules/electron/dist/electron"
	[[ -x $electron_bin ]]
	[[ $(< "$electron_bin") == 'stub.zip' ]]
}

@test "fetch-electron-binary: fails fast when @electron/get is missing" {
	make_work_dir
	mv "$TEST_TMP/work/node_modules/@electron/get" "$TEST_TMP/electron-get.off"
	run bash -c 'cd "$1" && exec node "$2"' _ "$TEST_TMP/work" "$SCRIPT"
	[[ $status -ne 0 ]]
	[[ $output == *'Could not resolve @electron/get'* ]]
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

@test "fetch-electron-binary: ELECTRON_TARGET_ARCH overrides the host arch" {
	run node -e '
		const { resolveTargetArch } = require(process.argv[1]);
		console.log([
			resolveTargetArch({ ELECTRON_TARGET_ARCH: "arm64" }, "x64"),
			resolveTargetArch({ ELECTRON_TARGET_ARCH: "" }, "x64"),
			resolveTargetArch({}, "arm"),
		].join(" "));
	' "$SCRIPT"
	[[ $status -eq 0 ]]
	[[ $output == 'arm64 x64 armv7l' ]]
}

@test "fetch-electron-binary: an unsupported ELECTRON_TARGET_ARCH fails" {
	run node -e '
		require(process.argv[1]).resolveTargetArch({ ELECTRON_TARGET_ARCH: "riscv64" }, "x64");
	' "$SCRIPT"
	[[ $status -ne 0 ]]
	[[ $output == *'Unsupported architecture: riscv64'* ]]
}

@test "dependencies.sh: passes the package arch to the fetch script" {
	# shellcheck disable=SC2016 # スクリプトの元の文字列をそのまま扱い、ここでは展開しない
	run grep -nE 'ELECTRON_TARGET_ARCH="\$electron_arch"' "$DEPS_SH"
	[[ $status -eq 0 ]]
}
