#===============================================================================
# Top-level app.asar patch orchestration: extract, wrap entry point, stub
# native module, copy i18n and tray icons, then invoke per-feature patches.
#
# Sourced by: build.sh
# Sourced globals:
#   claude_extract_dir, app_staging_dir, asar_exec, source_dir,
#   build_format, dark_tray_icons
# Modifies globals: (none directly — delegated patches may mutate electron_var)
#===============================================================================

_read_package_json_field() {
	local field="$1"
	node -e 'console.log(require("./app.asar.contents/package.json")[process.argv[1]] ?? "")' \
		"$field"
}

# Derive the desktop-entry StartupWMClass from the asar package.json
# desktopName. Chromium turns desktopName into the runtime X11
# WM_CLASS / Wayland app_id by stripping the .desktop suffix; it
# ignores --class, productName, and the ELF basename. The value is
# therefore format-dependent (RPM ships claude-desktop.desktop,
# AppImage ships io.github.presire.claude-desktop-suse.desktop) and
# must come from the same variable that patch_app_asar writes into
# package.json so the two cannot drift (#779).
#
# Fails loudly instead of echoing an empty string: a missing field or
# a changed suffix would otherwise ship a .desktop entry that cannot
# group its own window.
_derive_startup_wm_class() {
	local desktop_name="$1"

	if [[ -z $desktop_name ]]; then
		echo 'Error: desktopName is missing/empty — cannot derive' \
			'StartupWMClass. Upstream moved the field Chromium reads' \
			'the window class from; re-verify before shipping (#779).' >&2
		return 1
	fi
	if [[ $desktop_name != *.desktop ]]; then
		echo "Error: desktopName '$desktop_name' has no .desktop suffix" \
			'— upstream changed its shape; re-verify how Chromium' \
			'derives the window class before shipping (#779).' >&2
		return 1
	fi

	printf '%s\n' "${desktop_name%.desktop}"
}

# Run one patch function in the current shell. The tray patches
# publish globals (electron_var, electron_var_re) that later patches
# read, so capturing output in a subshell would silently lose them.
#
# A non-zero exit from the patch fails the stage in both modes: a
# patch that wrote part of its change and then failed must not pass
# as effective just because the digest moved.
#
# mode 'check' (the first pass) digests .vite/build before and after
# and fails unless the function changed it or is allowlisted. Mode
# 'no-check' is for the PATCH_STAGE_RERUN=1 replay, where every patch
# is expected to be a no-op and only the whole-stage idempotency check
# applies.
_run_suse_patch_function() {
	local fn="$1"
	local mode="${2:-check}"
	local before after

	if [[ $mode == 'check' ]]; then
		before=$(_patch_bundle_digest) || {
			echo "Patch effect: cannot digest the bundle before $fn" >&2
			return 1
		}
	fi

	patch_noop_declared=''
	"$fn"
	local fn_status=$?
	if (( fn_status != 0 )); then
		echo "Patch stage: $fn failed (exit $fn_status)" >&2
		return 1
	fi

	if [[ $mode == 'check' ]]; then
		after=$(_patch_bundle_digest) || {
			echo "Patch effect: cannot digest the bundle after $fn" >&2
			return 1
		}
		_check_patch_effect "$fn" "$before" "$after" \
			"$patch_noop_declared" || return 1
	fi
}

_suse_patch_stage_fail() {
	echo 'Patch stage aborted. See the Patch effect message above.' >&2
	cd "$project_root" || exit 1
	exit 1
}

# Run every per-feature patch against $main_js (CWD =
# $app_staging_dir). Factored out so the PATCH_STAGE_RERUN=1
# idempotency self-check can re-run the identical sequence on the
# already-patched tree; that replay passes 'no-check' so the
# per-patch effect check does not treat every guard as a failure.
_run_suse_patch_stage() {
	local mode="${1:-check}"
	# Extract electron module variable name for tray patches
	_run_suse_patch_function extract_electron_variable "$mode" || _suse_patch_stage_fail

	# Fix incorrect nativeTheme variable references
	_run_suse_patch_function fix_native_theme_references "$mode" || _suse_patch_stage_fail

	# Patch tray menu handler
	_run_suse_patch_function patch_tray_menu_handler "$mode" || _suse_patch_stage_fail

	# Patch tray icon selection
	_run_suse_patch_function patch_tray_icon_selection "$mode" || _suse_patch_stage_fail

	# Honor CLAUDE_TRAY_USE_DARK_ICON (Cinnamon dark panels, #604)
	_run_suse_patch_function patch_tray_icon_env_override "$mode" || _suse_patch_stage_fail

	# Inject fast-path that updates the tray icon in place on theme
	# changes (avoids the KDE duplicate-SNI race on destroy+recreate)
	_run_suse_patch_function patch_tray_inplace_update "$mode" || _suse_patch_stage_fail

	# Keep the tray context menu on Linux: upstream's tray usage-menu
	# gate swaps setContextMenu for a right-click popUpContextMenu,
	# which Electron does not support on Linux; left-click records the
	# tray open that the usage poll needs instead
	_run_suse_patch_function patch_tray_linux_context_menu "$mode" || _suse_patch_stage_fail

	# Patch menuBarEnabled to default to true when unset
	_run_suse_patch_function patch_menu_bar_default "$mode" || _suse_patch_stage_fail

	# Patch quick window
	_run_suse_patch_function patch_quick_window "$mode" || _suse_patch_stage_fail

	# Patch Exit menu accelerator for Ctrl+Q (SUSE-specific)
	_run_suse_patch_function patch_exit_accelerator "$mode" || _suse_patch_stage_fail

	# Add Linux Claude Code support
	_run_suse_patch_function patch_linux_claude_code "$mode" || _suse_patch_stage_fail

	# Reject .asar paths in the directory-check helper so Electron's
	# ASAR VFS shim doesn't misidentify app.asar as a folder and
	# trigger false Cowork dispatch (#383, #622, #632).
	_run_suse_patch_function patch_asar_path_filter "$mode" || _suse_patch_stage_fail

	# Reject .asar paths in the argv file-drop collector so the
	# existsSync branch doesn't dispatch app.asar as a file drop,
	# triggering a permission prompt on every window reopen (#383, #622).
	_run_suse_patch_function patch_asar_argv_file_drop_guard "$mode" || _suse_patch_stage_fail

	# Patch Cowork mode for Linux (TypeScript VM client + Unix socket)
	_run_suse_patch_function patch_cowork_linux "$mode" || _suse_patch_stage_fail

	_run_suse_patch_function patch_virtiofsd_probe "$mode" || _suse_patch_stage_fail

	# Add Linux org-plugins path for MDM-managed plugin marketplace
	_run_suse_patch_function patch_org_plugins_path "$mode" || _suse_patch_stage_fail

	# Inject WCO shim into the BrowserView preload so claude.ai's
	# desktop topbar renders on Linux. The shim spoofs the bundle's
	# isWindows() UA check (load-bearing) plus matchMedia and
	# windowControlsOverlay (defensive). See
	# docs/learnings/linux-topbar-shim.md.
	_run_suse_patch_function patch_wco_shim "$mode" || _suse_patch_stage_fail

	# Keep mcpServers when a failed config load would let a write wipe
	# them; servers deleted in Settings are written as-is (#400)
	_run_suse_patch_function patch_config_write_merge "$mode" || _suse_patch_stage_fail

	# Reject .asar paths in addTrustedFolder to reduce spurious config
	# writes that amplify the stale-cache overwrite bug (#400)
	_run_suse_patch_function patch_asar_trusted_folder_guard "$mode" || _suse_patch_stage_fail

	# Filter .asar paths from --add-dir dispatch and session restore
	# so corrupted pre-#640 sessions cannot crash local agent mode (#649)
	_run_suse_patch_function patch_asar_additional_dirs_guard "$mode" || _suse_patch_stage_fail
}

patch_app_asar() {
	echo 'Processing app.asar...'
	cp "$claude_extract_dir/lib/net45/resources/app.asar" "$app_staging_dir/" || exit 1
	cp -a "$claude_extract_dir/lib/net45/resources/app.asar.unpacked" "$app_staging_dir/" || exit 1
	cd "$app_staging_dir" || exit 1
	"$asar_exec" extract app.asar app.asar.contents || exit 1

	# Frame fix wrapper
	echo 'Creating BrowserWindow frame fix wrapper...'
	local original_main
	original_main=$(_read_package_json_field main)
	echo "Original main entry: $original_main"

	cp "$source_dir/scripts/frame-fix-wrapper.js" app.asar.contents/frame-fix-wrapper.js || exit 1
	cp "$source_dir/scripts/frame-fix-menu.js" app.asar.contents/frame-fix-menu.js || exit 1
	cp "$source_dir/scripts/frame-fix-autostart.js" app.asar.contents/frame-fix-autostart.js || exit 1

	cat > app.asar.contents/frame-fix-entry.js << EOFENTRY
// Load frame fix first
require('./frame-fix-wrapper.js');
// Then load original main
require('./${original_main}');
EOFENTRY

	# BrowserWindow frame/titleBarStyle patching is handled at runtime by
	# frame-fix-wrapper.js via a Proxy on require('electron'). No sed patches
	# needed — the wrapper detects popup vs main windows by their options and
	# applies frame:true/false accordingly.

	# Update package.json — set pkg.desktopName so KDE Plasma Wayland groups
	# windows with the installed .desktop file (#562). Format-conditional:
	# rpm install ships claude-desktop.desktop; AppImage bundles
	# io.github.presire.claude-desktop-suse.desktop inside the AppDir, which
	# is the id Gear Lever / AppImageLauncher honour when integrating.
	echo 'Modifying package.json to load frame fix and add node-pty...'
	local desktop_name='claude-desktop.desktop'
	if [[ ${build_format:-} == 'appimage' ]]; then
		desktop_name='io.github.presire.claude-desktop-suse.desktop'
	fi
	node -e "
const fs = require('fs');
const pkg = require('./app.asar.contents/package.json');
pkg.originalMain = pkg.main;
pkg.main = 'frame-fix-entry.js';
pkg.desktopName = process.argv[1];
pkg.optionalDependencies = pkg.optionalDependencies || {};
pkg.optionalDependencies['node-pty'] = '^1.0.0';
fs.writeFileSync('./app.asar.contents/package.json', JSON.stringify(pkg, null, 2));
console.log('Updated package.json: main entry, desktopName=' + process.argv[1] + ', and node-pty dependency');
" "$desktop_name"

	# Packaging scripts and build.sh interpolate this into every
	# .desktop StartupWMClass; an empty value would ship a broken
	# entry, so refuse to continue without the derivation. Exported
	# because the packaging scripts run as child processes.
	STARTUP_WM_CLASS=$(_derive_startup_wm_class "$desktop_name") || {
		cd "$project_root" || exit 1
		exit 1
	}
	export STARTUP_WM_CLASS
	echo "StartupWMClass '$STARTUP_WM_CLASS' derived from desktopName '$desktop_name'"

	local product_name
	product_name=$(_read_package_json_field productName)
	if [[ $product_name != "$WM_CLASS" ]]; then
		echo "Error: upstream productName '$product_name' != WM_CLASS '$WM_CLASS'" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	# Resolve the code-split main chunk once; every patch reads $main_js.
	# Since upstream 1.19367.0 index.js is a stub that require()s the
	# real main chunk (index.chunk-<hash>.js). All patch anchors live in
	# the chunk, not the stub.
	local stub_js='app.asar.contents/.vite/build/index.js'
	main_js=$(_resolve_main_js "$stub_js") || {
		echo 'Failed to resolve main-process JS from stub' >&2
		echo "  This usually means the installed Claude version's bundle" \
			'layout is newer than the patch scripts support.' >&2
		echo '  Build the verified default release instead (omit' \
			'--claude-version):' >&2
		echo '    ./build.sh --build rpm' >&2
		cd "$project_root" || exit 1
		exit 1
	}
	echo "Main-process JS: $main_js"

	# MB-1 tripwire: the settings default that keeps the menu bar on.
	# The tray patches assume this default is present; if upstream flips
	# it, the menu bar would default OFF on Linux. Check the resolved
	# main JS (stub or chunk) so the anchor is found in code-split
	# bundles where it lives in index.chunk-<hash>.js, not index.js.
	_check_mb1_tripwire "$main_js" || {
		cd "$project_root" || exit 1
		exit 1
	}
	echo 'Upstream tripwire clear (menuBarEnabled:!0 present)'

	# Create stub native module
	echo 'Creating stub native module...'
	mkdir -p app.asar.contents/node_modules/@ant/claude-native || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		app.asar.contents/node_modules/@ant/claude-native/index.js || exit 1

	mkdir -p app.asar.contents/resources/i18n || exit 1
	# All locales, including region-less ones (am.json, ru.json, ...).
	cp "$claude_extract_dir/lib/net45/resources/"*.json app.asar.contents/resources/i18n/ || exit 1

	# Copy tray icons into asar so both packaged (process.resourcesPath)
	# and unpackaged (app.getAppPath()) code paths can find them
	cp "$claude_extract_dir/lib/net45/resources/Tray"* app.asar.contents/resources/ 2>/dev/null || \
		echo 'Warning: No tray icon files found for asar inclusion'

	# --dark: replace default tray icons with dark-mode variants inside asar
	if [[ ${dark_tray_icons:-false} == true ]]; then
		echo 'Replacing asar tray icons with dark-mode variants...'
		local dark_icon base_icon
		for dark_icon in app.asar.contents/resources/TrayIconTemplate-Dark*.png; do
			[[ ! -f $dark_icon ]] && continue
			base_icon="${dark_icon/-Dark/}"
			cp "$dark_icon" "$base_icon"
		done
	fi

	_run_suse_patch_stage

	# Opt-in idempotency self-check (mirrors Debian's
	# PATCH_STAGE_RERUN=1): re-run the same patch functions on the
	# already-patched tree and fail when any byte changes, i.e. a
	# patch guard misses its own output and re-applies. Default
	# behaviour is unchanged when the variable is unset.
	if [[ ${PATCH_STAGE_RERUN:-} == '1' ]]; then
		echo 'PATCH_STAGE_RERUN=1: re-running patch stage' \
			'to verify idempotency...'
		local rerun_before rerun_after
		rerun_before=$(_patch_bundle_digest) || {
			echo 'Idempotency: cannot digest the patched' \
				'bundle' >&2
			cd "$project_root" || exit 1
			exit 1
		}
		_run_suse_patch_stage no-check
		rerun_after=$(_patch_bundle_digest) || {
			echo 'Idempotency: cannot digest the bundle' \
				'after the re-run' >&2
			cd "$project_root" || exit 1
			exit 1
		}
		_check_patch_stage_idempotent \
			"$rerun_before" "$rerun_after" || {
			cd "$project_root" || exit 1
			exit 1
		}
		echo 'Idempotency: second patch pass left the bundle unchanged'
	fi

	# Copy cowork VM service daemon for Linux Cowork mode
	echo 'Installing cowork VM service daemon...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		app.asar.contents/cowork-vm-service.js || exit 1
	echo 'Cowork VM service daemon installed'
}
