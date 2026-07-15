#!/usr/bin/env bats
#
# launcher-common.bats
# Tests for launcher utility functions in scripts/launcher-common.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

# Check whether a value exists in the electron_args array.
# Supports glob patterns (e.g., '*WaylandWindowDecorations*').
has_electron_arg() {
	local pattern="$1"
	local arg
	for arg in "${electron_args[@]}"; do
		# shellcheck disable=SC2254,SC2053 # intentional glob pattern match
		[[ $arg == $pattern ]] && return 0
	done
	return 1
}

_stub_dbus_send() {
	mkdir -p "$TEST_TMP/bin"
	case "${1:-fail}" in
		kwallet6)
			cat > "$TEST_TMP/bin/dbus-send" <<'STUB'
#!/usr/bin/env bash
echo 'boolean true'
STUB
			;;
		secrets-ok)
			cat > "$TEST_TMP/bin/dbus-send" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *kwalletd6* ]] && exit 1
exit 0
STUB
			;;
		*)
			printf '#!/usr/bin/env bash\nexit 1\n' \
				> "$TEST_TMP/bin/dbus-send"
			;;
	esac
	chmod +x "$TEST_TMP/bin/dbus-send"
	export PATH="$TEST_TMP/bin:$PATH"
}

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Redirect all filesystem-touching functions to temp dirs
	export HOME="$TEST_TMP/home"
	export XDG_CACHE_HOME="$TEST_TMP/cache"
	export XDG_CONFIG_HOME="$TEST_TMP/config"
	export XDG_RUNTIME_DIR="$TEST_TMP/run"
	mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"

	# Clear display/wayland variables to avoid leaking host state
	unset DISPLAY
	unset WAYLAND_DISPLAY
	unset CLAUDE_USE_WAYLAND
	unset NIRI_SOCKET
	unset XDG_CURRENT_DESKTOP
	unset XDG_SESSION_TYPE
	unset CLAUDE_MENU_BAR
	unset CLAUDE_TITLEBAR_STYLE
	unset COWORK_VM_BACKEND
	unset ELECTRON_USE_SYSTEM_TITLE_BAR
	unset GTK_IM_MODULE
	unset XMODIFIERS
	unset QT_IM_MODULE
	unset CLAUDE_GTK_IM_MODULE
	unset CLAUDE_DISABLE_GPU
	unset CLAUDE_PASSWORD_STORE

	cp "$SCRIPT_DIR/../scripts/launcher-common.sh" "$TEST_TMP/launcher-common.sh"
	cp "$SCRIPT_DIR/../scripts/doctor.sh" "$TEST_TMP/doctor.sh"
	sed -i 's/@@WM_CLASS@@/Claude/' "$TEST_TMP/launcher-common.sh"
	# shellcheck source=scripts/launcher-common.sh
	source "$TEST_TMP/launcher-common.sh"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# setup_logging
# =============================================================================

@test "setup_logging: creates log directory and sets log_file" {
	run setup_logging
	[[ $status -eq 0 ]]
	[[ -d "$XDG_CACHE_HOME/claude-desktop-suse" ]]
}

@test "setup_logging: sets log_file under XDG_CACHE_HOME" {
	setup_logging
	[[ $log_file == "$XDG_CACHE_HOME/claude-desktop-suse/launcher.log" ]]
}

@test "setup_logging: falls back to HOME/.cache when XDG_CACHE_HOME unset" {
	unset XDG_CACHE_HOME
	setup_logging
	[[ $log_dir == "$HOME/.cache/claude-desktop-suse" ]]
	[[ -d "$HOME/.cache/claude-desktop-suse" ]]
}

# =============================================================================
# log_message
# =============================================================================

@test "log_message: appends message to log file" {
	setup_logging
	log_message "test message one"
	log_message "test message two"
	[[ -f $log_file ]]
	run cat "$log_file"
	[[ "${lines[0]}" == "test message one" ]]
	[[ "${lines[1]}" == "test message two" ]]
}

@test "log_message: joins multiple arguments" {
	setup_logging
	log_message "first fragment" "second fragment"

	run cat "$log_file"
	[[ $status -eq 0 ]]
	[[ $output == "first fragment second fragment" ]]
}

@test "log_message: is a no-op before logging is configured" {
	unset log_file

	run log_message "message before setup"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "setup_logging: rotates oversized log and keeps two generations" {
	local log_path="$XDG_CACHE_HOME/claude-desktop-suse/launcher.log"
	mkdir -p "$(dirname "$log_path")"
	printf 'oldest\n' > "$log_path.2"
	printf 'older\n' > "$log_path.1"
	truncate -s 5242881 "$log_path"

	run setup_logging
	[[ $status -eq 0 ]]
	[[ -f $log_path.1 ]]
	[[ -f $log_path.2 ]]
	[[ ! -f $log_path.3 ]]
	[[ $(stat -c '%s' "$log_path.1") -eq 5242881 ]]
	[[ $(<"$log_path.2") == 'older' ]]
}

@test "setup_logging: leaves log below rotation threshold unchanged" {
	local log_path="$XDG_CACHE_HOME/claude-desktop-suse/launcher.log"
	mkdir -p "$(dirname "$log_path")"
	printf 'small\n' > "$log_path"

	run setup_logging
	[[ $status -eq 0 ]]
	[[ ! -e $log_path.1 ]]
	[[ $(<"$log_path") == 'small' ]]
}

# =============================================================================
# log_session_env
# =============================================================================

@test "log_session_env: emits env={ ... } block with all required keys" {
	setup_logging
	XDG_SESSION_TYPE='wayland'
	WAYLAND_DISPLAY='wayland-0'
	DISPLAY=':0'
	XDG_CURRENT_DESKTOP='KDE'
	GTK_IM_MODULE='ibus'
	# shellcheck disable=SC2034 # read indirectly via ${!key} in log_session_env()
	XMODIFIERS='@im=ibus'
	# shellcheck disable=SC2034 # read indirectly via ${!key} in log_session_env()
	QT_IM_MODULE='ibus'
	CLAUDE_USE_WAYLAND='1'
	CLAUDE_TITLEBAR_STYLE='hybrid'
	CLAUDE_PASSWORD_STORE='basic'
	CLAUDE_GTK_IM_MODULE='xim'
	CLAUDE_DISABLE_GPU='1'
	log_session_env

	run cat "$log_file"
	# Exact-line match locks block structure (open/close braces on
	# their own lines) and per-key formatting in one pass.
	[[ "${lines[0]}"  == 'env={' ]]
	[[ "${lines[1]}"  == '  XDG_SESSION_TYPE=wayland' ]]
	[[ "${lines[2]}"  == '  WAYLAND_DISPLAY=wayland-0' ]]
	[[ "${lines[3]}"  == '  DISPLAY=:0' ]]
	[[ "${lines[4]}"  == '  XDG_CURRENT_DESKTOP=KDE' ]]
	[[ "${lines[5]}"  == '  GTK_IM_MODULE=ibus' ]]
	[[ "${lines[6]}"  == '  XMODIFIERS=@im=ibus' ]]
	[[ "${lines[7]}"  == '  QT_IM_MODULE=ibus' ]]
	[[ "${lines[8]}"  == '  CLAUDE_USE_WAYLAND=1' ]]
	[[ "${lines[9]}"  == '  CLAUDE_TITLEBAR_STYLE=hybrid' ]]
	[[ "${lines[10]}" == '  CLAUDE_PASSWORD_STORE=basic' ]]
	[[ "${lines[11]}" == '  CLAUDE_GTK_IM_MODULE=xim' ]]
	[[ "${lines[12]}" == '  CLAUDE_DISABLE_GPU=1' ]]
	[[ "${lines[13]}" == '}' ]]
}

@test "log_session_env: unset/empty values render as 'KEY=' (no value)" {
	setup_logging
	# All vars unset by setup() except this one, which exercises the
	# empty-string branch (must be indistinguishable from unset).
	GTK_IM_MODULE=''
	unset CLAUDE_PASSWORD_STORE
	log_session_env

	run cat "$log_file"
	# Exact-line match proves the line ends right after '=' — a
	# substring like *'KEY='* would also match 'KEY=value'.
	[[ "${lines[1]}"  == '  XDG_SESSION_TYPE=' ]]
	[[ "${lines[2]}"  == '  WAYLAND_DISPLAY=' ]]
	[[ "${lines[3]}"  == '  DISPLAY=' ]]
	[[ "${lines[4]}"  == '  XDG_CURRENT_DESKTOP=' ]]
	[[ "${lines[5]}"  == '  GTK_IM_MODULE=' ]]
	[[ "${lines[6]}"  == '  XMODIFIERS=' ]]
	[[ "${lines[7]}"  == '  QT_IM_MODULE=' ]]
	[[ "${lines[8]}"  == '  CLAUDE_USE_WAYLAND=' ]]
	[[ "${lines[9]}"  == '  CLAUDE_TITLEBAR_STYLE=' ]]
	[[ "${lines[10]}" == '  CLAUDE_PASSWORD_STORE=' ]]
	[[ "${lines[11]}" == '  CLAUDE_GTK_IM_MODULE=' ]]
	[[ "${lines[12]}" == '  CLAUDE_DISABLE_GPU=' ]]
}

# =============================================================================
# check_display
# =============================================================================

@test "check_display: fails when no display variables set" {
	unset DISPLAY
	unset WAYLAND_DISPLAY
	run check_display
	[[ $status -ne 0 ]]
}

@test "check_display: succeeds with DISPLAY set" {
	DISPLAY=":0"
	run check_display
	[[ $status -eq 0 ]]
}

@test "check_display: succeeds with WAYLAND_DISPLAY set" {
	WAYLAND_DISPLAY="wayland-0"
	run check_display
	[[ $status -eq 0 ]]
}

@test "check_display: succeeds with both set" {
	DISPLAY=":0"
	WAYLAND_DISPLAY="wayland-0"
	run check_display
	[[ $status -eq 0 ]]
}

# =============================================================================
# detect_display_backend
# =============================================================================

@test "detect_display_backend: X11 session sets is_wayland=false" {
	DISPLAY=":0"
	setup_logging
	detect_display_backend
	[[ $is_wayland == false ]]
}

@test "detect_display_backend: Wayland session sets is_wayland=true" {
	WAYLAND_DISPLAY="wayland-0"
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
}

@test "detect_display_backend: defaults to XWayland on Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
	[[ $use_x11_on_wayland == true ]]
}

@test "detect_display_backend: CLAUDE_USE_WAYLAND=1 forces native Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	CLAUDE_USE_WAYLAND=1
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri detected via NIRI_SOCKET forces native Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	NIRI_SOCKET="/tmp/niri.sock"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri detected via XDG_CURRENT_DESKTOP forces native Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="niri"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri in colon-separated XDG_CURRENT_DESKTOP" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="niri:GNOME"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri case-insensitive detection" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="NIRI"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: non-Niri Wayland keeps XWayland default" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="sway"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == true ]]
}

@test "detect_display_backend: Niri not forced when CLAUDE_USE_WAYLAND already set" {
	# CLAUDE_USE_WAYLAND=1 already forces native, Niri detection shouldn't conflict
	WAYLAND_DISPLAY="wayland-0"
	CLAUDE_USE_WAYLAND=1
	NIRI_SOCKET="/tmp/niri.sock"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

# =============================================================================
# build_electron_args
# =============================================================================

@test "build_electron_args: X11 rpm - only CustomTitlebar disabled" {
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--disable-features=CustomTitlebar'
	has_electron_arg '--class=Claude'
	has_electron_arg '--password-store=basic'
	# shellcheck disable=SC2314 # last command in test, ! works correctly
	! has_electron_arg '--no-sandbox'
}

@test "build_electron_args: X11 appimage - includes --no-sandbox" {
	is_wayland=false
	setup_logging
	build_electron_args appimage
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: Wayland XWayland rpm - includes x11 platform and no-sandbox" {
	is_wayland=true
	use_x11_on_wayland=true
	setup_logging
	build_electron_args rpm
	has_electron_arg '--ozone-platform=x11'
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: Wayland native rpm - includes wayland platform flags" {
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--ozone-platform=wayland'
	has_electron_arg '--enable-wayland-ime'
	has_electron_arg '*WaylandWindowDecorations*'
}

@test "build_electron_args: Wayland appimage - always includes --no-sandbox" {
	is_wayland=true
	use_x11_on_wayland=true
	setup_logging
	build_electron_args appimage
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: Wayland native includes text-input-version=3" {
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--wayland-text-input-version=3'
}

# =============================================================================
# _detect_password_store
# =============================================================================

@test "_detect_password_store: CLAUDE_PASSWORD_STORE env var wins without calling dbus-send" {
	CLAUDE_PASSWORD_STORE='mystore'
	_stub_dbus_send fail
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'mystore' ]]
}

@test "_detect_password_store: falls back to kwallet6 when kwallet6 dbus-send call succeeds" {
	unset CLAUDE_PASSWORD_STORE
	_stub_dbus_send kwallet6
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'kwallet6' ]]
}

@test "_detect_password_store: falls back to gnome-libsecret when kwallet6 fails but secrets ping succeeds" {
	unset CLAUDE_PASSWORD_STORE
	_stub_dbus_send secrets-ok
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'gnome-libsecret' ]]
}

@test "_detect_password_store: falls back to basic when both dbus-send calls fail" {
	unset CLAUDE_PASSWORD_STORE
	_stub_dbus_send fail
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'basic' ]]
}

# =============================================================================
# setup_electron_env
# =============================================================================

_write_launcher_cfg() {
	mkdir -p "$XDG_CONFIG_HOME/claude-desktop-suse"
	printf '%s\n' "$@" \
		> "$XDG_CONFIG_HOME/claude-desktop-suse/environment"
}

# =============================================================================
# load_launcher_config
# =============================================================================

@test "load_launcher_config: every SUSE allowlisted key round-trips" {
	_write_launcher_cfg \
		'CLAUDE_USE_WAYLAND=1' \
		'CLAUDE_PASSWORD_STORE=gnome-libsecret' \
		'CLAUDE_GTK_IM_MODULE=xim' \
		'CLAUDE_DISABLE_GPU=1' \
		'CLAUDE_TITLEBAR_STYLE=native' \
		'CLAUDE_MENU_BAR=visible' \
		'CLAUDE_KEEP_AWAKE=0' \
		'COWORK_VM_BACKEND=bwrap'
	load_launcher_config
	[[ $CLAUDE_USE_WAYLAND == '1' ]]
	[[ $CLAUDE_PASSWORD_STORE == 'gnome-libsecret' ]]
	[[ $CLAUDE_GTK_IM_MODULE == 'xim' ]]
	[[ $CLAUDE_DISABLE_GPU == '1' ]]
	[[ $CLAUDE_TITLEBAR_STYLE == 'native' ]]
	[[ $CLAUDE_MENU_BAR == 'visible' ]]
	[[ $CLAUDE_KEEP_AWAKE == '0' ]]
	[[ $COWORK_VM_BACKEND == 'bwrap' ]]
}

@test "load_launcher_config: ignores keys outside the allowlist" {
	unset LD_PRELOAD
	_write_launcher_cfg 'LD_PRELOAD=/tmp/evil.so'
	load_launcher_config
	[[ -z ${LD_PRELOAD:-} ]]
}

@test "load_launcher_config: existing environment wins over config" {
	export CLAUDE_TITLEBAR_STYLE='hidden'
	_write_launcher_cfg 'CLAUDE_TITLEBAR_STYLE=native'
	load_launcher_config
	[[ $CLAUDE_TITLEBAR_STYLE == 'hidden' ]]
}

@test "load_launcher_config: missing file is a silent no-op" {
	run load_launcher_config
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "load_launcher_config: skips comments and blank lines" {
	_write_launcher_cfg \
		'# a comment' \
		'' \
		'   ' \
		'  # an indented comment' \
		'CLAUDE_MENU_BAR=visible'
	load_launcher_config
	[[ $CLAUDE_MENU_BAR == 'visible' ]]
}

@test "load_launcher_config: trims whitespace and surrounding quotes" {
	_write_launcher_cfg ' CLAUDE_PASSWORD_STORE = "gnome-libsecret" '
	load_launcher_config
	[[ $CLAUDE_PASSWORD_STORE == 'gnome-libsecret' ]]
}

@test "setup_electron_env: sets ELECTRON_FORCE_IS_PACKAGED" {
	setup_electron_env
	[[ $ELECTRON_FORCE_IS_PACKAGED == 'true' ]]
}

@test "setup_electron_env: sets ELECTRON_USE_SYSTEM_TITLE_BAR in hybrid mode (default)" {
	setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

@test "setup_electron_env: sets ELECTRON_USE_SYSTEM_TITLE_BAR in native mode" {
	CLAUDE_TITLEBAR_STYLE=native setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

@test "setup_electron_env: skips ELECTRON_USE_SYSTEM_TITLE_BAR in hidden mode" {
	CLAUDE_TITLEBAR_STYLE=hidden setup_electron_env
	[[ -z ${ELECTRON_USE_SYSTEM_TITLE_BAR:-} ]]
}

@test "setup_electron_env: skips ELECTRON_USE_SYSTEM_TITLE_BAR for invalid value (falls back to hybrid)" {
	CLAUDE_TITLEBAR_STYLE=garbage setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE set propagates to GTK_IM_MODULE" {
	setup_logging
	# shellcheck disable=SC2030 # Bats @test subshell mutation is intentional
	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE='xim'
	setup_electron_env
	[[ $GTK_IM_MODULE == 'xim' ]]
	# Override is logged so users can verify it took effect
	run cat "$log_file"
	[[ $output == *'GTK_IM_MODULE override: ibus -> xim (via CLAUDE_GTK_IM_MODULE)'* ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE set logs <unset> when GTK_IM_MODULE was unset" {
	setup_logging
	# GTK_IM_MODULE unset by setup()
	CLAUDE_GTK_IM_MODULE='xim'
	setup_electron_env
	# shellcheck disable=SC2031 # value intentionally observed within the same Bats test subshell
	[[ $GTK_IM_MODULE == 'xim' ]]
	run cat "$log_file"
	[[ $output == *'GTK_IM_MODULE override: <unset> -> xim (via CLAUDE_GTK_IM_MODULE)'* ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE unset leaves GTK_IM_MODULE alone" {
	setup_logging
	GTK_IM_MODULE='ibus'
	# CLAUDE_GTK_IM_MODULE unset by setup()
	setup_electron_env
	[[ $GTK_IM_MODULE == 'ibus' ]]
	# No override line should appear in the log
	run cat "$log_file"
	[[ $output != *'GTK_IM_MODULE override'* ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE empty leaves GTK_IM_MODULE alone" {
	setup_logging
	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE=''
	setup_electron_env
	[[ $GTK_IM_MODULE == 'ibus' ]]
	run cat "$log_file"
	[[ $output != *'GTK_IM_MODULE override'* ]]
}

# =============================================================================
# _resolve_titlebar_style
# =============================================================================

@test "_resolve_titlebar_style: returns 'hybrid' when unset" {
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: returns 'hybrid' for hybrid" {
	CLAUDE_TITLEBAR_STYLE=hybrid
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: returns 'native' for native" {
	CLAUDE_TITLEBAR_STYLE=native
	[[ $(_resolve_titlebar_style) == 'native' ]]
}

@test "_resolve_titlebar_style: returns 'hidden' for hidden" {
	CLAUDE_TITLEBAR_STYLE=hidden
	[[ $(_resolve_titlebar_style) == 'hidden' ]]
}

@test "_resolve_titlebar_style: case-insensitive (HYBRID)" {
	CLAUDE_TITLEBAR_STYLE=HYBRID
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: case-insensitive (Native)" {
	CLAUDE_TITLEBAR_STYLE=Native
	[[ $(_resolve_titlebar_style) == 'native' ]]
}

@test "_resolve_titlebar_style: case-insensitive (Hidden)" {
	CLAUDE_TITLEBAR_STYLE=Hidden
	[[ $(_resolve_titlebar_style) == 'hidden' ]]
}

@test "_resolve_titlebar_style: falls back to hybrid for invalid value" {
	CLAUDE_TITLEBAR_STYLE=garbage
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: falls back to hybrid for empty value" {
	CLAUDE_TITLEBAR_STYLE=''
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

# =============================================================================
# build_electron_args: titlebar mode flag selection
# =============================================================================

@test "build_electron_args: hybrid mode (default) disables CustomTitlebar" {
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--disable-features=CustomTitlebar'
	# shellcheck disable=SC2314
	! has_electron_arg '--enable-features=WindowControlsOverlay'
}

@test "build_electron_args: native mode disables CustomTitlebar" {
	CLAUDE_TITLEBAR_STYLE=native
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--disable-features=CustomTitlebar'
	# shellcheck disable=SC2314
	! has_electron_arg '--enable-features=WindowControlsOverlay'
}

@test "build_electron_args: hidden mode enables WindowControlsOverlay" {
	CLAUDE_TITLEBAR_STYLE=hidden
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--enable-features=WindowControlsOverlay'
	# shellcheck disable=SC2314
	! has_electron_arg '--disable-features=CustomTitlebar'
}

@test "build_electron_args: invalid titlebar value falls back to hybrid flags" {
	CLAUDE_TITLEBAR_STYLE=garbage
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--disable-features=CustomTitlebar'
}

# =============================================================================
# cleanup_stale_lock
# =============================================================================

@test "cleanup_stale_lock: no lock file - returns 0" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
}

@test "cleanup_stale_lock: removes stale lock (dead PID)" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	# Use PID 99999999 which almost certainly doesn't exist
	ln -s "myhost-99999999" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	[[ ! -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: keeps lock for running process" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	# Use our own PID (guaranteed to be running)
	ln -s "myhost-$$" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	# Lock should still exist
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: handles non-numeric PID in lock target" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	ln -s "myhost-notanumber" "$config_dir/SingletonLock"
	setup_logging
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
	# Lock should still exist (function returns early on non-numeric)
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: handles regular file (not symlink)" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	echo "not a symlink" > "$config_dir/SingletonLock"
	setup_logging
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
	# Regular file should not be touched
	[[ -f "$config_dir/SingletonLock" ]]
}

# =============================================================================
# cleanup_stale_cowork_socket
# =============================================================================

@test "cleanup_stale_cowork_socket: no socket - returns 0" {
	run cleanup_stale_cowork_socket
	[[ $status -eq 0 ]]
}

@test "cleanup_stale_cowork_socket: removes stale socket file" {
	# Create a socket-like file (not a real socket, but -S check needs a socket)
	# Use python to create a real unix socket for the test
	local sock="$XDG_RUNTIME_DIR/cowork-vm-service.sock"
	python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.close()
" "$sock" 2>/dev/null || skip "Cannot create test unix socket"

	# Stub pgrep so the test is isolated from host process state:
	# a real cowork-vm-service daemon on the developer machine would
	# trip the function's "daemon alive, leave socket alone" branch.
	pgrep() { return 1; }

	setup_logging
	cleanup_stale_cowork_socket
	[[ ! -S "$sock" ]]
}

# =============================================================================
# Doctor helper functions
# =============================================================================

@test "_doctor_colors: sets color vars when stdout is a terminal" {
	# Force non-terminal to test the else branch
	_doctor_colors
	# When not a terminal, all should be empty
	[[ -z $_green ]]
	[[ -z $_red ]]
	[[ -z $_yellow ]]
	[[ -z $_bold ]]
	[[ -z $_reset ]]
}

@test "_pass: outputs PASS with message" {
	_doctor_colors
	run _pass "test passed"
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"test passed"* ]]
}

@test "_fail: outputs FAIL with message and increments counter" {
	_doctor_colors
	_doctor_failures=0
	_fail "something broke"
	[[ $_doctor_failures -eq 1 ]]
}

@test "_warn: outputs WARN with message" {
	_doctor_colors
	run _warn "warning message"
	[[ $output == *"[WARN]"* ]]
	[[ $output == *"warning message"* ]]
}

@test "_info: outputs indented message" {
	_doctor_colors
	run _info "info message"
	[[ $output == *"info message"* ]]
}

# =============================================================================
# _cowork_distro_id
# =============================================================================

@test "_cowork_distro_id: reads ID from /etc/os-release" {
	# This test uses the real /etc/os-release on the test system
	[[ -f /etc/os-release ]] || skip "No /etc/os-release"
	local result
	result=$(_cowork_distro_id)
	# Should return something non-empty
	[[ -n $result ]]
	[[ $result != 'unknown' ]]
}

# =============================================================================
# _cowork_pkg_hint
# =============================================================================

@test "_cowork_pkg_hint: opensuse uses zypper" {
	local result
	result=$(_cowork_pkg_hint opensuse bubblewrap)
	[[ $result == "sudo zypper install bubblewrap" ]]
}

@test "_cowork_pkg_hint: sles uses zypper" {
	local result
	result=$(_cowork_pkg_hint sles socat)
	[[ $result == "sudo zypper install socat" ]]
}

@test "_cowork_pkg_hint: qemu maps to suse-specific packages" {
	local result
	result=$(_cowork_pkg_hint opensuse qemu)
	[[ $result == "sudo zypper install qemu-x86 qemu-tools" ]]
}

@test "_cowork_pkg_hint: unknown distro gives generic message" {
	local result
	result=$(_cowork_pkg_hint gentoo bubblewrap)
	[[ $result == "Install bubblewrap using your package manager" ]]
}

# =============================================================================
# _electron_version
# =============================================================================

@test "_electron_version: reads version from file beside binary" {
	mkdir -p "$TEST_TMP/electron"
	echo "33.4.0" > "$TEST_TMP/electron/version"
	touch "$TEST_TMP/electron/electron"
	local result
	result=$(_electron_version "$TEST_TMP/electron/electron")
	[[ $result == "33.4.0" ]]
}

@test "_electron_version: returns empty when version file missing" {
	mkdir -p "$TEST_TMP/electron"
	touch "$TEST_TMP/electron/electron"
	local result
	result=$(_electron_version "$TEST_TMP/electron/electron") || true
	[[ -z $result ]]
}
