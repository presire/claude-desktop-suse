# shellcheck shell=bash
#
# @file patches/file-manager-entries.sh
# @brief Linuxでもアプリ生成のファイルマネージャー項目を有効にする
#
# Windows版のapp.asarは、Linux固有のNautilus/KDE項目の生成を
# 次のゲートで止めている。
#
#   function <name>(){return!1}
#
# この関数はファイルマネージャー項目の書き込み (Hho) と削除 (Uho) の
# 両方を制御しており、Windowsでは不要な処理を止めるためのものだ。
# SUSE版はWindowsのnupkgをLinux向けに組み直すため、ゲートを
# process.platform === "linux" に変え、ExecとTryExecを直列化する。
# Windowsでは従来どおり無効のままにする。
#
# アンカーには、ゲート直前のサービスメニューのパス
# "kservices5/ServiceMenus" を使う。この文字列はバンドル内で一意で、
# minifyされても残る。ゲートの関数名はリリースごとに変わるため、
# 名前を直書きせず、パス解決関数の直後にある無引数の!1関数を捕捉する。
#
# 次の場合はビルドを止める (fail-closed)。
#   * パスのアンカーが0件または複数件
#   * アンカーの直後に!1ゲートがちょうど1件ない
#   * 独自のLinuxゲートと上流の!1ゲートが混在している
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : main_js
# 変更するグローバル変数 : なし
#

#
# @brief ファイルマネージャー項目のLinuxゲートを有効にする
# @global main_js (参照のみ) パッチ対象のメインプロセス用index.js
# @stdout 適用またはスキップのメッセージ
# @return 0 = 適用した、または適用済み、1 = アンカーが安全に決められない
# @note ゲートと.desktopの直列化を、Acornで確定した実コード範囲だけに適用する
#       適用済みの場合はバイト列を変えずに戻るため、再実行しても冪等になる
#
patch_file_manager_entries_linux() {
	local index_js="${main_js:-}"

	if [[ -z $index_js || ! -f $index_js ]]; then
		echo 'Error: main-process JS is missing; cannot enable' \
			'Linux file-manager entries' >&2
		return 1
	fi
	if ! command -v node >/dev/null 2>&1; then
		echo 'Error: node is required to enable Linux' \
			'file-manager entries' >&2
		return 1
	fi

	echo 'Enabling Linux file-manager entry generation...'
	if ! INDEX_JS="$index_js" PATCH_WORK_DIR="${work_dir:-}" \
		PATCH_SOURCE="${BASH_SOURCE[0]%/*}/file-manager-source.cjs" \
		node <<'FILE_MANAGER_ENTRIES_PATCH'
'use strict';

const fs = require('fs');
const { analyze, menuAt, stringValue } = require(require('path').resolve(process.env.PATCH_SOURCE));

const indexJs = process.env.INDEX_JS;
if (!indexJs) {
	console.error('  ERROR: INDEX_JS is not set');
	process.exit(2);
}

let code;
try {
	code = fs.readFileSync(indexJs, 'utf8');
} catch (error) {
	console.error('  ERROR: cannot read the main-process JS: ' +
		error.message);
	process.exit(2);
}

const fail = function (message) {
	console.error('  ERROR: ' + message);
	process.exit(1);
};

function parse(source) {
	try {
		return analyze(source);
	} catch (error) {
		fail('cannot parse main-process JS: ' + error.message);
	}
}
const original = parse(code);

// ゲート直前のサービスメニュー解決処理にだけ現れる安定した文字列。
const anchor = 'kservices5/ServiceMenus';
const anchorCount = code.split(anchor).length - 1;
if (anchorCount !== 1) {
	fail('expected exactly one ' + anchor + ' anchor, found ' +
		anchorCount);
}

// 上流のminifierは文字列を二重引用符・単一引用符・バッククォートの
// いずれでも出力するため、パスの区切りは3種類すべてを受ける。
const quote = '[`"\']';

// kservices5/ServiceMenus を含むパス解決関数の直後に続く、
// 無引数で!1を返す関数だけをゲートとみなす。
// パス解決関数の本体に波括弧が増えた場合は、別の関数を巻き込まないよう
// 一致させずに失敗させる。
const resolver =
	'function\\s+[\\w$]+\\s*\\(\\s*[\\w$]+\\s*\\)\\s*\\{' +
	'[^{}]*' + quote + 'kservices5\\/ServiceMenus' + quote +
	'[^{}]*\\}';

const rawGate = new RegExp(
	'(' + resolver + '\\s*function\\s+)([\\w$]+)' +
	'(\\s*\\(\\s*\\)\\s*\\{\\s*return\\s*)!\\s*1(\\s*\\})',
	'g');
const linuxGate = new RegExp(
	'(' + resolver + '\\s*function\\s+)([\\w$]+)' +
	'(\\s*\\(\\s*\\)\\s*\\{\\s*return\\s*)process\\.platform\\s*===\\s*' +
	'(["\'])linux\\4(\\s*\\})',
	'g');

const isGate = match => {
	const resolverNode = original.functions.find(fn =>
		fn.type === 'FunctionDeclaration' && fn.start === match.index);
	return resolverNode && original.strings.some(node =>
		node.start > resolverNode.start && node.end < resolverNode.end &&
		code.slice(node.start + 1, node.end - 1) === anchor) &&
		original.functions.some(fn => fn.type === 'FunctionDeclaration' &&
			fn.end === match.index + match[0].length);
};
const upstream = [...code.matchAll(rawGate)].filter(isGate);
const enabled = [...code.matchAll(linuxGate)].filter(isGate);
const messages = [];
let updated = code;

if (upstream.length === 1 && enabled.length === 0) {
	const match = upstream[0];
	const beforeReturn = match[3].replace(/\s*$/, ' ');
	const replacement = match[1] + match[2] + beforeReturn +
		'process.platform==="linux"' + match[4];
	updated = updated.slice(0, match.index) + replacement +
		updated.slice(match.index + match[0].length);
	messages.push('Enabled Linux file-manager entry gate (' +
		match[2] + ')');
} else if (upstream.length === 0 && enabled.length === 1) {
	messages.push('Linux file-manager entry gate already enabled (' +
		enabled[0][2] + ')');
} else {
	fail('expected exactly one upstream !1 gate after the ' +
		'file-manager service-menu anchor, found ' + upstream.length +
		' upstream and ' + enabled.length + ' Linux gate(s)');
}

// 生成側の直列化。TryExecは文字列値、Execはシェルとキーファイルの
// 二段階でエスケープする。ミニファイされた関数名には依存しない。
const serializationMarker = '/*claude-suse:file-manager-serialize*/';
// ASTで確定した関数の全範囲に、既知の変換形だけを一致させる。
const quoteFunctionShape =
	/^function\s+([\w$]+)\s*\(\s*([\w$]+)\s*\)\s*\{\s*return\s*`"\$\{\s*\2\s*\.\s*replace\s*\(\s*\/\[\\\\"`\$]\/g\s*,\s*\(\s*([\w$]+)\s*=>\s*`\\\\\$\{\3\}`\s*\)\s*\)\s*\.\s*replaceAll\s*\(\s*(["'`])%\4\s*,\s*\4%%\4\s*\)\s*\}"`\s*\}/;
// 既知のメニューテンプレート関数だけを、配列のjoin終端まで切り出す。
// 本体の文字列・テンプレート補間・コメント内の波括弧には依存しない。
const templateFunctionShape =
	/^function\s+([\w$]+)\s*\(\s*([\w$]+)\s*,\s*([\w$]+)\s*\)\s*\{\s*return\s*\[[\s\S]*?\]\s*\.\s*join\s*\(\s*`\\n`\s*\)\s*\}/;
if (updated.includes(serializationMarker)) {
	validateSerialization(updated);
	messages.push('File-manager entry serialization already patched');
} else {
	updated = serializeEntries(updated);
	messages.push('Serialized generated file-manager Exec and TryExec');
}

// Acorn supports the input's using declarations even on the Node 22 build
// host. An input parse failure never disables the output check.
parse(updated);

if (updated === code) {
	console.log(messages.join('\n'));
	process.exit(0);
}

const mode = fs.statSync(indexJs).mode & 0o7777;
const tmp = indexJs + '.fm1.' + process.pid;
try {
	fs.writeFileSync(tmp, updated, { mode });
	fs.renameSync(tmp, indexJs);
} catch (error) {
	try {
		fs.unlinkSync(tmp);
	} catch {
		// 一時ファイルがまだ無い場合もある
	}
	fail('cannot write the patched chunk: ' + error.message);
}

for (const message of messages) {
	console.log('  ' + message);
}

//
// @brief 既知のExec引用関数だけを厳密に切り出す
// @param indexJsCode 対象のJavaScript
// @param before Execのpercentアンカーの位置
// @return { start, end, name, arg, source }、形が違えばnull
//
function quoteFunctionAt(indexJsCode, before) {
	const nodes = parse(indexJsCode).functions.filter(fn =>
		fn.start <= before && fn.end > before);
	const node = nodes.sort((a, b) => (a.end - a.start) - (b.end - b.start))[0];
	if (!node || node.body.body.length !== 1 ||
		node.body.body[0].type !== 'ReturnStatement' || !node.body.body[0].argument) return null;
	const start = node.start;
	const match = indexJsCode.slice(start, node.end).match(quoteFunctionShape);
	if (!match || match[0].length !== node.end - start) {
		return null;
	}
	return {
		start: start,
		end: start + match[0].length,
		name: match[1],
		arg: match[2],
		source: match[0]
	};
}

//
// @brief 既知のメニューテンプレート関数だけを厳密に切り出す
// @param indexJsCode 対象のJavaScript
// @param before KonqPopupMenuアンカーの位置
// @return { start, end, source }、形が違えばnull
//
function templateFunctionAt(indexJsCode, before) {
	const menu = menuAt(parse(indexJsCode), before);
	if (!menu) return null;
	const { start, end } = menu.node;
	const source = indexJsCode.slice(start, end);
	const match = source.match(templateFunctionShape);
	if (!match || match[0].length !== source.length) return null;
	return { start, end, source, entries: menu.entries };
}

function quoteReplacement(name, arg) {
	const slash = String.fromCharCode(92);
	return 'function ' + name + '(' + arg + '){return ' + "'\"'+" + arg +
		'.replace(/[' + slash + slash + '"`$]/g,e=>\'' + slash + slash +
		'\'+e)' + ".replaceAll('%','%%')" +
		".replaceAll('" + slash + slash + "','" +
		slash + slash + slash + slash + "')+'\"'}";
}

function validateSerialization(indexJsCode) {
	const analysis = parse(indexJsCode);
	const percentMatches = execPercentMatches(analysis);
	const replacements = analysis.functions.filter(fn =>
		fn.id && fn.params.length === 1 && fn.params[0].type === 'Identifier' &&
		percentMatches.length === 1 && fn.start < percentMatches[0].index &&
		fn.end > percentMatches[0].index &&
		indexJsCode.slice(fn.start, fn.end) === quoteReplacement(fn.id.name, fn.params[0].name));
	const markers = indexJsCode.split(serializationMarker).length - 1;
	const helper = /^`TryExec=\$\{\/\*claude-suse:file-manager-serialize\*\/\(function (__claudeSuseDesktopString_*)\(e\)\{return e\.replaceAll\("\\\\","\\\\\\\\"\)\.replaceAll\("\\t","\\\\t"\)\}\)\([\w$]+\.tryExec\)\}`$/;
	const anchor = 'X-KDE-ServiceTypes=KonqPopupMenu/Plugin';
	const menu = indexJsCode.split(anchor).length === 2 &&
		templateFunctionAt(indexJsCode, indexJsCode.indexOf(anchor));
	if (markers !== 1 || replacements.length !== 1 || !menu ||
		menu.entries.filter(entry => entry && entry.type === 'TemplateLiteral' &&
			indexJsCode.slice(entry.start, entry.end).match(helper)).length !== 1) {
		fail('incomplete or ambiguous file-manager serialization');
	}
}

function execPercentMatches(analysis) {
	return analysis.calls.filter(call => call.callee.type === 'MemberExpression' &&
		(call.callee.computed ? stringValue(call.callee.property) : call.callee.property.name) === 'replaceAll' &&
		call.arguments.length === 2 && stringValue(call.arguments[0]) === '%' &&
		stringValue(call.arguments[1]) === '%%')
		.map(call => ({ index: call.callee.property.start }));
}

//
// @brief アプリが生成する.desktopのExecとTryExecを直列化する
// @param indexJsCode パッチ対象のJavaScript
// @return 直列化を追加したJavaScript
// @note Exec引用関数は空白と引用符の揺れを許して特定し、
//       minifyされた名前は捕捉して使う
//       TryExecはKonqPopupMenu/Pluginを含むテンプレート関数の
//       `TryExec=${...}` だけを書き換える
//       挿入するヘルパー名は既存の識別子と衝突しないよう動的に決める
//
function serializeEntries(indexJsCode) {
	const marker = '/*claude-suse:file-manager-serialize*/';
	const backslash = String.fromCharCode(92);

	// 上流はダブルクォート、シングルクォート、バッククォートの
	// いずれも出力し得る。コロンやカンマ前後の空白も許す。
	const analysis = parse(indexJsCode);
	const execMatches = execPercentMatches(analysis);
	if (execMatches.length !== 1) {
		fail('expected exactly one file-manager Exec percent anchor, ' +
			'found ' + execMatches.length);
	}
	const quoteFunction = quoteFunctionAt(indexJsCode,
		execMatches[0].index);
	if (!quoteFunction) {
		fail('cannot parse the file-manager Exec quote function');
	}
	// 一段目でシェル用に \ " ` $ を逃がし、二段目でキーファイル用に
	// バックスラッシュを二重化する。%はフィールドコードなので%%にする。
	const execReplacement = quoteReplacement(quoteFunction.name, quoteFunction.arg);
	let result = indexJsCode.slice(0, quoteFunction.start) + execReplacement +
		indexJsCode.slice(quoteFunction.end);

	// メニューを組み立てるテンプレート関数は
	// X-KDE-ServiceTypes=KonqPopupMenu/Plugin を一意に含む。
	const templateAnchor = 'X-KDE-ServiceTypes=KonqPopupMenu/Plugin';
	const templateCount = result.split(templateAnchor).length - 1;
	if (templateCount !== 1) {
		fail('expected exactly one file-manager menu template anchor, ' +
			'found ' + templateCount);
	}
	const anchorPos = result.indexOf(templateAnchor);
	const templateFunction = templateFunctionAt(result, anchorPos);
	if (!templateFunction) {
		fail('cannot parse the file-manager menu template function');
	}
	const tryPattern =
		/(`TryExec=\$\{)\s*([\w$]+)\s*\.\s*tryExec\s*(}`)/g;
	const execPattern =
		/(`Exec=\$\{)\s*([\w$]+)\s*\.\s*exec\s*(}`)/g;
	const actualMatches = pattern => templateFunction.entries.filter(entry =>
		entry && entry.type === 'TemplateLiteral').flatMap(entry =>
			[...result.slice(entry.start, entry.end).matchAll(pattern)].filter(match =>
				match.index === 0 && match[0].length === entry.end - entry.start));
	const tryMatches = actualMatches(tryPattern);
	const execMatchesInTemplate = actualMatches(execPattern);
	const allTryMatches = parse(result).templates.filter(entry =>
		new RegExp('^' + tryPattern.source + '$').test(result.slice(entry.start, entry.end)));
	if (tryMatches.length !== 1 || execMatchesInTemplate.length !== 1 ||
		allTryMatches.length !== 1) {
		fail('expected one TryExec and one Exec template, found ' +
			tryMatches.length + ' and ' + execMatchesInTemplate.length);
	}

	let helper = '__claudeSuseDesktopString';
	while (result.includes(helper)) {
		helper += '_';
	}
	const helperSource = marker + '(function ' + helper + '(e){return e' +
		'.replaceAll("' + backslash + backslash + '","' +
		backslash + backslash + backslash + backslash + '")' +
		'.replaceAll("' + backslash + 't","' +
		backslash + backslash + 't")})';
	const tryEntry = templateFunction.entries.find(entry => entry &&
		entry.type === 'TemplateLiteral' && new RegExp('^' + tryPattern.source + '$')
			.test(result.slice(entry.start, entry.end)));
	const transformedEntry = result.slice(tryEntry.start, tryEntry.end).replace(tryPattern,
		function (_match, prefix, objectName, suffix) {
			return prefix + helperSource + '(' + objectName + '.tryExec)' +
				suffix;
		});

	return result.slice(0, tryEntry.start) + transformedEntry + result.slice(tryEntry.end);
}

FILE_MANAGER_ENTRIES_PATCH
	then
		echo 'Error: Linux file-manager entry patch failed;' \
			'refusing to ship an app without the feature' >&2
		return 1
	fi

	echo 'Linux file-manager entry generation enabled'
}
