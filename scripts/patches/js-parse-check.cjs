'use strict';

// Patch-stage syntax gate.
//   snapshot <build_dir> <out.json>  record a SHA-256 per *.js before patching
//   check    <build_dir> <in.json>   parse every *.js that changed or appeared
// A patch that splices broken JavaScript into one chunk would otherwise only
// surface when Electron loads that chunk at run time. Every chunk of the
// pristine Windows bundle parses as CommonJS with the pinned acorn, so the
// same parser options apply to all of them.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { acorn } = require('./file-manager-source.cjs');

function digests(dir) {
	const out = {};
	for (const rel of fs.readdirSync(dir, { recursive: true }).sort()) {
		const file = path.join(dir, rel);
		if (!rel.endsWith('.js') || !fs.statSync(file).isFile()) continue;
		out[rel] = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
	}
	return out;
}

const [mode, dir, state] = process.argv.slice(2);
if (!['snapshot', 'check'].includes(mode) || !dir || !state) {
	console.error('usage: js-parse-check.cjs snapshot|check <build_dir> <state.json>');
	process.exit(2);
}

if (mode === 'snapshot') {
	fs.writeFileSync(state, JSON.stringify(digests(dir)));
	process.exit(0);
}

const before = JSON.parse(fs.readFileSync(state, 'utf8'));
const changed = Object.entries(digests(dir))
	.filter(([rel, sum]) => before[rel] !== sum).map(([rel]) => rel);
const failures = [];
for (const rel of changed) {
	try {
		acorn.parse(fs.readFileSync(path.join(dir, rel), 'utf8'),
			{ ecmaVersion: 2026, sourceType: 'commonjs' });
	} catch (error) {
		failures.push(`${rel}: ${error.message}`);
	}
}
if (failures.length) {
	console.error('JS parse check: the patch stage left unparsable JavaScript:');
	for (const line of failures) console.error(`  ${line}`);
	process.exit(1);
}
console.log(`JS parse check: ${changed.length} patched file(s) parse`);
