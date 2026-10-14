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
# Sourced globals: main_js (resolved by app-asar.sh via _resolve_main_js),
#                  app_staging_dir (via caller's cd)
# Modifies globals: (none)
#===============================================================================

patch_virtiofsd_probe() {
	echo 'Patching virtiofsd resolution (bundled fallback un-gate)...'
	# shellcheck disable=SC2154  # main_js is a sourced global set by app-asar.sh
	local index_js="$main_js"

	# Anchored on the probe-path array literal (path strings survive
	# minification); the gate rewrite happens in a bounded window after
	# it so the shape-matched expression can't hit an unrelated site.
	# An anchor miss emits a WARNING but does NOT fail the build: the
	# SUSE fork uses a Windows-installer-derived bundle whose Cowork
	# section may differ from the official Linux .deb, so absence is
	# not necessarily a regression. A duplicated array (more than one
	# match) likewise WARNS and skips instead of rewriting an
	# arbitrary site.
	#
	# Quote class: newer bundles re-emit string literals as backtick
	# templates, so a bare " in the array anchor matches nothing
	# (Debian #820).
	local arr_anchor_re="\\[\\s*${_ANCHOR_Q}/usr/libexec/virtiofsd${_ANCHOR_Q}"
	arr_anchor_re+="\\s*,\\s*${_ANCHOR_Q}/usr/bin/virtiofsd${_ANCHOR_Q}\\s*\\]"
	# Capture the anchor diagnostic instead of letting it print: when
	# the miss is explained by the not-needed shape below, printing
	# its WARNING alongside the informational skip would defeat the
	# purpose (one explained skip, not a warning plus an excuse). A
	# genuinely unrecognised shape re-emits the diagnostic verbatim.
	local anchor_diag anchor_ok
	anchor_diag=$(_assert_single_anchor_match "$index_js" \
		"$arr_anchor_re" 'virtiofsd probe array' 2>&1)
	anchor_ok=$?
	if [[ $anchor_ok -eq 0 ]]; then
		: # Probe array present exactly once — fall through to the
		# un-gate rewrite below.
	elif grep -qF 'Missing HCS services' "$index_js" \
		&& ! grep -rq 'virtiofsd' "${index_js%/*}"; then
		# Not needed on this bundle lineage (2.37337.1 shape): the
		# Cowork support evaluator here only gates win32 (HCS —
		# `Missing HCS services: ... unsupportedCode:
		# "hcs_not_available"`) and darwin, then falls through to
		# {status:"supported"} — the Linux KVM probe this patch
		# un-gates (no qemuPath/firmwarePath/virtiofsdPath
		# anywhere; verified absent from both 1.44121.4 and
		# 2.37337.1) was never compiled into these Windows-derived
		# bundles, and Linux Cowork is provided by SUSE's own
		# patch_cowork_linux + cowork-vm-service.js stack instead.
		# The binary name is load-bearing — any probe or spawn of
		# it must spell `virtiofsd` — so its absence from the whole
		# build tree proves there is nothing to un-gate. This is an
		# informational skip, not a WARNING: absence here is the
		# expected lineage shape, not an anchor miss.
		echo '  Upstream evaluator is win32/darwin-gated with no' \
			'virtiofsd probe in this bundle — patch not needed, skipping'
		echo '##############################################################'
		return
	else
		if [[ -n $anchor_diag ]]; then
			printf '%s\n' "$anchor_diag" >&2
		fi
		echo 'virtiofsd probe patch skipped (anchor not present' \
			'unambiguously in this bundle)'
		echo '##############################################################'
		return
	fi
	if INDEX_JS="$index_js" node << 'VIRTIOFSD_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
if (!fs.existsSync(indexJs)) {
    console.log('  SKIP: ' + indexJs + ' not found');
    process.exit(2);
}
let code = fs.readFileSync(indexJs, 'utf8');

// q(): match a literal under any delimiter. Newer bundles re-emit
// nearly every string as a backtick template, so a bare " here
// matches nothing (Debian #820).
const q = s => '[`"\']' + s + '[`"\']';

// The client's virtiofsd probe-path array, whitespace-tolerant for
// beautified bundles:
//   [`/usr/libexec/virtiofsd`,`/usr/bin/virtiofsd`]
const arrRe = new RegExp(
    '\\[\\s*' + q('\\/usr\\/libexec\\/virtiofsd') + '\\s*,\\s*' +
    q('\\/usr\\/bin\\/virtiofsd') + '\\s*\\]', 'g');
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

// Gated resolver tail (minified):
//   older:  return t||(e?loe(Won,Y.constants.X_OK):null)
//   newer:  return await FT(kT)||(e?IT(TT,N.constants.X_OK):null)
// The left operand is the system-path hit. It used to be a bare
// identifier holding an already-awaited result; newer bundles inline
// the call, so it is now an `await F(x)` expression. Accept either
// shape — anything else here would be a different code path, not a
// re-minified one. The middle operand is the distro check and the
// captured call is the bundled copy. Identifiers are captured, not
// hardcoded, since they change every release.
const lhs = String.raw`(await\s+[\w$]+\(\s*[\w$]*\s*\)|[\w$]+)`;
const bundled =
    String.raw`([\w$]+\(\s*[\w$]+\s*,\s*[\w$]+\.constants\.X_OK\s*\))`;
const gatedRe = new RegExp(
    `return\\s+${lhs}\\s*\\|\\|\\s*\\(\\s*[\\w$]+\\s*\\?\\s*` +
    `${bundled}\\s*:\\s*null\\s*\\)`);
const ungatedRe = new RegExp(
    `return\\s+${lhs}\\s*\\|\\|\\s*` +
    String.raw`[\w$]+\(\s*[\w$]+\s*,\s*[\w$]+\.constants\.X_OK\s*\)`);

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
