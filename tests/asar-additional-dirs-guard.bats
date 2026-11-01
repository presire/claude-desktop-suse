#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # 文字列リテラル内の$は展開しない、Batsはテストごとにサブシェルで動く
#
# @file asar-additional-dirs-guard.bats
# @brief patch_asar_additional_dirs_guardが.asar配下のパスを除外する様子を確認する
#
# このパッチは、--add-dirのコマンドライン組み立てと、
# セッション復元時のフォルダ一覧から.asar配下のパスを取り除く (#649)
# .asarはアーカイブであり、中のパスをワークスペースとして渡しても解決できないため
#
# 上流はこれまでに送出側3種類、復元側2種類の形を出している
#
#   送出側 : for(let t of e)w.push("--add-dir",t)        (1.44121.4まで)
#            e.forEach(t=>w.push("--add-dir",t))
#            for(let t of e)w.push(Y7("--add-dir",t))    (2.37337.1)
#   復元側 : (o.userSelectedFolders||[]).map(...)         (1.44121.4まで)
#            d=u?[]:l.userSelectedFolders??[];...          (2.37337.1)
#            削除済みのフォルダをセッションから取り除く処理が続く
#
# どの形でもパッチは一度だけ当たり、再実行では何も変わらないこと、
# 送出箇所が見つからない場合や候補が曖昧な場合は何も書かずに失敗することを確認する
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"          # このテストファイルがあるディレクトリ
CONFIG_SH="$SCRIPT_DIR/../scripts/patches/config.sh"                   # 検証対象のconfig向けパッチ

#
# @brief テスト用の一時ディレクトリとパッチ対象のindex.jsを用意し、config.shを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global main_js パッチ対象のメインプロセス側バンドル (本関数で設定する)
# @global project_root リポジトリのルート (本関数で設定する)
# @note index.jsは実体を持たせず、パッチ対象の処理はindex.chunk-*.js側に置く
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	printf '%s' 'require("./index.chunk-Main0001.js");' > "$main_js"
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
# @brief 指定した名前のチャンクファイルにJavaScriptの断片を書き込む
# @param $1 チャンク名 (index.chunk-<チャンク名>.js になる)
# @param $2 書き込むJavaScriptの断片
# @global TEST_TMP チャンクファイルを置く一時ディレクトリ (参照のみ)
#
chunk() {
	printf '%s' "$2" > "$TEST_TMP/index.chunk-$1.js"
}

#
# @brief すべてのチャンクファイルを連結した内容のSHA-256を求める
# @global TEST_TMP チャンクファイルを置く一時ディレクトリ (参照のみ)
# @stdout 連結内容のSHA-256
# @note パッチが何も書き換えていないことを、実行前後の値の比較で確認するために使う
#
sha_all() {
	cat "$TEST_TMP"/index.chunk-*.js | sha256sum | cut -d' ' -f1
}

# 1.44121.4までの復元処理
# userSelectedFoldersから削除済みフォルダを除く形
LEGACY_RESTORE='async function r(o){let p=(await Promise.all((o.userSelectedFolders||[]).map((async e=>await a(e)?(j.info(`Filtering out deleted folder from session ${o.sessionId}: ${e}`),null):e)))).filter(Boolean);return p}'
# 2.37337.1の復元処理
# 削除済みフォルダの除去に加えて、戻り値の配列が増えている
CURRENT_RESTORE='async function r(c,t){let n=ll(c)&&h.n(c.userSelectedFolders??[]),w=new Set(c.userSelectedFolders??[]);let l=Fh(c,t.tG),u=l.sessionType===t.HK,d=u?[]:l.userSelectedFolders??[];t.Qn(d.length);let p=(await Promise.all(d.map((async e=>await a(e)?(t.j6.info(`Filtering out deleted folder from session ${l.sessionId}: ${e}`),null):e)))).filter(Boolean);return[n,w,p]}'

@test "add-dir guard: legacy for-of dispatch and legacy restore are filtered" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--add-dir",t);return w}'
	chunk Rest0001 "$LEGACY_RESTORE"

	run patch_asar_additional_dirs_guard
	[[ $status -eq 0 ]]
	[[ $output == *'Filtered --add-dir dispatch in index.chunk-Main0001.js'* ]]
	[[ $output == *'Injected .asar filter in session restore in index.chunk-Rest0001.js'* ]]
	grep -qF 'for(let t of e.filter(_d=>!_d.endsWith(".asar")))w.push("--add-dir",t)' \
		"$TEST_TMP/index.chunk-Main0001.js"
	grep -qF '(o.userSelectedFolders||[]).filter(_d=>!_d.endsWith(".asar")).map(' \
		"$TEST_TMP/index.chunk-Rest0001.js"
	node --check "$TEST_TMP/index.chunk-Main0001.js"
	node --check "$TEST_TMP/index.chunk-Rest0001.js"
}

@test "add-dir guard: forEach dispatch is filtered" {
	chunk Main0001 'function b(e,w){e.forEach(t=>w.push("--add-dir",t));return w}'

	run patch_asar_additional_dirs_guard
	[[ $status -eq 0 ]]
	grep -qF 'e.filter(_d=>!_d.endsWith(".asar")).forEach(t=>w.push("--add-dir",t))' \
		"$TEST_TMP/index.chunk-Main0001.js"
	[[ $output == *'WARNING: session restore anchor not found'* ]]
}

@test "add-dir guard: 2.37337.1 joiner dispatch and ?? restore are filtered" {
	chunk Main0001 'function Y7(e,t){return`${e}=${t}`}function b(e,w){for(let t of e)w.push(Y7("--add-dir",t));return w}'
	chunk Rest0001 "$CURRENT_RESTORE"

	run patch_asar_additional_dirs_guard
	[[ $status -eq 0 ]]
	grep -qF 'for(let t of e.filter(_d=>!_d.endsWith(".asar")))w.push(Y7("--add-dir",t))' \
		"$TEST_TMP/index.chunk-Main0001.js"
	grep -qF 'd=u?[]:(l.userSelectedFolders??[]).filter(_d=>!_d.endsWith(".asar"));t.Qn(' \
		"$TEST_TMP/index.chunk-Rest0001.js"
	# 復元処理の前半にある無関係な読み出しは書き換えない
	grep -qF 'h.n(c.userSelectedFolders??[]),w=new Set(c.userSelectedFolders??[])' \
		"$TEST_TMP/index.chunk-Rest0001.js"
	node --check "$TEST_TMP/index.chunk-Main0001.js"
	node --check "$TEST_TMP/index.chunk-Rest0001.js"
}

@test "add-dir guard: patched output reruns as a no-op for every shape" {
	local dispatch
	for dispatch in \
		'function b(e,w){for(let t of e)w.push("--add-dir",t)}' \
		'function b(e,w){e.forEach(t=>w.push("--add-dir",t))}' \
		'function b(e,w){for(let t of e)w.push(Y7("--add-dir",t))}'; do
		chunk Main0001 "$dispatch"
		chunk Rest0001 "$CURRENT_RESTORE"
		patch_asar_additional_dirs_guard > /dev/null
		local before
		before=$(sha_all)

		run patch_asar_additional_dirs_guard
		[[ $status -eq 0 ]]
		[[ $output == *'.asar --add-dir filter already present (idempotent)'* ]]
		[[ $output == *'Session restore filter already present (idempotent)'* ]]
		[[ $(sha_all) == "$before" ]]
	done
}

@test "add-dir guard: legacy restore reruns as a no-op" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--add-dir",t)}'
	chunk Rest0001 "$LEGACY_RESTORE"
	patch_asar_additional_dirs_guard > /dev/null
	local before
	before=$(sha_all)

	run patch_asar_additional_dirs_guard
	[[ $status -eq 0 ]]
	[[ $output == *'Session restore filter already present (idempotent)'* ]]
	[[ $(sha_all) == "$before" ]]
}

@test "add-dir guard: missing dispatch fails closed" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--other",t)}'

	run patch_asar_additional_dirs_guard
	[[ $status -ne 0 ]]
	[[ $output == *'FATAL: --add-dir dispatch loop not found.'* ]]
}

@test "add-dir guard: two dispatch sites fail closed without writing" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--add-dir",t)}'
	chunk Main0002 'function c(e,w){for(let t of e)w.push(Y7("--add-dir",t))}'
	local before
	before=$(sha_all)

	run patch_asar_additional_dirs_guard
	[[ $status -ne 0 ]]
	[[ $output == *'FATAL: --add-dir dispatch has ambiguous candidates.'* ]]
	[[ $(sha_all) == "$before" ]]
}

@test "add-dir guard: unknown userSelectedFolders shape fails closed" {
	chunk Main0001 'function b(e,w){for(let t of e)w.push("--add-dir",t)}'
	chunk Rest0001 'function r(l){let d=l.userSelectedFolders;return d}'

	run patch_asar_additional_dirs_guard
	[[ $status -ne 0 ]]
	[[ $output == *'FATAL: userSelectedFolders shape is unsupported.'* ]]
}
