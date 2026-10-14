#!/usr/bin/env bash
# Common launcher functions for Claude Desktop (AppImage and deb)
# This file is sourced by both launchers to avoid code duplication

# WM_CLASS / StartupWMClass — must match upstream productName.
# @@WM_CLASS@@ is replaced at build time; see build.sh.
readonly WM_CLASS='@@WM_CLASS@@'

# Rotate launcher.log when it exceeds a size cap, keeping a couple of
# old copies. Runs before the session header is written, so the launcher
# log cannot grow without bound across sessions. Every branch returns 0:
# rotation must never block launch.
rotate_log_file() {
	[[ -n ${log_file:-} && -f $log_file ]] || return 0

	local max_bytes=$((5 * 1024 * 1024))
	local keep=2 size i

	size=$(stat -c '%s' "$log_file" 2>/dev/null) || return 0
	[[ $size =~ ^[0-9]+$ ]] || return 0
	((size > max_bytes)) || return 0

	for ((i = keep - 1; i >= 1; i--)); do
		[[ -f "$log_file.$i" ]] && \
			mv -f "$log_file.$i" "$log_file.$((i + 1))" 2>/dev/null
	done
	mv -f "$log_file" "$log_file.1" 2>/dev/null || return 0
}

# Setup logging directory and file
# Sets: log_dir, log_file
setup_logging() {
	log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-suse"
	mkdir -p "$log_dir" || return 1
	log_file="$log_dir/launcher.log"
	rotate_log_file
	return 0
}

# Log a message to the log file
# Usage: log_message "message"
log_message() {
	[[ -n ${log_file:-} ]] || return 0
	local msg="$*"
	if [[ "$msg" == *claude://login* ]]; then
		msg=$(printf '%s' "$msg" \
			| sed -E 's#(claude://login[^ ?]*)\?[^ ]*#\1?<redacted>#g')
	fi
	echo "$msg" >> "$log_file"
}

# Log the session/IME environment vars that drive display and input
# decisions, so bug reports include enough context to reason about
# them without round-trip env-dump requests (#548).
#
# Emits one block:
#     env={
#       KEY=value
#       ...
#     }
#
# Empty or unset values are emitted as `KEY=` so absence is
# unambiguous (vs. silently omitted). Caller must run setup_logging
# first.
log_session_env() {
	local key
	log_message 'env={'
	for key in \
		XDG_SESSION_TYPE \
		WAYLAND_DISPLAY \
		DISPLAY \
		XDG_CURRENT_DESKTOP \
		GTK_IM_MODULE \
		XMODIFIERS \
		QT_IM_MODULE \
		CLAUDE_USE_WAYLAND \
		CLAUDE_TITLEBAR_STYLE \
		CLAUDE_PASSWORD_STORE \
		CLAUDE_GTK_IM_MODULE \
		CLAUDE_DISABLE_GPU
	do
		log_message "  $key=${!key:-}"
	done
	log_message '}'
}

# Detect display backend (Wayland vs X11)
# Sets: is_wayland, use_x11_on_wayland
detect_display_backend() {
	# Detect if Wayland is running
	is_wayland=false
	[[ -n "${WAYLAND_DISPLAY:-}" ]] && is_wayland=true

	# Default: Use X11/XWayland on Wayland so upstream's globalShortcut
	# (Quick Entry's Ctrl+Alt+Space) keeps working via an X11 key grab.
	#
	# CLAUDE_USE_WAYLAND is tri-state:
	#   1     - force native Wayland (global shortcuts via XDG portal)
	#   0     - force XWayland, skipping the auto-detect below
	#   unset - auto-detect per compositor
	use_x11_on_wayland=true
	local wayland_override="${CLAUDE_USE_WAYLAND:-}"
	[[ $wayland_override == '1' ]] && use_x11_on_wayland=false

	# Fixes: #226 - Only Niri is auto-forced to native Wayland: it has
	# no XWayland at all, so the X11 backend can't even start.
	#
	# GNOME Wayland is NOT auto-forced. mutter no longer honours
	# XWayland global key grabs (#404), and native Wayland would route
	# Quick Entry's globalShortcut through the XDG GlobalShortcuts portal
	# instead -- but flipping the default session off mature XWayland is
	# a rendering / IME / HiDPI risk, and on GNOME 50 the portal path is
	# a no-op anyway (electron/electron#51875). GNOME users who want the
	# portal route opt in with CLAUDE_USE_WAYLAND=1 (works on GNOME <=49
	# after the one-time portal permission dialog).
	#
	# Sway and Hyprland keep working XWayland grabs and their wlroots
	# portal has no GlobalShortcuts backend, so they also stay on the
	# XWayland default; opt in with CLAUDE_USE_WAYLAND=1 if desired. An
	# explicit CLAUDE_USE_WAYLAND=0 opts out of this auto-detect entirely.
	#
	# XDG_CURRENT_DESKTOP can be colon-separated (e.g. "niri:GNOME"); the
	# *glob* substring match handles this.
	if [[ $is_wayland == true && $use_x11_on_wayland == true \
		&& $wayland_override != '0' ]]; then
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

# Resolve CLAUDE_TITLEBAR_STYLE to one of {hybrid,native,hidden},
# defaulting to 'hybrid' when unset or invalid. Echoed (not exported)
# so callers can branch on it without polluting the environment.
# 'hybrid' is the recommended Linux experience: native OS frame +
# in-app topbar via the wco-shim. 'hidden' is upstream's frameless
# WCO config; broken on Linux X11 (clicks unresponsive) but kept for
# Wayland/diagnostic comparison.
_resolve_titlebar_style() {
	local raw="${CLAUDE_TITLEBAR_STYLE:-hybrid}"
	raw="${raw,,}"
	case "$raw" in
		hybrid|hidden|native) echo "$raw" ;;
		*) echo 'hybrid' ;;
	esac
}

# Determine the best available Chromium password-store backend.
#
# Electron's safeStorage API and Chromium's cookie encryption both rely
# on the OS credential store selected by --password-store. Without a
# working store safeStorage.isEncryptionAvailable() returns false, OAuth
# tokens are silently discarded on exit, and users must re-authenticate
# on every launch (Cookies file stays 0 bytes). Fixes: #593
#
# Detection order (first match wins):
#   CLAUDE_PASSWORD_STORE env var  — explicit user override
#   kwallet6                        — KDE Plasma 6 keyring
#   gnome-libsecret                 — GNOME Keyring / libsecret bridge
#   basic                           — fixed internal key (always works)
#
# With 'basic' the stored data is encrypted with a fixed key. Tokens
# remain protected by Linux filesystem permissions on ~/.config/Claude/.
#
# Assumes a D-Bus session bus is available; this is true for any
# graphical login session.
_detect_password_store() {
	if [[ -n ${CLAUDE_PASSWORD_STORE:-} ]]; then
		echo "$CLAUDE_PASSWORD_STORE"
		return
	fi

	# kwallet6: KDE Plasma 6 keyring
	if dbus-send --session --print-reply --reply-timeout=1000 \
		--dest=org.kde.kwalletd6 \
		/modules/kwalletd6 \
		org.kde.KWallet.isEnabled 2>/dev/null \
		| grep -q 'boolean true'
	then
		echo 'kwallet6'
		return
	fi

	# gnome-libsecret: GNOME Keyring, KWallet 5 compat bridge, etc.
	if dbus-send --session --print-reply --reply-timeout=1000 \
		--dest=org.freedesktop.secrets \
		/org/freedesktop/secrets \
		org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
	then
		echo 'gnome-libsecret'
		return
	fi

	# No keyring accessible — fall back to fixed-key provider.
	echo 'basic'
}

# Detect whether the previous launch ended in Chromium's
# "GPU process isn't usable" crash signature (#583).
#
# setup_logging() must have run first so $log_file is available. The
# launcher writes the current session header before build_electron_args()
# runs, so the previous launch lives in the penultimate log section.
#
# A recovered launch (running with --disable-gpu) produces no GPU
# output, so the crash signature alone would re-enable GPU on launch
# N+2 and oscillate crash/work/crash on permanently broken hardware.
# The launcher's own "disabling GPU" marker therefore also counts as
# a trigger, making recovery sticky once tripped. CLAUDE_DISABLE_GPU=0
# remains the escape hatch for retesting hardware acceleration.
#
# Section headers vary by package format: deb/rpm write "Launcher
# Start", AppImage writes "AppImage Start", and Nix writes "Launcher
# Start (NixOS)" (nix/claude-desktop.nix).
_previous_launch_hit_gpu_fatal() {
	[[ -f ${log_file:-} ]] || return 1

	awk '
		/^--- Claude Desktop (Launcher|AppImage) Start( \(NixOS\))? ---$/ {
			section++
			prev_failed = cur_failed
			prev_notusable = cur_notusable
			prev_prevfatal = cur_prevfatal
			cur_failed = 0
			cur_notusable = 0
			cur_prevfatal = 0
			next
		}
		{
			if (index($0,
				"GPU process launch failed: error_code=")) {
				cur_failed = 1
			}
			if (index($0,
				"GPU process isn'\''t usable. Goodbye.")) {
				cur_notusable = 1
			}
			if (index($0,
				"Previous launch hit GPU process FATAL")) {
				cur_prevfatal = 1
			}
		}
		END {
			if (section >= 2) {
				t_failed = prev_failed
				t_notusable = prev_notusable
				t_prevfatal = prev_prevfatal
			} else if (section == 1) {
				t_failed = cur_failed
				t_notusable = cur_notusable
				t_prevfatal = cur_prevfatal
			} else {
				exit 1
			}
			if ((t_failed && t_notusable) || t_prevfatal) {
				exit 0
			}
			exit 1
		}
	' "$log_file"
}

# Build Electron arguments array based on display backend
# Requires: is_wayland, use_x11_on_wayland to be set
#           (call detect_display_backend first)
# Sets: electron_args array
# Arguments: $1 = "appimage" or "rpm" (affects --no-sandbox behavior)

build_electron_args() {
	local package_type="${1:-rpm}"

	electron_args=()

	# Chromium ignores all but the LAST --enable-features switch on a
	# command line, so every feature we want must end up in ONE
	# comma-joined flag. Accumulate them here and emit a single
	# --enable-features=... at the end of the function.
	local enable_features=()

	# AppImage always needs --no-sandbox due to FUSE constraints
	[[ $package_type == 'appimage' ]] && electron_args+=('--no-sandbox')

	# CLAUDE_TITLEBAR_STYLE selects between:
	#   hybrid (default) / native: --disable-features=CustomTitlebar
	#           so Chromium's drawn CSD titlebar doesn't compete with
	#           the DE-drawn one. Both modes use frame:true.
	#   hidden: WindowControlsOverlay because WCO is off by default on
	#           Linux Chromium (Win/macOS have it on by default).
	#           Without it, titleBarOverlay is silently ignored at the
	#           page level.
	local _tb
	_tb=$(_resolve_titlebar_style)
	if [[ $_tb == 'hidden' ]]; then
		enable_features+=('WindowControlsOverlay')
	else
		electron_args+=('--disable-features=CustomTitlebar')
	fi

	# WM_CLASS must match the .desktop StartupWMClass and upstream's
	# productName. Ref: #647, #652
	electron_args+=("--class=$WM_CLASS")

	# Chromium's safeStorage API and cookie encryption both require a
	# system keyring selected by --password-store. Without an explicit
	# value, Electron may silently report encryption unavailable even
	# when a keyring daemon is running, discarding OAuth tokens on exit
	# and forcing re-authentication on every launch. We probe for the
	# best available store at startup. Fixes: #593
	local pw_store
	pw_store=$(_detect_password_store)
	electron_args+=("--password-store=${pw_store}")
	log_message "Password store: ${pw_store}"

	# Remote XRDP sessions lack GPU acceleration and render a blank
	# window when GPU compositing is enabled. Detect via XRDP_SESSION
	# (set by xrdp's session init) and loginctl session Type. We do
	# not probe xrdp-sesman via pgrep because that daemon also runs
	# on hosts where the user is on a local (non-XRDP) session.
	# Fixes: #319
	local rdp_session_type=''
	[[ -n ${XDG_SESSION_ID:-} ]] && rdp_session_type=$(
		loginctl show-session "$XDG_SESSION_ID" \
			-p Type --value 2>/dev/null
	)
	# Track GPU-disable decision so XRDP and CLAUDE_DISABLE_GPU don't
	# stack duplicate flags. Either signal is sufficient.
	local _disable_gpu=false
	if [[ -n ${XRDP_SESSION:-} || $rdp_session_type == xrdp ]]; then
		_disable_gpu=true
		log_message 'XRDP session detected - GPU compositing disabled'
	fi
	# CLAUDE_DISABLE_GPU=1: opt-in workaround for users hitting the
	# Chromium GPU process FATAL exhaustion (#583). The same upstream
	# behaviour is reachable via Settings → disable hardware
	# acceleration; this lets users persist it via the env without
	# having to reach the Settings UI through repeated crashes.
	if [[ -v CLAUDE_DISABLE_GPU ]]; then
		if [[ ${CLAUDE_DISABLE_GPU} == '1' ]]; then
			_disable_gpu=true
			log_message \
				'CLAUDE_DISABLE_GPU=1 - hardware acceleration disabled'
		fi
	elif _previous_launch_hit_gpu_fatal; then
		_disable_gpu=true
		log_message \
			'Previous launch hit GPU process FATAL - disabling GPU'
	fi
	# Keep Chromium's software rasterizer available. Disabling both
	# hardware GPU and the software fallback can make Electron abort
	# with "GPU process isn't usable" instead of recovering.
	[[ $_disable_gpu == true ]] && electron_args+=('--disable-gpu')

	# X11 session - no display-backend flags needed.
	if [[ $is_wayland != true ]]; then
		log_message 'X11 session detected'
	else
		# Wayland: rpm needs --no-sandbox in both modes (AppImage already
		# added it above). CLAUDE_FORCE_SANDBOX=1 is the opt-in escape
		# hatch, symmetrical to CLAUDE_DISABLE_GPU, for users who know
		# their system runs the setuid chrome-sandbox fine and want the
		# sandbox kept on. It cannot apply to the AppImage: the FUSE
		# mount strips the setuid bit chrome-sandbox needs.
		if [[ ${CLAUDE_FORCE_SANDBOX:-} == '1' && $package_type == 'rpm' ]]; then
			log_message \
				'CLAUDE_FORCE_SANDBOX=1 - keeping Chromium sandbox enabled on Wayland'
		elif [[ $package_type == 'rpm' ]]; then
			electron_args+=('--no-sandbox')
		fi

		if [[ $use_x11_on_wayland == true ]]; then
			# Use X11 via XWayland; globalShortcut uses an X11 key grab.
			log_message 'Using X11 backend via XWayland (for global hotkey support)'
			electron_args+=('--ozone-platform=x11')
		else
			# Native Wayland: route globalShortcut through the XDG
			# GlobalShortcutsPortal instead of an X11 key grab. Needs
			# the wayland ozone platform (the feature is inert under
			# XWayland) and Electron >= 35. Fixes #404 on GNOME, where
			# mutter no longer honours XWayland grabs. On compositors
			# whose portal lacks a GlobalShortcuts backend (e.g.
			# wlroots) the feature is a harmless no-op.
			log_message 'Using native Wayland backend (global shortcuts via XDG portal)'
			enable_features+=(
				'UseOzonePlatform'
				'WaylandWindowDecorations'
				'GlobalShortcutsPortal'
			)
			electron_args+=('--ozone-platform=wayland')
			electron_args+=('--enable-wayland-ime')
			electron_args+=('--wayland-text-input-version=3')
			# Override any system-wide GDK_BACKEND=x11 that would silently
			# prevent GTK from connecting to the Wayland compositor, causing
			# blurry rendering or launch failures on HiDPI displays.
			export GDK_BACKEND=wayland
		fi
	fi

	# Emit all accumulated Chromium features as a single switch (see the
	# enable_features declaration above for why a single switch matters).
	if [[ ${#enable_features[@]} -gt 0 ]]; then
		local IFS=','
		electron_args+=("--enable-features=${enable_features[*]}")
	fi
}

# Does a /proc/PID/cmdline (joined with spaces) belong to the Claude
# Desktop Electron UI main process?
#
# We can NOT fingerprint on `app.asar`: since #700 the launchers no
# longer pass it as an argument (Electron auto-loads it from
# resources/), so it never appears in any cmdline.  The stable
# signature across deb/rpm/AppImage/nix is the `--class=$WM_CLASS`
# flag every launcher passes via build_electron_args; Chromium keeps
# the exec'd argv in /proc/PID/cmdline and does not propagate --class
# to its --type=... helper children (verified empirically).
#
# Callers join /proc/PID/cmdline with `tr '\0' ' '`, which leaves
# every argument space-terminated, so anchoring on the trailing space
# rejects look-alike classes (e.g. ClaudeDev).
_claude_desktop_ui_cmdline_matches() {
	local cmdline="$1"

	# Never the cowork daemon (defensive; it carries no --class) and
	# never a Chromium helper: zygote, renderer, gpu, utility, etc.
	[[ $cmdline == *cowork-vm-service* ]] && return 1
	[[ $cmdline == *cowork-linux-helper* ]] && return 1
	[[ $cmdline == *--type=* ]] && return 1

	[[ $cmdline == *"--class=$WM_CLASS "* ]]
}

# Is a live Claude Desktop UI running for this user?
#
# We can NOT use `pgrep -f 'claude-desktop'` on its own for this: it
# matches the launcher's own bash process (this script's cmdline
# contains "/usr/bin/claude-desktop"), any stale launcher bash left
# stopped/zombie after a previous crash, and the cowork daemon
# itself.  Counting any of those as "the UI is alive" causes false
# negatives in the cleanup functions below.  The reliable definition
# is: a process whose cmdline carries our --class fingerprint (see
# _claude_desktop_ui_cmdline_matches) and is actually runnable (not
# stopped/zombie), excluding our own launcher bash and its parent.
#
# _claude_desktop_ui_pids prints the fingerprint-matching PIDs, one per
# line; _claude_desktop_own_ui_is_alive adds the runnable check on top.
_claude_desktop_ui_pids() {
	local pid cmdline
	for pid in \
		$(pgrep -u "$(id -u)" -f -- "--class=$WM_CLASS" 2>/dev/null); do
		# Skip our own launcher bash and its parent.
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		_claude_desktop_ui_cmdline_matches "$cmdline" || continue
		printf '%s\n' "$pid"
	done
}

# Process state letter from /proc/PID/status (R, S, T, t, Z, ...).
_proc_state() {
	local key value rest
	while read -r key value rest; do
		if [[ $key == 'State:' ]]; then
			printf '%s' "$value"
			return 0
		fi
	done 2>/dev/null < "/proc/$1/status"
	return 1
}

# Is a live (runnable) Claude Desktop UI running for this user?
#
# Two fingerprints, because the answer gates the reapers: a "no" lets
# them kill helpers. Our own UI carries --class=$WM_CLASS
# (_claude_desktop_own_ui_is_alive). Another Claude Desktop build
# installed side by side (Anthropic's official package, or the
# upstream claude-desktop-debian RPM) runs an ELF named
# `claude-desktop` that may carry no --class, so any such main process
# also counts. This only ever makes the reapers skip more.
_claude_desktop_ui_is_alive() {
	_claude_desktop_own_ui_is_alive || _claude_desktop_any_main_is_alive
}

# Is OUR launcher's UI (--class=$WM_CLASS) up and runnable? Only it can
# be the parent of our cowork daemon, so the doctor asks this rather
# than the reapers' broader gate.
_claude_desktop_own_ui_is_alive() {
	local pid state
	for pid in $(_claude_desktop_ui_pids); do
		# Skip stopped (T/t) and zombie (Z) processes — not a live UI.
		state=$(_proc_state "$pid") || continue
		[[ $state == T || $state == t || $state == Z ]] && continue
		# Found a genuine live Electron UI.
		return 0
	done
	return 1
}

# Is any runnable `claude-desktop` Electron main process up for this
# user, whoever launched it? Our own build runs the npm Electron binary
# (exe basename `electron`) and is covered by the --class check above;
# this arm covers builds that ship the Electron ELF as `claude-desktop`.
# Chromium's helpers are the same binary with --type=, so: exe basename
# `claude-desktop` (" (deleted)" stripped, for an upgraded binary), no
# --type= and not run as Node (ELECTRON_RUN_AS_NODE=1). A launcher
# script is excluded by its exe (bash).
_claude_desktop_any_main_is_alive() {
	local pid exe cmdline state
	for pid in $(pgrep -u "$(id -u)" -x claude-desktop 2>/dev/null); do
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
		exe=${exe% (deleted)}
		[[ ${exe##*/} == claude-desktop ]] || continue
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		[[ $cmdline == *--type=* ]] && continue
		# Electron run as Node (a fork or MCP server): same exe, no
		# --type=, but not a main. Counting it would let an orphan
		# hold the gate open and shield itself from the reapers.
		# An unreadable environ falls through to "alive" (safe side).
		tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" \
			| grep -qx 'ELECTRON_RUN_AS_NODE=1' && continue
		state=$(_proc_state "$pid") || continue
		[[ $state == T || $state == t || $state == Z ]] && continue
		return 0
	done
	return 1
}

# Print field $2 of /proc/$1/stat, counted after the "(comm)" field:
# comm may itself hold spaces and parentheses, so the split starts at
# the last ") ". Index 0 is the state (field 3 in proc(5)), 2 the
# process group, 19 the start time in clock ticks since boot.
_proc_stat_field() {
	local stat
	local -a fields
	{ read -r stat < "/proc/$1/stat"; } 2>/dev/null || return 1
	read -r -a fields <<< "${stat##*) }"
	[[ -n ${fields[$2]:-} ]] || return 1
	printf '%s' "${fields[$2]}"
}

# Is PID $1 still the process that had start time $2, and not a zombie?
_pid_is_same_process() {
	local stat
	local -a fields
	{ read -r stat < "/proc/$1/stat"; } 2>/dev/null || return 1
	read -r -a fields <<< "${stat##*) }"
	[[ ${fields[0]:-} != Z && ${fields[19]:-} == "$2" ]]
}

# SIGTERM every PID, wait up to ~2s for all of them to go, then
# escalate to SIGKILL for whatever is left.  Logs "$label (PIDs: ...)",
# or "$label (SIGKILL, PIDs: ...)" when escalation was needed.
#
# Each PID is pinned to its start time before the first signal and
# re-checked before every later one: a target that exits during the
# grace period frees its PID, and an unrelated process that inherits
# it must not get the SIGKILL. PIDs already gone are dropped.
_kill_pids_escalating() {
	local label="$1"
	shift
	local pid start i alive=false waited=0
	local -a pids=() starts=()

	for pid in "$@"; do
		start=$(_proc_stat_field "$pid" 19) || continue
		pids+=("$pid")
		starts+=("$start")
	done
	[[ ${#pids[@]} -gt 0 ]] || return 0

	for i in "${!pids[@]}"; do
		kill "${pids[i]}" 2>/dev/null || true
	done

	while ((waited < 20)); do
		alive=false
		for i in "${!pids[@]}"; do
			if _pid_is_same_process "${pids[i]}" "${starts[i]}"; then
				alive=true
				break
			fi
		done
		[[ $alive == false ]] && break
		sleep 0.1
		waited=$((waited + 1))
	done

	if [[ $alive == true ]]; then
		for i in "${!pids[@]}"; do
			_pid_is_same_process "${pids[i]}" "${starts[i]}" \
				&& kill -KILL "${pids[i]}" 2>/dev/null
		done
		log_message "$label (SIGKILL, PIDs: ${pids[*]})"
	else
		log_message "$label (PIDs: ${pids[*]})"
	fi
	return 0
}

# Was this process's executable, a Claude Desktop Electron, replaced
# (unlinked) underneath it? The kernel appends " (deleted)" to
# /proc/PID/exe once the binary behind a running process is gone,
# which is exactly what rpm does when `zypper up` upgrades the package
# while its UI is still running.
#
# Plain readlink, NOT readlink -f: -f canonicalizes, so it fails when
# the install DIRECTORY is gone too (a package migration or layout
# change, not just a file replace) and the replaced UI would be
# silently missed. The raw link content carries the marker either way.
#
# The --class fingerprint alone is not ownership: any Electron app
# started with --class=Claude matches it, and an unrelated app whose
# binary was upgraded underneath it would be killed. So the executable
# must also come from a claude-desktop tree (our RPM installs it under
# /usr/lib/claude-desktop/) or be named claude-desktop.
_claude_desktop_ui_is_replaced() {
	local exe_path

	exe_path=$(readlink "/proc/$1/exe" 2>/dev/null) || return 1
	[[ $exe_path == *' (deleted)' ]] || return 1
	exe_path=${exe_path% (deleted)}
	[[ $exe_path == */claude-desktop/* \
		|| ${exe_path##*/} == claude-desktop ]]
}

# Is PID a Claude Desktop browser process, one that can legitimately
# hold the SingletonLock in ~/.config/Claude?
#
# Keyed on the executable's path, NOT on the --class UI fingerprint:
# the lock is shared by every Claude Desktop build on the machine. Our
# RPM runs /usr/lib/claude-desktop/node_modules/electron/dist/electron,
# our AppImage runs the same tree inside its FUSE mount
# (/tmp/.mount_claude*/usr/lib/node_modules/electron/dist/electron, the
# mount dir carries the first characters of the AppImage file name),
# and other builds ship .../claude-desktop/claude-desktop. A bare
# `electron` basename would also count every unrelated Electron app on
# the machine as a live holder, so the path has to say Claude.
#
# Errs toward "live" when /proc/PID/exe cannot be read (a zombie, or a
# process that exec'd a setuid binary and is no longer dumpable):
# keeping a stale lock costs nothing, Electron unlinks it itself on the
# next start, while a wrong "stale" turns into a `Fix: rm` on a live
# lock in the doctor.
#
# A renamed AppImage mounts under /tmp/.mount_<new name>, and an
# extracted one runs from squashfs-root/: neither path says Claude, so
# the --class=$WM_CLASS UI fingerprint our launchers pass also counts.
_pid_is_claude_desktop() {
	local exe cmdline
	exe=$(readlink "/proc/$1/exe" 2>/dev/null) || return 0
	case "$exe" in
		*claude-desktop* | */.mount_[Cc]laude*)
			return 0
			;;
	esac
	cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline") || return 0
	_claude_desktop_ui_cmdline_matches "$cmdline"
}

# Terminate a live Claude Desktop UI whose executable was replaced
# underneath it by rpm. If left alive, the next launcher loses
# Electron's single-instance lock to the old process and appears to
# do nothing instead of starting the newly-installed build.
#
# A no-op on AppImage by construction: the binary lives inside the
# FUSE mount, which stays valid after the .AppImage file itself is
# replaced, so /proc/PID/exe never carries the marker there.
cleanup_replaced_desktop_ui() {
	local pids=() pid
	for pid in $(_claude_desktop_ui_pids); do
		_claude_desktop_ui_is_replaced "$pid" || continue
		pids+=("$pid")
	done

	[[ ${#pids[@]} -gt 0 ]] || return 0

	_kill_pids_escalating 'Killed replaced Claude Desktop UI' \
		"${pids[@]}"
}

# Is PID our cowork-vm-service daemon?
#
# Fingerprinted by argv shape, not by a `cowork-vm-service.js`
# substring: the substring also matches an editor, `tail -f` or a
# shell that merely names the file, and the reapers SIGKILL what this
# accepts. The cowork.sh auto-launch patch starts the daemon with
# child_process.fork(), i.e. as
#   <electron> [node options] <resourcesPath>/app.asar.unpacked/cowork-vm-service.js
# (ELECTRON_RUN_AS_NODE=1), and a manual run uses `node <path>`. So
# argv[0] is an interpreter, only `-` options may precede the script,
# and the script argument ends in /cowork-vm-service.js.
#
# cmdline is read NUL-split into an array because `tr '\0' ' '`
# would lose the argument boundaries.
_is_cowork_fallback_daemon() {
	local -a argv
	local i
	mapfile -d '' argv 2>/dev/null < "/proc/$1/cmdline" || return 1

	case ${argv[0]##*/} in
		electron | node | nodejs)
			;;
		*)
			return 1
			;;
	esac

	for ((i = 1; i < ${#argv[@]}; i++)); do
		[[ ${argv[i]} == */cowork-vm-service.js ]] && return 0
		[[ ${argv[i]} == -* ]] || return 1
	done
	return 1
}

# PIDs of this user's cowork daemon, one per line.
#
# pgrep only narrows the candidates; _is_cowork_fallback_daemon
# decides. Scoped to this user and skipping our own launcher bash and
# its parent, like _claude_desktop_ui_pids.
_cowork_fallback_daemon_pids() {
	local pid
	for pid in \
		$(pgrep -u "$(id -u)" -f 'cowork-vm-service\.js' 2>/dev/null); do
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		_is_cowork_fallback_daemon "$pid" || continue
		printf '%s\n' "$pid"
	done
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
	local -a pids
	mapfile -t pids < <(_cowork_fallback_daemon_pids)
	[[ ${#pids[@]} -gt 0 ]] || return 0

	# A live Claude Desktop UI process means the daemon is expected;
	# leave it alone.  See _claude_desktop_ui_is_alive for why neither
	# `pgrep -f 'claude-desktop'` nor an app.asar fingerprint works.
	if _claude_desktop_ui_is_alive; then
		return 0
	fi

	# No UI process found — daemon is orphaned, terminate it.
	# _kill_pids_escalating SIGKILLs a daemon still alive ~2s after
	# SIGTERM, so cleanup_stale_cowork_socket (which runs next)
	# reliably sees no daemon.
	_kill_pids_escalating 'Killed orphaned cowork-vm-service daemon' \
		"${pids[@]}"
}

# No cowork-vm-service.js arm: a substring here would also match an
# editor or `tail -f` on the script. The daemon is matched by argv
# shape (_is_cowork_fallback_daemon) in cleanup_stale_desktop_helpers
# instead.
_desktop_helper_cmdline_matches() {
	local cmdline="$1"
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"

	# /proc/PID/cmdline is NUL-joined and rendered with tr, so argv[0] is
	# everything up to the first space. Every arm that identifies a
	# process by the *binary it is running* tests argv[0], never the whole
	# string: a bystander that merely names one of our binaries as an
	# argument -- `gdb .../chrome_crashpad_handler core`, `coredumpctl
	# gdb`, an editor, a `less` -- must not land in the reaper's kill
	# list.
	#
	# Argv[0] carrying a space degrades to a miss, never a false match.
	# The RPM install prefix has none; an AppImage mounted under a path
	# with a space is simply not reaped.
	local argv0="${cmdline%% *}"
	local appimage_tree=''
	[[ -n ${APPDIR:-} ]] && appimage_tree="$APPDIR/usr/lib/"

	case "$argv0" in
		*cowork-linux-helper*)
			return 0
			;;
		*/usr/lib/claude-desktop/*chrome_crashpad_handler*)
			# Crashpad is built to outlive the browser it
			# monitors, so it is the survivor the --type= arm
			# below cannot catch: it carries no --type= switch.
			# The path prefix keeps this scoped to our tree: a
			# bystander /usr/lib/chromium/chrome_crashpad_handler
			# must not match.
			return 0
			;;
	esac

	# The same crashpad survivor inside our own AppImage mount. The
	# runtime unmounts the AppDir as soon as AppRun exits, crashpad's
	# text pages are mmap'd from that mount, so it dies SIGBUS (with a
	# core dump) once per quit unless it is reaped first. Scoped to the
	# exact $APPDIR of this launch, never to every /tmp/.mount_* tree.
	if [[ -n $appimage_tree && $argv0 == "$appimage_tree"* \
		&& $argv0 == *chrome_crashpad_handler* ]]; then
		return 0
	fi

	# Chromium's own helpers: an in-tree argv[0] *and* a --type=
	# switch. Both halves are load-bearing -- the tree alone would
	# also match a resource Chrome (not Claude Desktop) spawns and owns
	# the lifetime of.
	if [[ $argv0 == */usr/lib/claude-desktop/* \
		|| ( -n $appimage_tree && $argv0 == "$appimage_tree"* ) ]]; then
		[[ $cmdline == *--type=* ]] && return 0
	fi

	# A Claude Desktop Chromium helper carrying our profile: argv[0]
	# named electron (our npm Electron tree) or claude-desktop, a
	# --type= switch and our --user-data-dir. A bystander handed the
	# same profile dir, such as `chromium --user-data-dir=~/.config/Claude`,
	# does not match.
	case ${argv0##*/} in
		electron | claude-desktop)
			if [[ $cmdline == *--type=* \
				&& $cmdline == *"--user-data-dir=$config_dir "* ]]; then
				return 0
			fi
			;;
	esac

	# Extension servers are matched by argv shape in
	# cleanup_stale_desktop_helpers (_is_claude_extension_server), not
	# here: a `$config_dir/Claude Extensions/` substring also matches a
	# pager, an editor or `rg` on an extension's files.
	return 1
}

# Is PID an MCP server of an installed Claude Desktop extension?
#
# Fingerprinted by argv shape, not by a `Claude Extensions/` substring:
# argv[0]'s basename is an interpreter, and argv[1], or a --directory
# value, sits under the extensions dir. That is how the app starts a
# server on a system runtime (`node <ext>/server/index.js`, `uv run
# --directory <ext> ...`). With the built-in Node it is either a
# utilityProcess (--type=utility, covered by the in-tree arm of
# _desktop_helper_cmdline_matches) or the npm `electron` binary run
# with ELECTRON_RUN_AS_NODE=1, counted here as an interpreter. An
# unreadable environ is no match.
#
# Known gap: a server started with the extension dir as its cwd and
# only relative arguments names no extension path in argv and is not
# matched.
#
# cmdline is read NUL-split into an array: the dir name has a space.
_is_claude_extension_server() {
	local ext_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/Claude Extensions/"
	local -a argv
	local i
	mapfile -d '' argv 2>/dev/null < "/proc/$1/cmdline" || return 1

	case ${argv[0]##*/} in
		node | python* | uv | uvx | bun | deno)
			;;
		electron | claude-desktop)
			tr '\0' '\n' 2>/dev/null < "/proc/$1/environ" \
				| grep -qx 'ELECTRON_RUN_AS_NODE=1' || return 1
			;;
		*)
			return 1
			;;
	esac

	[[ ${argv[1]:-} == "$ext_dir"* ]] && return 0
	for ((i = 1; i < ${#argv[@]}; i++)); do
		case ${argv[i]} in
			--directory=*)
				[[ ${argv[i]#--directory=} == "$ext_dir"* ]] && return 0
				;;
			--directory)
				[[ ${argv[i + 1]:-} == "$ext_dir"* ]] && return 0
				;;
		esac
	done
	return 1
}

# Process groups of recent launches, one per line, newest last.
#
# The argv shape of an extension server says what it is, not who
# started it: a developer running `uv run --directory <ext dir>` in a
# terminal has the same shape. The app spawns servers without
# detaching, so they stay in the process group of the Electron main,
# which a non-interactive launcher shares with its own bash. Recording
# that group at each launch lets the reaper ask "started by one of our
# launches?"; a terminal job gets its own group and is spared. A server
# the app ever starts detached is spared too, the safe side.
_launch_pgids_file() {
	printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-suse/launch-pgids"
}

_record_launch_pgid() {
	local file pgid tmp
	file=$(_launch_pgids_file)
	pgid=$(_proc_stat_field "$$" 2) || return 0
	mkdir -p "${file%/*}" 2>/dev/null || return 0
	tmp="$file.tmp.$$"
	{
		grep -vxF -- "$pgid" "$file" 2>/dev/null | tail -n 9
		printf '%s\n' "$pgid"
	} > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
	mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
	return 0
}

_pid_in_launch_group() {
	local pgid
	pgid=$(_proc_stat_field "$1" 2) || return 1
	grep -qxF -- "$pgid" "$(_launch_pgids_file)" 2>/dev/null
}

_desktop_helper_candidate_pids() {
	pgrep -u "$(id -u)" -f 'cowork-vm-service\.js|cowork-linux-helper|--user-data-dir=.*[/]Claude|Claude Extensions|/usr/lib/claude-desktop/|/usr/lib/node_modules/electron/dist/' 2>/dev/null
}

cleanup_stale_desktop_helpers() {
	# A live UI (any instance) suppresses all cleanup. We don't scope
	# helpers per-instance. Safe, not complete.
	if _claude_desktop_ui_is_alive; then
		return 0
	fi

	local pids pid cmdline
	pids=$(_desktop_helper_candidate_pids) || return 0

	local matched=()
	for pid in $pids; do
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		[[ ${_electron_child_pid:-} == "$pid" ]] && continue
		if _is_cowork_fallback_daemon "$pid"; then
			matched+=("$pid")
			continue
		fi
		if _is_claude_extension_server "$pid"; then
			_pid_in_launch_group "$pid" && matched+=("$pid")
			continue
		fi
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		_desktop_helper_cmdline_matches "$cmdline" || continue
		matched+=("$pid")
	done

	[[ ${#matched[@]} -gt 0 ]] || return 0

	_kill_pids_escalating 'Killed stale Claude Desktop helpers' \
		"${matched[@]}"
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

	# A live PID is never ours to judge: the holder may be a Claude
	# Desktop this launcher cannot recognize (a renamed or extracted
	# AppImage, another build), and unlinking its lock lets a second
	# instance start on the same profile. A recycled PID is harmless
	# here, because Chromium's ProcessSingleton compares the holder's
	# executable with its own and unlinks a foreign one on start.
	kill -0 "$lock_pid" 2>/dev/null && return 0

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
# We use that invariant directly instead of depending on socat or an
# age heuristic (the old 24h fallback effectively disabled the cleanup
# for any recent crash). The daemon is identified by argv shape, so an
# editor or `tail -f` on the script does not keep a stale socket alive.
cleanup_stale_cowork_socket() {
	local sock="${XDG_RUNTIME_DIR:-/tmp}/cowork-vm-service.sock"

	[[ -S $sock ]] || return 0

	# If a cowork daemon is alive, it owns this socket; leave it.
	# cleanup_orphaned_cowork_daemon has already run and removed any
	# orphan (with SIGKILL escalation), so anything still alive here
	# is a non-orphaned, live daemon.
	if [[ -n $(_cowork_fallback_daemon_pids) ]]; then
		return 0
	fi

	# No daemon — the socket file is left over from a crash.
	rm -f "$sock"
	log_message "Removed stale cowork-vm-service socket (no daemon running)"
}

# Rotate out-of-band backups of the user config and Cowork store index
# files before launch, keeping $keep generations per file in the cache
# dir. Only rotates on a real change (cmp -s), so it neither churns nor
# evicts the pre-wipe copy on every launch. Fail-safe: never blocks
# launch (all error paths return 0).
backup_user_config() {
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local backup_dir
	backup_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-suse"
	backup_dir="$backup_dir/config-backups"
	local keep=5

	mkdir -p "$backup_dir" 2>/dev/null || return 0

	local -a sources=("$config_dir/claude_desktop_config.json")

	local lam="$config_dir/local-agent-mode-sessions"
	if [[ -d $lam ]]; then
		local f
		for f in "$lam"/*/*/spaces.json \
			"$lam"/*/*/remote-session-spaces.json \
			"$lam"/*/*/scheduled-tasks.json; do
			[[ -f $f ]] && sources+=("$f")
		done
	fi

	local src flat newest i
	for src in "${sources[@]}"; do
		[[ -f $src ]] || continue

		flat="${src#"$config_dir"/}"
		flat="${flat//\//__}"
		newest="$backup_dir/$flat.1"

		[[ -f $newest ]] && cmp -s "$src" "$newest" && continue

		for (( i = keep - 1; i >= 1; i-- )); do
			[[ -f "$backup_dir/$flat.$i" ]] && \
				mv -f "$backup_dir/$flat.$i" \
					"$backup_dir/$flat.$((i + 1))" 2>/dev/null
		done
		cp -f "$src" "$newest" 2>/dev/null && \
			log_message "Backed up $flat (keep $keep)"
	done
}

# AUTO-1: the app writes its own XDG autostart entry with Exec=<elf path>
# when "Run on startup" is enabled. Login launches would bypass every
# launcher policy (Wayland opt-in, GPU recovery, --class). Rewrite Exec
# to point at the launcher on every start.
#
# Safe against the Settings toggle: upstream's is-enabled check reads
# only file existence plus Hidden=/X-GNOME-Autostart-enabled= — never
# Exec content. The app rewrites the entry on each toggle-on, so the
# heal repeats per launch.
#
# $1 = absolute launcher path to point the entry at.
heal_autostart_entry() {
	local launcher="$1"
	local entry_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
	local entry="$entry_dir/claude-desktop.desktop"
	local exec_line current args rest escaped new_line tmp line
	local replaced=false

	[[ -n $launcher && -f $entry ]] || return 0

	exec_line=$(LC_ALL=C grep -m1 '^Exec=' "$entry") || return 0

	if [[ $exec_line =~ ^Exec=\"([^\"]*)\"(.*)$ ]]; then
		current="${BASH_REMATCH[1]}"
		args="${BASH_REMATCH[2]}"
	else
		rest="${exec_line#Exec=}"
		current="${rest%%[[:space:]]*}"
		args="${rest#"$current"}"
	fi

	[[ $current == "$launcher" ]] && return 0
	case "$current" in
		*/claude-desktop) ;;
		*) return 0 ;;
	esac

	escaped=$(_desktop_exec_quote "$launcher") || return 0
	new_line="Exec=$escaped$args"

	tmp="$entry.tmp.$$"
	while IFS= read -r line || [[ -n $line ]]; do
		if [[ $replaced == false && $line == Exec=* ]]; then
			printf '%s\n' "$new_line"
			replaced=true
		else
			printf '%s\n' "$line"
		fi
	done < "$entry" > "$tmp" || { rm -f "$tmp"; return 0; }
	mv "$tmp" "$entry" || { rm -f "$tmp"; return 0; }

	if [[ -n ${log_file:-} ]]; then
		log_message \
			"Healed autostart Exec: $current -> $launcher (AUTO-1)"
	fi
	return 0
}

# Print $1 as a double-quoted desktop-entry Exec token, as written in
# the file. The spec layers two escapings: inside the quotes, \ " ` $
# take a backslash (Exec quoting), and the whole value is then a
# desktop-entry string, where every backslash is itself written \\
# (so a literal " ends up as \\" on disk). % becomes %% for the field
# codes. A newline or CR cannot be represented in an Exec token, so
# such a path is refused (status 1).
_desktop_exec_quote() {
	local escaped="$1"
	[[ $escaped == *[$'\n\r']* ]] && return 1
	escaped=${escaped//\\/\\\\}
	escaped=${escaped//\"/\\\"}
	escaped=${escaped//\`/\\\`}
	escaped=${escaped//\$/\\\$}
	escaped=${escaped//\\/\\\\}
	escaped=${escaped//%/%%}
	printf '"%s"' "$escaped"
}

readonly PORTAL_ENTRY_MARKER='X-Claude-Desktop-Suse-Portal-Alias=true'

# 0 when $1 is an entry the app itself generated (X-Claude-Generated=true)
# whose TryExec no longer resolves, e.g. a rotated AppImage mount path.
_portal_entry_is_stale_generated() {
	local entry="$1" try_exec

	LC_ALL=C grep -qxF 'X-Claude-Generated=true' "$entry" 2>/dev/null ||
		return 1
	try_exec=$(LC_ALL=C grep -m1 '^TryExec=' "$entry" 2>/dev/null) ||
		return 1
	try_exec=${try_exec#TryExec=}
	[[ -n $try_exec ]] || return 1
	if [[ $try_exec == /* ]]; then
		[[ ! -x $try_exec ]]
	else
		! command -v "$try_exec" &> /dev/null
	fi
}

# Electron >= 44 (Chromium 152) registers the asar desktopName, minus
# ".desktop", with org.freedesktop.host.portal.Registry before using the
# GlobalShortcuts or Secret portals, and xdg-desktop-portal >= 1.20
# refuses ids without an installed <id>.desktop. The RPM ships that
# entry system-wide; an unintegrated AppImage does not, so on native
# Wayland write a hidden alias under $XDG_DATA_HOME. The alias also
# carries x-scheme-handler/claude because setAsDefaultProtocolClient
# points claude:// at the same id, so an alias we already own is kept
# current on every backend. A system entry for the id makes the alias
# redundant, and foreign files are never touched.
#
# $1 = launcher path for Exec=, $2 = app id (desktopName minus .desktop),
# $3 = Icon= name.
ensure_portal_app_id_entry() {
	local launcher="$1" app_id="$2" icon="${3:-}"
	local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
	local entry dir tmp exec_token ours=false stale=false
	local -a data_dirs=()

	[[ -n $app_id ]] || return 0
	entry="$data_home/applications/$app_id.desktop"

	if [[ -f $entry ]]; then
		if LC_ALL=C grep -qxF "$PORTAL_ENTRY_MARKER" "$entry" 2>/dev/null; then
			ours=true
		elif _portal_entry_is_stale_generated "$entry"; then
			stale=true
		fi
	fi

	IFS=: read -r -a data_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
	for dir in "${data_dirs[@]}"; do
		[[ -n $dir && -f $dir/applications/$app_id.desktop ]] || continue
		if [[ $ours == true ]]; then
			rm -f "$entry" &&
				log_message "Removed portal app-id entry $entry (system entry $dir/applications/$app_id.desktop exists)"
		fi
		return 0
	done

	if [[ $ours == false ]]; then
		[[ ${is_wayland:-false} == true &&
			${use_x11_on_wayland:-true} == false ]] || return 0
	fi
	[[ -n $launcher ]] || return 0

	if [[ -f $entry && $ours == false && $stale == false ]]; then
		log_message "Left portal app-id entry $entry in place (not written by the launcher)"
		return 0
	fi

	exec_token=$(_desktop_exec_quote "$launcher") || return 0
	mkdir -p "$data_home/applications" || return 0
	tmp="$entry.tmp.$$"
	{
		printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Claude'
		printf 'Exec=%s %%u\n' "$exec_token"
		[[ -n $icon ]] && printf 'Icon=%s\n' "$icon"
		printf '%s\n' 'NoDisplay=true' 'MimeType=x-scheme-handler/claude;' \
			"$PORTAL_ENTRY_MARKER"
	} > "$tmp" || { rm -f "$tmp"; return 0; }

	if [[ $ours == true ]] && cmp -s "$tmp" "$entry"; then
		rm -f "$tmp"
		return 0
	fi
	mv -f "$tmp" "$entry" || { rm -f "$tmp"; return 0; }
	[[ $stale == true ]] &&
		log_message "Replacing stale app-generated entry $entry (TryExec not found)"
	log_message "Wrote portal app-id entry $entry"
	return 0
}

cleanup_after_electron_exit() {
	cleanup_orphaned_cowork_daemon
	cleanup_stale_desktop_helpers
	cleanup_stale_lock
	cleanup_stale_cowork_socket
}

_electron_launcher_forward_signal() {
	local signal="$1"

	if [[ -n ${_electron_child_pid:-} ]]; then
		kill "-$signal" "$_electron_child_pid" 2>/dev/null || true
	fi
}

# Bound what a session can write to launcher.log. Electron's whole
# stdout/stderr lands in the log for the life of the session, and a
# Chromium message stuck in a loop can write gigabytes before the
# launch-time rotation in setup_logging ever sees the file again. Two
# defences, in order:
#
#   1. Runs of identical lines collapse to the line plus one
#      "[launcher] last line repeated N more times" summary, so a
#      single-line loop costs two lines however long it spins.
#   2. After ELECTRON_LOG_CAP_BYTES of output (20 MiB default) the
#      filter stops WRITING but keeps READING: a marker line records
#      the cap, and every later line is consumed and dropped. The
#      pipe is never closed, so Electron never sees SIGPIPE.
#
# fflush() per line keeps the log live for `tail -f`. mawk and gawk
# both support it. Reads stdin, writes stdout; the caller aims stdout
# at the log.
_electron_output_filter() {
	local max="${ELECTRON_LOG_CAP_BYTES:-$((20 * 1024 * 1024))}"

	awk -v max="$max" '
		function emit(line) {
			if (capped) return
			if (written >= max) {
				print "[launcher] output cap (" max " bytes) reached;" \
					" further output dropped this session"
				fflush()
				capped = 1
				return
			}
			print line
			fflush()
			written += length(line) + 1
		}
		function end_run() {
			if (repeat > 1) {
				emit("[launcher] last line repeated " (repeat - 1) \
					" more times")
			}
			repeat = 0
		}
		{
			if (capped) next
			if (have_prev && $0 == prev) {
				repeat++
				next
			}
			if (have_prev) end_run()
			prev = $0
			have_prev = 1
			repeat = 1
			emit($0)
		}
		END { end_run() }
	'
}

# Run Electron in the background, forward TERM/INT/HUP to it, wait for
# it, then reap whatever it left behind (cleanup_after_electron_exit).
# Pre-launch hygiene (backup_user_config, heal_autostart_entry, the
# cleanup_* calls) is the launcher body's job, before this is called.
run_electron_and_cleanup() {
	local status fifo_dir fifo filter_pid=''

	_record_launch_pgid

	# A named pipe rather than > >(...) so the filter pid is known and
	# the log can be drained before the exit line is written. Fail-safe:
	# if the pipe cannot be made, fall back to the bare redirect rather
	# than block launch.
	if fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-launcher.XXXXXX" \
		2>/dev/null) && mkfifo "$fifo_dir/electron.out" 2>/dev/null; then
		fifo="$fifo_dir/electron.out"
		_electron_output_filter < "$fifo" >> "$log_file" &
		filter_pid=$!
		"$@" > "$fifo" 2>&1 &
		_electron_child_pid=$!
	else
		[[ -n ${fifo_dir:-} ]] && rm -rf "$fifo_dir"
		"$@" >> "$log_file" 2>&1 &
		_electron_child_pid=$!
	fi

	trap '_electron_launcher_forward_signal TERM' TERM
	trap '_electron_launcher_forward_signal INT' INT
	trap '_electron_launcher_forward_signal HUP' HUP

	wait "$_electron_child_pid"
	status=$?
	while kill -0 "$_electron_child_pid" 2>/dev/null; do
		wait "$_electron_child_pid"  # reap only; keep status
	done

	trap - TERM INT HUP

	# Drain the filter so Electron's last lines land before the exit
	# line. Bounded: a helper that inherited the pipe's write end and
	# outlives the main process keeps it open, so after ~2s the filter
	# is stopped and reaped. Otherwise it would go on appending that
	# helper's output after the "Launcher End" line, with no launcher
	# left to bound it. The filter is a subshell running awk; awk is
	# signalled first so it cannot outlive its parent.
	if [[ -n $filter_pid ]]; then
		local i
		for (( i = 0; i < 20; i++ )); do
			kill -0 "$filter_pid" 2>/dev/null || break
			sleep 0.1
		done
		if kill -0 "$filter_pid" 2>/dev/null; then
			pkill -TERM -P "$filter_pid" 2>/dev/null
			kill "$filter_pid" 2>/dev/null
		fi
		wait "$filter_pid" 2>/dev/null
		rm -rf "$fifo_dir"
	fi

	log_message "Electron exited with code: $status"
	cleanup_after_electron_exit
	_electron_child_pid=''
	log_message '--- Claude Desktop Launcher End ---'

	return "$status"
}

# Load persistent launcher environment from a per-user config file. GUI
# launches cannot set per-user environment through a desktop entry, so this
# provides a literal KEY=value file for supported launcher variables.
#
# The file is deliberately parsed instead of sourced: only the allowlisted
# variables below can be exported, and values never undergo shell expansion.
load_launcher_config() {
	local cfg
	cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-desktop-suse/environment"
	[[ -r $cfg ]] || return 0

	local allowlist=' CLAUDE_USE_WAYLAND CLAUDE_PASSWORD_STORE'
	allowlist+=' CLAUDE_GTK_IM_MODULE CLAUDE_DISABLE_GPU'
	allowlist+=' CLAUDE_TITLEBAR_STYLE CLAUDE_MENU_BAR'
	allowlist+=' CLAUDE_KEEP_AWAKE CLAUDE_FORCE_SANDBOX'
	allowlist+=' COWORK_VM_BACKEND '
	local line key val
	while IFS= read -r line || [[ -n $line ]]; do
		# Ignore blank lines and comments, including indented comments.
		[[ -z ${line//[[:space:]]/} || \
			${line#"${line%%[![:space:]]*}"} == '#'* ]] && continue
		[[ $line == *=* ]] || continue

		key="${line%%=*}"
		key="${key//[[:space:]]/}"
		val="${line#*=}"
		val="${val#"${val%%[![:space:]]*}"}"
		val="${val%"${val##*[![:space:]]}"}"
		[[ $allowlist == *" $key "* ]] || {
			log_message "Config: ignoring unrecognized key '$key' in $cfg"
			continue
		}

		# An explicitly exported empty value still wins over the file.
		[[ -v $key ]] && continue

		if [[ ($val == \"*\" && $val == *\") || \
			($val == \'*\' && $val == *\') ]]; then
			val="${val:1:${#val}-2}"
		fi
		export "$key=$val"
		log_message "Config: $key=$val (from $cfg)"
	done < "$cfg"
}

# Set common environment variables
setup_electron_env() {
	load_launcher_config
	# ELECTRON_FORCE_IS_PACKAGED makes app.isPackaged return true, which
	# causes the Claude app to resolve resources via process.resourcesPath.
	# The Nix derivation creates a custom Electron tree with the binary
	# copied and app resources co-located in resources/, so resourcesPath
	# naturally points to the right place on all package types.
	export ELECTRON_FORCE_IS_PACKAGED=true
	# ELECTRON_USE_SYSTEM_TITLE_BAR=1 forces a system titlebar at the
	# Electron level. Set in 'native' and 'hybrid' modes (both use
	# frame:true); skipped in 'hidden' mode (frame:false + WCO config).
	if [[ $(_resolve_titlebar_style) != 'hidden' ]]; then
		export ELECTRON_USE_SYSTEM_TITLE_BAR=1
	fi
	# CLAUDE_GTK_IM_MODULE: opt-in override for users hit by broken
	# IBus integration on Linux (#549). Propagated to GTK_IM_MODULE
	# so e.g. `xim` can be persisted without wrapping every launch.
	if [[ -n ${CLAUDE_GTK_IM_MODULE:-} ]]; then
		local prev="${GTK_IM_MODULE:-<unset>}"
		export GTK_IM_MODULE="$CLAUDE_GTK_IM_MODULE"
		log_message \
			"GTK_IM_MODULE override: $prev -> $GTK_IM_MODULE (via CLAUDE_GTK_IM_MODULE)"
	fi
}

#===============================================================================
# Doctor Diagnostics
#
# run_doctor and its helpers live in doctor.sh alongside this file. Sourced
# here so any consumer of launcher-common.sh gets the full run_doctor entry
# point without needing to know about the split. Each packaging target
# (deb/rpm/AppImage/Nix) installs doctor.sh next to launcher-common.sh.
#===============================================================================
# shellcheck source=scripts/doctor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/doctor.sh"
