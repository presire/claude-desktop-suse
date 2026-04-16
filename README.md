# Claude Desktop for openSUSE/SLE Linux

This is a fork of [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) adapted for openSUSE and SUSE Linux Enterprise distributions.  

This project provides build scripts to run Claude Desktop natively on openSUSE/SUSE Linux Enterprise systems.  
It repackages the official Windows application, producing `.rpm` packages.  

**Note:**  
This is an unofficial build script. For official support, please visit [Anthropic's website](https://www.anthropic.com).  
For issues with the build script or Linux implementation, please [open an issue](https://github.com/presire/claude-desktop-suse/issues) in this repository.  

---

> **EXPERIMENTAL: Cowork Mode Support**  
> Cowork mode is **enabled by default** in this build.  
> It uses Anthropic's native VM images with a pluggable isolation backend:  
>
> | Backend | Isolation | Requirements |
> |---------|-----------|-------------|
> | **KVM** (preferred) | Full VM via QEMU/KVM | `/dev/kvm`, `qemu-system-x86_64`, `/dev/vhost-vsock`, `socat`, `virtiofsd` |
> | **bubblewrap** (fallback) | Namespace sandbox | `bwrap` installed and functional |
> | **host** (last resort) | None — runs directly on host | No additional requirements |
>
> The best available backend is auto-detected at startup.  
> Run `claude-desktop --doctor` to check which backend will be used and which dependencies are missing.  
>
> **Note:**  
> The bubblewrap backend mounts your home directory as read-only (only the project working directory is writable).  
> You can customize sandbox mount points (additional read-only/read-write binds, disabled defaults) via  
> `~/.config/Claude/claude_desktop_linux_config.json`. See [Configuration > Cowork Sandbox Mounts](docs/CONFIGURATION.md#cowork-sandbox-mounts) for details.  
> The host backend provides no isolation — use it only if you understand the security implications.  

---

## Features

- **Native Linux Support**: Run Claude Desktop without virtualization or Wine
- **MCP Support**: Full Model Context Protocol integration
  Configuration file location: `~/.config/Claude/claude_desktop_config.json`
- **Cowork Mode**: Pluggable isolation backends (KVM / bubblewrap / host) with auto-detection
- **Diagnostics**: Built-in health check via `claude-desktop --doctor`
- **System Integration**:
  - Global hotkey support (Ctrl+Alt+Space) - works on X11 and Wayland (via XWayland)
  - System tray integration
  - Desktop environment integration
  - Configurable menu bar visibility via `CLAUDE_MENU_BAR` environment variable
- **Customizable Install Path**: Use `--prefix` to specify installation directory

### Screenshots

![Claude Desktop running on Linux](screenshot/screenshot_01.png)  

![Global hotkey popup](screenshot/screenshot_02.png)  

## Installation

### Building from Source

For detailed build instructions, technical details, and manual update procedures, see [docs/BUILDING.md](docs/BUILDING.md).

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

**Note:**
Building the node-pty native module (for Claude Code terminal features) requires **Python 3.8 or later**.
If your system's default Python is older (e.g., Python 3.6 on openSUSE Leap 15.x), node-pty compilation will fail with a `SyntaxError: invalid syntax` error in `gyp`, because `node-gyp` uses Python's walrus operator (`:=`) which was introduced in Python 3.8.
Claude Desktop itself will still build and run, but Claude Code terminal features will not be available.

To resolve this, specify a Python 3.8+ path before building:

```bash
# Check your current Python version
python3 --version

# If Python 3.8+ is installed at a different path, specify it:
export PYTHON=/path/to/python3.8+
./build.sh

# Or set it via npm config:
npm config set python /path/to/python3.8+
```

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

The common dependencies above (`p7zip`, `wget`, `icoutils`, `ImageMagick`) are also auto-installed for AppImage builds.  
Node.js 20+ is downloaded locally if not already installed.  

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

### Environment Variables

| Variable | Values | Default | Description |
|----------|--------|---------|-------------|
| `CLAUDE_MENU_BAR` | `auto`, `visible`, `hidden` | `auto` | Menu bar visibility. `auto`: hidden by default, Alt toggles. `visible`: always shown. `hidden`: always hidden. |
| `CLAUDE_USE_WAYLAND` | `1` | unset | Set to `1` for native Wayland mode (disables global hotkeys). Default uses X11 via XWayland. |
| `COWORK_VM_BACKEND` | `kvm`, `bwrap`, `host` | auto-detect | Override cowork isolation backend selection. |
| `COWORK_VM_DEBUG` | `1` | unset | Enable detailed cowork daemon logging. |

### Application Logs

Runtime logs are available at:  

```
$HOME/.cache/claude-desktop-suse/launcher.log
```

Cowork daemon logs:  

```
$HOME/.config/Claude/logs/cowork_vm_daemon.log
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

Run `claude-desktop --doctor` for built-in diagnostics that check common issues (display server, sandbox permissions, MCP config, stale locks, and more).  
It also reports cowork mode readiness — which isolation backend will be used, and which dependencies (KVM, QEMU, vsock, socat, virtiofsd, bubblewrap) are installed or missing.  

### Window Scaling Issues

If the window doesn't scale correctly on first launch:  

1. Right-click the Claude Desktop tray icon  
2. Select "Quit" (do not force quit)  
3. Restart the application  

This allows the application to save display settings properly.  

### Common Issues

- Run `claude-desktop --doctor` to diagnose most issues automatically
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
- `scripts/launcher-common.sh` - Shared launcher functions (Wayland/X11 detection, `--doctor` diagnostics, stale lock cleanup)
- `scripts/frame-fix-wrapper.js` - Electron BrowserWindow frame fix for Linux (menu bar control, KWin bounds fix)
- `scripts/claude-native-stub.js` - Native module stub for Linux compatibility
- `scripts/cowork-vm-service.js` - Cowork VM service daemon (pluggable KVM/bwrap/host backends)
- `tests/cowork-path-translation.bats` - BATS test suite for cowork path translation

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
- **[leobuskin](https://github.com/leobuskin/unofficial-claude-desktop-linux)** for the Playwright-based URL resolution approach
- **[yarikoptic](https://github.com/yarikoptic)** for codespell support and shellcheck compliance
- **[IamGianluca](https://github.com/IamGianluca)** for build dependency check improvements
- **[ing03201](https://github.com/ing03201)** for IBus/Fcitx5 input method support
- **[ajescudero](https://github.com/ajescudero)** for pinning @electron/asar for Node compatibility
- **[delorenj](https://github.com/delorenj)** for Wayland compatibility support
- **[Regen-forest](https://github.com/Regen-forest)** for suggesting Gear Lever as AppImageLauncher replacement
- **[niekvugteveen](https://github.com/niekvugteveen)** for fixing Debian packaging permissions
- **[speleoalex](https://github.com/speleoalex)** for native window decorations support
- **[imaginalnika](https://github.com/imaginalnika)** for moving logs to `~/.cache/`
- **[richardspicer](https://github.com/richardspicer)** for the menu bar visibility fix on Linux
- **[jacobfrantz1](https://github.com/jacobfrantz1)** for Claude Desktop code preview support and quick window submit fix
- **[janfrederik](https://github.com/janfrederik)** for the `--exe` flag to use a local installer
- **[MrEdwards007](https://github.com/MrEdwards007)** for discovering the OAuth token cache fix
- **[lizthegrey](https://github.com/lizthegrey)** for version update contributions
- **[mathys-lopinto](https://github.com/mathys-lopinto)** for the AUR package and automated deployment
- **[pkuijpers](https://github.com/pkuijpers)** for root cause analysis of the RPM repo GPG signing issue
- **[dlepold](https://github.com/dlepold)** for identifying the tray icon variable name bug with a working fix
- **[Voork1144](https://github.com/Voork1144)** for detailed analysis of the tray icon minifier bug, root-cause analysis of the Chromium layout cache bug, and the direct child `setBounds()` fix approach
- **[sabiut](https://github.com/sabiut)** for the `--doctor` diagnostic command and SHA-256 checksum validation for downloads
- **[milog1994](https://github.com/milog1994)** for Linux UX improvements including popup detection, functional stubs, and Wayland compositor support
- **[jarrodcolburn](https://github.com/jarrodcolburn)** for passwordless sudo support in container/CI environments and multiple CI/release pipeline fixes
- **[chukfinley](https://github.com/chukfinley)** for experimental Cowork mode support on Linux
- **[CyPack](https://github.com/CyPack)** for orphaned cowork daemon cleanup on startup
- **[IliyaBrook](https://github.com/IliyaBrook)** for fixing the platform patch for Claude Desktop >= 1.1.3541 arm64 refactor
- **[MichaelMKenny](https://github.com/MichaelMKenny)** for diagnosing the `$`-prefixed electron variable bug with root cause analysis and workaround
- **[daa25209](https://github.com/daa25209)** for detailed root cause analysis of the cowork platform gate crash and patch script
- **[noctuum](https://github.com/noctuum)** for the `CLAUDE_MENU_BAR` env var with configurable menu bar visibility and boolean alias support
- **[typedrat](https://github.com/typedrat)** for the NixOS flake integration with build.sh, node-pty derivation, and CI auto-update
- **[cbonnissent](https://github.com/cbonnissent)** for reverse-engineering the Cowork VM guest RPC protocol and KVM startup fixes
- **[joekale-pp](https://github.com/joekale-pp)** for adding `--doctor` support to the RPM launcher
- **[ecrevisseMiroir](https://github.com/ecrevisseMiroir)** for the bwrap backend sandbox isolation with tmpfs-based minimal root
- **[arauhala](https://github.com/arauhala)** for detailed root cause analysis of the NixOS `isPackaged` regression
- **[cromagnone](https://github.com/cromagnone)** for confirming the VM download loop on bwrap installs with detailed logs
- **[aHk-coder](https://github.com/aHk-coder)** for diagnosing the hardcoded minified variable crash in the cowork smol-bin patch
- **[RayCharlizard](https://github.com/RayCharlizard)** for detailed analysis of the self-referential `.mcpb-cache` symlink ELOOP bug
- **[reinthal](https://github.com/reinthal)** for fixing the NixOS build breakage caused by the nixpkgs `nodePackages` removal
- **[gianluca-peri](https://github.com/gianluca-peri)** for reporting the GNOME quit accessibility issue and confirming tray behavior with AppIndicator

For NixOS users, please refer to [k3d3's repository](https://github.com/k3d3/claude-desktop-linux-flake) for a Nix-specific implementation.  

## License

The build scripts in this repository are dual-licensed under:  

- MIT License (see [LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 (see [LICENSE-APACHE](LICENSE-APACHE))

The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).  

## Contributing

Contributions are welcome! By submitting a contribution, you agree to license it under the same dual-license terms as this project.  

For contributions related to the original Debian build scripts, please consider contributing to the [upstream repository](https://github.com/aaddrick/claude-desktop-debian).  
