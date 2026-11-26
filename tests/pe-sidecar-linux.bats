#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # JavaScriptは文字列リテラルとして渡す、Batsはテストごとにサブシェルで動く
#
# @file pe-sidecar-linux.bats
# @brief Windows用PEサイドカーがLinuxで実行されないことを確認する
#
# Windowsの.nupkg由来のバンドルには、GitHubの組み込みMCPサーバーとして
# github-mcp-server.exeが、Microsoft 365のbrokerとしてmsal-node-runtime.nodeが
# 同梱されている。どちらもWindowsのPEであり、Linuxでは実行できない。
#
# GitHub側は、パッケージ済みのLinuxで.exeをspawnしようとするため、
# 接続関数の先頭で明示的な未対応エラーを返すパッチを当てる。
# Microsoft 365側は、msal-node-runtime.nodeの読み込みがtry/catchで
# StartupErrorになり、brokerが無効になることを確認する。
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"  # このテストファイルのディレクトリ
COMMON_SH="$SCRIPT_DIR/../scripts/patches/_common.sh"           # パッチ共通の補助関数
APP_ASAR_SH="$SCRIPT_DIR/../scripts/patches/app-asar.sh"        # パッチ段階の実行補助
PE_SH="$SCRIPT_DIR/../scripts/patches/pe-sidecar.sh"            # 検証対象のPEサイドカー向けパッチ
REAL_ROOT="${CLAUDE_DESKTOP_737095_DIR:-/tmp/opencode/probe-7.37095.0/asar_out}"  # 実バンドルのルート

#
# @brief テスト用の一時ディレクトリを用意し、パッチを読み込む
# @global TEST_TMP テスト専用の一時ディレクトリ (本関数で設定する)
# @global main_js パッチ対象のメイン側バンドル (本関数で設定する)
# @global project_root リポジトリのルート (本関数で設定する)
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	mkdir -p "$TEST_TMP/build"
	printf '%s\n' '// main chunk placeholder' > "$TEST_TMP/build/index.chunk-main.js"
	main_js="$TEST_TMP/build/index.chunk-main.js"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/_common.sh
	source "$COMMON_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/app-asar.sh
	source "$APP_ASAR_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/pe-sidecar.sh
	source "$PE_SH"
}

#
# @brief テスト用の一時ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief GitHub組み込みMCPのチャンクに似た最小のファイルを書く
# @global TEST_TMP 書き込み先の一時ディレクトリ (参照のみ)
# @return 0 = 書けた、1 = 書けなかった
#
write_github_fixture() {
	cat > "$TEST_TMP/build/index.chunk-BD.js" << 'FIXTURE'
"use strict";const a=require("electron");let r=require("node:path"),i=require("node:fs");const l="github-mcp-server.exe";let __access=0,__spawn=0;function d(){if(a.app.isPackaged)return r.default.join(process.resourcesPath,"app.asar.unpacked","resources","github-mcp",l);return process.env.CLAUDE_DESKTOP_GITHUB_MCP_BINARY||r.default.join(a.app.getAppPath(),"resources","github-mcp",l)}async function m(e,l){let v=d();try{await i.default.promises.access(v)}catch{}__access+=1;__spawn+=1;return"SPAWNED"}exports.connectGithubBuiltinMcp=m;
FIXTURE
}

@test "guards the GitHub sidecar before it is spawned" {
	write_github_fixture
	run patch_pe_sidecar_linux_guard
	[[ $status -eq 0 ]]
	[[ $output == *'refuses the Windows .exe on Linux'* ]]
	grep -qF 'process.env["CLAUDE_DESKTOP_GITHUB_MCP_BINARY"]' "$TEST_TMP/build/index.chunk-BD.js"
	grep -qF 'cannot run on Linux' "$TEST_TMP/build/index.chunk-BD.js"
}

@test "second run keeps the GitHub chunk byte-identical" {
	write_github_fixture
	patch_pe_sidecar_linux_guard > /dev/null
	cp "$TEST_TMP/build/index.chunk-BD.js" "$TEST_TMP/once.js"
	run patch_pe_sidecar_linux_guard
	[[ $status -eq 0 ]]
	[[ $output == *'already present'* ]]
	cmp "$TEST_TMP/build/index.chunk-BD.js" "$TEST_TMP/once.js"
}

@test "a missing connectGithubBuiltinMcp export fails closed" {
	write_github_fixture
	sed -i 's/exports\.connectGithubBuiltinMcp=m;/exports.other=m;/' "$TEST_TMP/build/index.chunk-BD.js"
	cp "$TEST_TMP/build/index.chunk-BD.js" "$TEST_TMP/before.js"
	run patch_pe_sidecar_linux_guard
	[[ $status -ne 0 ]]
	[[ $output == *'connectGithubBuiltinMcp'* ]]
	cmp "$TEST_TMP/build/index.chunk-BD.js" "$TEST_TMP/before.js"
}

@test "a bundle without the GitHub sidecar is a reviewed no-op" {
	patch_pe_sidecar_linux_guard > /dev/null
	[[ $patch_noop_declared == '1' ]]
}

@test "runtime: packaged and bare unpackaged Linux throw before access or spawn, env override still runs" {
	write_github_fixture
	patch_pe_sidecar_linux_guard > /dev/null
	run env FIXTURE="$TEST_TMP/build/index.chunk-BD.js" node << 'RUNTIME'
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.env.FIXTURE, 'utf8');

function extract(name) {
    let start = src.indexOf('function ' + name + '(');
    if (start < 0) {
        throw new Error('missing function ' + name);
    }
    if (src.slice(Math.max(0, start - 6), start) === 'async ') {
        start -= 6;
    }
    let depth = 0;
    let i = src.indexOf('{', start);
    for (; i < src.length; i += 1) {
        if (src[i] === '{') {
            depth += 1;
        } else if (src[i] === '}') {
            depth -= 1;
            if (depth === 0) {
                i += 1;
                break;
            }
        }
    }
    return src.slice(start, i);
}

async function run(packaged, env) {
    const sandbox = {
        process: { platform: 'linux', env: env || {} },
        __dirname: '/app/resources/app.asar/.vite/build',
        require: () => ({ app: { isPackaged: packaged, getAppPath: () => '/app' } }),
        d: () => '/app/resources/github-mcp/github-mcp-server.exe',
        i: { default: { promises: { access: async () => undefined } } },
        __access: 0,
        __spawn: 0
    };
    sandbox.global = sandbox;
    const code = '(async () => {' + extract('m') + ';' +
        'try { return { spawned: await m({}, "token") }; }' +
        'catch (error) { return { message: error.message }; }' +
        '})()';
    const result = await vm.runInNewContext(code, sandbox);
    result.access = sandbox.__access;
    result.spawn = sandbox.__spawn;
    return result;
}

(async () => {
    const blocked = await run(true);
    const unpackagedBlocked = await run(false);
    const allowed = await run(false, { CLAUDE_DESKTOP_GITHUB_MCP_BINARY: '/usr/bin/linux-mcp' });
    console.log(JSON.stringify({ blocked, unpackagedBlocked, allowed }));
})().catch((error) => { console.error(error.message); process.exit(1); });
RUNTIME
	[[ $status -eq 0 ]]
	[[ $output == *'"blocked":{"message":"[github-mcp] the bundled GitHub MCP server is a Windows executable and cannot run on Linux'* ]]
	[[ $output == *'"unpackagedBlocked":{"message":"[github-mcp] the bundled GitHub MCP server is a Windows executable and cannot run on Linux'* ]]
	[[ $output == *'"access":0,"spawn":0'* ]]
	[[ $output == *'"allowed":{"spawned":"SPAWNED","access":1,"spawn":1}'* ]]
}

@test "real 7.37095.0 GitHub sidecar is guarded" {
	local real_chunk="$REAL_ROOT/.vite/build/index.chunk-BD-0Fu1D.js"
	if [[ ! -f $real_chunk ]]; then
		skip "7.37095.0 GitHub chunk is not available at $real_chunk"
	fi
	cp "$real_chunk" "$TEST_TMP/build/index.chunk-BD.js"
	run patch_pe_sidecar_linux_guard
	[[ $status -eq 0 ]]
	grep -qF 'cannot run on Linux' "$TEST_TMP/build/index.chunk-BD.js"
	grep -qF 'CLAUDE_DESKTOP_GITHUB_MCP_BINARY' "$TEST_TMP/build/index.chunk-BD.js"
}

@test "real 7.37095.0 Microsoft 365 runtime degrades to StartupError on Linux" {
	local worker="$REAL_ROOT/.vite/build/msal-broker-worker/msalBrokerWorker.js"
	if [[ ! -f $worker ]]; then
		skip "7.37095.0 msal broker worker is not available at $worker"
	fi
	run env WORKER="$worker" node << 'RUNTIME'
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { createRequire } = require('module');
const worker = fs.readFileSync(process.env.WORKER, 'utf8');
const at = worker.indexOf('"office365-mcp","msal-node-runtime.node"');
if (at < 0) {
    throw new Error('runtime loader anchor missing');
}
let start = worker.lastIndexOf('function a(', at);
if (start < 0) {
    throw new Error('loader function missing');
}
let depth = 0;
let i = worker.indexOf('{', start);
for (; i < worker.length; i += 1) {
    if (worker[i] === '{') {
        depth += 1;
    } else if (worker[i] === '}') {
        depth -= 1;
        if (depth === 0) {
            i += 1;
            break;
        }
    }
}
const fn = worker.slice(start, i);
const sandbox = {
    __dirname: path.dirname(process.env.WORKER),
    n: path.join,
    r: createRequire,
    i: undefined,
    console
};
sandbox.global = sandbox;
const result = vm.runInNewContext('(' + fn + ')()', sandbox);
if (!result || !result.StartupError) {
    throw new Error('expected StartupError, got ' + JSON.stringify(Object.keys(result || {})));
}
console.log('StartupError:' + (result.StartupError.code || result.StartupError.name));
RUNTIME
	[[ $status -eq 0 ]]
	[[ $output == StartupError:* ]]
}

@test "real 7.37095.0 msal-node-runtime.node cannot load on Linux" {
	local runtime="$REAL_ROOT/resources/office365-mcp/msal-node-runtime.node"
	if [[ ! -f $runtime ]]; then
		skip "7.37095.0 msal runtime is not available at $runtime"
	fi
	run env RUNTIME="$runtime" node << 'RUNTIME'
try {
    require(process.env.RUNTIME);
    console.log('LOADED');
} catch (error) {
    console.log('REFUSED:' + (error.code || error.name));
}
RUNTIME
	[[ $status -eq 0 ]]
	[[ $output == REFUSED:* ]]
}

@test "real 7.37095.0 Microsoft 365 fallback and broker gate are present" {
	local mjs="$REAL_ROOT/resources/office365-mcp/office365-mcp-stdio.mjs"
	local main_chunk
	local worker_chunk
	main_chunk=$(grep -lF 'isBrokerAvailable' "$REAL_ROOT"/.vite/build/index.chunk-*.js 2>/dev/null | head -n 1)
	worker_chunk=$(grep -lF 'fileName:"msalBrokerWorker.js"' "$REAL_ROOT"/.vite/build/index.chunk-*.js 2>/dev/null | head -n 1)
	if [[ ! -f $mjs || -z $main_chunk || -z $worker_chunk ]]; then
		skip "7.37095.0 Microsoft 365 files are not available"
	fi
	grep -qF 'try{wc.msalNodeRuntime=$("./msal-node-runtime.node")}catch{wc.msalNodeRuntime=new scs}' "$mjs"
	grep -qF 'isBrokerAvailable' "$main_chunk"
	grep -qF 'fileName:"msalBrokerWorker.js"' "$worker_chunk"
}
