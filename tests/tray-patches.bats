#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # Bats executes tests in subshells

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
		'Nx.on("menuBarEnabled",(()=>{I3r()}));var J9=null;function I3r(){B3r(!1)}function z3r(e){switch("ico"){case"ico":return"Tray-Win32.ico";case"png":return"TrayIconLinux.png"}}function B3r(e){let r=z3r(e);if(J9&&!J9.isDestroyed()){r!==Y9&&(J9.setImage(o.nativeImage.createFromPath(r)),Y9=r);return}J9=new o.Tray(o.nativeImage.createFromPath(r))}' \
		> "$main_js"
}

@test "latest tray: wrapped settings callback is resolved" {
	write_latest_tray_fixture
	run patch_tray_menu_handler
	[[ $status -eq 0 ]]
	[[ $output == *'updater already updates in place'* ]]
	! grep -qF 'I3r._running' "$main_js"
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
