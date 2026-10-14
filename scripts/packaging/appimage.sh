#!/usr/bin/env bash

# Arguments passed from the main script
version="$1"
architecture="$2"
work_dir="$3"           # The top-level build directory (e.g., ./build)
app_staging_dir="$4"    # Directory containing the prepared app files
package_name="$5"

# Version is baked into the AppRun --version fast path; reject before
# packaging to fail closed upstream.
if [[ -z $version || ! $version =~ ^[0-9]+(\.[0-9]+)+(-[0-9]+(\.[0-9]+)*)?$ ]]; then
	echo "Error: invalid build version '$version'" >&2
	echo 'Expected a non-empty version starting with a digit' >&2
	exit 1
fi

echo '--- Starting AppImage Build ---'
echo "Version: $version"
echo "Architecture: $architecture"
echo "Work Directory: $work_dir"
echo "App Staging Directory: $app_staging_dir"
echo "Package Name: $package_name"

component_id='io.github.presire.claude-desktop-suse'
# Define AppDir structure path
# Note: AppImage internal paths use /usr/lib (standard AppImage convention),
# independent of the host system's /usr/lib64 convention on SUSE.
appdir_path="$work_dir/${component_id}.AppDir"
rm -rf "$appdir_path"
mkdir -p "$appdir_path/usr/bin" || exit 1
mkdir -p "$appdir_path/usr/lib" || exit 1
mkdir -p "$appdir_path/usr/share/icons/hicolor/256x256/apps" || exit 1
mkdir -p "$appdir_path/usr/share/applications" || exit 1

echo 'Staging application files into AppDir...'
# Copy node_modules first to set up Electron directory structure
if [[ -d $app_staging_dir/node_modules ]]; then
	echo 'Copying node_modules from staging to AppDir...'
	cp -a "$app_staging_dir/node_modules" "$appdir_path/usr/lib/" || exit 1
fi

# Install app.asar in Electron's resources directory where process.resourcesPath points
resources_dir="$appdir_path/usr/lib/node_modules/electron/dist/resources"
mkdir -p "$resources_dir" || exit 1
if [[ -f $app_staging_dir/app.asar ]]; then
	cp -a "$app_staging_dir/app.asar" "$resources_dir/" || exit 1
fi
if [[ -d $app_staging_dir/app.asar.unpacked ]]; then
	cp -a "$app_staging_dir/app.asar.unpacked" "$resources_dir/" || exit 1
fi
echo 'Application files copied to Electron resources directory'

# Copy shared launcher library (launcher-common.sh sources doctor.sh
# at runtime, so both must live in the same directory)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$appdir_path/usr/lib/claude-desktop" || exit 1
cp "$(dirname "$script_dir")/launcher-common.sh" "$appdir_path/usr/lib/claude-desktop/" || exit 1
sed -i "s/@@WM_CLASS@@/$WM_CLASS/" "$appdir_path/usr/lib/claude-desktop/launcher-common.sh"
cp "$(dirname "$script_dir")/doctor.sh" "$appdir_path/usr/lib/claude-desktop/" || exit 1
echo 'Shared launcher library + doctor copied'

# Ensure Electron is bundled within the AppDir for portability
bundled_electron_path="$appdir_path/usr/lib/node_modules/electron/dist/electron"
echo "Checking for executable at: $bundled_electron_path"
if [[ ! -x $bundled_electron_path ]]; then
	echo 'Electron executable not found or not executable in staging area.' >&2
	echo "Path checked: $bundled_electron_path" >&2
	echo 'AppImage requires Electron to be bundled. Ensure the main script copies it correctly.' >&2
	exit 1
fi
chmod +x "$bundled_electron_path" || exit 1

# --- Create AppRun Script ---
echo 'Creating AppRun script...'
cat > "$appdir_path/AppRun" << 'EOF'
#!/usr/bin/env bash

# Find the location of the AppRun script
appdir=$(dirname "$(readlink -f "$0")")

# Source shared launcher library
source "$appdir/usr/lib/claude-desktop/launcher-common.sh"

# Handle --doctor flag before anything else
if [[ "${1:-}" == '--doctor' ]]; then
	electron_path="$appdir/usr/lib/node_modules/electron/dist/electron"
	run_doctor "$electron_path" 'appimage'
	exit $?
fi

# --version fast path: print stamped version and exit 0 before any
# logging, display detection, D-Bus/sandbox, or Electron launch.
if [[ "${1:-}" == '--version' ]]; then
	echo '@@PACKAGE_NAME@@ @@VERSION@@'
	exit 0
fi

# Setup logging and environment
setup_logging || exit 1
setup_electron_env
cleanup_replaced_desktop_ui
cleanup_orphaned_cowork_daemon
cleanup_stale_desktop_helpers
cleanup_stale_lock
cleanup_stale_cowork_socket
heal_autostart_entry "${APPIMAGE:-}"
backup_user_config

# Detect display backend
detect_display_backend
ensure_portal_app_id_entry "${APPIMAGE:-}" 'io.github.presire.claude-desktop-suse' \
	'io.github.presire.claude-desktop-suse'

# Log startup info
log_message '--- Claude Desktop AppImage Start ---'
log_message "Timestamp: $(date)"
log_message "Arguments: $@"
log_message "APPDIR: $appdir"
log_session_env

# Path to the bundled Electron executable and app
electron_exec="$appdir/usr/lib/node_modules/electron/dist/electron"
app_path="$appdir/usr/lib/node_modules/electron/dist/resources/app.asar"

# Build electron args (appimage mode adds --no-sandbox)
build_electron_args 'appimage'

# Add app path LAST - Chromium flags must come before this
electron_args+=("$app_path")

# Change to HOME directory before launching Electron to avoid CWD permission issues
cd "$HOME" || exit 1

# Execute Electron. AppRun stays alive as Electron's parent so it can
# filter output into the log and reap Cowork/helper processes the app
# leaves behind; the FUSE mount is held until that cleanup finishes.
log_message "Executing: $electron_exec ${electron_args[*]} $*"
run_electron_and_cleanup "$electron_exec" "${electron_args[@]}" "$@"
EOF
chmod +x "$appdir_path/AppRun" || exit 1
# The AppRun heredoc is quoted (runtime expansion), so stamp the
# build-time --version fast-path values in afterwards.
sed -i "s/@@PACKAGE_NAME@@/$package_name/; s/@@VERSION@@/$version/" \
	"$appdir_path/AppRun" || exit 1
echo 'AppRun script created'

# --- Create Desktop Entry (Bundled inside AppDir) ---
echo 'Creating bundled desktop entry...'
cat > "$appdir_path/$component_id.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=AppRun %u
Icon=$component_id
Type=Application
Terminal=false
Categories=Network;Utility;
Comment=Claude Desktop for Linux
MimeType=x-scheme-handler/claude;
StartupWMClass=$WM_CLASS
X-AppImage-Version=$version
X-AppImage-Name=Claude Desktop
EOF
mkdir -p "$appdir_path/usr/share/applications" || exit 1
cp "$appdir_path/$component_id.desktop" "$appdir_path/usr/share/applications/" || exit 1
echo 'Bundled desktop entry created and copied to usr/share/applications/'

# --- Copy Icons ---
echo 'Copying icons...'
# icotool's image index differs between releases; match the size only.
icon_source_path="$work_dir/claude_*_256x256x32.png"
for candidate in "$work_dir"/claude_*_256x256x32.png; do
	[[ -f $candidate ]] && icon_source_path="$candidate" && break
done
if [[ -f $icon_source_path ]]; then
	cp "$icon_source_path" "$appdir_path/usr/share/icons/hicolor/256x256/apps/${component_id}.png" || exit 1
	cp "$icon_source_path" "$appdir_path/${component_id}.png" || exit 1
	cp "$icon_source_path" "$appdir_path/${component_id}" || exit 1
	cp "$icon_source_path" "$appdir_path/.DirIcon" || exit 1
	echo 'Icon copied to standard path, top-level (.png and no ext), and .DirIcon'
else
	echo "Warning: Missing 256x256 icon at $icon_source_path. AppImage icon might be missing."
fi

# --- Create AppStream Metadata ---
echo 'Creating AppStream metadata...'
metadata_dir="$appdir_path/usr/share/metainfo"
mkdir -p "$metadata_dir" || exit 1

appdata_file="$metadata_dir/${component_id}.appdata.xml"

# project_license describes the app the user launches (the proprietary
# Claude binary), not the MIT packaging scripts; it matches the RPM
# metainfo in scripts/packaging/.
cat > "$appdata_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$component_id</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>LicenseRef-proprietary</project_license>
  <developer id="io.github.presire">
    <name>presire</name>
  </developer>

  <name>Claude Desktop</name>
  <summary>Unofficial desktop client for Claude AI</summary>

  <description>
    <p>
      Provides a desktop experience for interacting with Claude AI, wrapping the web interface.
    </p>
  </description>

  <launchable type="desktop-id">${component_id}.desktop</launchable>
  <icon type="stock">${component_id}</icon>

  <url type="homepage">https://github.com/presire/claude-desktop-suse</url>
  <screenshots>
      <screenshot type="default">
          <image>https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45</image>
      </screenshot>
  </screenshots>
  <provides>
    <binary>AppRun</binary>
  </provides>

  <categories>
    <category>Network</category>
    <category>Utility</category>
  </categories>

  <content_rating type="oars-1.1" />

  <releases>
    <release version="$version" date="$(date +%Y-%m-%d)">
      <description>
        <p>Version $version.</p>
      </description>
    </release>
  </releases>

</component>
EOF
echo "AppStream metadata created at $appdata_file"

# appimagetool also runs appstream-glib's appstream-util, which rejects
# the stock <icon> that the AppStream reference validator accepts in
# metainfo ("<icon> not allowed in desktop appdata"). Validate with
# appstreamcli here and switch appimagetool's own check off below.
if command -v appstreamcli &> /dev/null; then
	if ! appstreamcli validate --no-net --explain "$appdata_file"; then
		echo "AppStream validation failed: $appdata_file" >&2
		exit 1
	fi
else
	echo 'appstreamcli not found - skipping AppStream validation (zypper install AppStream)' >&2
fi


# --- Get appimagetool ---
# appimagetool is a native binary that runs on the HOST machine, not the
# package's target architecture, so select it strictly by uname -m. The
# target architecture is only used later for the embedded ARCH and the
# runtime stub.
host_arch=$(uname -m)
case "$host_arch" in
	x86_64|aarch64) ;;
	*)
		echo "Unsupported host architecture for appimagetool: $host_arch" >&2
		exit 1
		;;
esac

# Pinned AppImage toolchain (ported from claude-desktop-debian #932).
# AppImageKit's old "continuous" runtime is dynamically linked against
# libfuse.so.2, which minimal openSUSE/SLE installs do not always carry.
# The type2-runtime build is static with FUSE linked in, so the AppImage
# needs no libfuse2 on the host. appimagetool comes from the matching
# AppImage/appimagetool project. Both are pinned by release and SHA-256.
APPIMAGETOOL_VERSION='1.9.1'
APPIMAGETOOL_SHA256_X86_64='ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'
APPIMAGETOOL_SHA256_AARCH64='f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158'
TYPE2_RUNTIME_VERSION='20251108'
TYPE2_RUNTIME_SHA256_X86_64='2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d'
TYPE2_RUNTIME_SHA256_AARCH64='00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444'

# Download $1 (URL) to $2 unless a copy with SHA-256 $3 is already
# there, then verify it. A cached or downloaded file with the wrong
# hash is removed and the build fails.
fetch_pinned() {
	local url="$1" dest="$2" sha256="$3"
	local checksum_line="$sha256  $dest"
	if [[ -f $dest ]] \
		&& sha256sum -c --status <<< "$checksum_line" 2> /dev/null; then
		echo "Using cached $dest"
		return 0
	fi
	echo "Downloading $url"
	if ! wget -q -O "$dest" "$url"; then
		echo "Failed to download $url" >&2
		rm -f "$dest"
		return 1
	fi
	if ! sha256sum -c --status <<< "$checksum_line"; then
		echo "SHA-256 mismatch for $dest (expected $sha256)" >&2
		rm -f "$dest"
		return 1
	fi
	return 0
}

appimagetool_path=''

# Check system PATH first. The runtime is forced with --runtime-file
# below, so a local tool still produces a libfuse2-free AppImage.
if command -v appimagetool &> /dev/null; then
	appimagetool_path=$(command -v appimagetool)
	echo "Found appimagetool in PATH: $appimagetool_path"
fi

# Otherwise use the pinned HOST-arch tool. The versioned name keeps a
# --clean no build from reusing an older AppImageKit download.
if [[ -z $appimagetool_path ]]; then
	case "$host_arch" in
		x86_64) appimagetool_sha256="$APPIMAGETOOL_SHA256_X86_64" ;;
		aarch64) appimagetool_sha256="$APPIMAGETOOL_SHA256_AARCH64" ;;
	esac
	appimagetool_url='https://github.com/AppImage/appimagetool/releases/download/'
	appimagetool_url+="${APPIMAGETOOL_VERSION}/appimagetool-${host_arch}.AppImage"
	appimagetool_path="$work_dir/appimagetool-${APPIMAGETOOL_VERSION}"
	appimagetool_path+="-${host_arch}.AppImage"
	fetch_pinned "$appimagetool_url" "$appimagetool_path" \
		"$appimagetool_sha256" || exit 1
	chmod +x "$appimagetool_path" || exit 1
fi

# Run the tool without mounting it, so the build host needs no FUSE
# either.
export APPIMAGE_EXTRACT_AND_RUN=1

# Normalize AppDir permissions before squashing. The staging copies
# preserve source modes, and a restrictive build umask can leave
# directories at 0700. mksquashfs records those verbatim, so a user who
# later runs the AppImage cannot traverse into app.asar.unpacked/ and
# Cowork's daemon auto-launch silently fails (the fork is guarded by
# fs.existsSync()). Canonical modes: dirs and executables 755, rest 644.
echo 'Normalizing AppDir permissions...'
find "$appdir_path" -type d -exec chmod 755 {} + || exit 1
find "$appdir_path" -type f -exec chmod u=rwX,go=rX {} + || exit 1

# --- Build AppImage ---
echo 'Building AppImage...'
output_filename="${package_name}-${version}-${architecture}.AppImage"
output_path="$work_dir/$output_filename"

# ARCH names the TARGET architecture in uname style (x86_64/aarch64),
# not the package-style amd64/arm64 used in file names. appimagetool
# always embeds the runtime bundled with the tool itself, which is
# host-arch, so the pinned TARGET-arch type2 runtime is forced in with
# --runtime-file.
case "$architecture" in
	amd64)
		export ARCH='x86_64'
		runtime_sha256="$TYPE2_RUNTIME_SHA256_X86_64"
		;;
	arm64)
		export ARCH='aarch64'
		runtime_sha256="$TYPE2_RUNTIME_SHA256_AARCH64"
		;;
	*)
		echo "Unsupported target architecture for ARCH: $architecture" >&2
		exit 1
		;;
esac
echo "Using ARCH=$ARCH"

runtime_url='https://github.com/AppImage/type2-runtime/releases/download/'
runtime_url+="${TYPE2_RUNTIME_VERSION}/runtime-${ARCH}"
runtime_path="$work_dir/type2-runtime-${TYPE2_RUNTIME_VERSION}-${ARCH}"
fetch_pinned "$runtime_url" "$runtime_path" "$runtime_sha256" || exit 1

# appimagetool's option parser rejects a --runtime-file value it cannot
# convert from the locale charset ("Invalid byte sequence in conversion
# input"), e.g. a checkout under a non-ASCII directory; positional paths
# are passed through untouched. Run it from the work dir and name the
# runtime relatively - that file name is always ASCII.
run_appimagetool() {
	(cd "$work_dir" && "$appimagetool_path" --no-appstream \
		--runtime-file "./${runtime_path##*/}" "$@")
}

# Local build - no update information
if [[ ${GITHUB_ACTIONS:-} != 'true' ]]; then
	echo 'Running locally - building AppImage without update information'
	echo '(Update info and zsync files are only generated in GitHub Actions for releases)'

	if ! run_appimagetool "$appdir_path" "$output_path"; then
		echo "Failed to build AppImage using $appimagetool_path" >&2
		exit 1
	fi
	echo "AppImage built successfully: $output_path"
	echo '--- AppImage Build Finished ---'
	exit 0
fi

# GitHub Actions build - embed update information
echo 'Running in GitHub Actions - embedding update information for automatic updates...'

# Format: gh-releases-zsync|<username>|<repository>|<tag>|<filename-pattern>
update_info="gh-releases-zsync|presire|claude-desktop-suse|latest|claude-desktop-*-${architecture}.AppImage.zsync"
echo "Update info: $update_info"

# appimagetool writes the .zsync itself (no zsyncmake needed), into its
# current directory (the work dir, see run_appimagetool) under the
# AppImage's base name. Clear any earlier copy first so a stale file
# cannot pass the check below, then move it next to the AppImage where
# it has always been published.
zsync_cwd="$work_dir/${output_filename}.zsync"
zsync_file="${output_path}.zsync"
rm -f "$zsync_cwd" "$zsync_file"

if ! run_appimagetool --updateinformation "$update_info" \
	"$appdir_path" "$output_path"; then
	echo "Failed to build AppImage using $appimagetool_path" >&2
	exit 1
fi

echo "AppImage built successfully with embedded update info: $output_path"
if [[ -f $zsync_cwd && $zsync_cwd != "$zsync_file" ]]; then
	mv "$zsync_cwd" "$zsync_file" || exit 1
fi
# The embedded update info points installed AppImages at this file; a
# release without it breaks in-place updates, so its absence is fatal.
if [[ ! -f $zsync_file ]]; then
	echo "zsync file not found at $zsync_file" >&2
	exit 1
fi
echo "zsync file generated: $zsync_file"

echo '--- AppImage Build Finished ---'

exit 0
