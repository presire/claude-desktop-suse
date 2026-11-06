'use strict';

// Build-only parser. Resolve from the build work directory, or the repository
// for standalone patch tests; never fall back to a different parser version.
const acorn = require(require.resolve('acorn', {
	paths: [process.env.PATCH_WORK_DIR || __dirname, __dirname],
}));
if (acorn.version !== '8.19.0') {
	throw new Error('file-manager patch requires acorn@8.19.0');
}

function analyze(code) {
	const comments = [];
	const tree = acorn.parse(code, {
		ecmaVersion: 2026,
		sourceType: 'commonjs',
		onComment: comments,
	});
	const functions = [], calls = [], templates = [], strings = [];
	const pending = [tree];
	while (pending.length) {
		const node = pending.pop();
		if (node.type === 'FunctionDeclaration' || node.type === 'FunctionExpression') {
			functions.push(node);
		}
		if (node.type === 'CallExpression') calls.push(node);
		if (node.type === 'TemplateLiteral') templates.push(node);
		if ((node.type === 'Literal' || node.type === 'TemplateLiteral') &&
			typeof stringValue(node) === 'string') strings.push(node);
		for (const value of Object.values(node)) {
			if (Array.isArray(value)) {
				for (const child of value) {
					if (child && typeof child.type === 'string') pending.push(child);
				}
			} else if (value && typeof value.type === 'string') {
				pending.push(value);
			}
		}
	}
	return { functions, calls, templates, strings, comments };
}

function stringValue(node) {
	if (node.type === 'Literal') return node.value;
	if (node.type === 'TemplateLiteral' && node.expressions.length === 0) {
		return node.quasis[0].value.cooked;
	}
	return undefined;
}

// Only the direct array returned through .join("\n") is a menu. A literal
// hidden inside a nested expression, comment or string cannot identify it.
function menuAt(analysis, before) {
	const candidates = [];
	for (const fn of analysis.functions) {
		if (fn.body.body.length !== 1 || fn.body.body[0].type !== 'ReturnStatement') continue;
		const call = fn.body.body[0].argument;
		if (!call || call.type !== 'CallExpression' || call.optional ||
			call.callee.type !== 'MemberExpression' || call.callee.computed ||
			call.callee.property.name !== 'join' || call.arguments.length !== 1 ||
			stringValue(call.arguments[0]) !== '\n' ||
			call.callee.object.type !== 'ArrayExpression') continue;
		const entries = call.callee.object.elements;
		const values = entries.filter(Boolean).map(entry =>
			entry.type === 'TemplateLiteral' ? entry.quasis[0].value.cooked : stringValue(entry));
		// KeyFile accepts whitespace around keys and embedded newlines start
		// new entries. Count decoded keys, rather than raw source prefixes.
		const keys = values.filter(value => typeof value === 'string').flatMap(value =>
			[...value.matchAll(/^\s*(TryExec|Exec)\s*=/gm)].map(match => match[1]));
		if (['TryExec', 'Exec'].some(key => keys.filter(value => value === key).length !== 1)) continue;
		if (!entries.some(entry => entry && entry.start <= before && entry.end > before &&
			stringValue(entry) === 'X-KDE-ServiceTypes=KonqPopupMenu/Plugin')) continue;
		// Comments with function-shaped source are outside the supported menu
		// contract. Reject conservatively instead of guessing their intent.
		if (analysis.comments.some(comment => comment.start > fn.start &&
			comment.end < fn.end && /\bfunction\b/.test(comment.value))) continue;
		candidates.push({ node: fn, entries });
	}
	return candidates.length === 1 ? candidates[0] : null;
}

module.exports = { analyze, menuAt, stringValue };
