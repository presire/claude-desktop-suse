#!/usr/bin/env node
// Fetches the Electron prebuilt binary into node_modules/electron/dist/.
//
// electron@42.0.0 (2026-05-06) removed the postinstall script that
// historically populated dist/ during `npm install`. This helper restores
// that behavior using @electron/get plus the Electron-maintained hardened
// extractor, so the rest of the build pipeline (which depends on the dist/
// layout) keeps working.
//
// The extractor is @electron-internal/extract-zip rather than the
// unmaintained extract-zip package: upstream extract-zip (<=2.0.1) carries
// two unfixed symlink-traversal advisories (GHSA-jmr9-qjv8-65gv and
// GHSA-7pqw-9j4j-h8q3), while the fork reimplements extraction on a Rust
// core with path-containment checks. The fork is ESM-only, so it is
// resolved from the work dir and loaded with a dynamic import().
//
// @electron/get 5.x is ESM-only too. require() of it throws ERR_REQUIRE_ESM
// on the Node 20 that setup_nodejs installs (require(esm) needs >= 22.12),
// so it is loaded the same way.
//
// Run from the directory containing node_modules/electron. Reads the
// installed electron version from its package.json and downloads the
// matching binary for the host platform/arch.
//
// See: https://github.com/aaddrick/claude-desktop-debian/issues/584

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const { pathToFileURL } = require('node:url');

const EXTRACTOR_PACKAGE = '@electron-internal/extract-zip';
const ELECTRON_GET_PACKAGE = '@electron/get';

// Resolve the ESM-only extractor from the work dir and return its extract
// function. Fails loudly so a missing or reshaped package is never mistaken
// for a successful fetch.
async function loadExtractor(workDirRequire) {
	let extractorPath;
	try {
		extractorPath = workDirRequire.resolve(EXTRACTOR_PACKAGE);
	} catch (err) {
		throw new Error(
			`Could not resolve ${EXTRACTOR_PACKAGE} from the work ` +
			`directory: ${err.message}. Install it there (see ` +
			'scripts/setup/dependencies.sh).',
		);
	}

	const extractorNs = await import(pathToFileURL(extractorPath).href);
	const extract = extractorNs.extract ?? extractorNs.default;
	if (typeof extract !== 'function') {
		throw new Error(
			`${EXTRACTOR_PACKAGE} at ${extractorPath} does not export ` +
			'an extract function.',
		);
	}

	return { extract, extractorPath };
}

// Resolve @electron/get from the work dir and return its downloadArtifact.
// A dynamic import() loads both the ESM 5.x releases and older CommonJS ones.
async function loadDownloadArtifact(workDirRequire) {
	let getPath;
	try {
		getPath = workDirRequire.resolve(ELECTRON_GET_PACKAGE);
	} catch (err) {
		throw new Error(
			`Could not resolve ${ELECTRON_GET_PACKAGE} from the work ` +
			`directory: ${err.message}. Install it there (see ` +
			'scripts/setup/dependencies.sh).',
		);
	}

	const getNs = await import(pathToFileURL(getPath).href);
	const downloadArtifact =
		getNs.downloadArtifact ?? getNs.default?.downloadArtifact;
	if (typeof downloadArtifact !== 'function') {
		throw new Error(
			`${ELECTRON_GET_PACKAGE} at ${getPath} does not export ` +
			'downloadArtifact.',
		);
	}

	return downloadArtifact;
}

async function main() {
	const cwd = process.cwd();
	const electronModuleDir = path.join(cwd, 'node_modules', 'electron');
	const distDir = path.join(electronModuleDir, 'dist');

	if (!fs.existsSync(electronModuleDir)) {
		throw new Error(
			`Electron module not found at ${electronModuleDir}; ` +
			"run 'npm install electron' first.",
		);
	}

	const pkgPath = path.join(electronModuleDir, 'package.json');
	const { version } = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
	if (!version) {
		throw new Error(`Could not read version from ${pkgPath}`);
	}

	const platform = 'linux';
	// node's process.arch values map cleanly to electron release archs,
	// except 'arm' which electron publishes as 'armv7l'.
	const arch = process.arch === 'arm' ? 'armv7l' : process.arch;

	const supportedArchs = ['x64', 'arm64', 'armv7l', 'ia32'];
	if (!supportedArchs.includes(arch)) {
		throw new Error(
			`Unsupported architecture: ${arch}. ` +
			`Electron publishes Linux binaries for ${supportedArchs.join(', ')}.`,
		);
	}

	// Resolve @electron/get and the extractor from the work-dir's
	// node_modules. The script lives at scripts/setup/ so a plain
	// require() walks up from there and never sees work_dir/.
	const workDirRequire = createRequire(path.join(cwd, 'package.json'));
	const downloadArtifact = await loadDownloadArtifact(workDirRequire);
	const { extract, extractorPath } = await loadExtractor(workDirRequire);

	console.log(`Fetching electron@${version} for ${platform}-${arch}...`);
	const zipPath = await downloadArtifact({
		version,
		platform,
		arch,
		artifactName: 'electron',
	});

	console.log(`Extracting ${zipPath} into ${distDir} (${extractorPath})`);
	fs.mkdirSync(distDir, { recursive: true });
	await extract(zipPath, { dir: distDir });

	const electronBin = path.join(distDir, 'electron');
	if (fs.existsSync(electronBin)) {
		fs.chmodSync(electronBin, 0o755);
	}

	console.log('Electron binary fetched and extracted successfully.');
}

if (require.main === module) {
	main().catch((err) => {
		console.error(err && err.stack ? err.stack : err);
		process.exit(1);
	});
}

module.exports = {
	loadExtractor,
	loadDownloadArtifact,
	EXTRACTOR_PACKAGE,
	ELECTRON_GET_PACKAGE,
};
