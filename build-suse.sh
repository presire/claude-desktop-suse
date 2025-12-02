#!/bin/bash
set -euo pipefail

# --- Architecture Detection ---
echo -e "\033[1;36m--- Architecture Detection ---\033[0m"
echo "⚙️ Detecting system architecture..."
# openSUSEではrpmのマクロまたはuname -mを使用
HOST_ARCH=$(uname -m)
echo "Detected host architecture: $HOST_ARCH"
cat /etc/os-release && uname -m

# Set variables based on detected architecture
# RPMアーキテクチャに変換
if [ "$HOST_ARCH" = "x86_64" ]; then
    CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"
    ARCHITECTURE="x86_64"  # RPMではx86_64を使用
    CLAUDE_EXE_FILENAME="Claude-Setup-x64.exe"
    echo "Configured for x86_64 build."
elif [ "$HOST_ARCH" = "aarch64" ]; then
    CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-arm64/Claude-Setup-arm64.exe"
    ARCHITECTURE="aarch64"  # RPMではaarch64を使用
    CLAUDE_EXE_FILENAME="Claude-Setup-arm64.exe"
    echo "Configured for aarch64 build."
else
    echo "❌ Unsupported architecture: $HOST_ARCH. This script currently supports x86_64 and aarch64."
    exit 1
fi
echo "Target Architecture (detected): $ARCHITECTURE"
echo -e "\033[1;36m--- End Architecture Detection ---\033[0m"

# openSUSEディストリビューションの確認
if [ ! -f "/etc/SUSE-brand" ] && [ ! -f "/etc/SuSE-release" ]; then
    # /etc/os-releaseでもチェック
    if ! grep -qi "opensuse\|suse" /etc/os-release 2>/dev/null; then
        echo "❌ This script requires an openSUSE Linux distribution"
        exit 1
    fi
fi

if [ "$EUID" -eq 0 ]; then
   echo "❌ This script should not be run using sudo or as the root user."
   echo "   It will prompt for sudo password when needed for specific actions."
   echo "   Please run as a normal user."
   exit 1
fi

ORIGINAL_USER=$(whoami)
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
if [ -z "$ORIGINAL_HOME" ]; then
    echo "❌ Could not determine home directory for user $ORIGINAL_USER."
    exit 1
fi
echo "Running as user: $ORIGINAL_USER (Home: $ORIGINAL_HOME)"

# Check for NVM and source it if found - this may provide a Node.js 20+ version
if [ -d "$ORIGINAL_HOME/.nvm" ]; then
    echo "Found NVM installation for user $ORIGINAL_USER, checking for Node.js 20+..."
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # Source NVM script to set up NVM environment variables temporarily
        # shellcheck disable=SC1091
        \. "$NVM_DIR/nvm.sh" # This loads nvm
        # Initialize and find the path to the currently active or default Node version's bin directory
        NODE_BIN_PATH=""
        NODE_BIN_PATH=$(nvm which current | xargs dirname 2>/dev/null || find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

        if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
            echo "Adding NVM Node bin path to PATH: $NODE_BIN_PATH"
            export PATH="$NODE_BIN_PATH:$PATH"
        else
            echo "Warning: Could not determine NVM Node bin path."
        fi
    else
        echo "Warning: nvm.sh script not found or not sourceable."
    fi
fi # End of if [ -d "$ORIGINAL_HOME/.nvm" ] check

echo "System Information:"
echo "Distribution: $(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)"
if [ -f "/etc/SuSE-release" ]; then
    echo "SUSE version: $(head -n 1 /etc/SuSE-release)"
fi
echo "Target Architecture: $ARCHITECTURE" 
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
PROJECT_ROOT="$(pwd)" 
WORK_DIR="$PROJECT_ROOT/build" 
APP_STAGING_DIR="$WORK_DIR/electron-app" 
VERSION="" 

echo -e "\033[1;36m--- Argument Parsing ---\033[0m"
BUILD_FORMAT="rpm"  # デフォルトをrpmに変更
CLEANUP_ACTION="yes"  
TEST_FLAGS_MODE=false

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -b|--build)
        if [[ -z "$2" || "$2" == -* ]]; then              
            echo "❌ Error: Argument for $1 is missing" >&2
            exit 1
        fi
        BUILD_FORMAT="$2"
        shift 2 ;; # Shift past flag and value
        -c|--clean)
        if [[ -z "$2" || "$2" == -* ]]; then              
            echo "❌ Error: Argument for $1 is missing" >&2
            exit 1
        fi
        CLEANUP_ACTION="$2"
        shift 2 ;; # Shift past flag and value
        --test-flags)
        TEST_FLAGS_MODE=true
        shift # past argument
        ;;
        -h|--help)
        echo "Usage: $0 [--build rpm] [--clean yes|no] [--test-flags]"
        echo "  --build: Specify the build format (rpm). Default: rpm"
        echo "  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes"
        echo "  --test-flags: Parse flags, print results, and exit without building."
        exit 0
        ;;
        *)            
        echo "❌ Unknown option: $1" >&2
        echo "Use -h or --help for usage information." >&2
        exit 1
        ;;
    esac
done

# Validate arguments
BUILD_FORMAT=$(echo "$BUILD_FORMAT" | tr '[:upper:]' '[:lower:]') 
CLEANUP_ACTION=$(echo "$CLEANUP_ACTION" | tr '[:upper:]' '[:lower:]')

if [[ "$BUILD_FORMAT" != "rpm" ]]; then
    echo "❌ Invalid build format specified: '$BUILD_FORMAT'. Must be 'rpm'." >&2
    exit 1
fi
if [[ "$CLEANUP_ACTION" != "yes" && "$CLEANUP_ACTION" != "no" ]]; then
    echo "❌ Invalid cleanup option specified: '$CLEANUP_ACTION'. Must be 'yes' or 'no'." >&2
    exit 1
fi

echo "Selected build format: $BUILD_FORMAT"
echo "Cleanup intermediate files: $CLEANUP_ACTION"

PERFORM_CLEANUP=false
if [ "$CLEANUP_ACTION" = "yes" ]; then
    PERFORM_CLEANUP=true
fi
echo -e "\033[1;36m--- End Argument Parsing ---\033[0m"

# Exit early if --test-flags mode is enabled
if [ "$TEST_FLAGS_MODE" = true ]; then
    echo "--- Test Flags Mode Enabled ---"
    echo "Build Format: $BUILD_FORMAT"
    echo "Clean Action: $CLEANUP_ACTION"
    echo "Exiting without build."
    exit 0
fi

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

echo "Checking dependencies..."
DEPS_TO_INSTALL=""
# openSUSE用の依存パッケージ名
COMMON_DEPS="7z wget wrestool icotool convert"
RPM_DEPS="rpmbuild rpmdevtools"

ALL_DEPS_TO_CHECK="$COMMON_DEPS $RPM_DEPS"

for cmd in $ALL_DEPS_TO_CHECK; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "7z") DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip" ;;
            "wget") DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget" ;;
            "wrestool"|"icotool") DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils" ;;
            "convert") DEPS_TO_INSTALL="$DEPS_TO_INSTALL ImageMagick" ;;
            "rpmbuild") DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpm-build" ;;
            "rpmdevtools") DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpmdevtools" ;;
        esac
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    echo "System dependencies needed: $DEPS_TO_INSTALL"
    echo "Attempting to install using sudo..."
    if ! sudo -v; then
        echo "❌ Failed to validate sudo credentials. Please ensure you can run sudo."
        exit 1
    fi
    # openSUSEではzypperを使用
    if ! sudo zypper refresh; then
        echo "❌ Failed to run 'sudo zypper refresh'."
        exit 1
    fi
    # -y オプションで自動承認、--no-recommends で推奨パッケージをスキップ
    if ! sudo zypper install -y --no-recommends $DEPS_TO_INSTALL; then
        echo "❌ Failed to install dependencies."
        exit 1
    fi
fi

# Node.jsとnpmのバージョン確認
echo "Checking Node.js and npm versions..."
if ! check_command "node"; then
    echo "❌ Node.js is not installed."
    echo "Please install Node.js 20 or higher (e.g., using NVM or system packages)."
    exit 1
fi

if ! check_command "npm"; then
    echo "❌ npm is not installed."
    echo "Please install npm (typically comes with Node.js)."
    exit 1
fi

NODE_VERSION=$(node --version | cut -d'v' -f2)
NODE_MAJOR_VERSION=$(echo "$NODE_VERSION" | cut -d'.' -f1)
echo "Node.js version: $NODE_VERSION"
if [ "$NODE_MAJOR_VERSION" -lt 20 ]; then
    echo "❌ Node.js version 20 or higher is required. Current version: $NODE_VERSION"
    echo "   Consider using NVM to install a newer version: https://github.com/nvm-sh/nvm"
    exit 1
fi
echo "✓ Node.js version check passed"

NPM_VERSION=$(npm --version)
echo "npm version: $NPM_VERSION"
echo "✓ npm found"

echo "All dependencies are available!"

# Work directory setup
echo -e "\033[1;36m--- Work Directory Setup ---\033[0m"
if [ -d "$WORK_DIR" ]; then
    echo "🧹 Cleaning existing work directory: $WORK_DIR"
    rm -rf "$WORK_DIR"
fi
mkdir -p "$WORK_DIR"
echo "✓ Work directory created: $WORK_DIR"

# Download and extract Claude
echo -e "\033[1;36m--- Download Claude Windows Installer ---\033[0m"
CLAUDE_DOWNLOAD_PATH="$WORK_DIR/$CLAUDE_EXE_FILENAME"

if [ ! -f "$CLAUDE_DOWNLOAD_PATH" ]; then
    echo "📥 Downloading Claude installer from $CLAUDE_DOWNLOAD_URL..."
    if ! wget -O "$CLAUDE_DOWNLOAD_PATH" "$CLAUDE_DOWNLOAD_URL"; then
        echo "❌ Failed to download Claude installer"
        exit 1
    fi
    echo "✓ Claude installer downloaded"
else
    echo "✓ Claude installer already exists at $CLAUDE_DOWNLOAD_PATH"
fi

# Extract installer
echo -e "\033[1;36m--- Extract Claude Installer ---\033[0m"
CLAUDE_EXTRACT_DIR="$WORK_DIR/claude-extracted"
mkdir -p "$CLAUDE_EXTRACT_DIR"
echo "📦 Extracting Claude installer..."

# openSUSEでは7zコマンドを使用（p7zipパッケージ）
if ! 7z x "$CLAUDE_DOWNLOAD_PATH" -o"$CLAUDE_EXTRACT_DIR" -y; then
    echo "❌ Failed to extract Claude installer"
    exit 1
fi
echo "✓ Claude installer extracted to $CLAUDE_EXTRACT_DIR"

# Extract app.asar from nupkg
echo "📦 Extracting app.asar from nupkg file..."
echo "🔍 Searching for .nupkg files in $CLAUDE_EXTRACT_DIR..."
echo "Directory contents:"
ls -la "$CLAUDE_EXTRACT_DIR" || echo "Failed to list directory"

# Try different search patterns
echo "Searching for any .nupkg files..."
find "$CLAUDE_EXTRACT_DIR" -name "*.nupkg" -type f

echo "Searching specifically for claude-*.nupkg..."
NUPKG_FILE=$(find "$CLAUDE_EXTRACT_DIR" -name "claude-*.nupkg" -type f | head -n 1)

if [ -z "$NUPKG_FILE" ]; then
    echo "❌ Cannot find claude-*.nupkg file"
    echo "Trying broader search for any .nupkg file..."
    NUPKG_FILE=$(find "$CLAUDE_EXTRACT_DIR" -name "*.nupkg" -type f | head -n 1)
fi

if [ -z "$NUPKG_FILE" ] || [ ! -f "$NUPKG_FILE" ]; then
    echo "❌ Cannot find .nupkg file in extracted installer"
    echo "Please check the directory structure manually:"
    echo "  ls -la $CLAUDE_EXTRACT_DIR"
    exit 1
fi

echo "✓ Found nupkg file: $NUPKG_FILE"

NUPKG_EXTRACT_DIR="$WORK_DIR/nupkg-extracted"
mkdir -p "$NUPKG_EXTRACT_DIR"

if ! 7z x "$NUPKG_FILE" -o"$NUPKG_EXTRACT_DIR" -y; then
    echo "❌ Failed to extract .nupkg file"
    exit 1
fi
echo "✓ .nupkg file extracted"

# Find app.asar
ASAR_FILE=$(find "$NUPKG_EXTRACT_DIR" -name "app.asar" | head -n 1)
if [ -z "$ASAR_FILE" ] || [ ! -f "$ASAR_FILE" ]; then
    echo "❌ Cannot find app.asar in extracted .nupkg"
    exit 1
fi
echo "✓ Found app.asar at: $ASAR_FILE"

# Determine version from nupkg filename
echo -e "\033[1;36m--- Version Detection ---\033[0m"
NUPKG_BASENAME=$(basename "$NUPKG_FILE")
echo "Extracting version from: $NUPKG_BASENAME"

# Extract version - support both "claude-X.Y.Z" and "AnthropicClaude-X.Y.Z" formats
# Pattern explanation: Match any text, then a hyphen, then capture version numbers (X.Y.Z format),
# then optionally a hyphen and more text, ending with .nupkg
VERSION=$(echo "$NUPKG_BASENAME" | sed -n 's/^.*[Cc]laude-\([0-9][0-9.]*\).*\.nupkg$/\1/p')

if [ -z "$VERSION" ]; then
    echo "❌ Failed to extract version from nupkg filename: $NUPKG_BASENAME"
    echo "Attempting alternative version extraction method..."
    # Try a more generic pattern: anything-VERSION-anything.nupkg
    VERSION=$(echo "$NUPKG_BASENAME" | sed -n 's/^.*-\([0-9][0-9.]*\)-.*\.nupkg$/\1/p')
fi

if [ -z "$VERSION" ]; then
    echo "❌ Could not extract version from nupkg filename: $NUPKG_BASENAME"
    echo "Please report this filename format to the maintainers."
    exit 1
fi

echo "✓ Detected version: $VERSION"

# Prepare application staging directory
echo -e "\033[1;36m--- Application Staging ---\033[0m"
mkdir -p "$APP_STAGING_DIR"
echo "📁 Staging directory created: $APP_STAGING_DIR"

# Copy app.asar and its unpacked resources
cp "$ASAR_FILE" "$APP_STAGING_DIR/"

# Check for app.asar.unpacked directory
ASAR_UNPACKED_DIR="${ASAR_FILE}.unpacked"
if [ -d "$ASAR_UNPACKED_DIR" ]; then
    echo "📁 Copying app.asar.unpacked directory..."
    cp -r "$ASAR_UNPACKED_DIR" "$APP_STAGING_DIR/"
else
    echo "⚠️  Warning: app.asar.unpacked directory not found. App may not function correctly if native modules are required."
fi

# Install Electron locally for packaging
echo -e "\033[1;36m--- Electron Installation ---\033[0m"
echo "📦 Installing Electron locally for packaging..."

# Create a minimal package.json for Electron installation in a temp location
TEMP_ELECTRON_DIR="$WORK_DIR/temp-electron-install"
mkdir -p "$TEMP_ELECTRON_DIR"
cd "$TEMP_ELECTRON_DIR"

cat > package.json << 'EOF'
{
  "name": "temp-electron-install",
  "version": "1.0.0",
  "private": true
}
EOF

# Install Electron 37 (latest stable that supports the features we need)
echo "Installing electron@37..."
if ! npm install --save electron@37 --foreground-scripts; then
    echo "❌ Failed to install Electron"
    cd "$PROJECT_ROOT"
    exit 1
fi

ELECTRON_DIR_NAME="electron"
CHOSEN_ELECTRON_MODULE_PATH="$TEMP_ELECTRON_DIR/node_modules/$ELECTRON_DIR_NAME"

if [ ! -d "$CHOSEN_ELECTRON_MODULE_PATH" ]; then
    echo "❌ Electron module not found at $CHOSEN_ELECTRON_MODULE_PATH after installation"
    cd "$PROJECT_ROOT"
    exit 1
fi

echo "✓ Electron installed at $CHOSEN_ELECTRON_MODULE_PATH"
cd "$PROJECT_ROOT"

# Copy Electron to staging directory
echo "Staging Electron in application directory..."
mkdir -p "$APP_STAGING_DIR/node_modules"
echo "Copying from $CHOSEN_ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
cp -a "$CHOSEN_ELECTRON_MODULE_PATH" "$APP_STAGING_DIR/node_modules/" 

STAGED_ELECTRON_BIN="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/electron"
if [ -f "$STAGED_ELECTRON_BIN" ]; then
    echo "Setting executable permission on staged Electron binary: $STAGED_ELECTRON_BIN"
    chmod +x "$STAGED_ELECTRON_BIN"
else
    echo "Warning: Staged Electron binary not found at expected path: $STAGED_ELECTRON_BIN"
fi

# Ensure Electron locale files are available
ELECTRON_RESOURCES_SRC="$CHOSEN_ELECTRON_MODULE_PATH/dist/resources"
ELECTRON_RESOURCES_DEST="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/resources"
if [ -d "$ELECTRON_RESOURCES_SRC" ]; then
    echo "Copying Electron locale resources..."
    mkdir -p "$ELECTRON_RESOURCES_DEST"
    cp -a "$ELECTRON_RESOURCES_SRC"/* "$ELECTRON_RESOURCES_DEST/"
    echo "✓ Electron locale resources copied"
else
    echo "⚠️  Warning: Electron resources directory not found at $ELECTRON_RESOURCES_SRC"
fi

echo -e "\033[1;36m--- Icon Processing ---\033[0m"
# Extract application icons from Windows executable
# Note: claude.exe is in the nupkg extraction directory, not the initial exe extraction directory
cd "$NUPKG_EXTRACT_DIR"
EXE_RELATIVE_PATH="lib/net45/claude.exe"
if [ ! -f "$EXE_RELATIVE_PATH" ]; then
    echo "❌ Cannot find claude.exe at expected path within nupkg extraction dir: $NUPKG_EXTRACT_DIR/$EXE_RELATIVE_PATH"
    echo "Searching for claude.exe in extraction directory..."
    FOUND_EXE=$(find "$NUPKG_EXTRACT_DIR" -name "claude.exe" -o -name "Claude.exe" | head -n 1)
    if [ -n "$FOUND_EXE" ]; then
        echo "✓ Found exe at: $FOUND_EXE"
        cd "$(dirname "$FOUND_EXE")"
        EXE_RELATIVE_PATH="$(basename "$FOUND_EXE")"
    else
        echo "❌ Cannot find claude.exe anywhere in nupkg extraction"
        cd "$PROJECT_ROOT" && exit 1
    fi
fi
echo "🎨 Extracting application icons from $EXE_RELATIVE_PATH..."
if ! wrestool -x -t 14 "$EXE_RELATIVE_PATH" -o claude.ico; then
    echo "❌ Failed to extract icons from exe"
    cd "$PROJECT_ROOT" && exit 1
fi

if ! icotool -x claude.ico; then
    echo "❌ Failed to convert icons"
    cd "$PROJECT_ROOT" && exit 1
fi
cp claude_*.png "$WORK_DIR/"
echo "✓ Application icons extracted and copied to $WORK_DIR"

cd "$PROJECT_ROOT"

# Copy tray icon files to Electron resources directory for runtime access
# Note: Use NUPKG_EXTRACT_DIR since that's where the actual app files are
CLAUDE_LOCALE_SRC="$NUPKG_EXTRACT_DIR/lib/net45/resources"
echo "🖼️  Copying tray icon files to Electron resources directory..."
if [ -d "$CLAUDE_LOCALE_SRC" ]; then
    # Tray icons must be in filesystem (not inside asar) for Electron Tray API to access them
    cp "$CLAUDE_LOCALE_SRC/Tray"* "$ELECTRON_RESOURCES_DEST/" 2>/dev/null || echo "⚠️  Warning: No tray icon files found at $CLAUDE_LOCALE_SRC/Tray*"
    echo "✓ Tray icon files copied to Electron resources directory"
else
    echo "⚠️  Warning: Claude resources directory not found at $CLAUDE_LOCALE_SRC"
fi
echo -e "\033[1;36m--- End Icon Processing ---\033[0m"

# Copy Claude locale JSON files to Electron resources directory where they're expected
echo "Copying Claude locale JSON files to Electron resources directory..."
if [ -d "$CLAUDE_LOCALE_SRC" ]; then
    # Copy Claude's locale JSON files to the Electron resources directory
    cp "$CLAUDE_LOCALE_SRC/"*-*.json "$ELECTRON_RESOURCES_DEST/" 2>/dev/null || echo "⚠️  Warning: No locale JSON files found"
    echo "✓ Claude locale JSON files copied to Electron resources directory"
else
    echo "⚠️  Warning: Claude locale source directory not found at $CLAUDE_LOCALE_SRC"
fi

echo "✓ app.asar processed and staged in $APP_STAGING_DIR"

cd "$PROJECT_ROOT"

echo -e "\033[1;36m--- Call Packaging Script ---\033[0m"
FINAL_OUTPUT_PATH=""

if [ "$BUILD_FORMAT" = "rpm" ]; then
    echo "📦 Calling RPM packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-rpm-package.sh
    if ! scripts/build-rpm-package.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" \
        "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
        echo "❌ RPM packaging script failed."
        exit 1
    fi
    
    # Find the generated RPM file
    RPM_FILE=$(find "$HOME/rpmbuild/RPMS/$ARCHITECTURE" -name "${PACKAGE_NAME}-${VERSION}-*.${ARCHITECTURE}.rpm" 2>/dev/null | head -n 1)
    
    echo "✓ RPM Build complete!"
    if [ -n "$RPM_FILE" ] && [ -f "$RPM_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$RPM_FILE")"
        mv "$RPM_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"
    else
        echo "Warning: Could not determine final .rpm file path for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi
fi

echo -e "\033[1;36m--- Cleanup ---\033[0m"
if [ "$PERFORM_CLEANUP" = true ]; then
    echo "🧹 Cleaning up intermediate build files in $WORK_DIR..."
    if rm -rf "$WORK_DIR"; then
        echo "✓ Cleanup complete ($WORK_DIR removed)."
    else
        echo "⚠️ Cleanup command (rm -rf $WORK_DIR) failed."
    fi
else
    echo "Skipping cleanup of intermediate build files in $WORK_DIR."
fi

echo "✅ Build process finished."

echo -e "\n\033[1;34m====== Next Steps ======\033[0m"
if [ "$BUILD_FORMAT" = "rpm" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "📦 To install the RPM package, run:"
        echo -e "   \033[1;32msudo zypper install $FINAL_OUTPUT_PATH\033[0m"
        echo -e "   (or \`sudo rpm -ivh $FINAL_OUTPUT_PATH\`)"
    else
        echo -e "⚠️ RPM package file not found. Cannot provide installation instructions."
    fi
fi
echo -e "\033[1;34m======================\033[0m"

exit 0
