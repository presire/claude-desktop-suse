#!/bin/bash
set -e

# Arguments passed from the main script
VERSION="$1"
ARCHITECTURE="$2"
WORK_DIR="$3" # The top-level build directory (e.g., ./build)
APP_STAGING_DIR="$4" # Directory containing the prepared app files (e.g., ./build/electron-app)
PACKAGE_NAME="$5"
MAINTAINER="$6"
DESCRIPTION="$7"

echo "--- Starting RPM Package Build ---"
echo "Version: $VERSION"
echo "Architecture: $ARCHITECTURE"
echo "Work Directory: $WORK_DIR"
echo "App Staging Directory: $APP_STAGING_DIR"
echo "Package Name: $PACKAGE_NAME"

# RPMビルドのディレクトリ構造をセットアップ
RPMBUILD_DIR="$HOME/rpmbuild"
echo "Setting up RPM build directory structure at $RPMBUILD_DIR..."
mkdir -p "$RPMBUILD_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# ファイルを準備するためのステージングディレクトリ（BUILDROOTではない）
STAGING_DIR="$RPMBUILD_DIR/BUILD/${PACKAGE_NAME}-${VERSION}"
INSTALL_DIR="$STAGING_DIR/opt/$PACKAGE_NAME"

# Clean previous staging if it exists
rm -rf "$STAGING_DIR"

# Create installation directory structure in staging
echo "Creating installation structure in $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$STAGING_DIR/usr/share/applications"
mkdir -p "$STAGING_DIR/usr/share/icons"
mkdir -p "$STAGING_DIR/usr/bin"

# --- Icon Installation ---
echo "🎨 Installing icons..."
# Map icon sizes to their corresponding extracted files (relative to WORK_DIR)
declare -A icon_files=(
    ["16"]="claude_13_16x16x32.png"
    ["24"]="claude_11_24x24x32.png"
    ["32"]="claude_10_32x32x32.png"
    ["48"]="claude_8_48x48x32.png"
    ["64"]="claude_7_64x64x32.png"
    ["256"]="claude_6_256x256x32.png"
)

for size in 16 24 32 48 64 256; do
    icon_dir="$STAGING_DIR/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    icon_source_path="$WORK_DIR/${icon_files[$size]}"
    if [ -f "$icon_source_path" ]; then
        echo "Installing ${size}x${size} icon from $icon_source_path..."
        install -Dm 644 "$icon_source_path" "$icon_dir/claude-desktop.png"
    else
        echo "Warning: Missing ${size}x${size} icon at $icon_source_path"
    fi
done
echo "✓ Icons installed"

# --- Copy Application Files ---
echo "📦 Copying application files from $APP_STAGING_DIR..."

# Copy local electron if it was packaged (check if node_modules exists in staging)
if [ -d "$APP_STAGING_DIR/node_modules" ]; then
    echo "Copying packaged electron..."
    cp -r "$APP_STAGING_DIR/node_modules" "$INSTALL_DIR/"
fi

# Install app.asar in Electron's resources directory where process.resourcesPath points
RESOURCES_DIR="$INSTALL_DIR/node_modules/electron/dist/resources"
mkdir -p "$RESOURCES_DIR"
cp "$APP_STAGING_DIR/app.asar" "$RESOURCES_DIR/"
cp -r "$APP_STAGING_DIR/app.asar.unpacked" "$RESOURCES_DIR/"
echo "✓ Application files copied to Electron resources directory"

# --- Create Desktop Entry ---
echo "📝 Creating desktop entry..."
cat > "$STAGING_DIR/usr/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=/usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF
echo "✓ Desktop entry created"

# --- Create Launcher Script ---
echo "🚀 Creating launcher script..."
cat > "$STAGING_DIR/usr/bin/claude-desktop" << 'EOF'
#!/bin/bash
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-opensuse"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/launcher.log"
echo "--- Claude Desktop Launcher Start ---" > "$LOG_FILE"
echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "Arguments: $@" >> "$LOG_FILE"

export ELECTRON_FORCE_IS_PACKAGED=true

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ ! -z "$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
  echo "Wayland detected" >> "$LOG_FILE"
fi

# Check for display issues and set compatibility mode if needed
if [ "$IS_WAYLAND" = true ]; then
  echo "Setting Wayland compatibility mode..." >> "$LOG_FILE"
  # Use native Wayland backend with GlobalShortcuts Portal support
  export ELECTRON_OZONE_PLATFORM_HINT=wayland
  # Keep GPU acceleration enabled for better performance
  echo "Wayland compatibility mode enabled (using native Wayland backend)" >> "$LOG_FILE"
elif [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
  echo "No display detected (TTY session) - cannot start graphical application" >> "$LOG_FILE"
  # No graphical environment detected; display error message in TTY session
  echo "Error: Claude Desktop requires a graphical desktop environment." >&2
  echo "Please run from within an X11 or Wayland session, not from a TTY." >&2
  exit 1
fi

# Determine Electron executable path - local installation in /opt
LOCAL_ELECTRON_PATH="/opt/claude-desktop/node_modules/electron/dist/electron"
if [ -f "$LOCAL_ELECTRON_PATH" ]; then
    ELECTRON_EXEC="$LOCAL_ELECTRON_PATH"
    echo "Using local Electron: $ELECTRON_EXEC" >> "$LOG_FILE"
else
    echo "Error: Electron executable not found at $LOCAL_ELECTRON_PATH" >> "$LOG_FILE"
    # Display error to the user if zenity or kdialog is available
    if command -v zenity &> /dev/null; then
        zenity --error --text="Claude Desktop cannot start because the Electron framework is missing. Please reinstall Claude Desktop."
    elif command -v kdialog &> /dev/null; then
        kdialog --error "Claude Desktop cannot start because the Electron framework is missing. Please reinstall Claude Desktop."
    fi
    exit 1
fi

# Base command arguments array, starting with app path
# App is now in Electron's resources directory
APP_PATH="/opt/claude-desktop/node_modules/electron/dist/resources/app.asar"
ELECTRON_ARGS=("$APP_PATH")

# Add compatibility flags
if [ "$IS_WAYLAND" = true ]; then
  echo "Adding compatibility flags for Wayland session" >> "$LOG_FILE"
  ELECTRON_ARGS+=("--no-sandbox")
  # Enable Wayland features for Electron 37+
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations,GlobalShortcutsPortal")
  ELECTRON_ARGS+=("--ozone-platform=wayland")
  ELECTRON_ARGS+=("--enable-wayland-ime")
  ELECTRON_ARGS+=("--wayland-text-input-version=3")
  echo "Enabled native Wayland support with GlobalShortcuts Portal" >> "$LOG_FILE"
else
  # X11 session - ensure native window decorations
  echo "X11 session detected, enabling native window decorations" >> "$LOG_FILE"
fi

# Force disable custom titlebar for all sessions
ELECTRON_ARGS+=("--disable-features=CustomTitlebar")
# Try to force native frame
export ELECTRON_USE_SYSTEM_TITLE_BAR=1

# Change to the application directory
APP_DIR="/opt/claude-desktop"
echo "Changing directory to $APP_DIR" >> "$LOG_FILE"
cd "$APP_DIR" || { echo "Failed to cd to $APP_DIR" >> "$LOG_FILE"; exit 1; }

# Execute Electron with app path, flags, and script arguments
# Redirect stdout and stderr to the log file
FINAL_CMD="\"$ELECTRON_EXEC\" \"${ELECTRON_ARGS[@]}\" \"$@\""
echo "Executing: $FINAL_CMD" >> "$LOG_FILE"
"$ELECTRON_EXEC" "${ELECTRON_ARGS[@]}" "$@" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?
echo "Electron exited with code: $EXIT_CODE" >> "$LOG_FILE"
echo "--- Claude Desktop Launcher End ---" >> "$LOG_FILE"
exit $EXIT_CODE
EOF
chmod +x "$STAGING_DIR/usr/bin/claude-desktop"
echo "✓ Launcher script created"

# --- Create SPEC File ---
echo "📄 Creating SPEC file..."
SPEC_FILE="$RPMBUILD_DIR/SPECS/${PACKAGE_NAME}.spec"

# Determine dependencies - Electron is packaged locally
REQUIRES="nodejs npm p7zip"

cat > "$SPEC_FILE" << EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        $DESCRIPTION

License:        Proprietary
URL:            https://claude.ai
BuildArch:      $ARCHITECTURE

# Dependencies
Requires:       $REQUIRES

%description
Claude is an AI assistant from Anthropic.
This package provides the desktop interface for Claude.

Supported on openSUSE and SUSE Linux Enterprise distributions.
Requires: nodejs (>= 12.0.0), npm

%prep
# No prep needed - files are already prepared

%build
# No build needed - files are already built

%install
# Copy all prepared files from staging directory to buildroot
rm -rf %{buildroot}
mkdir -p %{buildroot}

# Copy all directories from our staging area
cp -a $RPMBUILD_DIR/BUILD/%{name}-%{version}/* %{buildroot}/

%files
# Application files in /opt
/opt/%{name}/*

# Launcher script
%attr(755, root, root) /usr/bin/claude-desktop

# Desktop entry
/usr/share/applications/claude-desktop.desktop

# Icons
/usr/share/icons/hicolor/*/apps/claude-desktop.png

%post
# Update desktop database for MIME types
echo "Updating desktop database..."
update-desktop-database /usr/share/applications &> /dev/null || true

# Set correct permissions for chrome-sandbox
echo "Setting chrome-sandbox permissions..."
SANDBOX_PATH="/opt/%{name}/node_modules/electron/dist/chrome-sandbox"

if [ -f "\$SANDBOX_PATH" ]; then
    echo "Found chrome-sandbox at: \$SANDBOX_PATH"
    chown root:root "\$SANDBOX_PATH" || echo "Warning: Failed to chown chrome-sandbox"
    chmod 4755 "\$SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"
    echo "Permissions set for \$SANDBOX_PATH"
else
    echo "Warning: chrome-sandbox binary not found at \$SANDBOX_PATH. Sandbox may not function correctly."
fi

exit 0

%postun
# Clean up desktop database after uninstall
if [ \$1 -eq 0 ]; then
    update-desktop-database /usr/share/applications &> /dev/null || true
fi

%changelog
* $(LC_ALL=C date '+%a %b %d %Y') $MAINTAINER - $VERSION-1
- Initial RPM package for openSUSE

EOF

echo "✓ SPEC file created at $SPEC_FILE"

# --- Build RPM Package ---
echo "📦 Building RPM package..."

# Build the RPM using rpmbuild
if ! rpmbuild -bb "$SPEC_FILE"; then
    echo "❌ Failed to build RPM package"
    exit 1
fi

# Find the generated RPM
RPM_FILE=$(find "$RPMBUILD_DIR/RPMS/$ARCHITECTURE" -name "${PACKAGE_NAME}-${VERSION}-*.${ARCHITECTURE}.rpm" | head -n 1)

if [ -z "$RPM_FILE" ] || [ ! -f "$RPM_FILE" ]; then
    echo "❌ RPM file not found after build"
    exit 1
fi

echo "✓ RPM package built successfully: $RPM_FILE"
echo "--- RPM Package Build Finished ---"

exit 0
