#!/usr/bin/env bash
# Common launcher functions for Claude Desktop (RPM package)
# This file is sourced by the launcher to avoid code duplication

# Setup logging directory and file
# Sets: log_dir, log_file
setup_logging() {
	log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-suse"
	mkdir -p "$log_dir" || return 1
	log_file="$log_dir/launcher.log"
}

# Log a message to the log file
# Usage: log_message "message"
log_message() {
	echo "$1" >> "$log_file"
}

# Detect display backend (Wayland vs X11)
# Sets: is_wayland, use_x11_on_wayland
detect_display_backend() {
	# Detect if Wayland is running
	is_wayland=false
	[[ -n "${WAYLAND_DISPLAY:-}" ]] && is_wayland=true

	# Default: Use X11/XWayland on Wayland for global hotkey support
	# Set CLAUDE_USE_WAYLAND=1 to use native Wayland (global hotkeys disabled)
	use_x11_on_wayland=true
	[[ "${CLAUDE_USE_WAYLAND:-}" == '1' ]] && use_x11_on_wayland=false

	# Fixes: #226 - Auto-detect compositors that require native Wayland
	# Only Niri is auto-forced: it has no XWayland support.
	# Sway and Hyprland have working XWayland, so users on those
	# compositors who want native Wayland can set CLAUDE_USE_WAYLAND=1.
	# XDG_CURRENT_DESKTOP can be colon-separated (e.g. "niri:GNOME");
	# glob matching with *niri* handles this correctly.
	if [[ $is_wayland == true && $use_x11_on_wayland == true ]]; then
		local desktop="${XDG_CURRENT_DESKTOP:-}"
		desktop="${desktop,,}"

		if [[ -n "${NIRI_SOCKET:-}" || "$desktop" == *niri* ]]; then
			log_message "Niri detected - forcing native Wayland"
			use_x11_on_wayland=false
		fi
	fi
}

# Check if we have a valid display (not running from TTY)
# Returns: 0 if display available, 1 if not
check_display() {
	[[ -n $DISPLAY || -n $WAYLAND_DISPLAY ]]
}

# Build Electron arguments array based on display backend
# Requires: is_wayland, use_x11_on_wayland to be set
#           (call detect_display_backend first)
# Sets: electron_args array
# Arguments: $1 = package type (default: "rpm")
build_electron_args() {
	local package_type="${1:-rpm}"

	electron_args=()

	# AppImage always needs --no-sandbox due to FUSE constraints
	[[ $package_type == 'appimage' ]] && electron_args+=('--no-sandbox')

	# Disable CustomTitlebar for better Linux integration
	electron_args+=('--disable-features=CustomTitlebar')

	# Remote XRDP sessions lack GPU acceleration and render a blank
	# window when GPU compositing is enabled. Detect via XRDP_SESSION
	# (set by xrdp's session init) and loginctl session Type.
	local rdp_session_type=''
	[[ -n ${XDG_SESSION_ID:-} ]] && rdp_session_type=$(
		loginctl show-session "$XDG_SESSION_ID" \
			-p Type --value 2>/dev/null
	)
	if [[ -n ${XRDP_SESSION:-} || $rdp_session_type == xrdp ]]; then
		electron_args+=('--disable-gpu' '--disable-software-rasterizer')
		log_message 'XRDP session detected - GPU compositing disabled'
	fi

	# X11 session - no special flags needed (AppImage --no-sandbox already added above)
	if [[ $is_wayland != true ]]; then
		log_message 'X11 session detected'
		return
	fi

	# Wayland: RPM needs --no-sandbox too
	[[ $package_type == 'rpm' ]] && electron_args+=('--no-sandbox')

	if [[ $use_x11_on_wayland == true ]]; then
		# Default: Use X11 via XWayland for global hotkey support
		log_message 'Using X11 backend via XWayland (for global hotkey support)'
		electron_args+=('--ozone-platform=x11')
	else
		# Native Wayland mode (user opted in via CLAUDE_USE_WAYLAND=1)
		log_message 'Using native Wayland backend (global hotkeys may not work)'
		electron_args+=('--enable-features=UseOzonePlatform,WaylandWindowDecorations')
		electron_args+=('--ozone-platform=wayland')
		electron_args+=('--enable-wayland-ime')
		electron_args+=('--wayland-text-input-version=3')
		# Override any system-wide GDK_BACKEND=x11 that would silently
		# prevent GTK from connecting to the Wayland compositor, causing
		# blurry rendering or launch failures on HiDPI displays.
		export GDK_BACKEND=wayland
	fi
}

# Kill orphaned cowork-vm-service daemon processes.
# After a crash or unclean shutdown the cowork daemon may outlive the
# main Electron UI process.  The orphaned daemon holds LevelDB locks
# in ~/.config/Claude/Local Storage/ AND keeps the Unix socket at
# $XDG_RUNTIME_DIR/cowork-vm-service.sock bound, which causes a new
# launch to either silently quit (LevelDB) or connect to the stale
# daemon (socket) and hang with a blank window.
# Must run BEFORE cleanup_stale_lock / cleanup_stale_cowork_socket
# so that stale files left behind by the daemon can be cleaned up.
cleanup_orphaned_cowork_daemon() {
	local cowork_pids
	cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) \
		|| return 0

	# Check if a live Claude Desktop UI process is also running.
	#
	# We can NOT use `pgrep -f 'claude-desktop'` on its own for this:
	# it matches the launcher's own bash process (this script's
	# cmdline contains "/usr/bin/claude-desktop"), any stale launcher
	# bash left stopped/zombie after a previous crash, and the cowork
	# daemon itself.  Counting any of those as "the UI is alive"
	# causes a false negative and the orphan survives.
	#
	# The reliable definition of "UI is alive" is: an Electron main
	# process whose cmdline references app.asar and is NOT a Chromium
	# helper (--type=...) and NOT the cowork daemon, and is actually
	# runnable (not stopped/zombie).
	local pid cmdline state
	for pid in $(pgrep -f 'app\.asar' 2>/dev/null); do
		# Skip our own launcher bash and its parent.
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) \
			|| continue
		# Skip the cowork daemon (matches app.asar.unpacked path).
		[[ $cmdline == *cowork-vm-service* ]] && continue
		# Skip Chromium helpers: zygote, renderer, gpu, utility, etc.
		[[ $cmdline == *--type=* ]] && continue
		# Skip stopped (T/t) and zombie (Z) processes — not a live UI.
		state=$(awk '/^State:/ {print $2; exit}' \
			"/proc/$pid/status" 2>/dev/null) || continue
		[[ $state == T || $state == t || $state == Z ]] && continue
		# Found a genuine live Electron UI — daemon is expected
		return 0
	done

	# No UI process found — daemon is orphaned, terminate it.
	# Escalate to SIGKILL if a daemon is stuck and does not exit
	# after SIGTERM within ~2s, so cleanup_stale_cowork_socket
	# (which runs next) reliably sees no daemon.
	for pid in $cowork_pids; do
		kill "$pid" 2>/dev/null || true
	done
	local _wait=0
	while ((_wait < 20)); do
		pgrep -f 'cowork-vm-service\.js' &>/dev/null || break
		sleep 0.1
		((_wait++))
	done
	if pgrep -f 'cowork-vm-service\.js' &>/dev/null; then
		for pid in $cowork_pids; do
			kill -KILL "$pid" 2>/dev/null || true
		done
		log_message "Killed orphaned cowork-vm-service daemon (SIGKILL, PIDs: $cowork_pids)"
	else
		log_message "Killed orphaned cowork-vm-service daemon (PIDs: $cowork_pids)"
	fi
}

# Clean up stale SingletonLock if the owning process is no longer running.
# Electron uses requestSingleInstanceLock() which silently quits if the lock
# is held. A stale lock (from a crash or unclean update) blocks all launches
# with no user-facing error message.
# The lock is a symlink whose target is "hostname-PID".
cleanup_stale_lock() {
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local lock_file="$config_dir/SingletonLock"

	[[ -L $lock_file ]] || return 0

	local lock_target
	lock_target="$(readlink "$lock_file" 2>/dev/null)" || return 0

	local lock_pid="${lock_target##*-}"

	# Validate that we extracted a numeric PID
	[[ $lock_pid =~ ^[0-9]+$ ]] || return 0

	if kill -0 "$lock_pid" 2>/dev/null; then
		# Process is still running — lock is valid
		return 0
	fi

	rm -f "$lock_file"
	log_message "Removed stale SingletonLock (PID $lock_pid no longer running)"
}

# Clean up stale cowork-vm-service socket if no daemon is listening.
# The service daemon creates a Unix socket at
# $XDG_RUNTIME_DIR/cowork-vm-service.sock. After a crash or unclean
# shutdown, the socket file persists but nothing is listening, causing
# ECONNREFUSED instead of ENOENT when the app tries to connect.
#
# NOTE: this function MUST run after cleanup_orphaned_cowork_daemon,
# which is responsible for killing any orphaned daemon.  Given that
# ordering, the presence of a live daemon proves the socket is in
# use; the absence of a daemon proves the socket is stale.
cleanup_stale_cowork_socket() {
	local sock="${XDG_RUNTIME_DIR:-/tmp}/cowork-vm-service.sock"

	[[ -S $sock ]] || return 0

	# If a cowork daemon is alive, it owns this socket; leave it.
	# cleanup_orphaned_cowork_daemon has already run and removed any
	# orphan (with SIGKILL escalation), so anything still alive here
	# is a non-orphaned, live daemon.
	if pgrep -f 'cowork-vm-service\.js' &>/dev/null; then
		return 0
	fi

	# No daemon — the socket file is left over from a crash.
	rm -f "$sock"
	log_message "Removed stale cowork-vm-service socket (no daemon running)"
}

# Clean up resources after Electron exits.
# Kills any leftover systemd user scope created for the app and
# removes shared-memory segments that Chromium may have left behind.
# This prevents ghost "electron" entries in KDE System Monitor.
cleanup_after_exit() {
	log_message 'Running post-exit cleanup'

	# Stop orphaned cowork daemon (in case quit handler didn't fire)
	local cowork_pids
	cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) || true
	if [[ -n $cowork_pids ]]; then
		# Only kill if no Claude Desktop UI process is running
		local has_ui=false pid cmdline
		for pid in $(pgrep -f 'claude-desktop' 2>/dev/null); do
			cmdline=$(tr '\0' ' ' \
				< "/proc/$pid/cmdline" 2>/dev/null) || continue
			[[ $cmdline == *cowork-vm-service* ]] && continue
			has_ui=true
			break
		done
		if [[ $has_ui == false ]]; then
			kill $cowork_pids 2>/dev/null || true
			log_message "Terminated orphaned cowork daemon after exit"
		fi
	fi

	# Clean up stale cowork socket
	local sock="${XDG_RUNTIME_DIR:-/tmp}/cowork-vm-service.sock"
	if [[ -S $sock ]]; then
		rm -f "$sock"
		log_message "Removed cowork socket after exit"
	fi

	# Stop MCP server containers that were spawned by Electron.
	#
	# When Claude Desktop launches MCP servers via podman, those
	# container processes inherit the app-electron-*.scope cgroup.
	# After Electron exits the containers keep running, and KDE
	# System Monitor shows a ghost "electron" application entry
	# because the cgroup (named after electron) is still alive.
	#
	# Find every app-electron-*.scope under the user slice, collect
	# the PIDs still inside it, and gracefully stop any podman
	# containers whose processes live in that scope.
	local cgroup_base='/sys/fs/cgroup/user.slice'
	cgroup_base+="/user-$(id -u).slice/user@$(id -u).service/app.slice"

	local scope_dir
	for scope_dir in "$cgroup_base"/app-electron-*.scope; do
		[[ -d $scope_dir ]] || continue
		local procs_file="$scope_dir/cgroup.procs"
		[[ -r $procs_file ]] || continue

		# Read PIDs still alive in this scope
		local remaining_pids
		remaining_pids=$(awk '{print $NF}' "$procs_file" 2>/dev/null) \
			|| continue
		[[ -n $remaining_pids ]] || continue

		local scope_name
		scope_name=$(basename "$scope_dir")
		log_message "Found lingering cgroup: $scope_name"

		# Identify running podman containers whose processes
		# are inside this scope, then stop them gracefully.
		if command -v podman &>/dev/null; then
			local container_ids
			container_ids=$(podman ps -q 2>/dev/null) || true
			if [[ -n $container_ids ]]; then
				local cid cid_pid
				for cid in $container_ids; do
					cid_pid=$(podman inspect --format '{{.State.Pid}}' \
						"$cid" 2>/dev/null) || continue
					[[ -n $cid_pid && $cid_pid != '0' ]] || continue
					# Check if the container's init process
					# lives in this electron scope
					local pid_cgroup
					pid_cgroup=$(cat "/proc/$cid_pid/cgroup" \
						2>/dev/null) || continue
					if [[ $pid_cgroup == *"$scope_name"* ]]; then
						log_message \
							"Stopping MCP container $cid (PID $cid_pid)"
						podman stop -t 5 "$cid" 2>/dev/null || true
					fi
				done
			fi
		fi

		# Kill any non-container processes still lingering
		# (re-read after podman stop since containers should be gone)
		remaining_pids=$(awk '{print $NF}' "$procs_file" 2>/dev/null) \
			|| true
		if [[ -n $remaining_pids ]]; then
			local p
			for p in $remaining_pids; do
				kill "$p" 2>/dev/null || true
			done
			sleep 0.5
			remaining_pids=$(awk '{print $NF}' "$procs_file" \
				2>/dev/null) || true
			for p in $remaining_pids; do
				kill -9 "$p" 2>/dev/null || true
			done
			log_message "Killed remaining processes in $scope_name"
		fi

		# Reset the now-empty scope so KDE drops the entry
		if command -v systemctl &>/dev/null; then
			systemctl --user stop "$scope_name" 2>/dev/null || true
			systemctl --user reset-failed "$scope_name" \
				2>/dev/null || true
			log_message "Stopped systemd scope: $scope_name"
		fi
	done
}

# Set common environment variables
# Arguments: $1 = package type ("deb", "appimage", "rpm", or "nix")
setup_electron_env() {
	local package_type="${1:-rpm}"

	# ELECTRON_FORCE_IS_PACKAGED makes app.isPackaged return true, which
	# causes the Claude app to resolve resources via process.resourcesPath.
	# On NixOS, Electron is a separate store path so resourcesPath points
	# to Electron's resources dir, not the app's.  The frame-fix-wrapper
	# corrects this at JS load time, but some app code may run before the
	# fix or cache the original value.  Skipping this env var for Nix
	# keeps isPackaged=false, using development-style fallback paths that
	# work correctly with NixOS's split-package layout.
	if [[ $package_type != 'nix' ]]; then
		export ELECTRON_FORCE_IS_PACKAGED=true
	fi
	export ELECTRON_USE_SYSTEM_TITLE_BAR=1
}

#===============================================================================
# Doctor Diagnostics
#===============================================================================

# Color helpers (disabled when stdout is not a terminal)
_doctor_colors() {
	if [[ -t 1 ]]; then
		_green='\033[0;32m'
		_red='\033[0;31m'
		_yellow='\033[0;33m'
		_bold='\033[1m'
		_reset='\033[0m'
	else
		_green='' _red='' _yellow='' _bold='' _reset=''
	fi
}

# Return the distro ID from /etc/os-release
_cowork_distro_id() {
	local id='unknown'
	if [[ -f /etc/os-release ]]; then
		local line
		while IFS= read -r line; do
			if [[ $line == ID=* ]]; then
				id="${line#ID=}"
				id="${id//\"/}"
				break
			fi
		done < /etc/os-release
	fi
	printf '%s' "$id"
}

# Return a distro-specific install command for a cowork tool
# Usage: _cowork_pkg_hint <distro_id> <tool_name>
_cowork_pkg_hint() {
	local distro="$1"
	local tool="$2"
	local pkg_cmd

	# Determine package manager command
	case "$distro" in
		suse|opensuse*) pkg_cmd='sudo zypper install' ;;
		debian|ubuntu)  pkg_cmd='sudo apt install' ;;
		fedora)         pkg_cmd='sudo dnf install' ;;
		arch)           pkg_cmd='sudo pacman -S' ;;
		*)              pkg_cmd='sudo zypper install' ;;
	esac

	# Map tool name to distro-specific package(s)
	local pkg
	case "$tool" in
		qemu)
			case "$distro" in
				suse|opensuse*) pkg='qemu-kvm qemu-tools' ;;
				debian|ubuntu)  pkg='qemu-system-x86 qemu-utils' ;;
				fedora)         pkg='qemu-kvm qemu-img' ;;
				arch)           pkg='qemu-full' ;;
				*)              pkg='qemu-kvm qemu-tools' ;;
			esac
			;;
		*) pkg="$tool" ;;
	esac

	printf '%s' "$pkg_cmd $pkg"
}

# Read the version string from the version file beside an Electron binary.
# Prints the raw version string, or nothing if unavailable.
_electron_version() {
	local version_file
	version_file="$(dirname "$1")/version"
	[[ -r $version_file ]] && printf '%s' "$(< "$version_file")"
}

_pass() { echo -e "${_green}[PASS]${_reset} $*"; }
_fail() {
	echo -e "${_red}[FAIL]${_reset} $*"
	_doctor_failures=$((_doctor_failures + 1))
}
_warn() { echo -e "${_yellow}[WARN]${_reset} $*"; }
_info() { echo -e "       $*"; }

# Check custom bwrap mount configuration and report findings
_doctor_check_bwrap_mounts() {
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local config_file="$config_dir/claude_desktop_linux_config.json"

	[[ -f $config_file ]] || return 0

	local parser=''
	if command -v python3 &>/dev/null; then
		parser='python3'
	elif command -v node &>/dev/null; then
		parser='node'
	else
		return 0
	fi

	local mounts_json=''
	if [[ $parser == 'python3' ]]; then
		mounts_json=$(python3 - "$config_file" 2>/dev/null <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    mounts = cfg.get('preferences', {}).get('coworkBwrapMounts', {})
    if mounts:
        print(json.dumps(mounts))
except Exception:
    pass
PYEOF
)
	else
		mounts_json=$(node - "$config_file" 2>/dev/null <<'JSEOF'
try {
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const m = (cfg.preferences || {}).coworkBwrapMounts || {};
    if (Object.keys(m).length > 0)
        process.stdout.write(JSON.stringify(m));
} catch (_) {}
JSEOF
)
	fi

	if [[ -z $mounts_json ]]; then
		_info 'Bwrap mounts: default (no custom configuration)'
		return 0
	fi

	_info 'Bwrap custom mount configuration detected:'

	local parsed_output=''
	if [[ $parser == 'python3' ]]; then
		parsed_output=$(python3 - "$mounts_json" 2>/dev/null <<'PYEOF'
import json, sys
m = json.loads(sys.argv[1])
for p in m.get('additionalROBinds', []):
    print(p)
print('---')
for p in m.get('additionalBinds', []):
    print(p)
print('---')
for p in m.get('disabledDefaultBinds', []):
    print(p)
PYEOF
)
	else
		parsed_output=$(node - "$mounts_json" 2>/dev/null <<'JSEOF'
const m = JSON.parse(process.argv[1]);
(m.additionalROBinds || []).forEach(p => console.log(p));
console.log('---');
(m.additionalBinds || []).forEach(p => console.log(p));
console.log('---');
(m.disabledDefaultBinds || []).forEach(p => console.log(p));
JSEOF
)
	fi

	local ro_binds='' rw_binds='' disabled_binds=''
	local section=0
	while IFS= read -r line; do
		if [[ $line == '---' ]]; then
			((section++))
			continue
		fi
		case $section in
			0) ro_binds+="${line}"$'\n' ;;
			1) rw_binds+="${line}"$'\n' ;;
			2) disabled_binds+="${line}"$'\n' ;;
		esac
	done <<< "$parsed_output"
	ro_binds=${ro_binds%$'\n'}
	rw_binds=${rw_binds%$'\n'}
	disabled_binds=${disabled_binds%$'\n'}

	if [[ -n $ro_binds ]]; then
		_info '  Read-only mounts:'
		while IFS= read -r bind_path; do
			_info "    - $bind_path"
		done <<< "$ro_binds"
	fi

	if [[ -n $rw_binds ]]; then
		_info '  Read-write mounts:'
		while IFS= read -r bind_path; do
			_info "    - $bind_path"
		done <<< "$rw_binds"
	fi

	local critical_warned=false
	if [[ -n $disabled_binds ]]; then
		while IFS= read -r bind_path; do
			case "$bind_path" in
				/usr|/etc)
					_warn \
						"Disabled default mount: $bind_path" \
						'(may break system tools!)'
					critical_warned=true
					;;
				*)
					_info "  Disabled default mount: $bind_path"
					;;
			esac
		done <<< "$disabled_binds"
		if [[ $critical_warned == true ]]; then
			_info \
				'  Disabling /usr or /etc may cause commands' \
				'to fail inside the sandbox.'
			_info \
				'  Restart the daemon after config changes:' \
				'pkill -f cowork-vm-service'
		fi
	fi

	if [[ $critical_warned != true ]]; then
		_info \
			'  Note: Restart daemon for config changes:' \
			'pkill -f cowork-vm-service'
	fi
}

# Run all diagnostic checks and print results
# Arguments: $1 = electron path (optional, for package-specific checks)
run_doctor() {
	local electron_path="${1:-}"
	local _doctor_failures=0
	_doctor_colors

	echo -e "${_bold}Claude Desktop Diagnostics${_reset}"
	echo '================================'
	echo

	# -- Installed package version --
	if command -v rpm &>/dev/null; then
		local pkg_version
		pkg_version=$(rpm -q --queryformat='%{VERSION}-%{RELEASE}' \
			claude-desktop 2>/dev/null) || true
		if [[ -n $pkg_version && $pkg_version != *'not installed'* ]]; then
			_pass "Installed version: $pkg_version"
		else
			_warn 'claude-desktop not found via rpm (AppImage?)'
		fi
	fi

	# -- Display server --
	if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
		_pass "Display server: Wayland (WAYLAND_DISPLAY=$WAYLAND_DISPLAY)"
		local desktop="${XDG_CURRENT_DESKTOP:-unknown}"
		_info "Desktop: $desktop"
		if [[ "${CLAUDE_USE_WAYLAND:-}" == '1' ]]; then
			_info 'Mode: native Wayland (CLAUDE_USE_WAYLAND=1)'
		else
			_info 'Mode: X11 via XWayland (default, for global hotkey support)'
			_info 'Tip: Set CLAUDE_USE_WAYLAND=1 for native Wayland'
			_info '     (disables global hotkeys)'
		fi
	elif [[ -n "${DISPLAY:-}" ]]; then
		_pass "Display server: X11 (DISPLAY=$DISPLAY)"
	else
		_fail "No display server detected" \
			"(DISPLAY and WAYLAND_DISPLAY are unset)"
		_info 'Fix: Run from within an X11 or Wayland session, not a TTY'
	fi

	# -- Menu bar mode --
	local menu_bar_mode="${CLAUDE_MENU_BAR:-}"
	if [[ -n $menu_bar_mode ]]; then
		local resolved_mode="${menu_bar_mode,,}"
		# Resolve boolean-style aliases
		case "$resolved_mode" in
			1|true|yes|on) resolved_mode='visible' ;;
			0|false|no|off) resolved_mode='hidden' ;;
		esac
		case "$resolved_mode" in
			auto|visible|hidden)
				_pass "Menu bar mode: $resolved_mode" \
					"(CLAUDE_MENU_BAR=$menu_bar_mode)"
				;;
			*)
				_warn "Unknown CLAUDE_MENU_BAR: '$menu_bar_mode'"
				_info 'Will fall back to auto'
				_info 'Valid values: auto, visible, hidden' \
					'(or 0/1/true/false/yes/no/on/off)'
				;;
		esac
	else
		_info 'Menu bar mode: auto (default, Alt toggles visibility)'
	fi

	# -- Electron binary --
	# Version is read from the file next to the binary rather than
	# launching Electron, which can hang (see #371).
	if [[ -n $electron_path && -x $electron_path ]]; then
		local ver
		ver=$(_electron_version "$electron_path")
		if [[ $ver =~ ^v?[0-9]+\.[0-9]+ ]]; then
			_pass "Electron: v${ver#v} ($electron_path)"
		else
			_pass "Electron: found at $electron_path"
		fi
	elif [[ -n $electron_path ]]; then
		_fail "Electron binary not found at $electron_path"
		_info 'Fix: Reinstall claude-desktop package'
	elif command -v electron &>/dev/null; then
		local ver
		ver=$(_electron_version "$(command -v electron)")
		_pass "Electron: ${ver:+v${ver#v} }(system)"
	else
		_fail 'Electron binary not found'
		_info 'Fix: Reinstall claude-desktop package'
	fi

	# -- Chrome sandbox permissions --
	local sandbox_paths=(
		'/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox'
	)
	# Also check relative to the provided electron path
	if [[ -n $electron_path ]]; then
		local electron_dir
		electron_dir=$(dirname "$electron_path")
		sandbox_paths+=("$electron_dir/chrome-sandbox")
	fi
	local sandbox_checked=false
	for sandbox_path in "${sandbox_paths[@]}"; do
		if [[ -f $sandbox_path ]]; then
			sandbox_checked=true
			local sandbox_perms sandbox_owner
			sandbox_perms=$(stat -c '%a' "$sandbox_path" 2>/dev/null) || true
			sandbox_owner=$(stat -c '%U' "$sandbox_path" 2>/dev/null) || true
			if [[ $sandbox_perms == '4755' && $sandbox_owner == 'root' ]]; then
				_pass "Chrome sandbox: permissions OK ($sandbox_path)"
			else
				_fail "Chrome sandbox: perms=${sandbox_perms:-?},\
 owner=${sandbox_owner:-?}"
				_info "Fix: sudo chown root:root $sandbox_path"
				_info "     sudo chmod 4755 $sandbox_path"
			fi
			break
		fi
	done
	if [[ $sandbox_checked == false ]]; then
		_warn 'Chrome sandbox not found (expected for AppImage)'
	fi

	# -- SingletonLock --
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local lock_file="$config_dir/SingletonLock"
	if [[ -L $lock_file ]]; then
		local lock_target lock_pid
		lock_target="$(readlink "$lock_file" 2>/dev/null)" || true
		lock_pid="${lock_target##*-}"
		if [[ $lock_pid =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
			_pass "SingletonLock: held by running process (PID $lock_pid)"
		else
			_warn "SingletonLock: stale lock found" \
				"(PID $lock_pid is not running)"
			_info "Fix: rm '$lock_file'"
		fi
	else
		_pass 'SingletonLock: no lock file (OK)'
	fi

	# -- MCP config --
	local mcp_config="$config_dir/claude_desktop_config.json"
	if [[ -f $mcp_config ]]; then
		if command -v python3 &>/dev/null; then
			if python3 -c \
			"import json,sys; json.load(open(sys.argv[1]))" \
			"$mcp_config" 2>/dev/null; then
				_pass "MCP config: valid JSON ($mcp_config)"
				# Check if any MCP servers are configured
				local server_count
				server_count=$(python3 -c "
import json,sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
servers = cfg.get('mcpServers', {})
print(len(servers))
" "$mcp_config" 2>/dev/null) || server_count='0'
				_info "MCP servers configured: $server_count"
			else
				_fail "MCP config: invalid JSON"
				_info "Fix: Check $mcp_config for syntax errors"
				_info "Tip: python3 -m json.tool '$mcp_config' to see the error"
			fi
		elif command -v node &>/dev/null; then
			if node -e \
			"JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" \
			"$mcp_config" 2>/dev/null; then
				_pass "MCP config: valid JSON ($mcp_config)"
			else
				_fail "MCP config: invalid JSON"
				_info "Fix: Check $mcp_config for syntax errors"
			fi
		else
			_warn "MCP config: exists but cannot validate" \
				"(no python3 or node available)"
		fi
	else
		_info "MCP config: not found at $mcp_config (OK if not using MCP)"
	fi

	# -- Node.js (needed by MCP servers) --
	if command -v node &>/dev/null; then
		local node_version
		node_version=$(node --version 2>/dev/null) || true
		local node_major="${node_version#v}"
		node_major="${node_major%%.*}"
		if ((node_major >= 20)); then
			_pass "Node.js: $node_version"
		elif ((node_major >= 1)); then
			_warn "Node.js: $node_version (v20+ recommended for MCP servers)"
			_info 'Fix: Update Node.js to v20 or later'
		fi
		_info "Path: $(command -v node)"
	else
		_warn 'Node.js: not found (required for MCP servers)'
		_info 'Fix: Install Node.js v20+ from https://nodejs.org'
	fi

	# -- Desktop integration --
	local desktop_file='/usr/share/applications/claude-desktop.desktop'
	if [[ -f $desktop_file ]]; then
		_pass "Desktop entry: $desktop_file"
	else
		_warn 'Desktop entry not found (expected for AppImage installs)'
	fi

	# -- Disk space --
	local config_disk_avail
	config_disk_avail=$(df -BM --output=avail "$config_dir" 2>/dev/null \
		| tail -1 | tr -d ' M') || true
	if [[ -n $config_disk_avail ]]; then
		if ((config_disk_avail < 100)); then
			_fail "Disk space: ${config_disk_avail}MB free on config partition"
			_info 'Fix: Free up disk space'
		elif ((config_disk_avail < 500)); then
			_warn "Disk space: ${config_disk_avail}MB free" \
				"on config partition (low)"
		else
			_pass "Disk space: ${config_disk_avail}MB free"
		fi
	fi

	# -- Cowork Mode --
	echo
	echo -e "${_bold}Cowork Mode${_reset}"
	echo '----------------'

	# Detect distro for package hints
	local _distro_id
	_distro_id=$(_cowork_distro_id)

	# Bubblewrap (default backend)
	if command -v bwrap &>/dev/null; then
		_pass 'bubblewrap: found'
	else
		_warn 'bubblewrap: not found'
		_info \
			"Fix: $(_cowork_pkg_hint "$_distro_id" bubblewrap)"
	fi

	# Warn on missing KVM deps only when explicitly requested;
	# otherwise just inform since bwrap is the default.
	local _kvm_active=false
	[[ ${COWORK_VM_BACKEND-} == [Kk][Vv][Mm] ]] && _kvm_active=true
	local _kvm_issue=_info
	$_kvm_active && _kvm_issue=_warn

	# KVM backend (opt-in via COWORK_VM_BACKEND=kvm)
	if [[ -e /dev/kvm ]]; then
		if [[ -r /dev/kvm && -w /dev/kvm ]]; then
			_pass 'KVM: accessible'
		else
			"$_kvm_issue" 'KVM: /dev/kvm exists but not accessible'
			if $_kvm_active; then
				_info "Fix: sudo usermod -aG kvm $USER"
				_info '(Log out and back in after running this)'
			fi
		fi
	else
		"$_kvm_issue" 'KVM: not available'
		if $_kvm_active; then
			_info \
				'Fix: Install qemu-kvm and ensure KVM is enabled in BIOS'
		fi
	fi

	# vsock module
	if [[ -e /dev/vhost-vsock ]]; then
		_pass 'vsock: module loaded'
	else
		"$_kvm_issue" 'vsock: /dev/vhost-vsock not found'
		if $_kvm_active; then
			_info 'Fix: sudo modprobe vhost_vsock'
		fi
	fi

	# KVM tools: QEMU, socat, virtiofsd
	local _tool_label _tool_bin _tool_pkg
	for _tool_label in \
		'QEMU:qemu-system-x86_64:qemu' \
		'socat:socat:socat' \
		'virtiofsd:virtiofsd:virtiofsd'
	do
		_tool_bin="${_tool_label#*:}"
		_tool_pkg="${_tool_bin#*:}"
		_tool_bin="${_tool_bin%%:*}"
		_tool_label="${_tool_label%%:*}"

		if command -v "$_tool_bin" &>/dev/null; then
			_pass "$_tool_label: found"
		else
			"$_kvm_issue" "$_tool_label: not found"
			if $_kvm_active; then
				_info \
					"Fix: $(_cowork_pkg_hint "$_distro_id" "$_tool_pkg")"
			fi
		fi
	done

	# VM image
	local vm_image
	vm_image="${HOME}/.local/share/claude-desktop/vm/rootfs.qcow2"
	if [[ -f $vm_image ]]; then
		local vm_size
		vm_size=$(du -h "$vm_image" 2>/dev/null \
			| cut -f1) || vm_size='unknown size'
		_pass "VM image: $vm_size"
	else
		_info 'VM image: not downloaded yet'
	fi

	# Determine active backend (matches daemon's detectBackend())
	local cowork_backend='none (host-direct, no isolation)'
	if [[ -n ${COWORK_VM_BACKEND-} ]]; then
		case ${COWORK_VM_BACKEND,,} in
			kvm)  cowork_backend='KVM (full VM isolation, via override)' ;;
			bwrap) cowork_backend='bubblewrap (namespace sandbox, via override)' ;;
			host) cowork_backend='host-direct (no isolation, via override)' ;;
		esac
	elif command -v bwrap &>/dev/null \
		&& bwrap --ro-bind / / true &>/dev/null; then
		cowork_backend='bubblewrap (namespace sandbox)'
	elif [[ -e /dev/kvm ]] \
		&& [[ -r /dev/kvm && -w /dev/kvm ]] \
		&& command -v qemu-system-x86_64 &>/dev/null \
		&& [[ -e /dev/vhost-vsock ]]; then
		cowork_backend='KVM (full VM isolation)'
	fi
	_info "Cowork isolation: $cowork_backend"

	# Custom bwrap mount configuration
	_doctor_check_bwrap_mounts

	# -- Orphaned cowork daemon --
	local _cowork_pids
	_cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) \
		|| true
	if [[ -n $_cowork_pids ]]; then
		local _daemon_orphaned=true _pid _cmdline
		for _pid in $(pgrep -f 'claude-desktop' 2>/dev/null); do
			_cmdline=$(tr '\0' ' ' \
				< "/proc/$_pid/cmdline" 2>/dev/null) || continue
			[[ $_cmdline == *cowork-vm-service* ]] && continue
			_daemon_orphaned=false
			break
		done
		if [[ $_daemon_orphaned == true ]]; then
			_warn "Cowork daemon: orphaned (PIDs: $_cowork_pids)"
			_info 'Fix: Restart Claude Desktop' \
				'(daemon will be cleaned up automatically)'
		else
			_pass 'Cowork daemon: running (parent alive)'
		fi
	fi

	# -- Log file --
	local log_path
	log_path="${XDG_CACHE_HOME:-$HOME/.cache}"
	log_path="$log_path/claude-desktop-suse/launcher.log"
	if [[ -f $log_path ]]; then
		local log_size
		log_size=$(stat -c '%s' "$log_path" 2>/dev/null) || log_size=0
		local log_size_kb=$((log_size / 1024))
		if ((log_size_kb > 10240)); then
			_warn "Log file: ${log_size_kb}KB" \
				"(consider clearing: rm '$log_path')"
		else
			_pass "Log file: ${log_size_kb}KB ($log_path)"
		fi
	else
		_info 'Log file: not yet created (OK)'
	fi

	# -- Summary --
	echo
	if ((_doctor_failures == 0)); then
		echo -e "${_green}${_bold}All checks passed.${_reset}"
	else
		echo -e "${_red}${_bold}${_doctor_failures} check(s) failed.${_reset}"
		echo 'See above for fixes.'
	fi

	return "$_doctor_failures"
}
