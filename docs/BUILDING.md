[< Back to README](../README.md)

# Building from Source

## Prerequisites

- openSUSE Leap 15.5+ / openSUSE Tumbleweed / SUSE Linux Enterprise 15 SP5+
- Git, gcc-c++, make
- Python 3.8+
- Basic build tools (automatically installed by the script via zypper)

## Build Instructions

```bash
# Clone the repository
git clone https://github.com/presire/claude-desktop-suse.git
cd claude-desktop-suse

# Build RPM package (default)
./build.sh

# Or specify a format explicitly:
./build.sh --build rpm       # openSUSE/SLE .rpm package
./build.sh --build appimage  # Distribution-agnostic AppImage

# Build with custom options
./build.sh --build rpm --clean no   # Keep intermediate files
./build.sh --prefix /usr/lib64      # Custom install prefix

# Build with dark-mode tray icons (white icons for dark panels)
./build.sh --dark
./build.sh --build appimage --dark  # Combine with other options

# Build using a locally downloaded installer
# (useful when the bundled download URL is outdated)
./build.sh --exe /path/to/Claude-Setup.exe
```

The build script defaults to RPM format for openSUSE/SLE:
| Distribution | Default Format | Package Manager |
|--------------|----------------|-----------------|
| openSUSE, SLE | `.rpm` | zypper |
| Other | `.AppImage` | - |

## Installing the Built Package

### For .rpm packages (openSUSE/SLE)

```bash
sudo zypper install ./claude-desktop-VERSION-ARCH.rpm
# Or: sudo rpm -i ./claude-desktop-VERSION-ARCH.rpm
```

### For AppImages

```bash
# Make executable
chmod +x ./claude-desktop-*.AppImage

# Run directly
./claude-desktop-*.AppImage

# Or integrate with your system using Gear Lever
```

**Note:** AppImage login requires proper desktop integration. Use [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) or manually install the provided `.desktop` file to `~/.local/share/applications/`.

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Downloads the official Windows installer (or uses a local copy via `--exe`)
2. Extracts application resources from the nupkg
3. Replaces Windows-specific native modules with Linux-compatible implementations
4. Applies Linux-specific patches (frame fixes, tray integration, Cowork mode)
5. Repackages as one of:
   - **RPM package (.rpm)**: For openSUSE, SUSE Linux Enterprise
   - **AppImage**: Portable, distribution-agnostic executable

### Build Process

The build script (`build.sh`) handles:
- Dependency checking and installation (via zypper)
- Dynamic version resolution from official release server
- Resource extraction from Windows installer
- Icon processing for Linux desktop standards
- Native module replacement (claude-native stub, node-pty)
- 10 application patches for Linux compatibility
- Package generation based on selected format

### Manual Updates

If you need to build with a specific version:

1. **Use a local installer**: Download the latest installer from [claude.ai/download](https://claude.ai/download) and build with:
   ```bash
   ./build.sh --exe /path/to/Claude-Setup.exe
   ```
