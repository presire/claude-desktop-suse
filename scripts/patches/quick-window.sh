#===============================================================================
# Quick-window patches: KDE-gated blur/focus workarounds for the pop-up menu
# so the main window reappears after quick-entry submit.
#
# Sourced by: build.sh
# Sourced globals: (none — all context is captured from index.js at runtime)
# Modifies globals: (none)
#===============================================================================

# Quote class: newer bundles re-emit string literals as backtick
# templates, so a bare " in an anchor matches nothing (Debian #820).
_QW_Q='[`"'"'"']'

patch_quick_window() {
	echo 'Patching quick window for Linux...'
	local index_js="$main_js"

	# Anchor on the full setAlwaysOnTop shape, not on "pop-up-menu"
	# alone — the bare literal can also occur in a sibling chunk that
	# has no call to rewrite. The QUICK_ENTRY tag (the window-kind
	# enum key passed just before the call; a property name, so the
	# minifier keeps it) is required when present: newer bundles ship
	# a second pop-up window with the identical setAlwaysOnTop call
	# (Debian #919). The gap allows an extra call between the tag and
	# the rewrite target but not a statement boundary.
	local tagged_re="QUICK_ENTRY\\)[^;]{0,200}?"
	tagged_re+="\\K[\$\\w]+(?=\\.setAlwaysOnTop\\(\\s*!0\\s*,\\s*"
	tagged_re+="${_QW_Q}pop-up-menu${_QW_Q}\\s*\\))"
	# Legacy fallback for older bundles that predate the QUICK_ENTRY
	# tag: the bare call shape with quote class and whitespace
	# tolerance. Used ONLY when the tagged shape is absent.
	local bare_re="[\$\\w]+(?=\\.setAlwaysOnTop\\(\\s*!0\\s*,\\s*"
	bare_re+="${_QW_Q}pop-up-menu${_QW_Q}\\s*\\))"

	# Extract the quick window variable name, e.g.:
	#   tagged: Li.QUICK_ENTRY),Sa.setAlwaysOnTop(!0,`pop-up-menu`)
	#   legacy: Sa.setAlwaysOnTop(!0,"pop-up-menu")
	local anchor_re=''
	if grep -qP -- "$tagged_re" "$index_js"; then
		if ! _assert_single_anchor_match "$index_js" \
			"$tagged_re" 'quick-window setAlwaysOnTop (QUICK_ENTRY-tagged)'; then
			echo '##############################################################'
			return
		fi
		anchor_re="$tagged_re"
	elif grep -qP -- "$bare_re" "$index_js"; then
		if ! _assert_single_anchor_match "$index_js" \
			"$bare_re" 'quick-window setAlwaysOnTop (legacy)'; then
			echo '##############################################################'
			return
		fi
		anchor_re="$bare_re"
	else
		echo 'WARNING: Could not extract quick window variable name'
		echo '##############################################################'
		return
	fi
	local quick_var
	quick_var=$(grep -oP -- "$anchor_re" "$index_js" | head -1)
	if [[ -z $quick_var ]]; then
		echo 'WARNING: Could not extract quick window variable name'
		echo '##############################################################'
		return
	fi
	echo "  Found quick window variable: $quick_var"

	local quick_var_re="${quick_var//\$/\\$}"

	# Part 1: Add blur() before hide() on the quick window so that
	# isFocused() returns false after hiding (Electron Linux bug on KDE).
	# The hide call sits after || (e.g. GUARD()||VAR.hide()), so both
	# calls must be wrapped in parens to preserve short-circuit semantics.
	# Gated to KDE only: on GNOME/Ubuntu the blur() regresses quick entry
	# (see #393), and the focus-stale bug doesn't manifest there.
	local de_check='(process.env.XDG_CURRENT_DESKTOP||"")'
	de_check+='.toLowerCase().includes("kde")'
	if grep -qF "${quick_var}.blur(),${quick_var}.hide()" "$index_js"; then
		echo '  Quick window blur already patched'
	elif grep -qP "\|\|\s*${quick_var_re}\.hide\(\)" "$index_js"; then
		sed -i -E \
			"s/\|\|\s*${quick_var_re}\.hide\(\)/||(${de_check}?(${quick_var}.blur(),${quick_var}.hide()):${quick_var}.hide())/g" \
			"$index_js"
		echo '  Added KDE-gated blur() before hide() on quick window'
	else
		echo '  WARNING: Could not find quick window hide() call'
	fi

	# Part 2: Fix main window not appearing after quick entry submit.
	# On KDE, isFocused() can return stale true after hiding, causing
	# FOCUS_CHECK()||Lt.show() to skip the show. Gate the visibility-check
	# replacement to KDE only: on GNOME, the original focus check works
	# and replacing it regresses quick entry (see #393).
	if INDEX_JS="$index_js" node << 'QUICK_WINDOW_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');
let patchCount = 0;

// Both the focus check and the window handle are captured from the
// call site itself — the only place both are spelled the way they are
// used. An earlier revision resolved them definition-side: find
// `isWindowFocused:()=>!!X()`, then hunt a sibling visibility helper
// `function Y(){return!...isVisible()}` within 500 chars of X's
// definition. That broke on 2.37337.1: the sibling sits at offset 497
// with a body longer than the remaining window (`function PSe(){
// return!B||B.isDestroyed()?!1:B.isVisible()}` — a "near ko"
// near-miss), and the helper additionally exists as an arrow property
// (`isWindowVisible:()=>!!(B&&!B.isDestroyed()&&B.isVisible())`)
// that no `function`-declaration regex can name. Capturing at the
// call site drops both fragile lookups (the same conclusion Debian
// reached for 1.26832.0, where the pair moved into a shared module
// and the call site sees only import bindings).
// Whitespace is allowed around the dots of a dotted handle and the
// lookbehinds forbid starting inside one, so `exports . focused ()`
// is captured whole instead of as its trailing `focused` member.
// Captures are whitespace-stripped (norm) before being compared or
// written back.
const win = String.raw`(?<![\w$])(?<!\.\s*)[\w$]+(?:\s*\.\s*[\w$]+)*`;
const norm = (s) => s.replace(/\s+/g, '');

// Anchor on the unique QuickEntry log string to patch only the right
// site. The second anchor this script used to carry, 'Navigating to
// existing chat', is absent from both 1.44121.4 and 2.37337.1 (and
// from Debian's 1.24012.11/1.26832.0), so it only ever produced a
// standing WARNING — dropped rather than kept as noise.
const anchors = [
    'Creating new chat with submit_quick_entry',
];
// Sites already carrying the gate from a previous run. Counted
// separately from patchCount so a re-run over a fully patched bundle
// stays silent instead of emitting a WARNING that nothing was patched —
// there was nothing left to patch, which is success, not a miss.
let alreadyCount = 0;
// `\s*` between every token: a re-minified or prettified bundle may
// write `ko () || B.show ()` with the same meaning.
const ws = String.raw`\s*`;
const call = (name) => name + ws + String.raw`\(` + ws + String.raw`\)`;
const member = (obj, prop) => obj + ws + String.raw`\.` + ws + prop;
// matches: <focusCall>()||<win>.show(). Both sides are captured:
// <focusCall> is `ko` on 2.37337.1 and `za` on 1.44121.4; <win>
// is the bare local `B` / `z` there, but the capture tolerates
// dotted handles too (exports.mainWindow, or a module binding
// like i.f — capture the whole handle so the rewrite keeps the
// .show() call pointed at the real window).
const rawRe = new RegExp(call(`(${win})`) + ws + String.raw`\|\|` + ws +
    call(member(`(${win})`, 'show')), 'g');
// The complete gate a previous run injected (see newStr below), with
// the window handle captured at all four uses so they can be required
// to agree. Recognising the whole shape, instead of any mention of
// XDG_CURRENT_DESKTOP near the anchor, keeps an unrelated mention from
// passing for "already patched" while the raw call stays unpatched.
const patchedRe = new RegExp(
    String.raw`\(` + ws + String.raw`\(` + ws +
    member(member('process', 'env'), 'XDG_CURRENT_DESKTOP') + ws +
    String.raw`\|\|` + ws + '""' + ws + String.raw`\)` + ws +
    call(String.raw`\.` + ws + 'toLowerCase') + ws +
    String.raw`\.` + ws + 'includes' + ws + String.raw`\(` + ws +
    '"kde"' + ws + String.raw`\)` + ws + String.raw`\?` + ws +
    String.raw`\(` + ws + '!' + ws + `(${win})` + ws + String.raw`\|\|` +
    ws + call(member(`(${win})`, 'isDestroyed')) + ws + String.raw`\?` +
    ws + '!1' + ws + ':' + ws + call(member(`(${win})`, 'isVisible')) +
    ws + String.raw`\)` + ws + ':' + ws + call(`(${win})`) + ws +
    String.raw`\)` + ws + String.raw`\|\|` + ws +
    call(member(`(${win})`, 'show')), 'g');
for (const anchor of anchors) {
    const anchorIdx = code.indexOf(anchor);
    if (anchorIdx === -1) {
        console.log('  WARNING: anchor not found: ' + anchor);
        continue;
    }
    if (code.indexOf(anchor, anchorIdx + 1) !== -1) {
        console.log('  WARNING: anchor "' + anchor + '" occurs more than' +
            ' once — skipping to avoid patching the wrong site');
        continue;
    }
    // Search region after anchor (1500 chars covers promise chains)
    const region = code.substring(anchorIdx, anchorIdx + 1500);
    const rawMatches = [...region.matchAll(rawRe)];
    const patchedMatches = [...region.matchAll(patchedRe)].filter(
        (m) => norm(m[1]) === norm(m[2]) && norm(m[2]) === norm(m[3]) &&
            norm(m[3]) === norm(m[5]));
    if (rawMatches.length === 0 && patchedMatches.length === 1) {
        console.log('  Quick entry show() already patched near "' +
            anchor.substring(0, 30) + '..."');
        alreadyCount++;
        continue;
    }
    // Exactly one raw site and no patched one: patching the first of
    // several would hit an arbitrary location, and a mix of raw and
    // patched sites is a shape this patch was not written for, so both
    // warn and skip instead (same policy as the shell-side anchor
    // assertions above).
    if (rawMatches.length === 1 && patchedMatches.length === 0) {
        const oldStr = rawMatches[0][0];
        const focusCall = norm(rawMatches[0][1]);
        const mainWin = norm(rawMatches[0][2]);
        // Gate the visibility check to KDE only; fall back to original
        // focus check on GNOME/other so #390 doesn't regress them (#393).
        // The visibility test is inlined from the captured handle
        // rather than calling upstream's helper, which is no longer
        // nameable from here (arrow property on 2.37337.1). Inlining
        // `(!win||win.isDestroyed()?!1:win.isVisible())` runs the same
        // test against the window being shown: a hidden window whose
        // webContents still reports focus now gets show() instead of
        // being skipped, which is the safe direction for the #390
        // symptom (show() skipped), and the null/destroyed case never
        // reaches it — the surrounding upstream guard
        // (`!win||win.isDestroyed()||(...)`) short-circuits first.
        const deCheck = '(process.env.XDG_CURRENT_DESKTOP||"")' +
            '.toLowerCase().includes("kde")';
        const visible = '(!' + mainWin + '||' + mainWin +
            '.isDestroyed()?!1:' + mainWin + '.isVisible())';
        // Built by concatenation, never through String.replace(): a
        // captured handle can contain `$`, which replace() would
        // reinterpret as a substitution pattern.
        const newStr = '(' + deCheck + '?' + visible + ':' +
            focusCall + '())||' + mainWin + '.show()';
        const absIdx = anchorIdx + rawMatches[0].index;
        code = code.substring(0, absIdx) + newStr +
            code.substring(absIdx + oldStr.length);
        console.log('  KDE-gated ' + focusCall + '()/' + mainWin +
            '.isVisible() for show() near "' + anchor.substring(0, 30) + '..."');
        patchCount++;
    } else if (rawMatches.length === 0 && patchedMatches.length === 0) {
        console.log('  WARNING: show() pattern not found near "' +
            anchor + '"');
    } else {
        console.log('  WARNING: ' + rawMatches.length + ' raw and ' +
            patchedMatches.length + ' patched show() sites near "' +
            anchor + '" — skipping to avoid patching the wrong one');
    }
}

if (patchCount > 0) {
    fs.writeFileSync(indexJs, code);
    console.log('  Patched ' + patchCount +
        ' quick entry show() calls to use visibility check');
} else if (alreadyCount === anchors.length) {
    console.log('  Quick entry show() calls already patched (' +
        alreadyCount + '/' + anchors.length + ')');
} else {
    console.log('  WARNING: No quick entry show() calls patched');
}
QUICK_WINDOW_PATCH
	then
		echo 'Quick window patches applied'
	else
		echo 'WARNING: Quick window show patch failed' >&2
	fi
	echo '##############################################################'
}
