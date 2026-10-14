#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031  # Literal JS; Bats uses subshells
#
# patch-anchors.bats
#
# Anchor robustness for patch_quick_window, patch_org_plugins_path and
# patch_virtiofsd_probe, ported from Debian's #820/#821/#919 fixes:
#
#   * quote class [`"'] — newer bundles re-emit string literals as
#     backtick templates, so a bare " anchor matches nothing;
#   * QUICK_ENTRY tag requirement on the setAlwaysOnTop anchor, with a
#     legacy fallback for older bundles that predate the tag;
#   * virtiofsd `await F(x)` vs bare-identifier left-operand shapes;
#   * exactly-one-match assertion (WARN + skip, never patch arbitrary);
#   * second-run byte identity;
#   * PATCH_STAGE_RERUN digest helpers detecting a non-idempotent patch.
#
# Fixtures are synthetic but model the minified shapes found in the
# Debian/SUSE bundles and comments (double-quote legacy emission,
# backtick re-emission, single-quote variation).

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
COMMON_SH="$SCRIPT_DIR/../scripts/patches/_common.sh"
QW_SH="$SCRIPT_DIR/../scripts/patches/quick-window.sh"
ORG_SH="$SCRIPT_DIR/../scripts/patches/org-plugins.sh"
VFSD_SH="$SCRIPT_DIR/../scripts/patches/virtiofsd-probe.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/_common.sh
	source "$COMMON_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/quick-window.sh
	source "$QW_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/org-plugins.sh
	source "$ORG_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/virtiofsd-probe.sh
	source "$VFSD_SH"
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

write_fixture() {
	printf '%s' "$1" > "$TEST_TMP/fixture.js"
	main_js="$TEST_TMP/fixture.js"
}

sha_of() {
	sha256sum "$1" | cut -d' ' -f1
}

# Part-2 tail shared by the quick-window fixtures: the QuickEntry log
# anchor and a show() site through the dotted exports.mainWindow
# handle. (The focus/visibility helpers are deliberately NOT modelled
# here: part 2 captures both sides at the call site, so it needs no
# definition-side names.)
QW_TAIL='function n1(){return!0}isWindowFocused:()=>!!n1();_.info("[QuickEntry] Navigating to existing chat");_.info("[QuickEntry] Creating new chat with submit_quick_entry");n1()||exports.mainWindow.show()'

# =============================================================================
# quick-window part 1: QUICK_ENTRY-tagged anchor + legacy fallback
# =============================================================================

@test "quick-window: tagged double-quoted shape extracts the var" {
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'"$QW_TAIL"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: er'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
}

@test "quick-window: tagged backtick shape extracts the var" {
	write_fixture 'n.n.QUICK_ENTRY),R.setAlwaysOnTop(!0,`pop-up-menu`),R.webContents;N6()||R.hide();'"$QW_TAIL"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: R'* ]]
	grep -qF 'R.blur(),R.hide()' "$main_js"
}

@test "quick-window: tagged single-quoted shape extracts the var" {
	write_fixture "Il.QUICK_ENTRY),Sa.setAlwaysOnTop(!0,'pop-up-menu'),Sa.webContents;N6()||Sa.hide();${QW_TAIL}"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: Sa'* ]]
	grep -qF 'Sa.blur(),Sa.hide()' "$main_js"
}

@test "quick-window: legacy bare shape still works when the tag is absent" {
	write_fixture 'Sa.setAlwaysOnTop(!0,"pop-up-menu"),Sa.webContents;N6()||Sa.hide();'"$QW_TAIL"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: Sa'* ]]
	grep -qF 'Sa.blur(),Sa.hide()' "$main_js"
}

@test "quick-window: whitespace around the call args is tolerated" {
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop( !0 , "pop-up-menu" ),er.webContents;N6()||er.hide();'"$QW_TAIL"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: er'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
}

@test "quick-window: duplicate tagged anchors warn and skip" {
	write_fixture 'Li.QUICK_ENTRY),mY.setAlwaysOnTop(!0,"pop-up-menu"),a;Li.QUICK_ENTRY),nZ.setAlwaysOnTop(!0,"pop-up-menu"),b;N6()||mY.hide();'"$QW_TAIL"
	local before
	before=$(sha_of "$main_js")
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'matched 2 sites'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "quick-window: second run is byte-identical with no WARNING" {
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'"$QW_TAIL"
	patch_quick_window >/dev/null
	local before
	before=$(sha_of "$main_js")
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'already patched'* ]]
	[[ $output != *'WARNING'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "quick-window: dotted show handle is captured whole" {
	# exports.mainWindow must survive as the .show() receiver; a
	# capture restricted to bare identifiers rewrites the wrong target.
	# The visibility test is inlined from the captured handle (there
	# is no callable upstream helper at the call site on 2.37337.1).
	# (Fragment fixture, so no node --check: it is not parseable JS
	# on its own.)
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'"$QW_TAIL"
	patch_quick_window >/dev/null
	grep -qF '(!exports.mainWindow||exports.mainWindow.isDestroyed()?!1:exports.mainWindow.isVisible())' "$main_js"
	grep -qF 'n1())||exports.mainWindow.show()' "$main_js"
}

@test "quick-window: 2.37337.1 shape with extra call in the tag gap" {
	# The setAlwaysOnTop call carries an extra call between the
	# QUICK_ENTRY tag and the rewrite target (t0r(AJ) here), and the
	# submit path calls ko()||B.show() while the visibility helper
	# lives only as an arrow property — the definition-side lookup
	# cannot name it, so the call site is captured instead.
	write_fixture 'Ni(AJ.webContents,ji.QUICK_ENTRY),t0r(AJ),AJ.setAlwaysOnTop(!0,`pop-up-menu`),AJ.webContents;X6()||AJ.hide();isWindowFocused:()=>!!ko()||r()||!1,isWindowVisible:()=>!!(B&&!B.isDestroyed()&&B.isVisible());_.info("[QuickEntry] Creating new chat with submit_quick_entry");!B||B.isDestroyed()||(ko()||B.show(),B.focus())'
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: AJ'* ]]
	[[ $output == *'KDE-gated ko()/B.isVisible()'* ]]
	[[ $output != *'WARNING'* ]]
	grep -qF 'AJ.blur(),AJ.hide()' "$main_js"
	grep -qF '(!B||B.isDestroyed()?!1:B.isVisible())' "$main_js"
}

@test "quick-window: ambiguous show sites warn and skip the site" {
	# Two show() call sites after the anchor: patching the first
	# would hit an arbitrary location, so part 2 warns and leaves
	# the bytes alone (part 1 still applies — it is unambiguous).
	write_fixture 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();_.info("[QuickEntry] Creating new chat with submit_quick_entry");a()||b.show();c()||d.show()'
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'2 raw and 0 patched show() sites near'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
	# Both show() sites are byte-unchanged: no visibility gate was
	# woven into either of them.
	grep -qF 'a()||b.show();c()||d.show()' "$main_js"
}

QW_HEAD='Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'
QW_LOG='_.info("[QuickEntry] Creating new chat with submit_quick_entry");'
QW_GATED='((process.env.XDG_CURRENT_DESKTOP||"").toLowerCase().includes("kde")?(!B||B.isDestroyed()?!1:B.isVisible()):ko())||B.show()'

@test "quick-window: an unrelated XDG_CURRENT_DESKTOP mention is not taken as already patched" {
	write_fixture "${QW_HEAD}${QW_LOG}console.log(process.env.XDG_CURRENT_DESKTOP);ko()||B.show()"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'KDE-gated ko()/B.isVisible()'* ]]
	[[ $output != *'show() already patched'* ]]
	grep -qF "console.log(process.env.XDG_CURRENT_DESKTOP);${QW_GATED}" "$main_js"
}

@test "quick-window: a duplicated log anchor warns and leaves the show() site alone" {
	write_fixture "${QW_HEAD}${QW_LOG}ko()||B.show();${QW_LOG}ko()||B.show()"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'occurs more than once'* ]]
	[[ $(grep -o 'ko()||B.show()' "$main_js" | wc -l) -eq 2 ]]
	[[ $(grep -o 'B.isVisible()' "$main_js" | wc -l) -eq 0 ]]
}

@test "quick-window: whitespace and newlines inside the show() site are tolerated" {
	write_fixture "${QW_HEAD}${QW_LOG}"$'!B||(ko ()\n||\nB . show ( ),B.focus())'
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'KDE-gated ko()/B.isVisible()'* ]]
	[[ $output != *'WARNING'* ]]
	grep -qF "!B||(${QW_GATED},B.focus())" "$main_js"
	local before
	before=$(sha_of "$main_js")
	run patch_quick_window
	[[ $output == *'show() already patched'* ]]
	[[ $output != *'WARNING'* ]]
	[[ $(sha_of "$main_js") == "$before" ]]
}

@test "quick-window: a whitespace-split dotted handle is captured whole" {
	write_fixture "${QW_HEAD}${QW_LOG}!B||(exports . focused () || B . show (),B.focus())"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'KDE-gated exports.focused()/B.isVisible()'* ]]
	[[ $output != *'WARNING'* ]]
	grep -qF ':exports.focused())||B.show(),B.focus())' "$main_js"
	[[ $(< "$main_js") != *'exports . ('* ]]
	# The fixture head is not a full program; syntax-check the site.
	local site="${TEST_TMP}/site.js"
	grep -oP '!B\|\|\(.*,B\.focus\(\)\)$' "$main_js" > "$site"
	node --check "$site"
	local before
	before=$(sha_of "$main_js")
	run patch_quick_window
	[[ $output == *'show() already patched'* ]]
	[[ $(sha_of "$main_js") == "$before" ]]
}

@test "quick-window: a mix of raw and patched show() sites warns and skips" {
	write_fixture "${QW_HEAD}${QW_LOG}${QW_GATED};a()||b.show()"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'1 raw and 1 patched show() sites near'* ]]
	grep -qF "${QW_GATED};a()||b.show()" "$main_js"
}

# =============================================================================
# org-plugins: quote class, whitespace tolerance, exactly-one-match
# =============================================================================

@test "org-plugins: injects the linux case on the double-quoted shape" {
	write_fixture 'return"/Library/Application Support/Claude/org-plugins";case"win32":return C.join("C:\\Program Files","Claude","org-plugins");default:return null}}'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	grep -qF 'case"linux":return"/etc/claude/org-plugins";default:return null' \
		"$main_js"
}

@test "org-plugins: injects the linux case on the backticked shape" {
	write_fixture 'return`/Library/Application Support/Claude/org-plugins`;case`win32`:return j(`C:\\Program Files`,`Claude`,`org-plugins`);default:return null}}'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	grep -qF 'case"linux":return"/etc/claude/org-plugins";default:return null' \
		"$main_js"
}

@test "org-plugins: injects the linux case on the single-quoted shape" {
	write_fixture "return'/Library/Application Support/Claude/org-plugins';case'win32':return j('C:\\\\Program Files','Claude','org-plugins');default:return null}}"
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	grep -qF 'case"linux":return"/etc/claude/org-plugins";default:return null' \
		"$main_js"
}

@test "org-plugins: whitespace around the switch arm is tolerated" {
	write_fixture 'return"/Library/Application Support/Claude/org-plugins";case"win32":return C.join("C:\\Program Files","Claude","org-plugins") ; default : return null}}'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	grep -qF '/etc/claude/org-plugins' "$main_js"
}

@test "org-plugins: duplicate switch sites warn and skip" {
	write_fixture 'return"/Library/Application Support/Claude/org-plugins";case"win32":return"x","org-plugins");default:return null};"org-plugins");default:return null}'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'matched 2 sites'* ]]
	run grep -qF '/etc/claude/org-plugins' "$main_js"
	[[ $status -ne 0 ]]
}

@test "org-plugins: second run is byte-identical" {
	write_fixture 'return"/Library/Application Support/Claude/org-plugins";case"win32":return"x","org-plugins");default:return null}'
	patch_org_plugins_path >/dev/null
	local before
	before=$(sha_of "$main_js")
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	[[ $output == *'already present'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "org-plugins: missing resolver warns and skips" {
	write_fixture 'var unrelated=true;'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	[[ $output == *'Warning'* ]]
}

# =============================================================================
# virtiofsd-probe: quote class, await/bare lhs, exactly-one-match
# =============================================================================

@test "virtiofsd: un-gates the double-quoted bare-identifier shape" {
	write_fixture 'Gon=["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"];async function Kon(e){const t=await Qot(Gon);return t||(e?loe(Won,Y.constants.X_OK):null)}'
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	grep -qF 'return t||loe(Won,Y.constants.X_OK)' "$main_js"
}

@test "virtiofsd: un-gates the backticked await-inlined shape" {
	write_fixture 'kT=[`/usr/libexec/virtiofsd`,`/usr/bin/virtiofsd`];async function jT(e){return await FT(kT)||(e?IT(TT,N.constants.X_OK):null)}'
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	grep -qF 'return await FT(kT)||IT(TT,N.constants.X_OK)' "$main_js"
	run grep -qF '(e?IT(TT,N.constants.X_OK):null)' "$main_js"
	[[ $status -ne 0 ]]
}

@test "virtiofsd: un-gates the single-quoted shape" {
	write_fixture "Gon=['/usr/libexec/virtiofsd','/usr/bin/virtiofsd'];async function Kon(e){const t=await Qot(Gon);return t||(e?loe(Won,Y.constants.X_OK):null)}"
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	grep -qF 'return t||loe(Won,Y.constants.X_OK)' "$main_js"
}

@test "virtiofsd: duplicate probe arrays warn and skip" {
	write_fixture 'a=["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"];return t||(e?loe(Won,Y.constants.X_OK):null);b=["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"];return u||(f?mex(Don,Z.constants.X_OK):null)'
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'matched 2 sites'* ]]
	grep -qF 'return t||(e?loe(Won,Y.constants.X_OK):null)' "$main_js"
}

@test "virtiofsd: missing probe array skips without failing" {
	write_fixture 'var x=["/usr/bin/qemu-system-x86_64"];'
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'skipped'* ]]
}

@test "virtiofsd: second run is byte-identical" {
	write_fixture 'kT=[`/usr/libexec/virtiofsd`,`/usr/bin/virtiofsd`];async function jT(e){return await FT(kT)||(e?IT(TT,N.constants.X_OK):null)}'
	patch_virtiofsd_probe >/dev/null
	local before
	before=$(sha_of "$main_js")
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'already un-gated'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "virtiofsd: win32/darwin-gated evaluator with no probe is not needed" {
	# Windows-lineage bundle shape (2.37337.1, also 1.44121.4): the
	# Cowork evaluator only gates win32/darwin and the virtiofsd
	# binary name occurs nowhere in the build tree, so there is
	# nothing to un-gate — an informational skip, not a WARNING.
	write_fixture 'if(e==="win32"){let e=Amr();if(!e.available)return{status:"unsupported",reason:`Missing HCS services: ${e.missingServices.join(", ")}`,unsupportedCode:"hcs_not_available"}}return{status:"supported"}'
	local before
	before=$(sha_of "$main_js")
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'patch not needed, skipping'* ]]
	[[ $output != *'WARNING'* ]]
	local after
	after=$(sha_of "$main_js")
	[[ $before == "$after" ]]
}

@test "virtiofsd: evaluator marker with a probe elsewhere stays a warning" {
	# The not-needed claim requires the binary name to be absent
	# from the whole build tree: a probe string in a sibling file
	# means the resolver may live in another chunk, so the miss
	# stays a WARNING + skip instead of an informational skip.
	write_fixture 'if(e==="win32"){let e=Amr();if(!e.available)return{status:"unsupported",reason:`Missing HCS services: ${e.missingServices.join(", ")}`,unsupportedCode:"hcs_not_available"}}return{status:"supported"}'
	printf '%s' '["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"]' \
		> "$TEST_TMP/sibling-chunk.js"
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'skipped'* ]]
}

# =============================================================================
# _count_anchor_matches / _assert_single_anchor_match
# =============================================================================

@test "anchor helper: counts zero, one and many matches" {
	write_fixture 'a.setAlwaysOnTop(!0,"pop-up-menu");b.setAlwaysOnTop(!0,"pop-up-menu")'
	local n
	n=$(_count_anchor_matches "$main_js" 'setAlwaysOnTop')
	[[ $n -eq 2 ]]
	n=$(_count_anchor_matches "$main_js" 'no-such-anchor-xyz')
	[[ $n -eq 0 ]]
	n=$(_count_anchor_matches "$TEST_TMP/does-not-exist.js" 'x')
	[[ $n -eq 0 ]]
}

@test "anchor helper: exactly one match is quiet success" {
	write_fixture 'a.setAlwaysOnTop(!0,"pop-up-menu")'
	run _assert_single_anchor_match "$main_js" 'setAlwaysOnTop' 'probe'
	[[ $status -eq 0 ]]
	[[ $output != *'WARNING'* ]]
}

@test "anchor helper: zero and many matches warn" {
	write_fixture 'a.setAlwaysOnTop(!0,"pop-up-menu");b.setAlwaysOnTop(!0,"pop-up-menu")'
	run _assert_single_anchor_match "$main_js" 'setAlwaysOnTop' 'probe'
	[[ $status -ne 0 ]]
	[[ $output == *'matched 2 sites'* ]]
	run _assert_single_anchor_match "$main_js" 'no-such-anchor-xyz' 'probe'
	[[ $status -ne 0 ]]
	[[ $output == *'not found'* ]]
}

# =============================================================================
# PATCH_STAGE_RERUN digest helpers
# =============================================================================

_make_build_tree() {
	mkdir -p "$TEST_TMP/staging/app.asar.contents/.vite/build"
	printf '%s' 'var core=1;' \
		> "$TEST_TMP/staging/app.asar.contents/.vite/build/index.js"
	cd "$TEST_TMP/staging" || return 1
}

@test "rerun digest: stable across reads, changes with bytes" {
	_make_build_tree
	local first second
	first=$(_patch_bundle_digest)
	[[ -n $first ]]
	second=$(_patch_bundle_digest)
	[[ $first == "$second" ]]
	printf '%s' 'var extra=2;' \
		>> "$TEST_TMP/staging/app.asar.contents/.vite/build/index.js"
	local third
	third=$(_patch_bundle_digest)
	[[ $third != "$first" ]]
}

@test "rerun digest: missing or empty tree fails" {
	cd "$TEST_TMP" || return 1
	run _patch_bundle_digest
	[[ $status -ne 0 ]]
	mkdir -p "$TEST_TMP/empty/app.asar.contents/.vite/build"
	cd "$TEST_TMP/empty" || return 1
	run _patch_bundle_digest
	[[ $status -ne 0 ]]
}

@test "rerun check: equal digests pass, differing digests fail loudly" {
	run _check_patch_stage_idempotent 'abc123' 'abc123'
	[[ $status -eq 0 ]]
	run _check_patch_stage_idempotent 'abc123' 'def456'
	[[ $status -ne 0 ]]
	[[ $output == *'Idempotency'* ]]
}

@test "rerun check: detects a deliberately non-idempotent fake patch" {
	_make_build_tree
	_fake_patch_appends() {
		printf '%s' '// fake' \
			>> "$TEST_TMP/staging/app.asar.contents/.vite/build/index.js"
	}
	local before after
	before=$(_patch_bundle_digest)
	_fake_patch_appends
	after=$(_patch_bundle_digest)
	run _check_patch_stage_idempotent "$before" "$after"
	[[ $status -ne 0 ]]
	[[ $output == *'Idempotency: second patch pass'* ]]
}
