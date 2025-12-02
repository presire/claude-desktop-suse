# Claude Desktop for Linux (with openSUSE/SLE Support)

This is a fork of [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) with added support for openSUSE and SLE Linux Enterprise distributions.

This project provides build scripts to run Claude Desktop natively on Linux systems. It repackages the official Windows application for Debian-based and openSUSE/SLE distributions, producing `.deb` packages, `.rpm` packages, or AppImages.

**Note:** This is an unofficial build script. For official support, please visit [Anthropic's website](https://www.anthropic.com). For issues with the build script or Linux implementation, please [open an issue](https://github.com/presire/claude-desktop-suse/issues) in this repository.

## Additional Features in This Fork

- ✨ **openSUSE/SLE Support**: Build RPM packages for openSUSE and SUSE Linux Enterprise
- 📦 New build scripts: `build-suse.sh` and `build-rpm-package.sh`
- 🔧 Full compatibility with both Debian-based and RPM-based distributions

## Features

- **Native Linux Support**: Run Claude Desktop without virtualization or Wine
- **MCP Support**: Full Model Context Protocol integration
  Configuration file location: `~/.config/Claude/claude_desktop_config.json`
- **System Integration**:
  - X11 Global hotkey support (Ctrl+Alt+Space)
  - System tray integration
  - Desktop environment integration
- **Multi-Distribution Support**:
  - Debian-based: `.deb` packages
  - openSUSE/SLE: `.rpm` packages
  - Universal: AppImages

### Screenshots

![Claude Desktop running on Linux](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

![Global hotkey popup](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

![System tray menu on KDE](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

## Installation

### Building from Source

#### Prerequisites

**For Debian-based distributions (Debian, Ubuntu, Linux Mint, MX Linux, etc.):**
- Git
- Basic build tools (automatically installed by the script)

**For openSUSE/SLE distributions:**
- Git
- rpm-build (automatically installed by the script)
- Basic build tools

#### Build Instructions

**For Debian-based distributions:**
```bash
# Clone the repository
git clone https://github.com/presire/claude-desktop-debian.git
cd claude-desktop-debian

# Build a .deb package (default)
./build.sh

# Build an AppImage
./build.sh --build appimage

# Build with custom options
./build.sh --build deb --clean no  # Keep intermediate files
```

**For openSUSE/SLE distributions:**
```bash
# Clone the repository
git clone https://github.com/presire/claude-desktop-suse.git
cd claude-desktop-suse

# Build an RPM package
./build-suse.sh

# The script will automatically detect your system architecture
```

#### Installing the Built Package

**For .deb packages (Debian, Ubuntu, etc.):**
```bash
sudo dpkg -i ./claude-desktop_VERSION_ARCHITECTURE.deb

# If you encounter dependency issues:
sudo apt --fix-broken install
```

**For .rpm packages (openSUSE, SUSE):**
```bash
# Install the package
sudo zypper install ./claude-desktop-VERSION-ARCHITECTURE.rpm

# Or using rpm directly:
sudo rpm -ivh ./claude-desktop-VERSION-ARCHITECTURE.rpm
```

**For AppImages:**
```bash
# Make executable
chmod +x ./claude-desktop-*.AppImage

# Run directly
./claude-desktop-*.AppImage

# Or integrate with your system using Gear Lever
```

**Note:** AppImage login requires proper desktop integration. Use [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) or manually install the provided `.desktop` file to `~/.local/share/applications/`.

**Automatic Updates:** AppImages downloaded from GitHub releases include embedded update information and work seamlessly with Gear Lever for automatic updates. Locally-built AppImages can be manually configured for updates in Gear Lever.

## Configuration

### MCP Configuration

Model Context Protocol settings are stored in:
```
~/.config/Claude/claude_desktop_config.json
```

### Application Logs

Runtime logs are available at:

**For Debian-based distributions:**
```
$HOME/.cache/claude-desktop-debian/launcher.log
```

**For openSUSE/SLE distributions:**
```
$HOME/.cache/claude-desktop-opensuse/launcher.log
```

## Uninstallation

**For .deb packages:**
```bash
# Remove package
sudo dpkg -r claude-desktop

# Remove package and configuration
sudo dpkg -P claude-desktop
```

**For .rpm packages:**
```bash
# Remove package
sudo zypper remove claude-desktop

# Or using rpm directly:
sudo rpm -e claude-desktop
```

**For AppImages:**
1. Delete the `.AppImage` file
2. Remove the `.desktop` file from `~/.local/share/applications/`
3. If using Gear Lever, use its uninstall option

**Remove user configuration (all formats):**
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

### AppImage Sandbox Warning

AppImages run with `--no-sandbox` due to electron's chrome-sandbox requiring root privileges for unprivileged namespace creation. This is a known limitation of AppImage format with Electron applications.

For enhanced security, consider:
- Using the .deb or .rpm package instead
- Running the AppImage within a separate sandbox (e.g., bubblewrap)
- Using Gear Lever's integrated AppImage management for better isolation

### openSUSE/SLE Specific Issues

If you encounter issues on openSUSE/SLE:
- Ensure all dependencies are installed: `sudo zypper install nodejs npm p7zip`
- Check the log file at `$HOME/.cache/claude-desktop-opensuse/launcher.log`
- Verify that Electron is properly packaged in `/opt/claude-desktop/`

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Downloads the official Windows installer
2. Extracts application resources
3. Replaces Windows-specific native modules with Linux-compatible implementations
4. Repackages as either:
   - **Debian package (.deb)**: Standard system package for Debian-based distributions
   - **RPM package (.rpm)**: Standard system package for openSUSE/SLE distributions
   - **AppImage**: Portable, self-contained executable for any distribution

### Build Process

The build scripts handle:
- Dependency checking and installation
- Resource extraction from Windows installer
- Icon processing for Linux desktop standards
- Native module replacement
- Package generation based on selected format and distribution

**Build Scripts:**
- `build.sh` - Main build script for Debian-based distributions
- `build-deb-package.sh` - Debian package builder (called by build.sh)
- `build-suse.sh` - Build script for openSUSE/SLE distributions
- `build-rpm-package.sh` - RPM package builder (called by build-suse.sh)

### Updating for New Releases

The scripts automatically detect system architecture and download the appropriate version. If Claude Desktop's download URLs change, update the `CLAUDE_DOWNLOAD_URL` variables in the respective build scripts.

## Distribution Support

### Tested Distributions

**Debian-based (via .deb):**
- Debian 11, 12
- Ubuntu 20.04, 22.04, 24.04
- Linux Mint 20, 21, 22
- MX Linux 21, 23

**openSUSE/SLE (via .rpm):**
- openSUSE Leap 15.5+
- openSUSE Tumbleweed
- SUSE Linux Enterprise 15 SP5+

**Universal (via AppImage):**
- Any modern Linux distribution with glibc 2.31+

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
