#!/usr/bin/env bats

setup() {
	# shellcheck source-path=SCRIPTDIR/.. source=scripts/patches/app-asar.sh
	source "$BATS_TEST_DIRNAME/../scripts/patches/app-asar.sh"
	WRAPPER="$BATS_TEST_DIRNAME/../scripts/frame-fix-wrapper.js"
	HELPER="$BATS_TEST_DIRNAME/../scripts/frame-fix-autostart.js"
}

@test "RPM desktopName yields claude-desktop window class" {
	run _derive_startup_wm_class 'claude-desktop.desktop'
	[[ $status -eq 0 ]]
	[[ $output == 'claude-desktop' ]]
}

@test "AppImage desktopName yields the component id window class" {
	run _derive_startup_wm_class 'io.github.presire.claude-desktop-suse.desktop'
	[[ $status -eq 0 ]]
	[[ $output == 'io.github.presire.claude-desktop-suse' ]]
}

@test "empty desktopName fails loudly" {
	run _derive_startup_wm_class ''
	[[ $status -eq 1 ]]
	[[ $output == *desktopName* ]]
	[[ $output == *StartupWMClass* ]]
}

@test "desktopName without .desktop suffix fails loudly" {
	run _derive_startup_wm_class 'claude-desktop'
	[[ $status -eq 1 ]]
	[[ $output == *'.desktop suffix'* ]]
}

@test "node helper strips only the .desktop suffix" {
	run node -e '
		const { desktopNameToWMClass } = require(process.argv[1]);
		console.log(desktopNameToWMClass("io.github.presire.claude-desktop-suse.desktop"));
	' "$HELPER"
	[[ $status -eq 0 ]]
	[[ $output == 'io.github.presire.claude-desktop-suse' ]]
}

@test "node helper rejects values Chromium cannot use" {
	run node -e '
		const { desktopNameToWMClass } = require(process.argv[1]);
		const bad = [undefined, null, "", "claude-desktop", 42];
		for (const value of bad) {
			if (desktopNameToWMClass(value) !== "") {
				process.exit(1);
			}
		}
	' "$HELPER"
	[[ $status -eq 0 ]]
}

@test "autostart template uses the desktopName-derived class" {
	run grep -F "StartupWMClass=\${resolveStartupWMClass()}" "$WRAPPER"
	[[ $status -eq 0 ]]
}
