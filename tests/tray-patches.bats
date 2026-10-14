#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells
#
# tray-patches.bats
#
# Claude 1.44121.4 wraps the menuBarEnabled callback and already ships
# the in-place Tray.setImage update, so the mutex/delay patches must
# stand down instead of re-injecting guards. The tray flavor also moved
# from an assignment to a literal switch("ico"), which must be resolved
# to the PNG branch on Linux. Since that reshape (still current on
# 2.37337.1) the "png" branch already picks TrayIconLinux-Dark.png vs
# TrayIconLinux.png per theme, so the icon-selection patch must
# recognise the ternary and log it instead of warning.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
TRAY_SH="$SCRIPT_DIR/../scripts/patches/tray.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	main_js="$TEST_TMP/index.js"
	project_root="$SCRIPT_DIR/.."
	electron_var='o'
	electron_var_re='o'
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/tray.sh
	source "$TRAY_SH"
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

write_latest_tray_fixture() {
	printf '%s' \
		'Nx.on("menuBarEnabled",(()=>{I3r()}));var J9=null,Y9=null;function I3r(){B3r(!1)}function z3r(e){switch("ico"){case"ico":return!e&&o.nativeTheme.shouldUseDarkColors?"Tray-Win32-Dark.ico":"Tray-Win32.ico";case"template-image":return"TrayIconTemplate.png";case"png":return e||QVt()==="gnome"||o.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png"}}function B3r(e){let r=z3r(e);if(J9&&!J9.isDestroyed()){r!==Y9&&(J9.setImage(o.nativeImage.createFromPath(r)),Y9=r);return}J9=new o.Tray(o.nativeImage.createFromPath(r))}' \
		> "$main_js"
}

write_legacy_tray_fixture() {
	printf '%s' \
		'var cfg={tray:X="TrayIconTemplate.png"};function Lr(){switch("ico"){case"ico":return"Tray-Win32.ico";case"png":return"TrayIconLinux.png"}}' \
		> "$main_js"
}

write_anchor_miss_fixture() {
	printf '%s' \
		'var cfg={tray:X="plain.png"};function Mr(){switch(process.platform==="win32"?"ico":"png"){case"ico":return"a.ico";case"png":return"b.png"}}' \
		> "$main_js"
}

@test "latest tray: wrapped settings callback is resolved" {
	write_latest_tray_fixture
	run patch_tray_menu_handler
	[[ $status -eq 0 ]]
	[[ $output == *'updater already updates in place'* ]]
	run grep -qF 'I3r._running' "$main_js"
	[[ $status -eq 1 ]]
}

@test "latest tray: existing in-place update is not reinjected" {
	write_latest_tray_fixture
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_inplace_update
	[[ $status -eq 0 ]]
	[[ $output == *'already has an in-place setImage path'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "latest tray: literal flavor switch selects PNG on Linux" {
	write_latest_tray_fixture
	patch_tray_icon_selection >/dev/null
	grep -qF 'switch(process.platform==="win32"?"ico":"png")' "$main_js"
}

@test "latest tray: icon switch patch is idempotent" {
	write_latest_tray_fixture
	patch_tray_icon_selection >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	patch_tray_icon_selection >/dev/null
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "current shape: upstream theme ternary is recognised, not warned" {
	write_latest_tray_fixture
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'already handles Linux theme'* ]]
	[[ $output != *'WARNING'* ]]
	run grep -qF '?"TrayIconLinux-Dark.png":"TrayIconLinux.png"' "$main_js"
	[[ $status -eq 0 ]]
}

@test "current shape: rerun reports switch already patched" {
	write_latest_tray_fixture
	patch_tray_icon_selection >/dev/null
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'already uses PNG on Linux'* ]]
	[[ $output == *'already handles Linux theme'* ]]
}

@test "legacy shape: TrayIconTemplate assignment gains dark variant" {
	write_legacy_tray_fixture
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'Patched tray icon selection for Linux theme support'* ]]
	grep -qF 'X=o.nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"' \
		"$main_js"
}

@test "legacy shape: rerun distinguishes already-patched" {
	write_legacy_tray_fixture
	patch_tray_icon_selection >/dev/null
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'already patched'* ]]
	[[ $output != *'WARNING'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}

@test "anchor miss: warns on stderr and leaves bytes unchanged" {
	write_anchor_miss_fixture
	local before
	before=$(sha256sum "$main_js" | cut -d' ' -f1)
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'*'theme-selection anchor not found'* ]]
	local after
	after=$(sha256sum "$main_js" | cut -d' ' -f1)
	[[ $before == "$after" ]]
}
