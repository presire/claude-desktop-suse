#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Batsはテストごとにサブシェルで実行する
#
# @file config-write-merge.bats
# @brief patch_config_write_mergeがclaude_desktop_config.jsonの書き込み直前にガードを差し込む様子を確認する
#
# パッチは、書き込み前のガードを周囲のminify済みJavaScriptを壊さずに挿入する
# 上流の形は2種類ある
# 従来の独立した書き込み処理と、外側のtryの直下にあるreturn await Wr(...)の形である
# 後者は1.44121.4以降の戻り値形式で、書き込みはその式の中で起きる
#
# ガードは、これから書く設定にmcpServersのキーが無い場合(読み込みに失敗した場合)に限り、
# ディスク上のmcpServersを復元する
# 設定画面で削除したサーバーが復活してはいけない
# 挙動のテストは、パッチ適用済みの書き込み処理を通して実際の書き込みを動かす
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

@test "config merge: latest return-shaped writer remains valid JavaScript" {
	printf '%s' \
		'function cg(e){return I3e.runExclusive((async()=>{let t=ng();try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}))}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	grep -qF 'try{try{if(e.mcpServers==null){var _cdd_dc=' "$main_js"
	grep -qF '}catch(_cdd_ex){};return await Wr(t,e)' "$main_js"
	node --check "$main_js"
}

@test "config merge: spaced return-shaped writer with a dollar-sign logger stays valid JavaScript" {
	printf '%s' \
		'async function cg(e){let t=ng();try { return await Wr(t, e), N$.info("Config file written"), "written" } catch (x) { return "failed" }}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	grep -qF 'try {try{if(e.mcpServers==null)' "$main_js"
	node --check "$main_js"
}

@test "config merge: legacy standalone writer is patched before the write" {
	printf '%s' \
		'function old(){try{return x()}catch{}}async function cg(){let t=ng(),e={};await Wr(t,e),N.info("Config file written");return e}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	grep -qF '}catch(_cdd_ex){};await Wr(t,e)' "$main_js"
	node --check "$main_js"
}

@test "config merge: the merge block is inserted exactly once" {
	printf '%s' \
		'function cg(e){return I3e.runExclusive((async()=>{let t=ng();try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}))}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	[[ $(grep -cF 'var _cdd_dc=' "$main_js") -eq 1 ]]
}

@test "config merge: patching twice is byte-idempotent" {
	printf '%s' \
		'function cg(e){return I3e.runExclusive((async()=>{let t=ng();try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}))}' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_config_write_merge >/dev/null
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "config merge: zero anchors leaves the bundle byte-identical" {
	printf '%s' \
		'function noref(){return 1}' \
		> "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_config_write_merge
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "config merge: multiple anchors fails closed without corrupting the bundle" {
	printf '%s' \
		'function a(){try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}function b(){try{return await Wr(t,e),N.info("Config file written"),"written"}catch(e){return"failed"}}' \
		> "$main_js"
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_config_write_merge
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
	[[ $status -ne 0 ]]
}

# 戻り値形式の書き込み処理を、パッチを当てた状態で実行できるようにする
# 次のヘルパーはアプリの挙動を模す
# 起動時にファイルを一度だけ読み込んで設定オブジェクトを作り、アプリはそのオブジェクトを書き換え続ける
# write(cfg)は実際の書き込みを一度だけ行い、成功ならwritten、失敗ならfailedを返す
# failNextWrite()は次の書き込みをディスク容量不足のように失敗させる
# onDisk()は保存済みのサーバー一覧を返し、キーが無ければmissingを返す
#
# @brief 実行可能な書き込み処理と、アプリを模したヘルパーを用意する
# @global main_js パッチ対象のバンドル (この関数が書き込み処理を書き込む)
# @global TEST_TMP 一時ディレクトリ (harness.jsをここに置く)
# @note WRITER_JS、CONFIG_JSON、HARNESS_JSをexportする (nodeの子プロセスから参照できるようにするため)
#
_setup_writer() {
	printf '%s' \
		'const fs=require("fs"),N={info(){}};async function Wr(t,e){if(globalThis.__failNextWrite){globalThis.__failNextWrite=!1;throw new Error("ENOSPC")}fs.writeFileSync(t,JSON.stringify(e))}async function cg(t,e){try{return await Wr(t,e),N.info("Config file written"),"written"}catch(x){return"failed"}}module.exports=cg;' \
		> "$main_js"
	patch_config_write_merge >/dev/null
	cat > "$TEST_TMP/harness.js" << 'HARNESS'
const fs = require('fs');
const p = process.env.CONFIG_JSON;
const cg = require(process.env.WRITER_JS);
const servers = (names) =>
	Object.fromEntries(names.map((n) => [n, { command: n }]));
exports.disk = (names) =>
	fs.writeFileSync(p, JSON.stringify({ mcpServers: servers(names) }));
exports.launch = () => JSON.parse(fs.readFileSync(p, 'utf8'));
exports.write = (cfg) => cg(p, cfg);
exports.failNextWrite = () => {
	globalThis.__failNextWrite = true;
};
exports.onDisk = () => {
	const m = JSON.parse(fs.readFileSync(p, 'utf8')).mcpServers;
	return m === undefined ? 'missing' : Object.keys(m).join(',');
};
HARNESS
	export WRITER_JS="$main_js"
	export CONFIG_JSON="$TEST_TMP/claude_desktop_config.json"
	export HARNESS_JS="$TEST_TMP/harness.js"
}

@test "config merge: server deleted in Settings stays deleted across later writes" {
	_setup_writer
	run node -e '
const h = require(process.env.HARNESS_JS);
(async () => {
	h.disk(["context7", "fetch"]);
	const cfg = h.launch();
	const r = [await h.write(cfg)];
	delete cfg.mcpServers.context7;
	r.push(await h.write(cfg), await h.write(cfg));
	console.log(r.join(",") + "|" + h.onDisk());
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'written,written,written|fetch' ]]
}

@test "config merge: deleting the last server writes an empty mcpServers" {
	_setup_writer
	run node -e '
const h = require(process.env.HARNESS_JS);
(async () => {
	h.disk(["context7"]);
	const cfg = h.launch();
	delete cfg.mcpServers.context7;
	const r = await h.write(cfg);
	console.log(r + "|[" + h.onDisk() + "]");
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'written|[]' ]]
}

@test "config merge: deletion retried after a failed write stays deleted" {
	_setup_writer
	run node -e '
const h = require(process.env.HARNESS_JS);
(async () => {
	h.disk(["context7", "fetch"]);
	const cfg = h.launch();
	delete cfg.mcpServers.context7;
	h.failNextWrite();
	const r = [await h.write(cfg), h.onDisk()];
	r.push(await h.write(cfg), h.onDisk());
	console.log(r.join("|"));
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'failed|context7,fetch|written|fetch' ]]
}

@test "config merge: a config loaded without mcpServers keeps the servers on disk" {
	_setup_writer
	# 読み込みに失敗すると、実際に使われている設定オブジェクトにはmcpServersが残らない
	# 復元はそのオブジェクトに対して行われるため、後から削除しても消えたままになる
	run node -e '
const h = require(process.env.HARNESS_JS);
(async () => {
	h.disk(["context7", "fetch"]);
	const cfg = { preferences: {} };
	const r = [await h.write(cfg), h.onDisk()];
	delete cfg.mcpServers.context7;
	r.push(await h.write(cfg), h.onDisk());
	console.log(r.join("|"));
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'written|context7,fetch|written|fetch' ]]
}
