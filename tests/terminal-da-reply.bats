#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Batsはテストごとにサブシェルで実行する
#
# @file terminal-da-reply.bats
# @brief patch_terminal_da_replyが、画面に出る前のシェルへDA1応答を返し、
#        xtermからの重複応答を捨てる様子を確認する
#
# 固定データ(fixture)は実際の4.23118.0の形を模している
# 受け取り側のpty、ラッパー呼び出し、writeShellPtyの引数は
# リリースごとに変わるため、パッチはこれらを動的に捕捉する
# 挙動のテストは、パッチ適用済みのクラスを実際に動かして確認する
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
COMMON_SH="$SCRIPT_DIR/../scripts/patches/_common.sh"
DA_SH="$SCRIPT_DIR/../scripts/patches/terminal-da-reply.sh"

#
# @brief テスト用の一時ディレクトリと、パッチ対象のチャンクを作る
# @global TEST_TMP (本関数で設定する) テスト専用ディレクトリ
# @global BUILD_DIR (本関数で設定する) .vite/build
# @global FIXTURE (本関数で設定する) パッチ対象のチャンク
# @global ORIGINAL (本関数で設定する) パッチ前の複製
# @global DRIVER (本関数で設定する) 挙動を確認するNodeスクリプト
#
setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/_common.sh
	source "$COMMON_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/terminal-da-reply.sh
	source "$DA_SH"
	BUILD_DIR="$TEST_TMP/app.asar.contents/.vite/build"
	mkdir -p "$BUILD_DIR"
	FIXTURE="$BUILD_DIR/index.chunk-test.js"
	ORIGINAL="$TEST_TMP/original.js"
	DRIVER="$TEST_TMP/drive.js"
	write_driver
}

#
# @brief テスト専用ディレクトリを削除する
# @global TEST_TMP 削除する一時ディレクトリ (参照のみ)
#
teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

#
# @brief 実際の4.23118.0の形を模したチャンクを書き出す
# @global FIXTURE (参照のみ) 書き出し先
# @global ORIGINAL (参照のみ) パッチ前の複製先
#
write_fixture() {
	printf '%s' 'var t={Vvt:(n,f)=>f};module.exports=class{constructor(){this.shellPtyProcesses=new Map;this.written=[]}attach(e,U){this.shellPtyProcesses.set(e,U),U.onData(t.Vvt("pty:shell-data",(t=>{if(this.shellPtyProcesses.get(e)!==U)return;this.seen=t})))}writeShellPty(e,n,r){let{sessionId:i}=this.key(e);let a=this.shellPtyProcesses.get(e);if(!a)return;a.write(n),this.written.push(n)}key(e){return{sessionId:e}}};' > "$FIXTURE"
	cp "$FIXTURE" "$ORIGINAL"
}

#
# @brief パッチ適用済みクラスの挙動を確認するNodeスクリプトを書き出す
# @global DRIVER (参照のみ) 書き出し先
#
write_driver() {
	cat > "$DRIVER" <<'DRIVE_JS'
'use strict';
const assert = require('assert');
const Manager = require(process.argv[2]);
const reply = '\x1b[?1;2c';
const query = '\x1b[0c';

function make() {
    const manager = new Manager();
    const pty = {
        sent: [],
        write(chunk) {
            this.sent.push(chunk);
        },
        onData(callback) {
            this.callback = callback;
        },
    };
    manager.attach('tab', pty);
    return { manager, pty, emit: (chunk) => pty.callback(chunk) };
}

// 画面に出る前のシェルにも、メインプロセスから1回だけ応答する
let x = make();
x.emit(query);
assert.deepStrictEqual(x.pty.sent, [reply], 'ESC[0c gets one reply');

x = make();
x.emit('\x1b[c');
assert.deepStrictEqual(x.pty.sent, [reply], 'bare ESC[c gets one reply');

x = make();
x.emit(query + query);
assert.deepStrictEqual(x.pty.sent, [reply, reply], 'two queries get two replies');

// 二次DAやカーソル位置レポートには応答しない
x = make();
x.emit('\x1b[>0c\x1b[6n');
assert.deepStrictEqual(x.pty.sent, [], 'secondary DA and CPR are ignored');

// 読み取りの境界で分かれた問い合わせも応答する
x = make();
x.emit('x\x1b[');
assert.deepStrictEqual(x.pty.sent, [], 'partial query gets no reply yet');
x.emit('0c');
assert.deepStrictEqual(x.pty.sent, [reply], 'split query gets one reply');

// 完全な問い合わせを二重に数えない
x = make();
x.emit(query);
x.emit('');
assert.deepStrictEqual(x.pty.sent, [reply], 'complete query is not recounted');

// 画面に出ているxtermの応答は、メインプロセスが返した分だけ捨てる
x = make();
x.emit(query);
x.manager.writeShellPty('tab', reply, 'renderer');
assert.deepStrictEqual(x.pty.sent, [reply], 'duplicate xterm reply is dropped');
assert.deepStrictEqual(x.manager.written, [], 'duplicate never reaches the shell');

// 無関係なレポートと通常の入力は素通しする
x.manager.writeShellPty('tab', '\x1b[12;40R', 'renderer');
x.manager.writeShellPty('tab', 'ls\r', 'user');
assert.deepStrictEqual(x.manager.written, ['\x1b[12;40R', 'ls\r']);
console.log('all DA1 behaviors OK');
DRIVE_JS
}

@test "DA1: answers a primary device attribute query from the main process" {
	write_fixture
	cd "$TEST_TMP"
	run patch_terminal_da_reply
	[ "$status" -eq 0 ]
	[[ $output == *'Terminal DA1 reply applied'* ]]
	node --check "$FIXTURE"
	run node "$DRIVER" "$FIXTURE"
	[ "$status" -eq 0 ]
}

@test "DA1: adds the query answer before the existing handler guard" {
	write_fixture
	cd "$TEST_TMP"
	run patch_terminal_da_reply
	[ "$status" -eq 0 ]
	grep -qF 'let cddQ=(U.__cddDa1Tail??"")+t' "$FIXTURE"
	grep -qF 'U.write("\x1b[?1;2c")' "$FIXTURE"
	grep -qF 'if(this.shellPtyProcesses.get(e)!==U)return;' "$FIXTURE"
}

@test "DA1: rerun is byte-identical and reports already applied" {
	write_fixture
	cd "$TEST_TMP"
	run patch_terminal_da_reply
	[ "$status" -eq 0 ]
	local first
	first=$(sha256sum "$FIXTURE" | cut -d' ' -f1)
	run patch_terminal_da_reply
	[ "$status" -eq 0 ]
	[[ $output == *'already applied'* ]]
	[ "$(sha256sum "$FIXTURE" | cut -d' ' -f1)" = "$first" ]
}

@test "DA1: fails closed when only one patch site is present" {
	write_fixture
	printf '%s' 'var _x={};_x.__cddDa1Tail="";' >> "$FIXTURE"
	cd "$TEST_TMP"
	run patch_terminal_da_reply
	[ "$status" -eq 1 ]
	[[ $output == *'only one of the two DA1 patch sites'* ]]
}

@test "DA1: fails closed when the handler is ambiguous" {
	write_fixture
	printf '%s' 'U.onData(t.Vvt("pty:shell-data",(t=>{})));' >> "$FIXTURE"
	cd "$TEST_TMP"
	run patch_terminal_da_reply
	[ "$status" -eq 1 ]
	[[ $output == *'expected exactly 1 pty:shell-data handler'* ]]
}

@test "DA1: fails closed when writeShellPty is missing" {
	printf '%s' 'var t={Vvt:(n,f)=>f};module.exports=class{constructor(){this.shellPtyProcesses=new Map}attach(e,U){this.shellPtyProcesses.set(e,U),U.onData(t.Vvt("pty:shell-data",(t=>{})))}};' > "$FIXTURE"
	cd "$TEST_TMP"
	run patch_terminal_da_reply
	[ "$status" -eq 1 ]
	[[ $output == *'expected exactly 1 writeShellPty definition'* ]]
}

@test "DA1: fails closed when writeShellPty stops reading shellPtyProcesses" {
	printf '%s' 'var t={Vvt:(n,f)=>f};module.exports=class{constructor(){this.shellPtyProcesses=new Map}attach(e,U){this.shellPtyProcesses.set(e,U),U.onData(t.Vvt("pty:shell-data",(t=>{})))}writeShellPty(e,n,r){let a=null;if(!a)return;a.write(n)}};' > "$FIXTURE"
	cd "$TEST_TMP"
	run patch_terminal_da_reply
	[ "$status" -eq 1 ]
	[[ $output == *'writeShellPty no longer reads this.shellPtyProcesses'* ]]
}

@test "DA1: fails closed when multiple files carry the handler" {
	write_fixture
	cp "$FIXTURE" "$BUILD_DIR/index.chunk-other.js"
	cd "$TEST_TMP"
	run patch_terminal_da_reply
	[ "$status" -eq 1 ]
	[[ $output == *'expected exactly 1 file'* ]]
}

@test "DA1: tolerates whitespace between anchor tokens" {
	printf '%s' 'var t={Vvt:(n,f)=>f};module.exports=class{constructor(){this.shellPtyProcesses=new Map;this.written=[]}attach(e,U){this.shellPtyProcesses.set(e,U),U.onData ( t.Vvt ( "pty:shell-data" , ( t => {if(this.shellPtyProcesses.get(e)!==U)return;this.seen=t})))}writeShellPty (e,n,r){let a=this.shellPtyProcesses.get(e);if(!a)return;a.write(n),this.written.push(n)}};' > "$FIXTURE"
	cd "$TEST_TMP"
	run patch_terminal_da_reply
	[ "$status" -eq 0 ]
	node --check "$FIXTURE"
	run node "$DRIVER" "$FIXTURE"
	[ "$status" -eq 0 ]
}
