# shellcheck shell=bash
#===============================================================================
# virtiofsd resolution: un-gate the bundled fallback so Cowork's KVM
# stack resolves virtiofsd on every distro, not just Ubuntu 22.x.
#
# The official client resolves virtiofsd from exactly two absolute
# paths (/usr/libexec/virtiofsd, /usr/bin/virtiofsd) and only falls
# back to its own bundled copy (resources/virtiofsd) when
# /etc/os-release says ID=ubuntu with VERSION_ID 22.x. openSUSE,
# Arch, Debian, and Ubuntu derivatives all fail the os-release check
# — on all of them virtiofsdPath resolves null and the support
# evaluator reports "Cowork requires QEMU" with everything installed
# (#771, #772).
#
# Minimal fix: drop the os-release condition on the bundled fallback.
# System paths stay preferred; the version-matched binary Anthropic
# already ships covers everyone else. The probe array is deliberately
# NOT extended with distro-specific paths — on qemu <8 hosts
# /usr/lib/qemu/virtiofsd can be the legacy C implementation whose
# CLI is incompatible with how the client spawns the Rust virtiofsd.
#
# Sourced by: build.sh
# Sourced globals: app_staging_dir (via caller's cd)
# Modifies globals: (none)
#===============================================================================

patch_virtiofsd_probe() {
	echo 'Patching virtiofsd resolution (bundled fallback un-gate)...'
	local index_js='app.asar.contents/.vite/build/index.js'

	# Anchored on the probe-path array literal (path strings survive
	# minification); the gate rewrite happens in a bounded window after
	# it so the shape-matched expression can't hit an unrelated site.
	# An anchor miss emits a WARNING but does NOT fail the build: the
	# SUSE fork uses a Windows-installer-derived bundle whose Cowork
	# section may differ from the official Linux .deb, so absence is
	# not necessarily a regression.
	if INDEX_JS="$index_js" node << 'VIRTIOFSD_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
if (!fs.existsSync(indexJs)) {
    console.log('  SKIP: ' + indexJs + ' not found');
    process.exit(2);
}
let code = fs.readFileSync(indexJs, 'utf8');

const arrRe =
    /\[\s*"\/usr\/libexec\/virtiofsd"\s*,\s*"\/usr\/bin\/virtiofsd"\s*\]/g;
const arrMatches = [...code.matchAll(arrRe)];
if (arrMatches.length === 0) {
    console.log('  SKIP: virtiofsd probe-path array not found in bundle');
    process.exit(2);
}
if (arrMatches.length !== 1) {
    console.log('  WARNING: expected 1 virtiofsd probe-path array, found ' +
        arrMatches.length);
    process.exit(1);
}

const start = arrMatches[0].index + arrMatches[0][0].length;
const region = code.substring(start, start + 1200);

const gatedRe =
    /return\s+([\w$]+)\s*\|\|\s*\(\s*[\w$]+\s*\?\s*([\w$]+\(\s*[\w$]+\s*,\s*[\w$]+\.constants\.X_OK\s*\))\s*:\s*null\s*\)/;
const ungatedRe =
    /return\s+([\w$]+)\s*\|\|\s*[\w$]+\(\s*[\w$]+\s*,\s*[\w$]+\.constants\.X_OK\s*\)/;

const gated = region.match(gatedRe);
if (gated) {
    const abs = start + gated.index;
    const replacement = 'return ' + gated[1] + '||' + gated[2];
    code = code.substring(0, abs) + replacement +
        code.substring(abs + gated[0].length);
    fs.writeFileSync(indexJs, code);
    console.log('  Un-gated bundled virtiofsd fallback: ' + gated[2]);
} else if (ungatedRe.test(region)) {
    console.log('  Bundled virtiofsd fallback already un-gated');
} else {
    console.log('  WARNING: bundled-fallback gate not found near the ' +
        'probe array — upstream reshaped the resolver');
    process.exit(1);
}
VIRTIOFSD_PATCH
	then
		echo 'virtiofsd probe patch applied'
	elif [[ $? -eq 2 ]]
	then
		echo 'virtiofsd probe patch skipped (anchor not present in this bundle)'
	else
		echo 'WARNING: virtiofsd probe patch failed. Cowork may report' \
			'"requires QEMU" on non-Ubuntu hosts with a complete KVM' \
			'stack (#771, #772).' >&2
	fi
	echo '##############################################################'
}
