# Claude Desktop for openSUSE/SLE Linux

This is a fork of [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) adapted for openSUSE and SUSE Linux Enterprise distributions.

This project provides build scripts to run Claude Desktop natively on openSUSE/SLE Linux systems. It repackages the official Windows application, producing `.rpm` packages.

**Note:** This is an unofficial build script. For official support, please visit [Anthropic's website](https://www.anthropic.com). For issues with the build script or Linux implementation, please [open an issue](https://github.com/presire/claude-desktop-suse/issues) in this repository.

## Features

- **Native Linux Support**: Run Claude Desktop without virtualization or Wine
- **MCP Support**: Full Model Context Protocol integration
  Configuration file location: `~/.config/Claude/claude_desktop_config.json`
- **System Integration**:
  - X11 Global hotkey support (Ctrl+Alt+Space)
  - System tray integration
  - Desktop environment integration
- **Customizable Install Path**: Use `--prefix` to specify installation directory

### Screenshots

![Claude Desktop running on Linux](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

![Global hotkey popup](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

![System tray menu on KDE](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

## Installation

### Building from Source

#### Prerequisites

Install the required packages before building:

```bash
sudo zypper install git gcc-c++ make
```

| Package | Purpose |
|---------|---------|
| `git` | Clone the repository |
| `gcc-c++` | Compile node-pty native module (for Claude Code terminal features) |
| `make` | Build system for native compilation |

**Note:** Building the node-pty native module (for Claude Code terminal features) requires **Python 3.8 or later**. If your system's default Python is older (e.g., Python 3.6 on openSUSE Leap 15.x), node-pty compilation will fail. Claude Desktop itself will still build and run, but Claude Code terminal features will not be available.

**RPM builds** (`./build.sh`, default):

The build script automatically installs all remaining dependencies via zypper:

| Auto-installed Package | Purpose |
|----------------------|---------|
| `p7zip` | Extract Windows installer (7z format) |
| `wget` | Download Claude Desktop installer and Node.js |
| `icoutils` | Extract icons from Windows executable (`wrestool`, `icotool`) |
| `ImageMagick` | Process tray icons for Linux visibility |
| `rpm-build` | Build RPM packages (`rpmbuild` command) |

**AppImage builds** (`./build.sh --build appimage`):

Additionally install `libfuse2` before building:

```bash
sudo zypper install libfuse2
```

| Package | Purpose |
|---------|---------|
| `libfuse2` | Required by appimagetool to generate AppImage files |

The common dependencies above (`p7zip`, `wget`, `icoutils`, `ImageMagick`) are also auto-installed for AppImage builds. Node.js 20+ is downloaded locally if not already installed.

#### Build Instructions

```bash
# Clone the repository
git clone https://github.com/presire/claude-desktop-suse.git
cd claude-desktop-suse

# Build an RPM package (default)
./build.sh

# Build an AppImage
./build.sh --build appimage

# Build with custom install prefix (RPM only)
./build.sh --prefix /opt

# Build without cleaning intermediate files
./build.sh --clean no
```

#### Installing the Built Package

```bash
# Install the package
sudo zypper install ./claude-desktop-VERSION-ARCHITECTURE.rpm

# Or using rpm directly:
sudo rpm -ivh ./claude-desktop-VERSION-ARCHITECTURE.rpm
```

## Configuration

### MCP Configuration

Model Context Protocol settings are stored in:
```
~/.config/Claude/claude_desktop_config.json
```

### Application Logs

Runtime logs are available at:
```
$HOME/.cache/claude-desktop-suse/launcher.log
```

## Uninstallation

```bash
# Remove package
sudo zypper remove claude-desktop

# Or using rpm directly:
sudo rpm -e claude-desktop
```

**Remove user configuration:**
```bash
rm -rf ~/.config/Claude
```

## Troubleshooting

### Window Scaling Issues

If the window doesn't scale correctly on first launch:
1. Right-click the Claude Desktop tray icon
2. Select "Quit" (do not force quit)
3. Restart the application

This allows the application to save display settings properly.

### Common Issues

- Ensure all dependencies are installed: `sudo zypper install nodejs npm p7zip`
- Check the log file at `$HOME/.cache/claude-desktop-suse/launcher.log`
- Verify that Electron is properly packaged (default: `/usr/lib/claude-desktop/`)

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Downloads the official Windows installer
2. Extracts application resources
3. Applies Linux compatibility patches (frame fix, tray integration, native module stubs)
4. Installs node-pty for terminal support
5. Repackages as an RPM package or AppImage for openSUSE/SLE

### Build Scripts

- `build.sh` - Main build script (auto-detects openSUSE/SLE)
- `scripts/build-rpm-package.sh` - RPM package builder (called by build.sh)
- `scripts/build-appimage.sh` - AppImage builder (called by build.sh with `--build appimage`)
- `scripts/launcher-common.sh` - Shared launcher functions (Wayland/X11 detection)
- `scripts/frame-fix-wrapper.js` - Electron BrowserWindow frame fix for Linux
- `scripts/claude-native-stub.js` - Native module stub for Linux compatibility

### Build Options

| Option | Description | Default |
|--------|-------------|---------|
| `--build rpm\|appimage` | Build format | `rpm` |
| `--clean yes\|no` | Clean intermediate files | `yes` |
| `--prefix /path` | Installation prefix | `/usr/lib` |
| `--exe /path/to/installer.exe` | Use local installer | Download |
| `--release-tag TAG` | Release tag for versioning | None |

## Distribution Support

### Tested Distributions

- openSUSE Leap 15.5+
- openSUSE Tumbleweed
- SUSE Linux Enterprise 15 SP5+

## Acknowledgments

This fork is based on [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian).

The original project was inspired by [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) and their [Reddit post](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/) about running Claude Desktop natively on Linux.

Special thanks to:
- **aaddrick** for the original Debian build scripts
- **k3d3** for the original NixOS implementation and native bindings insights
- **[emsi](https://github.com/emsi/claude-desktop)** for the title bar fix and alternative implementation approach

For NixOS users, please refer to [k3d3's repository](https://github.com/k3d3/claude-desktop-linux-flake) for a Nix-specific implementation.

## License

The build scripts in this repository are dual-licensed under:
- MIT License (see [LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 (see [LICENSE-APACHE](LICENSE-APACHE))

The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contributing

Contributions are welcome! By submitting a contribution, you agree to license it under the same dual-license terms as this project.

For contributions related to the original Debian build scripts, please consider contributing to the [upstream repository](https://github.com/aaddrick/claude-desktop-debian).
