#
# @file terminal-da-reply.sh
# @brief 画面に出る前のシェルへ、メインプロセスからDA1(一次デバイス属性)の
#        応答を返す
#
# fish 4.xは起動時とコマンドごとにESC[0cを送り、応答を最大10秒待つ
# Runボタンやrun_in_terminalでは、xtermが画面に配置される前にシェルが
# 起動するため、問い合わせはバッファに溜まるだけになる
# 画面に到達したxtermが応答しても、レンダラーはリプレイ中の端末レポートを
# 意図的に捨てるため、fishは応答を受け取れない
# その結果タブは10秒間空白のままになり、待機中に貼り付けたコマンドも失われる
# (claude-desktop-debian #966と同じ不具合)
#
# メインプロセスはレンダラーの状態に関係なく問い合わせを即座に見られるので、
# そこで応答する
# 応答した回数はptyに記録し、writeShellPtyでxtermからの同じ応答を捨てる
# これにより、画面に出ているシェルにも応答は必ず1回だけ届く
# 2回目が届くと、応答直後に終了するプログラムではプロンプトへ
# 余計な文字列が残る
#
# 上流修正待ちの暫定対応であり、新機能ではない
# 上流はion-dist.asar側で直せるため、このパッチのno-opでは修正を証明できない
# 再現しなくなったら引退させる
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : _ANCHOR_Q (_common.shで定義)
# 変更するグローバル変数 : なし
#

#
# @brief pty:shell-dataを配線しているJavaScriptを1つだけ解決する
# @stdout パッチ対象のJavaScriptのパス
# @stderr 見つからない場合、または複数見つかった場合の診断メッセージ
# @return 0 = 一意に決まった、1 = 一意に決められない
# @note 本体チャンクの名前は毎回変わるため、_resolve_main_jsは使わない
#       .vite/build配下の全JavaScriptを対象にし、候補が1つのときだけ返す
#       推測して適用するより、失敗して気付けるほうが安全である
#
_resolve_terminal_da_target() {
	local -a hits=()
	local hit

	while IFS= read -r hit; do
		hits+=("$hit")
	done < <(grep -rlPz --include='*.js' \
		-e "\\.onData\\s*\\(\\s*[\\w$.]+\\s*\\(\\s*${_ANCHOR_Q}pty:shell-data${_ANCHOR_Q}" \
		app.asar.contents/.vite/build 2>/dev/null)

	if (( ${#hits[@]} != 1 )); then
		echo "_resolve_terminal_da_target: expected exactly 1 file" \
			"with a pty:shell-data handler, found ${#hits[@]}" >&2
		return 1
	fi

	printf '%s\n' "${hits[0]}"
}

#
# @brief DA1への応答と、xtermからの重複応答の抑制をメインプロセスへ注入する
# @global なし
# @stdout 適用またはスキップのメッセージ
# @stderr アンカーが一意でない場合の診断メッセージ
# @return 0 = 適用した、または適用済み、1 = 一意に決められない、または
#         部分適用の疑いがある
# @note アンカーは毎リリース変わるminify済み識別子を直書きせず、
#       pty:shell-dataとwriteShellPtyという安定した文字列から動的に取る
#       再実行しても二重に適用しない
#
patch_terminal_da_reply() {
	echo 'Patching terminal panel DA1 replies (hidden shell startup)...'

	local target_js
	if ! target_js=$(_resolve_terminal_da_target); then
		echo 'ERROR: terminal DA1 patch target could not be resolved' \
			'uniquely. The bundle no longer has the expected' \
			'pty:shell-data handler. Re-derive the anchors against the' \
			'new bundle, or retire the patch if upstream fixed the' \
			'replay filter.' >&2
		return 1
	fi

	if TARGET_JS="$target_js" node <<'TERMINAL_DA_PATCH'
const fs = require('fs');
const targetJs = process.env.TARGET_JS;
let code = fs.readFileSync(targetJs, 'utf8');

// 上流が出力しない私有プロパティ名をマーカーにする
// 2箇所は必ず同時に入るため、片方だけなら壊れたバンドルである
// 問い合わせ側だけが残ると、画面に出ている全シェルへ二重に応答してしまう
const owed = '__cddDa1Owed';
const tail = '__cddDa1Tail';

const querySeen = code.includes('.' + tail);
const replySeen = code.includes('.' + owed + '>0');
if (querySeen && replySeen) {
    console.log('  Terminal DA1 reply already applied');
    process.exit(0);
}
if (querySeen !== replySeen) {
    console.log('  WARNING: only one of the two DA1 patch sites is ' +
        'present - re-extract a pristine asar and re-run');
    process.exit(1);
}

// 受け取り側とデータ引数は直書きせず捕捉する
// これらはリリースごとに変わる
// 受け取り側はプロパティの連鎖を許し、連鎖したptyの末尾だけに
// 一致しないようにする
// 意図: PTY.onData(WRAP("pty:shell-data",(DATA=>{
const dataRe = new RegExp(
    '([\\w$]+(?:\\.[\\w$]+)*)\\.onData\\s*\\(\\s*' +
    '[\\w$]+(?:\\.[\\w$]+)*\\s*\\(\\s*' +
    '[`"\']pty:shell-data[`"\']' +
    '\\s*,\\s*\\(*\\s*([\\w$]+)\\s*\\)?\\s*=>\\s*\\{',
    'g');
const dataMatches = [...code.matchAll(dataRe)];
if (dataMatches.length !== 1) {
    console.log('  WARNING: expected exactly 1 pty:shell-data handler, ' +
        'found ' + dataMatches.length);
    process.exit(1);
}

// 解決したファイル内に定義は1つだけある
// ここへ転送するIPCディスパッチャは別チャンクにいる
// 意図: writeShellPty(KEY,INPUT,ORIGIN){
const writeRe = /\bwriteShellPty\s*\(\s*([\w$]+)\s*,\s*([\w$]+)\s*,\s*[\w$]+\s*\)\s*\{/g;
const writeMatches = [...code.matchAll(writeRe)];
if (writeMatches.length !== 1) {
    console.log('  WARNING: expected exactly 1 writeShellPty definition, ' +
        'found ' + writeMatches.length);
    process.exit(1);
}

const dataMatch = dataMatches[0];
const before = code.slice(0, dataMatch.index).replace(/\s+$/, '');
if (/[\w$.]$/.test(before)) {
    console.log('  WARNING: pty:shell-data receiver matched ' +
        'mid-expression (prefix ends "' + before.slice(-16) + '") - ' +
        'widen the receiver capture');
    process.exit(1);
}

const pty = dataMatch[1];
const data = dataMatch[2];
const reply = '"\\x1b[?1;2c"';

// 読み取りの境界で分かれた問い合わせを保持する
// 完全な問い合わせは残さないため、二重に数えることはない
const answerQueries =
    '{let cddQ=(' + pty + '.' + tail + '??"")+' + data + ',' +
    'cddN=cddQ.match(/\\x1b\\[0?c/g)?.length??0;' +
    pty + '.' + tail + '=' +
    '/\\x1b(?:\\[0?)?$/.exec(cddQ)?.[0]??"";' +
    'for(let cddI=0;cddI<cddN;cddI++)' +
    pty + '.' + owed + '=(' + pty + '.' + owed + '??0)+1,' +
    pty + '.write(' + reply + ')}';

const writeMatch = writeMatches[0];
const key = writeMatch[1];
const input = writeMatch[2];

// ここのthisは、上のハンドラーが確認するshellPtyProcessesを持つ
// マネージャーであり、メソッド自身も同じkeyで最初にそれを読む
const dropReply =
    'if(' + input + '===' + reply + '){' +
    'let cddP=this.shellPtyProcesses.get(' + key + ');' +
    'if(cddP?.' + owed + '>0){cddP.' + owed + '--;return}}';

if (!code.slice(writeMatch.index, writeMatch.index + 2000)
    .includes('this.shellPtyProcesses.get(' + key + ')')) {
    console.log('  WARNING: writeShellPty no longer reads ' +
        'this.shellPtyProcesses - re-derive the patch');
    process.exit(1);
}

// 先に後ろの位置へ挿入し、前の位置がずれないようにする
const sites = [
    [dataMatch.index + dataMatch[0].length, answerQueries],
    [writeMatch.index + writeMatch[0].length, dropReply],
].sort((a, b) => b[0] - a[0]);
for (const [at, text] of sites) {
    code = code.substring(0, at) + text + code.substring(at);
}

fs.writeFileSync(targetJs, code);
console.log('  Shell pty (' + pty + ') now answers DA1 from the main ' +
    'process');
TERMINAL_DA_PATCH
	then
		echo 'Terminal DA1 reply applied'
	else
		echo 'ERROR: terminal DA1 patch failed. Without it, fish 4.x tabs' \
			'started off screen stall for 10 seconds and lose pasted' \
			'commands. Update the anchors in' \
			'scripts/patches/terminal-da-reply.sh against the new bundle,' \
			'or retire the patch if the replay filter is fixed upstream.' >&2
		return 1
	fi

	echo '##############################################################'
}
