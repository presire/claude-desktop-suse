#!/usr/bin/env bats
# shellcheck disable=SC2329  # BATS @test blocks invoke mock functions indirectly
# shellcheck disable=SC2030,SC2031  # each BATS @test runs in its own subshell
#
# doctor.bats
# Tests for diagnostic helpers in scripts/doctor.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	export HOME="$TEST_TMP/home"
	export XDG_CACHE_HOME="$TEST_TMP/cache"
	export XDG_CONFIG_HOME="$TEST_TMP/config"
	mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

	# Clear all input/display vars to avoid host-state leakage
	unset DISPLAY
	unset WAYLAND_DISPLAY
	unset XDG_SESSION_TYPE
	unset CLAUDE_USE_WAYLAND
	unset GTK_IM_MODULE
	unset CLAUDE_GTK_IM_MODULE
	unset CLAUDE_PASSWORD_STORE

	# shellcheck source=scripts/doctor.sh
	source "$SCRIPT_DIR/../scripts/doctor.sh"

	_doctor_colors
	_doctor_failures=0

	# Default _pkg_installed to "unknown" (rc=2) so tests don't have
	# to stub it unless they're exercising the package-check branch.
	# Override in-test for rc=0 (installed) or rc=1 (missing).
	# shellcheck disable=SC2317 # test stub is invoked indirectly by sourced doctor helpers
	_pkg_installed() { return 2; }
	# shellcheck disable=SC2317 # test stub is invoked indirectly by sourced doctor helpers
	_detect_password_store() { echo 'basic'; }
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_install_getconf_shim() {
	mkdir -p "$TEST_TMP/bin"
	local value="$1"
	if [[ -z $value ]]; then
		cat > "$TEST_TMP/bin/getconf" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
	else
		cat > "$TEST_TMP/bin/getconf" <<SHIM
#!/usr/bin/env bash
echo ${value}
SHIM
	fi
	chmod +x "$TEST_TMP/bin/getconf"
	export PATH="$TEST_TMP/bin:$PATH"
}

_install_df_shim() {
	mkdir -p "$TEST_TMP/bin"
	local fstype="$1"
	if [[ -z $fstype ]]; then
		cat > "$TEST_TMP/bin/df" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
	else
		cat > "$TEST_TMP/bin/df" <<SHIM
#!/usr/bin/env bash
cat <<'OUT'
Type
${fstype}
OUT
SHIM
	fi
	chmod +x "$TEST_TMP/bin/df"
	export PATH="$TEST_TMP/bin:$PATH"
}

# Make `command -v gtk-query-immodules-3.0` report "not found" so the
# immodules cache check is skipped. Used by tests that aren't
# exercising the cache branch but reach it because no earlier gate
# fires. `command -v` finds bash functions too, so just unsetting a
# stub function isn't enough — we shadow `command` itself.
_skip_gtk_query() {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
}

# =============================================================================
# _cowork_pkg_hint: ibus-gtk3 mapping (#550)
# =============================================================================

@test "_cowork_pkg_hint: opensuse maps ibus-gtk3 to ibus-gtk3 via zypper" {
	local result
	result=$(_cowork_pkg_hint opensuse ibus-gtk3)
	[[ $result == "sudo zypper install ibus-gtk3" ]]
}

@test "_cowork_pkg_hint: sles maps ibus-gtk3 to ibus-gtk3 via zypper" {
	local result
	result=$(_cowork_pkg_hint sles ibus-gtk3)
	[[ $result == "sudo zypper install ibus-gtk3" ]]
}

# =============================================================================
# _doctor_check_im_modules: CLAUDE_GTK_IM_MODULE override visibility
# =============================================================================

@test "_doctor_check_im_modules: emits override line when CLAUDE_GTK_IM_MODULE set" {
	# CLAUDE_GTK_IM_MODULE makes active_im non-empty, so we'd reach
	# the cache check — skip it to keep this test focused.
	_skip_gtk_query

	CLAUDE_GTK_IM_MODULE='xim'
	run _doctor_check_im_modules opensuse
	[[ $output == *'CLAUDE_GTK_IM_MODULE=xim'* ]]
	[[ $output == *'overrides GTK_IM_MODULE for Electron'* ]]
}

@test "_doctor_check_im_modules: no override line when CLAUDE_GTK_IM_MODULE unset" {
	run _doctor_check_im_modules opensuse
	[[ $output != *'CLAUDE_GTK_IM_MODULE'* ]]
}

# =============================================================================
# _doctor_check_im_modules: XWayland-with-IBus routing note
# =============================================================================

@test "_doctor_check_im_modules: emits XWayland note when wayland session and CLAUDE_USE_WAYLAND unset" {
	XDG_SESSION_TYPE='wayland'
	# CLAUDE_USE_WAYLAND deliberately unset
	run _doctor_check_im_modules opensuse
	[[ $output == *'XWayland'* ]]
	[[ $output == *'CLAUDE_USE_WAYLAND=1'* ]]
}

@test "_doctor_check_im_modules: no XWayland note when CLAUDE_USE_WAYLAND=1" {
	XDG_SESSION_TYPE='wayland'
	CLAUDE_USE_WAYLAND='1'
	run _doctor_check_im_modules opensuse
	[[ $output != *'XWayland'* ]]
}

@test "_doctor_check_im_modules: no XWayland note on X11 session" {
	XDG_SESSION_TYPE='x11'
	run _doctor_check_im_modules opensuse
	[[ $output != *'XWayland'* ]]
}

# =============================================================================
# _doctor_check_im_modules: ibus-gtk3 package check
# =============================================================================

@test "_doctor_check_im_modules: warns when ibus selected but ibus-gtk3 missing" {
	# Package not installed (rc=1, definitive answer)
	# shellcheck disable=SC2317 # test stub is invoked indirectly by _doctor_check_im_modules
	_pkg_installed() { return 1; }

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules opensuse
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'ibus-gtk3 is not installed'* ]]
	[[ $output == *'sudo zypper install ibus-gtk3'* ]]
}

@test "_doctor_check_im_modules: no warning when ibus selected and ibus-gtk3 present" {
	# Package installed (rc=0); cache lists ibus.
	# shellcheck disable=SC2317 # test stub is invoked indirectly by _doctor_check_im_modules
	_pkg_installed() { return 0; }
	# shellcheck disable=SC2317 # command shim is invoked indirectly by `command -v` and the helper under test
	gtk-query-immodules-3.0() {
		echo '"ibus" "IBus" "ibus" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: no package warning when active module isn't ibus" {
	# Even with rc=1 for ibus-gtk3, the package check should be
	# skipped entirely when GTK_IM_MODULE isn't ibus.
	# shellcheck disable=SC2317 # test stub is invoked indirectly by _doctor_check_im_modules
	_pkg_installed() { return 1; }
	_skip_gtk_query

	GTK_IM_MODULE='xim'
	run _doctor_check_im_modules opensuse
	[[ $output != *'ibus-gtk3'* ]]
}

@test "_doctor_check_im_modules: no package warning on unsupported distro (rc=2)" {
	# Default _pkg_installed (rc=2) — no warning even with ibus.
	_skip_gtk_query

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules unknown
	[[ $output != *'[WARN]'* ]]
}

# =============================================================================
# _doctor_check_im_modules: immodules cache check
# =============================================================================

@test "_doctor_check_im_modules: warns when GTK_IM_MODULE not in immodules cache" {
	# gtk-query-immodules-3.0 lists xim but not fcitx
	# shellcheck disable=SC2317 # command shim is invoked indirectly by the helper under test
	gtk-query-immodules-3.0() {
		echo '"xim" "X Input Method" "gtk30" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='fcitx'
	run _doctor_check_im_modules opensuse
	[[ $output == *'[WARN]'* ]]
	[[ $output == *"'fcitx' not listed"* ]]
	[[ $output == *'gtk-query-immodules-3.0 --update-cache'* ]]
}

@test "_doctor_check_im_modules: no warning when active module is in cache" {
	# shellcheck disable=SC2317 # command shim is invoked indirectly by the helper under test
	gtk-query-immodules-3.0() {
		echo '"xim" "X Input Method" "gtk30" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='xim'
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: skips cache check when gtk-query-immodules-3.0 missing" {
	_skip_gtk_query

	GTK_IM_MODULE='fcitx'
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'cache may be stale'* ]]
}

@test "_doctor_check_im_modules: CLAUDE_GTK_IM_MODULE takes precedence as active module" {
	# Cache lists xim but not ibus. CLAUDE_GTK_IM_MODULE=xim should
	# win over GTK_IM_MODULE=ibus, so no cache warning fires.
	# shellcheck disable=SC2317 # command shim is invoked indirectly by the helper under test
	gtk-query-immodules-3.0() {
		echo '"xim" "X Input Method" "gtk30" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE='xim'
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: no checks fire when no IM module selected" {
	# Neither GTK_IM_MODULE nor CLAUDE_GTK_IM_MODULE set — function
	# should return early before the package or cache checks.
	run _doctor_check_im_modules opensuse
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'ibus-gtk3'* ]]
}

@test "_doctor_check_password_store: output contains 'Password store:' with a valid backend" {
	run _doctor_check_password_store
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'Password store:'* ]]
	[[ $output == *'basic'* ]]
}

@test "_doctor_check_filename_limit: silent when NAME_MAX >= 200" {
	_install_getconf_shim '255'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_filename_limit: warns when NAME_MAX < 200" {
	_install_getconf_shim '143'
	_install_df_shim 'ext4'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'NAME_MAX=143'* ]]
	[[ $output == *'#590'* ]]
	[[ $output != *'eCryptfs'* ]]
	[[ $output != *'LUKS'* ]]
}

@test "_doctor_check_filename_limit: eCryptfs adds LUKS workaround hint" {
	_install_getconf_shim '143'
	_install_df_shim 'ecryptfs'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'NAME_MAX=143'* ]]
	[[ $output == *'eCryptfs'* ]]
	[[ $output == *'LUKS'* ]]
}

@test "_doctor_check_filename_limit: silent on non-numeric getconf output" {
	_install_getconf_shim 'undefined'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_filename_limit: silent when getconf fails" {
	_install_getconf_shim ''
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_filename_limit: df failure suppresses eCryptfs hint, keeps warn" {
	_install_getconf_shim '143'
	_install_df_shim ''
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'NAME_MAX=143'* ]]
	[[ $output != *'eCryptfs'* ]]
	[[ $output != *'LUKS'* ]]
}

# =============================================================================
# _doctor_check_recent_crashes: GPU FATAL crash counter (#583)
# =============================================================================

# Install a coredumpctl shim. $1 is the coredumpctl-list-style
# multi-line output to emit (header + entry rows). The shim ignores
# its arguments — tests don't exercise the filter syntax.
_install_coredumpctl_shim() {
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/coredumpctl" <<SHIM
#!/usr/bin/env bash
cat <<'OUT'
$1
OUT
SHIM
	chmod +x "$TEST_TMP/bin/coredumpctl"
	export PATH="$TEST_TMP/bin:$PATH"
}

@test "_doctor_check_recent_crashes: no coredumpctl on PATH — silent" {
	# Force coredumpctl off PATH so the helper short-circuits.
	# Restore PATH before returning so teardown's rm works.
	local saved_path="$PATH"
	export PATH="/no-such-dir-for-test"
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	export PATH="$saved_path"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_recent_crashes: zero crashes — silent" {
	# Listing has the header line only, no entry rows.
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_recent_crashes: 1 crash — info line, no warn" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 21.6M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ $output == *'Recent Electron crashes: 1'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_recent_crashes: 3+ crashes — warn + #583 pointer" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 21.6M
Mon 2026-05-04 07:44:48 EDT 930532 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 22.8M
Sun 2026-05-03 14:34:10 EDT 567221 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 12.4M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'Recent Electron crashes: 3'* ]]
	[[ $output == *'CLAUDE_DISABLE_GPU=1'* ]]
	[[ $output == *'/issues/583'* ]]
}

@test "_doctor_check_recent_crashes: path mismatch falls back with footnote" {
	# Three crashes from a DIFFERENT electron binary (e.g., Slack).
	# Caller passes claude-desktop's electron path, which doesn't
	# match — helper falls back to total count and adds the footnote
	# so the user knows the count may be cross-app.
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 09:00:00 EDT 200001 1000 1000 SIGSEGV present /usr/lib/slack/electron 30M
Wed 2026-05-05 09:00:00 EDT 200002 1000 1000 SIGSEGV present /usr/lib/slack/electron 30M
Wed 2026-05-04 09:00:00 EDT 200003 1000 1000 SIGSEGV present /usr/lib/slack/electron 30M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'may be from other Electron apps'* ]]
}

@test "_doctor_check_recent_crashes: empty electron_path falls back" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 21.6M'
	# Caller didn't pass an electron_path — helper still counts and
	# emits the info line based on the unfiltered total.
	run _doctor_check_recent_crashes ''
	[[ $status -eq 0 ]]
	[[ $output == *'Recent Electron crashes: 1'* ]]
	[[ $output == *'may be from other Electron apps'* ]]
}

# Source the launcher library (which sources doctor.sh from its own
# directory) for checks that reuse launcher predicates.
_source_launcher_common() {
	cp "$SCRIPT_DIR/../scripts/launcher-common.sh" "$TEST_TMP/"
	cp "$SCRIPT_DIR/../scripts/doctor.sh" "$TEST_TMP/"
	sed -i 's/@@WM_CLASS@@/Claude/' "$TEST_TMP/launcher-common.sh"
	# shellcheck source=scripts/launcher-common.sh
	source "$TEST_TMP/launcher-common.sh"
	_doctor_colors
}

@test "_doctor_check_pkg_version: appimage reads X-AppImage-Version" {
	local appdir="$TEST_TMP/appdir"
	mkdir -p "$appdir/usr/lib/node_modules/electron/dist"
	printf '[Desktop Entry]\nName=Claude\nX-AppImage-Version=1.2.3\n' \
		> "$appdir/io.github.presire.claude-desktop-suse.desktop"
	run _doctor_check_pkg_version \
		"$appdir/usr/lib/node_modules/electron/dist/electron" 'appimage'
	[[ $status -eq 0 ]]
	[[ $output == *'Installed version: 1.2.3 (AppImage)'* ]]
	[[ $output != *'rpm'* ]]
}

@test "_doctor_check_pkg_version: appimage without version stamp is info only" {
	local appdir="$TEST_TMP/appdir"
	mkdir -p "$appdir/usr/lib/node_modules/electron/dist"
	run _doctor_check_pkg_version \
		"$appdir/usr/lib/node_modules/electron/dist/electron" 'appimage'
	[[ $status -eq 0 ]]
	[[ $output == *'Installed version: unknown'* ]]
	[[ $output != *'[WARN]'* && $output != *'[FAIL]'* ]]
}

@test "_doctor_check_chrome_sandbox: appimage is informational, never FAIL" {
	run _doctor_check_chrome_sandbox "$TEST_TMP/missing/electron" 'appimage'
	[[ $status -eq 0 ]]
	[[ $output == *'Chrome sandbox: not used'* ]]
	[[ $output != *'sudo'* ]]
	[[ $_doctor_failures -eq 0 ]]
}

@test "_doctor_check_chrome_sandbox: rpm reports a missing helper" {
	run _doctor_check_chrome_sandbox "$TEST_TMP/dist/electron" 'rpm'
	[[ $status -eq 0 ]]
	[[ $output == *"Chrome sandbox not found at $TEST_TMP/dist/chrome-sandbox"* ]]
}

@test "_doctor_check_singleton_lock: regular file is reported, not 'no lock'" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	: > "$XDG_CONFIG_HOME/Claude/SingletonLock"
	run _doctor_check_singleton_lock "$XDG_CONFIG_HOME/Claude"
	[[ $output == *'present but not a symlink'* ]]
	[[ $output != *'no lock file'* ]]
}

@test "_doctor_check_singleton_lock: dead PID is stale" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	ln -s 'myhost-999999999' "$XDG_CONFIG_HOME/Claude/SingletonLock"
	run _doctor_check_singleton_lock "$XDG_CONFIG_HOME/Claude"
	[[ $output == *'stale lock found'* ]]
	[[ $output == *'is not running'* ]]
}

@test "_doctor_check_singleton_lock: unrecognized live holder is not called stale" {
	_source_launcher_common
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	ln -s "myhost-$$" "$XDG_CONFIG_HOME/Claude/SingletonLock"
	run _doctor_check_singleton_lock "$XDG_CONFIG_HOME/Claude"
	[[ $output == *'not recognized as Claude Desktop'* ]]
	[[ $output != *'stale lock found'* ]]
	[[ $output != *'Fix: rm'* ]]
	[[ $_doctor_failures -eq 0 ]]
}

@test "_doctor_check_display_server: XWayland tip names the portal" {
	export WAYLAND_DISPLAY='wayland-0'
	run _doctor_check_display_server
	[[ $output == *'X11 via XWayland (default)'* ]]
	[[ $output == *'GlobalShortcuts portal'* ]]
	[[ $output != *'disables global hotkeys'* ]]
}

@test "_doctor_check_display_server: no display fails" {
	run _doctor_check_display_server
	[[ $output == *'No display server detected'* ]]
}

@test "_doctor_check_effective_sandbox: silent without launcher library" {
	run _doctor_check_effective_sandbox 'rpm'
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_effective_sandbox: rpm on native Wayland warns" {
	_source_launcher_common
	export WAYLAND_DISPLAY='wayland-0' CLAUDE_USE_WAYLAND=1
	unset CLAUDE_FORCE_SANDBOX
	detect_display_backend
	run _doctor_check_effective_sandbox 'rpm'
	[[ $output == *'disabled at runtime'* ]]
}

@test "_doctor_check_effective_sandbox: CLAUDE_FORCE_SANDBOX=1 keeps it enabled" {
	_source_launcher_common
	export WAYLAND_DISPLAY='wayland-0' CLAUDE_USE_WAYLAND=1
	export CLAUDE_FORCE_SANDBOX=1
	detect_display_backend
	run _doctor_check_effective_sandbox 'rpm'
	[[ $output == *'enabled at runtime'* ]]
}

@test "_doctor_check_effective_sandbox: appimage is skipped" {
	_source_launcher_common
	run _doctor_check_effective_sandbox 'appimage'
	[[ -z $output ]]
}

@test "_doctor_check_cowork_daemon: silent when no daemon runs" {
	_source_launcher_common
	# shellcheck disable=SC2317 # stub invoked by the check under test
	_cowork_fallback_daemon_pids() { :; }
	run _doctor_check_cowork_daemon
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_cowork_daemon: orphan with no UI says restart" {
	_source_launcher_common
	# shellcheck disable=SC2317 # stubs invoked by the check under test
	_cowork_fallback_daemon_pids() { echo 4242; }
	# shellcheck disable=SC2317
	_claude_desktop_own_ui_is_alive() { return 1; }
	# shellcheck disable=SC2317
	_claude_desktop_any_main_is_alive() { return 1; }
	run _doctor_check_cowork_daemon
	[[ $output == *'Cowork daemon: orphaned'* ]]
	[[ $output == *'4242'* ]]
	[[ $output == *'Restart Claude Desktop'* ]]
}

@test "_doctor_check_cowork_daemon: other build holding profile says quit it" {
	_source_launcher_common
	# shellcheck disable=SC2317 # stubs invoked by the check under test
	_cowork_fallback_daemon_pids() { echo 4242; }
	# shellcheck disable=SC2317
	_claude_desktop_own_ui_is_alive() { return 1; }
	# shellcheck disable=SC2317
	_claude_desktop_any_main_is_alive() { return 0; }
	run _doctor_check_cowork_daemon
	[[ $output == *'Quit the other running Claude Desktop'* ]]
}

@test "_doctor_check_cowork_daemon: daemon with live UI passes" {
	_source_launcher_common
	# shellcheck disable=SC2317 # stubs invoked by the check under test
	_cowork_fallback_daemon_pids() { echo 4242; }
	# shellcheck disable=SC2317
	_claude_desktop_own_ui_is_alive() { return 0; }
	run _doctor_check_cowork_daemon
	[[ $output == *'running (parent alive)'* ]]
}
