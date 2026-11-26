#!/usr/bin/env bats
#
# @file cowork-rpc-smoke.bats
# @brief cowork-rpc-smoke.jsの正常終了・隔離・SIGTERM失敗経路を確認する
#
# c8はNODE_V8_COVERAGEを子プロセスへ渡し、プロセスがgracefulにexit(0)
# した時だけV8カバレッジを書き出す。だからスモークはSIGKILLではなく
# SIGTERMでデーモンを止め、SIGKILLに落ちた実行は失敗として扱う。
# ここでは実デーモンの正常系に加えて、その前提を壊す偽デーモン
# (SIGTERMを無視するもの、SIGTERMで非0終了するもの、JSONでない応答を返すもの)と、
# スモーク自身がSIGTERMで止められた場合の後始末を固定する。
# また、スモークがsandboxをTMPDIR配下に作り、実HOMEや実XDGへ
# 触れないことを確認する。
#

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SMOKE="$REPO_ROOT/tools/cowork-rpc-smoke.js"

#
# @brief スモークがstdoutへ出す[cowork-rpc-smoke] {json}の行だけを取り出す
# @param $1 batsのrunが捕捉した出力 (stdoutとstderrの混合)
#
_smoke_json() {
	local line
	line=$(printf '%s\n' "$1" | grep -m 1 '^\[cowork-rpc-smoke\] {')
	printf '%s' "${line#\[cowork-rpc-smoke\] }"
}

#
# @brief JSONのドット区切りフィールドを文字列として取り出す
# @param $1 JSON文字列
# @param $2 ドット区切りのフィールド名 (例: exit.code)
# @note jqには依存せず、nodeで解析して文字列は引用符なしで返す
#
_json_field() {
	node -e '
const value = process.argv[2].split(".").reduce(
    (current, key) => current[key], JSON.parse(process.argv[1]));
process.stdout.write(typeof value === "string" ? value : JSON.stringify(value));
' "$1" "$2"
}

#
# @brief 最小限のRPCフレームに応答する偽デーモンを書き出す
# @param $1 書き出すJSのパス
# @param $2 SIGTERM受信時に実行するJS (空ならSIGTERMを無視する)
# @param $3 応答の本文を返すJSの関数式。nullなら応答しない (省略時は下記)
# @note 既定の応答のresultは{fake:true}にしてスモークの最初のconfigure検査を
#       失敗させ、SIGTERMの後始末だけを短時間で通す
# @note 自分のPIDを<JSのパス>.pidへ書き、SIGKILL後の生存確認に使う
# @note <JSのパス>.readyがあれば、最初の要求を受けた時にそこへ1行書く
#       (FIFOにしておくと、テストはsleepせずにその時点を待てる)
#
_write_fake_daemon() {
	local target="$1"
	local sigterm_body="$2"
	local reply="$3"
	if [[ -z $reply ]]; then
		reply='(request) => JSON.stringify({ id: request.id, success: true, result: { fake: true } })'
	fi
	cat > "$target" <<NODE
'use strict';

const fs = require('fs');
const net = require('net');
const path = require('path');

const socketPath = (process.env.XDG_RUNTIME_DIR || '/tmp')
    + '/cowork-vm-service.sock';
fs.writeFileSync(path.join(__dirname, path.basename(__filename) + '.pid'),
    String(process.pid));
const readyFile = __filename + '.ready';
const reply = $reply;
let announced = false;

const server = net.createServer((socket) => {
	let buffer = Buffer.alloc(0);
	socket.on('error', () => {});
	socket.on('data', (data) => {
		buffer = Buffer.concat([buffer, data]);
		while (buffer.length >= 4) {
			const length = buffer.readUInt32BE(0);
			if (buffer.length < 4 + length) break;
			const request = JSON.parse(
				buffer.subarray(4, 4 + length).toString());
			buffer = buffer.subarray(4 + length);
			if (!announced && fs.existsSync(readyFile)) {
				announced = true;
				fs.writeFileSync(readyFile, 'request\\n');
			}
			if (reply === null) continue;
			const body = Buffer.from(reply(request));
			const header = Buffer.alloc(4);
			header.writeUInt32BE(body.length, 0);
			socket.write(Buffer.concat([header, body]));
		}
	});
});

server.listen(socketPath, () => {
	console.log('[cowork-vm-service] Service started on ' + socketPath);
});

process.on('SIGTERM', () => {
	$sigterm_body
});
NODE
}

@test "real daemon: the smoke exits cleanly after SIGTERM" {
	run timeout 60 node "$SMOKE"
	[[ $status -eq 0 ]]

	json=$(_smoke_json "$output")
	[[ $(_json_field "$json" ok) == 'true' ]]
	[[ $(_json_field "$json" exit.code) == '0' ]]
	[[ $(_json_field "$json" exit.signal) == 'null' ]]
	[[ $(_json_field "$json" exit.forced) == 'false' ]]
	[[ $(_json_field "$json" failures) == '[]' ]]
	[[ $(_json_field "$json" service) == "$REPO_ROOT/scripts/cowork-vm-service.js" ]]
	[[ $(printf '%s\n' "$output" | grep -c '^\[cowork-rpc-smoke\] {') -eq 1 ]]
}

@test "isolation: sandbox stays under TMPDIR and HOME and host XDG stay empty" {
	local tmp_root="$BATS_TEST_TMPDIR/tmp"
	local real_home="$BATS_TEST_TMPDIR/realhome"
	local host_xdg="$BATS_TEST_TMPDIR/hostxdg"
	mkdir -p "$tmp_root" "$real_home" "$host_xdg"

	run timeout 60 env TMPDIR="$tmp_root" HOME="$real_home" \
		XDG_RUNTIME_DIR="$host_xdg" XDG_CONFIG_HOME="$host_xdg" \
		node "$SMOKE"
	[[ $status -eq 0 ]]

	json=$(_smoke_json "$output")
	[[ $(_json_field "$json" ok) == 'true' ]]
	sandbox=$(_json_field "$json" sandbox)
	[[ $sandbox == "$tmp_root"/claude-desktop-suse-cowork-smoke-* ]]
	[[ ! -e $sandbox ]]
	[[ -z $(ls -A "$real_home") ]]
	[[ ! -e $real_home/.config/Claude ]]
	[[ -z $(ls -A "$host_xdg") ]]
	[[ ! -e $host_xdg/cowork-vm-service.sock ]]
}

@test "SIGKILL fallback: an ignored SIGTERM fails the run and reaps the daemon" {
	local fake="$BATS_TEST_TMPDIR/fake-ignore.js"
	_write_fake_daemon "$fake" ''

	run timeout 60 env COWORK_RPC_SMOKE_TERM_TIMEOUT_MS=500 \
		node "$SMOKE" "$fake"
	[[ $status -eq 1 ]]
	[[ $output == *'ignored SIGTERM for 500ms; sent SIGKILL'* ]]

	json=$(_smoke_json "$output")
	[[ $(_json_field "$json" ok) == 'false' ]]
	[[ $(_json_field "$json" exit.forced) == 'true' ]]
	[[ $(_json_field "$json" exit.signal) == 'SIGKILL' ]]
	[[ $(_json_field "$json" exit.code) == 'null' ]]
	[[ ! -e $(_json_field "$json" sandbox) ]]

	[[ -f $fake.pid ]]
	pid=$(<"$fake.pid")
	run kill -0 "$pid"
	[[ $status -ne 0 ]]
}

@test "exit code: a non-zero daemon exit on SIGTERM fails the run" {
	local fake="$BATS_TEST_TMPDIR/fake-exit3.js"
	_write_fake_daemon "$fake" 'process.exit(3);'

	run timeout 60 node "$SMOKE" "$fake"
	[[ $status -eq 1 ]]
	[[ $output == *'FAIL: daemon exit code'* ]]

	json=$(_smoke_json "$output")
	[[ $(_json_field "$json" ok) == 'false' ]]
	[[ $(_json_field "$json" exit.code) == '3' ]]
	[[ $(_json_field "$json" exit.signal) == 'null' ]]
	[[ $(_json_field "$json" exit.forced) == 'false' ]]
	[[ ! -e $(_json_field "$json" sandbox) ]]
}

@test "broken frame: a reply that is not JSON fails the run without a hang" {
	local fake="$BATS_TEST_TMPDIR/fake-garbage.js"
	_write_fake_daemon "$fake" 'process.exit(0);' "() => '\"not json'"

	run timeout 60 node "$SMOKE" "$fake"
	[[ $status -eq 1 ]]
	[[ $output == *'FAIL: daemon sent a frame that is not JSON'* ]]

	json=$(_smoke_json "$output")
	[[ $(_json_field "$json" ok) == 'false' ]]
	[[ $(_json_field "$json" exit.forced) == 'false' ]]
	[[ ! -e $(_json_field "$json" sandbox) ]]
	run kill -0 "$(<"$fake.pid")"
	[[ $status -ne 0 ]]
}

@test "broken frame: a JSON null reply fails the run and still cleans up" {
	local fake="$BATS_TEST_TMPDIR/fake-null.js"
	_write_fake_daemon "$fake" 'process.exit(0);' "() => 'null'"

	run timeout 60 node "$SMOKE" "$fake"
	[[ $status -eq 1 ]]
	[[ $output == *'FAIL: daemon sent a frame that is not an object: null'* ]]

	json=$(_smoke_json "$output")
	[[ $(_json_field "$json" ok) == 'false' ]]
	[[ $(_json_field "$json" exit.code) == '0' ]]
	[[ ! -e $(_json_field "$json" sandbox) ]]
	run kill -0 "$(<"$fake.pid")"
	[[ $status -ne 0 ]]
}

@test "parent SIGTERM: the smoke reaps the daemon and removes the sandbox" {
	local fake="$BATS_TEST_TMPDIR/fake-silent.js"
	local tmp_root="$BATS_TEST_TMPDIR/tmp"
	local log="$BATS_TEST_TMPDIR/smoke.log"
	mkdir -p "$tmp_root"
	_write_fake_daemon "$fake" '' 'null'
	mkfifo "$fake.ready"

	TMPDIR="$tmp_root" node "$SMOKE" "$fake" > "$log" 2>&1 &
	local smoke_pid=$!
	# 偽デーモンが最初の要求を受けた時点 (スモークが応答を待っている間) まで待つ
	run timeout 30 cat "$fake.ready"
	[[ $status -eq 0 ]]

	kill -TERM "$smoke_pid"
	local rc=0
	wait "$smoke_pid" || rc=$?
	[[ $rc -eq 143 ]]
	[[ $(<"$log") == *'FAIL: interrupted by SIGTERM'* ]]
	[[ -z $(ls -A "$tmp_root") ]]
	run kill -0 "$(<"$fake.pid")"
	[[ $status -ne 0 ]]
}
