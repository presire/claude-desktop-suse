#
# @file pe-sidecar.sh
# @brief Windows用PEサイドカーをLinuxで起動しないようにするパッチ (E)
#
# Windowsの.nupkg由来のバンドルには、GitHubの組み込みMCPサーバーとして
# github-mcp-server.exe (WindowsのPE) が同梱されている。Linuxでも
# app.isPackagedが真になるRPM/AppImageでは、この.exeをそのままspawnしようと
# するため、ENOEXECになるか、binfmt_miscにWineが登録されていれば
# 意図せずWine経由で起動してしまう。
#
# ここでは、GitHub組み込みMCPの接続関数の先頭で、Linuxでは明示的な
# 「Linuxでは未対応」エラーを返す。ただし未パッケージの開発ビルドが
# CLAUDE_DESKTOP_GITHUB_MCP_BINARYでネイティブのLinuxバイナリを指定して
# いる場合だけは、上流のd()もそのパスを使うため通す。パッケージ済みの
# ビルドは上流が環境変数を見ないので、指定があっても起動させない。
#
# Microsoft 365側 (office365-mcp-stdio.mjs / msalBrokerWorker.js) は、
# msal-node-runtime.nodeのrequireをtry/catchで包んでおり、Linuxでは
# StartupErrorとして扱われてbrokerが無効になる。PEを実行しないため、
# ここでは変更しない (tests/pe-sidecar-linux.batsで挙動を検証する)。
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : main_js、project_root
# 変更するグローバル変数 : なし
#
# @note minifyされた識別子は使わず、安定したエクスポート名と文字列を使う
# @note GitHubのチャンクが無いバンドルでは何もせず、_declare_patch_noopを宣言する
# @note チャンクはあるがアンカーが一意に定まらない場合は、失敗する
#

#
# @brief GitHub組み込みMCPのPEサイドカーをLinuxで起動しないようにする
# @global main_js (参照のみ) パッチ対象のメインプロセス用index.js
# @global project_root (参照のみ) 異常終了時に戻る先
# @stdout 検出結果と適用結果
# @note 適用済みのガードは再実行しても二重に挿入しない
#
patch_pe_sidecar_linux_guard() {
	echo 'Patching GitHub builtin MCP to refuse the Windows sidecar on Linux...'
	INDEX_JS="$main_js" node << 'PE_SIDECAR_PATCH'
const fs = require('fs');
const path = require('path');
const indexJs = process.env.INDEX_JS;
const buildDir = path.dirname(indexJs);

let entries;
try {
    entries = fs.readdirSync(buildDir).filter((name) => name.endsWith('.js'));
} catch (e) {
    console.error('ERROR: cannot read the build directory ' + buildDir + ': ' + e.message);
    process.exit(1);
}

const candidates = [];
for (const name of entries) {
    const file = path.join(buildDir, name);
    let text;
    try {
        text = fs.readFileSync(file, 'utf8');
    } catch (e) {
        console.error('ERROR: cannot read ' + file + ': ' + e.message);
        process.exit(1);
    }
    if (text.includes('github-mcp-server.exe')) {
        candidates.push({ file, text });
    }
}

if (candidates.length === 0) {
    console.log('  No GitHub builtin MCP sidecar in this bundle; nothing to guard');
    process.exit(0);
}
if (candidates.length > 1) {
    console.error('ERROR: GitHub builtin MCP sidecar is ambiguous: ' + candidates.length + ' chunks contain github-mcp-server.exe');
    process.exit(1);
}

const target = candidates[0];
const exportRe = /exports\s*\.\s*connectGithubBuiltinMcp\s*=\s*([\w$]+)\s*;/g;
const exportsFound = [...target.text.matchAll(exportRe)];
if (exportsFound.length !== 1) {
    console.error('ERROR: GitHub builtin MCP export (connectGithubBuiltinMcp) is ' +
        (exportsFound.length === 0 ? 'missing' : 'ambiguous (' + exportsFound.length + ' sites)'));
    process.exit(1);
}
const fnName = exportsFound[0][1];

const guard = 'if(process.platform==="linux"&&!(process.env["CLAUDE_DESKTOP_GITHUB_MCP_BINARY"]' +
    '&&!require("electron").app.isPackaged))' +
    'throw new Error("[github-mcp] the bundled GitHub MCP server is a Windows executable ' +
    'and cannot run on Linux; disable the GitHub MCP server, or set ' +
    'CLAUDE_DESKTOP_GITHUB_MCP_BINARY to a Linux binary in an unpackaged build");';

const headRe = new RegExp(
    '(async\\s+function\\s+' + fnName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') +
    '\\s*\\([^)]*\\)\\s*\\{\\s*)', 'g');
const heads = [...target.text.matchAll(headRe)];
if (heads.length !== 1) {
    console.error('ERROR: GitHub builtin MCP connect function (' + fnName + ') is ' +
        (heads.length === 0 ? 'missing' : 'ambiguous (' + heads.length + ' sites)'));
    process.exit(1);
}

const bodyStart = heads[0].index + heads[0][0].length;
const body = target.text.slice(bodyStart, bodyStart + guard.length + 20);
if (body.startsWith(guard)) {
    console.log('  GitHub builtin MCP Linux guard already present');
    process.exit(0);
}

const patched = target.text.slice(0, bodyStart) + guard + target.text.slice(bodyStart);
fs.writeFileSync(target.file, patched);
console.log('  GitHub builtin MCP refuses the Windows .exe on Linux (before spawn)');
PE_SIDECAR_PATCH
	local status=$?
	if (( status != 0 )); then
		echo 'ERROR: PE sidecar guard failed; refusing to ship a partial patch.' >&2
		cd "$project_root" 2>/dev/null || true
		return 1
	fi

	# GitHubのチャンクが無いバンドルでは、上で何も書き換えずに終了している。
	# その場合もパッチ段階が「効果なし」で失敗しないよう、no-opを宣言する。
	if ! grep -qF 'github-mcp-server.exe' "${main_js%/*}"/*.js 2>/dev/null; then
		_declare_patch_noop
	fi
}
