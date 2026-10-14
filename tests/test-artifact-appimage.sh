#!/usr/bin/env bash
# Integration tests for AppImage artifacts

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
if [[ ! -d $artifact_dir || ! -r $artifact_dir ]]; then
	printf '[FAIL] Artifact directory is not readable: %s\n' "$artifact_dir" >&2
	exit 1
fi
artifact_dir="$(cd "$artifact_dir" && pwd)" || exit 1
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

# The runtime's FUSE half daemonizes into its own session, so killing
# the --appimage-mount process can leave the mount behind. Unmount by
# path; the daemon exits once the mount is gone.
_unmount_appimage() {
	[[ -n ${mount_point:-} ]] || return 0
	if mountpoint -q "$mount_point" 2>/dev/null; then
		fusermount3 -u "$mount_point" 2>/dev/null \
			|| fusermount -u "$mount_point" 2>/dev/null
	fi
	mount_point=''
}

# Single cleanup point: _launch_smoke_cleanup reaps an interrupted
# launch + its temp dirs; the mount and extract_dir are AppImage-specific.
_cleanup() {
	_launch_smoke_cleanup
	[[ -n ${mount_pid:-} ]] && kill "$mount_pid" 2>/dev/null
	_unmount_appimage
	[[ -n ${mount_log:-} ]] && rm -f "$mount_log"
	[[ -n ${extract_dir:-} ]] && rm -rf "$extract_dir"
}
trap _cleanup EXIT INT TERM

component_id='io.github.presire.claude-desktop-suse'

# Find the AppImage file (exclude .zsync)
appimage_file=$(find "$artifact_dir" -name '*.AppImage' \
	! -name '*.zsync' -type f | head -1)
if [[ -z $appimage_file ]]; then
	skip "No AppImage artifact available in $artifact_dir"
	print_summary
	exit 0
fi
pass "Found AppImage: $(basename "$appimage_file")"

# --- AppImage is executable ---
chmod +x "$appimage_file"
assert_executable "$appimage_file"

# --- File type check ---
file_type=$(file -b "$appimage_file")
if [[ $file_type == *"ELF"* ]] || [[ $file_type == *"executable"* ]]; then
	pass "AppImage is an ELF executable"
else
	fail "AppImage file type unexpected: $file_type"
fi

# --- Mounts through FUSE ---
# The AppImage embeds the static type2 runtime, which links FUSE in and
# needs only fusermount3, not libfuse2. --appimage-mount prints the
# mount point, then holds the mount until killed; AppRun showing up
# under it proves the runtime mounted the image, not just extracted it.
if ! command -v fusermount3 &>/dev/null \
	&& ! command -v fusermount &>/dev/null; then
	skip "fusermount3/fusermount not installed (zypper install fuse3)"
elif [[ ! -c /dev/fuse || ! -r /dev/fuse ]]; then
	skip "/dev/fuse is not available in this environment"
else
	mount_log=$(mktemp)
	"$appimage_file" --appimage-mount > "$mount_log" 2>&1 &
	mount_pid=$!
	mount_point=''
	for _ in {1..100}; do
		mount_point=$(head -1 "$mount_log")
		[[ -n $mount_point && -x $mount_point/AppRun ]] && break
		sleep 0.1
	done
	if [[ -n $mount_point && -x $mount_point/AppRun ]]; then
		pass "AppImage mounts via FUSE ($mount_point)"
	else
		fail "AppImage did not mount: $(head -3 "$mount_log" | tr '\n' ' ')"
	fi
	kill "$mount_pid" 2>/dev/null
	wait "$mount_pid" 2>/dev/null
	mount_pid=''
	_unmount_appimage
fi

# --- Extract AppImage ---
extract_dir=$(mktemp -d)
cd "$extract_dir" || exit 1
"$appimage_file" --appimage-extract >/dev/null 2>&1
appdir="$extract_dir/squashfs-root"

if [[ -d $appdir ]]; then
	pass "--appimage-extract succeeded"
else
	fail "--appimage-extract failed (no squashfs-root)"
	print_summary
fi

# --- AppDir structure ---
assert_file_exists "$appdir/AppRun"
assert_executable "$appdir/AppRun"

# Top-level desktop entry
if [[ -f "$appdir/${component_id}.desktop" ]]; then
	pass "Top-level .desktop file exists"
	assert_contains "$appdir/${component_id}.desktop" \
		'Type=Application' "Desktop entry Type correct"
	assert_contains "$appdir/${component_id}.desktop" \
		'Exec=AppRun' "Desktop entry Exec points to AppRun"
	assert_contains "$appdir/${component_id}.desktop" \
		'StartupWMClass=Claude' "Desktop entry WM_CLASS correct"
else
	fail "No top-level .desktop file"
fi

# Desktop entry in standard location
assert_file_exists \
	"$appdir/usr/share/applications/${component_id}.desktop"

# Top-level icon
if [[ -f "$appdir/${component_id}.png" ]]; then
	pass "Top-level icon present"
else
	fail "No top-level icon found"
fi

# .DirIcon
assert_file_exists "$appdir/.DirIcon"

# AppStream metadata. project_license describes the proprietary Claude
# app the user launches, matching the RPM metainfo.
appdata="$appdir/usr/share/metainfo/${component_id}.appdata.xml"
assert_file_exists "$appdata"
assert_contains "$appdata" \
	'<project_license>LicenseRef-proprietary</project_license>' \
	"AppStream project_license is LicenseRef-proprietary"
assert_contains "$appdata" \
	"<icon type=\"stock\">${component_id}</icon>" \
	"AppStream metainfo names the stock icon"
if command -v appstreamcli &> /dev/null; then
	assert_command_succeeds "appstreamcli accepts the metainfo" \
		appstreamcli validate --no-net "$appdata"
else
	skip "appstreamcli not installed (zypper install AppStream)"
fi

# --- Electron binary ---
electron_path="$appdir/usr/lib/node_modules/electron/dist/electron"
assert_file_exists "$electron_path"
assert_executable "$electron_path"

# --- Launcher library ---
assert_file_exists "$appdir/usr/lib/claude-desktop/launcher-common.sh"

# --- AppRun content ---
assert_contains "$appdir/AppRun" 'launcher-common.sh' \
	"AppRun sources launcher-common.sh"
assert_contains "$appdir/AppRun" 'run_doctor' \
	"AppRun references run_doctor"
assert_contains "$appdir/AppRun" 'build_electron_args' \
	"AppRun calls build_electron_args"
assert_contains "$appdir/AppRun" 'run_electron_and_cleanup' \
	"AppRun keeps Electron as a child (run_electron_and_cleanup)"

# --- App contents (asar) ---
resources_dir="$appdir/usr/lib/node_modules/electron/dist/resources"
validate_app_contents "$resources_dir"

doctor_exit=0
"$appimage_file" --doctor >/dev/null 2>&1 || doctor_exit=$?
if [[ $doctor_exit -lt 127 ]]; then
	pass "--doctor runs without crashing (exit: $doctor_exit)"
else
	fail "--doctor crashed (exit: $doctor_exit)"
fi

# --- Launcher --version fast-path ---
# The baked version comes from the artifact filename
# (claude-desktop-<version>-<arch>.AppImage).
appimage_version="$(basename "$appimage_file")"
appimage_version="${appimage_version#claude-desktop-}"
appimage_version="${appimage_version%.AppImage}"
appimage_version="${appimage_version%-*}"
run_version_flag_test 'AppImage' \
	"claude-desktop $appimage_version" exact "$appimage_file"

# --- Headless launch smoke test ---
# Sweep escaped children only in CI: locally, 'mount_claude' also
# matches a developer's live Claude Desktop AppImage session.
run_launch_smoke_test 'AppImage' '' "$appimage_file"

# --- Cleanup ---
rm -rf "$extract_dir"

print_summary
