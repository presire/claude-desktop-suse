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
	# 単体テストでは_common.shを読み込まないため、ビルド時と同じ契約の最小スタブを置く
	if ! declare -F _declare_patch_noop >/dev/null; then
		# shellcheck disable=SC2329 # Invoked indirectly by patch_config_write_merge
		_declare_patch_noop() { patch_noop_declared='1'; }
	fi
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

#
# @brief 7.37095.0の上流el()を模した実行可能な書き込み処理を用意する
# @global main_js パッチ対象のバンドル (この関数が書き込み処理を書き込む)
# @global TEST_TMP 一時ディレクトリ (fixtureと設定ファイルをここに置く)
# @global UPSTREAM_FIXTURE 生成したfixtureのパス (本関数で設定する)
# @global UPSTREAM_CONFIG fixtureが読み書きする設定ファイルのパス (本関数で設定する)
# @note 上流は読み込みが劣化しているとparkedを返し、通常はディスク上のmcpServersを
#       三方向マージしてから書き込む。パッチがこの保護を検出できるよう、実物と同じ
#       文字列 (Refusing config write / mcpServers:Object.fromEntries / Config file written)
#       を含める。マージ意味論は実物のXGe/ZGe/YGeを写したものである。
#
_setup_upstream_writer() {
	UPSTREAM_FIXTURE="$TEST_TMP/upstream-el.js"
	UPSTREAM_CONFIG="$TEST_TMP/claude_desktop_config.json"
	export UPSTREAM_FIXTURE UPSTREAM_CONFIG
	cat > "$UPSTREAM_FIXTURE" << 'FIXTURE'
const fs = require("fs");
const path = process.env.CONFIG_JSON;
let Kc = process.env.DEGRADED === "1";
const LOG = [];
const N = { warn: (m) => LOG.push(m), info: (m) => LOG.push(m) };
const a = { promises: { readFile: (p) => fs.promises.readFile(p, "utf8") } };
const ma = (f) => f();
const ui = (t) => t;
const Hs = (t) => typeof t === "object" && t !== null;
const f = { isDeepStrictEqual: (x, y) => JSON.stringify(x) === JSON.stringify(y) };
const Os = { safeParse: () => ({ data: undefined }) };
class MGe {}
let AGe = new Map(Object.entries(globalThis.__startupServers || {}));
const Jc = { get: () => globalThis.__previousServers && new Map(Object.entries(globalThis.__previousServers)) };
const JGe = { runExclusive: (fn) => fn() };
const Wc = () => path;
const Gc = {};
let qc;
async function xa(n, cfg) { fs.writeFileSync(n, JSON.stringify(cfg)); }
function YGe(e) { return new Map(Object.entries(structuredClone(e.mcpServers ?? {}))); }
async function XGe(e) {
	try {
		let t = ui(await ma(() => a.promises.readFile(e, "utf8")));
		if (!Hs(t)) return null;
		let n = t.mcpServers ?? {};
		return typeof n == "object" ? new Map(Object.entries(n)) : null;
	} catch { return null; }
}
function ZGe(e, t, n) {
	let r = new Map(e);
	for (let i of new Set([...t.keys(), ...n.keys()])) {
		let a = t.get(i);
		f.isDeepStrictEqual(a, n.get(i)) || (n.has(i) ? r.set(i, n.get(i)) : (!(a instanceof MGe) || f.isDeepStrictEqual(a.was, Os.safeParse(e.get(i)).data)) && r.delete(i));
	}
	return r;
}
async function el(e) {
	if (Kc) return N.warn("Refusing config write: the load was degraded (existing file unreadable, unparsable, or not a valid config object) — persisting the in-memory defaults could destroy the original"), Promise.resolve("parked");
	let t = AGe;
	return JGe.runExclusive((async () => {
		let n = Wc(), r = await XGe(n), { preferences: i } = e;
		try {
			let a = YGe(e), o = Jc.get(e);
			let s = r && o ? ZGe(r, o, a) : new Map([...Object.entries(t), ...a]);
			await xa(n, s.size > 0 || e.mcpServers ? { ...e, mcpServers: Object.fromEntries(s) } : e);
			N.info("Config file written"), qc = e !== Gc;
			return "written";
		} catch (e) { return "write-failed"; }
	}));
}
module.exports = { el, LOG };
FIXTURE
	printf 'function el(e){if(Kc)return N.warn("Refusing config write: the load was degraded"),Promise.resolve("parked");let t=AGe;return JGe.runExclusive((async()=>{let n=Wc(),r=await XGe(n);try{let a=YGe(e),o=Jc.get(e),s=r&&o?ZGe(r,o,a):new Map([...Object.entries(t),...a]);await xa(n,s.size>0||e.mcpServers?{...e,mcpServers:Object.fromEntries(s)}:e);N.info("Config file written"),qc=e!==Gc,"written"}catch(e){return"write-failed"}}))}' \
		> "$main_js"
	# 7.37095.0のバンドルには読み込み関数の実体も同梱されている。
	# 検出は呼び出し名だけでなく、解決した本体が実際に readFile を
	# 呼ぶことまで確かめるため、固定データにも実体を置く。
	printf '%s' \
		'async function XGe(e){try{let t=await a.promises.readFile(e,"utf8");return t?new Map(Object.entries(t)):null}catch{return null}}' \
		>> "$main_js"
}

# 注意: ここで確かめるのは、上流の「劣化ロード時の書き込み拒否」と
# 「通常保存時のディスク再読み込みマージ」である。保存直前の再読み込み
# そのものが失敗する競合までは解消しない (それは上流の責務のまま)。
@test "config merge: 7.37095.0 upstream protection is detected and the merge injection is skipped" {
	_setup_upstream_writer
	local before after
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_config_write_merge > "$TEST_TMP/patch.log" 2>&1
	local patch_status=$?
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $patch_status -eq 0 ]]
	grep -qF '[SKIP] Upstream already refuses degraded-load writes' "$TEST_TMP/patch.log"
	[[ $patch_noop_declared == '1' ]]
	[[ $before == "$after" ]]
	if grep -qF '_cdd_dc' "$main_js"; then
		return 1
	fi
}

# Oracle MINOR #5 : 上流の保護は、同じ書き込み関数の中で成立していなければならない
# 劣化ロードの拒否と fromEntries がファイルのどこかにあっても、
# 書き込み関数の中でディスクを読み直していなければ、保護は成立していない
# その状態を no-op と誤認してはいけない
@test "config merge: a writer without the disk reread is not a false no-op" {
	printf '%s' \
		'async function el(e){if(Kc)return N.warn("Refusing config write: the load was degraded"),Promise.resolve("parked");let r=null,s=r;try{return await Wr(t,e),N.info("Config file written"),{mcpServers:Object.fromEntries(s)}}catch(x){return"failed"}}' \
		> "$main_js"
	local before after
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_config_write_merge
	[[ $status -eq 0 ]]
	[[ $output != *'[SKIP] Upstream already refuses'* ]]
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before != "$after" ]]
	grep -qF '_cdd_dc' "$main_js"
	node --check "$main_js"
}

# Oracle round-2 MINOR #4 : 呼び出し名がローダーでも、実体が矢印関数で
# ディスクを読まないなら、上流の再読み込み保護は成立していない
# no-op と誤認して注入を止めてはいけない
@test "config merge: a non-reading arrow loader is not a false no-op" {
	printf '%s' \
		'async function el(e){if(Kc)return N.warn("Refusing config write: the load was degraded"),Promise.resolve("parked");let n=Wc(),r=await XGe(n),s=r;try{return await Wr(n,e),N.info("Config file written"),{mcpServers:Object.fromEntries(s)}}catch(x){return"failed"}}const XGe=async()=>null;' \
		> "$main_js"
	local before after
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_config_write_merge
	[[ $status -eq 0 ]]
	[[ $output != *'[SKIP] Upstream already refuses'* ]]
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before != "$after" ]]
	grep -qF '_cdd_dc' "$main_js"
	node --check "$main_js"
}

@test "config merge: 7.37095.0 degraded load is parked without writing" {
	_setup_upstream_writer
	patch_config_write_merge >/dev/null
	export CONFIG_JSON="$UPSTREAM_CONFIG"
	export DEGRADED=1
	run node -e '
const api = require(process.env.UPSTREAM_FIXTURE);
const fs = require("fs");
(async () => {
	const r = await api.el({ preferences: {} });
	console.log(r + "|" + api.LOG.length + "|" + fs.existsSync(process.env.CONFIG_JSON));
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'parked|1|false' ]]
}

@test "config merge: 7.37095.0 upstream merge keeps an intentionally deleted server deleted" {
	_setup_upstream_writer
	patch_config_write_merge >/dev/null
	export CONFIG_JSON="$UPSTREAM_CONFIG"
	export UPSTREAM_FIXTURE
	export DEGRADED=0
	printf '%s' '{"mcpServers":{"context7":{"command":"context7"},"fetch":{"command":"fetch"}}}' > "$UPSTREAM_CONFIG"
	run node -e '
globalThis.__startupServers = { context7: { command: "context7" }, fetch: { command: "fetch" } };
globalThis.__previousServers = { context7: { command: "context7" }, fetch: { command: "fetch" } };
const api = require(process.env.UPSTREAM_FIXTURE);
const fs = require("fs");
(async () => {
	const cfg = { preferences: {}, mcpServers: { fetch: { command: "fetch" } } };
	const r = await api.el(cfg);
	const disk = JSON.parse(fs.readFileSync(process.env.CONFIG_JSON, "utf8"));
	console.log(r + "|" + Object.keys(disk.mcpServers).join(","));
})();'
	[[ $status -eq 0 ]]
	[[ $output == 'written|fetch' ]]
}
