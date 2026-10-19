#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031  # Literal JS; Bats uses subshells
#
# quick-window-chunk-resolution.bats
#
# Each quick-window part resolves the file that carries its own anchor:
# the main chunk when it has the anchor, otherwise exactly one sibling
# *.js chunk in the same directory. Upstream may split the QuickEntry
# submit path away from the pop-up-menu path, and part 2 must follow it
# instead of silently skipping the KDE show() fix.
#
# The failure cases are load-bearing: two sibling chunks carrying the
# same anchor must fail the build rather than patch an arbitrary file.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
COMMON_SH="$SCRIPT_DIR/../scripts/patches/_common.sh"
QW_SH="$SCRIPT_DIR/../scripts/patches/quick-window.sh"

setup() {
	BUNDLE_DIR="$BATS_TEST_TMPDIR/bundle"
	mkdir -p "$BUNDLE_DIR"
	project_root="$SCRIPT_DIR/.."
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/_common.sh
	source "$COMMON_SH"
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/quick-window.sh
	source "$QW_SH"
}

# Part 1 in the main chunk: tagged anchor plus the hide() rewrite site.
QW_PART1='Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;N6()||er.hide();'

# Part 2 anchor (the log string survives patching, so re-runs resolve
# the same file) plus a show() site through a dotted handle.
QW_PART2='_.info("[QuickEntry] Creating new chat with submit_quick_entry");n1()||exports.mainWindow.show()'

# The KDE gate part 2 splices in front of the show() call.
QW_GATE='(!exports.mainWindow||exports.mainWindow.isDestroyed()?!1:exports.mainWindow.isVisible())'

@test "quick-window: part 2 anchor in a sibling chunk is patched there" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	local submit_js="$BUNDLE_DIR/index.chunk-submit.js"
	printf '%s' "$QW_PART1" > "$main_js"
	printf '%s' "$QW_PART2" > "$submit_js"

	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Patched 1 quick entry show() calls'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
	grep -qF "$QW_GATE" "$submit_js"
	run grep -qF 'exports.mainWindow' "$main_js"
	[[ $status -ne 0 ]]
}

@test "quick-window: part 1 in main and part 2 in a sibling are both patched" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	local submit_js="$BUNDLE_DIR/index.chunk-abc123.js"
	printf '%s' "$QW_PART1" > "$main_js"
	printf 'var unrelated=1;%s' "$QW_PART2" > "$submit_js"
	printf '%s' 'var decoy=2;' > "$BUNDLE_DIR/index.chunk-decoy.js"

	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: er'* ]]
	[[ $output == *'KDE-gated n1()/exports.mainWindow.isVisible()'* ]]
	[[ $output != *'WARNING'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
	grep -qF "$QW_GATE" "$submit_js"
}

@test "quick-window: anchor in two sibling chunks fails the build" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s' 'var mainOnly=1;' > "$main_js"
	printf '%s' 'Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu");' \
		> "$BUNDLE_DIR/index.chunk-a.js"
	printf '%s' 'Il.QUICK_ENTRY),R.setAlwaysOnTop(!0,`pop-up-menu`);' \
		> "$BUNDLE_DIR/index.chunk-b.js"
	cp "$main_js" "$BATS_TEST_TMPDIR/main.before"
	cp "$BUNDLE_DIR/index.chunk-a.js" "$BATS_TEST_TMPDIR/a.before"
	cp "$BUNDLE_DIR/index.chunk-b.js" "$BATS_TEST_TMPDIR/b.before"

	run patch_quick_window
	[[ $status -ne 0 ]]
	[[ $output == *'matched 2 sibling chunks'* ]]
	[[ $output == *'refusing to guess'* ]]
	cmp "$main_js" "$BATS_TEST_TMPDIR/main.before"
	cmp "$BUNDLE_DIR/index.chunk-a.js" "$BATS_TEST_TMPDIR/a.before"
	cmp "$BUNDLE_DIR/index.chunk-b.js" "$BATS_TEST_TMPDIR/b.before"
}

@test "quick-window: rerun over split files is byte-identical" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	local submit_js="$BUNDLE_DIR/index.chunk-submit.js"
	printf '%s' "$QW_PART1" > "$main_js"
	printf '%s' "$QW_PART2" > "$submit_js"
	patch_quick_window > /dev/null
	cp "$main_js" "$BATS_TEST_TMPDIR/main.first"
	cp "$submit_js" "$BATS_TEST_TMPDIR/submit.first"

	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'already patched'* ]]
	[[ $output != *'WARNING'* ]]
	cmp "$main_js" "$BATS_TEST_TMPDIR/main.first"
	cmp "$submit_js" "$BATS_TEST_TMPDIR/submit.first"
}

@test "quick-window: anchors in main keep the main-only path" {
	main_js="$BUNDLE_DIR/index.chunk-main.js"
	printf '%s%s' "$QW_PART1" "$QW_PART2" > "$main_js"
	local sibling="$BUNDLE_DIR/index.chunk-sibling.js"
	printf 'var a=1;%s' "$QW_PART2" > "$sibling"
	cp "$sibling" "$BATS_TEST_TMPDIR/sibling.before"

	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output != *'WARNING'* ]]
	grep -qF 'er.blur(),er.hide()' "$main_js"
	grep -qF "$QW_GATE" "$main_js"
	cmp "$sibling" "$BATS_TEST_TMPDIR/sibling.before"
}
