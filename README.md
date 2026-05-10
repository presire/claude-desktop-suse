# Claude Desktop for openSUSE/SLE Linux

This project provides build scripts to run Claude Desktop natively on openSUSE and SUSE Linux Enterprise systems.  
It repackages the official Windows application, producing `.rpm` packages and distribution-agnostic AppImages.  

This is a fork of [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) adapted for openSUSE/SLE distributions.  

**Note:** This is an unofficial build script. For official support, please visit [Anthropic's website](https://www.anthropic.com).  
For issues with the build script or Linux implementation,  
please [open an issue](https://github.com/presire/claude-desktop-suse/issues) in this repository.  

## Features

- **Native Linux Support**: Run Claude Desktop without virtualization or Wine
- **In-app Topbar**: Hamburger menu, sidebar toggle, search, and navigation via WCO shim (hybrid mode)
- **Titlebar Styles**: Three modes — hybrid (default, OS frame + in-app topbar), native, and hidden
- **Window Icon**: Claude logo set on `BrowserWindow` via `setIcon()` so X11 WMs (KWin etc.) draw the app icon in the titlebar / Alt-Tab / taskbar instead of Electron's default atom glyph
- **Close-to-tray**: Closing the window hides to tray, keeping MCP servers and schedulers alive
- **Run on Startup**: XDG Autostart integration for the "Run on startup" settings toggle
- **In-place Upgrade Detection**: When `zypper up` replaces `app.asar` while the app is running, Claude Desktop surfaces a "click to restart" notification so you don't end up with v(N+1) HTML running against v(N) IPC
- **KDE Plasma Wayland Launcher Grouping**: `pkg.desktopName` is set inside the packaged `app.asar` so KDE Plasma groups Claude Desktop windows under the installed `.desktop` file (fixes ungrouped taskbar entries on Wayland)
- **Tray Icon Theme Switching**: In-place `setImage` + `setContextMenu` fast-path on `nativeTheme` updates avoids the KDE Plasma duplicate-SNI race on theme change
- **MCP Support**: Full Model Context Protocol integration
  Configuration file location: `~/.config/Claude/claude_desktop_config.json`
- **Cowork Mode**: Pluggable isolation backends (bubblewrap / host) with auto-detection, sharedCwdPath forwarding from the user-selected folder, daemon auto-respawn with cooldown, and `{src, dst}` mount form for distinct host/sandbox paths
- **Diagnostics**: Built-in health check via `claude-desktop --doctor` (display server, sandbox permissions, MCP config, stale locks, IBus/GTK input-method routing, cowork backend readiness)
- **System Integration**:
  - Global hotkey support (Ctrl+Alt+Space) - works on X11 and Wayland (via XWayland)
  - System tray integration with close-to-tray persistence
  - Desktop environment integration
  - Quick Window blur/visibility patches gated to KDE only (avoids GNOME regressions)

### Screenshots

<p align="center">
  <img src="screenshot/screenshot_01.png" alt="Claude Desktop running on Linux" />
</p>

<p align="center">
  <img src="screenshot/screenshot_02.png" alt="Global hotkey popup" />
</p>

## Installation

### Building from Source

See [docs/BUILDING.md](docs/BUILDING.md) for detailed build instructions, technical details, and manual update procedures.  

#### Prerequisites

Install the required packages before building:  

```bash
sudo zypper install git gcc-c++ make
```

> **Note:**  
> Building the node-pty native module (for Claude Code terminal features) requires **Python 3.8 or later**.  
> If your system's default Python is older (e.g., Python 3.6 on openSUSE Leap 15.x), node-pty compilation will fail.  
> Claude Desktop itself will still build and run, but Claude Code terminal features will not be available.  
> See [docs/BUILDING.md](docs/BUILDING.md) for details on specifying a Python 3.8+ path.  

#### Build and Install

```bash
# Clone the repository
git clone https://github.com/presire/claude-desktop-suse.git
cd claude-desktop-suse

# Build an RPM package (default)
./build.sh

# Build an AppImage
./build.sh --build appimage

# Build with dark-mode tray icons (white icons for dark panels)
./build.sh --dark

# Install the package
sudo zypper install ./claude-desktop-VERSION-ARCHITECTURE.rpm
```

The build script automatically installs remaining dependencies (`p7zip`, `wget`, `icoutils`, `ImageMagick`, `rpm-build`) via zypper.  
Node.js 20+ is downloaded locally if not already installed.  

### Using Pre-built Releases

Download the latest `.rpm` or `.AppImage` from the [Releases page](https://github.com/presire/claude-desktop-suse/releases).  

## Configuration

Model Context Protocol settings are stored in:  

```
~/.config/Claude/claude_desktop_config.json
```

For additional configuration options including environment variables,  
Wayland support, and Cowork sandbox mounts, see [docs/CONFIGURATION.md](docs/CONFIGURATION.md).  

## Troubleshooting

Run `claude-desktop --doctor` for built-in diagnostics that check common issues (display server, sandbox permissions, MCP config, stale locks, and more).  
It also reports cowork mode readiness — which isolation backend will be used, and which dependencies are installed or missing.  

For additional troubleshooting, uninstallation instructions, and log locations, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).  

## Distribution Support

### Tested Distributions

- openSUSE Leap 15.6+
- openSUSE Tumbleweed
- SUSE Linux Enterprise 15 SP6+

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
- **[sabiut](https://github.com/sabiut)** for the `--doctor` diagnostic command, SHA-256 checksum validation for downloads, and post-build integration tests for deb, rpm, and AppImage artifacts
- **[milog1994](https://github.com/milog1994)** for Linux UX improvements including popup detection, functional stubs, and Wayland compositor support
- **[jarrodcolburn](https://github.com/jarrodcolburn)** for passwordless sudo support in container/CI environments, identifying the gh-pages 4GB bloat fix, identifying the virtiofsd PATH detection issue on Debian, detailed analysis of the CI release pipeline failure, and diagnosing the session-start hook sudo blocking issue
- **[chukfinley](https://github.com/chukfinley)** for experimental Cowork mode support on Linux
- **[CyPack](https://github.com/CyPack)** for orphaned cowork daemon cleanup on startup
- **[IliyaBrook](https://github.com/IliyaBrook)** for fixing the platform patch for Claude Desktop >= 1.1.3541 arm64 refactor
- **[MichaelMKenny](https://github.com/MichaelMKenny)** for diagnosing the `$`-prefixed electron variable bug with root cause analysis and workaround
- **[daa25209](https://github.com/daa25209)** for detailed root cause analysis of the cowork platform gate crash and patch script
- **[noctuum](https://github.com/noctuum)** for the `CLAUDE_MENU_BAR` env var with configurable menu bar visibility and boolean alias support
- **[typedrat](https://github.com/typedrat)** for the NixOS flake integration with build.sh, node-pty derivation, CI auto-update, and fixing the flake package scoping regression
- **[cbonnissent](https://github.com/cbonnissent)** for reverse-engineering the Cowork VM guest RPC protocol, fixing the KVM startup blocker, fixing RPC response id echoing for persistent connections, and configurable bwrap mount points via a dedicated Linux config file
- **[joekale-pp](https://github.com/joekale-pp)** for adding `--doctor` support to the RPM launcher
- **[ecrevisseMiroir](https://github.com/ecrevisseMiroir)** for the bwrap backend sandbox isolation with tmpfs-based minimal root
- **[arauhala](https://github.com/arauhala)** for detailed root cause analysis of the NixOS `isPackaged` regression
- **[cromagnone](https://github.com/cromagnone)** for confirming the VM download loop on bwrap installs with detailed logs that disproved the initial triage
- **[aHk-coder](https://github.com/aHk-coder)** for diagnosing the hardcoded minified variable crash in the cowork smol-bin patch
- **[RayCharlizard](https://github.com/RayCharlizard)** for detailed analysis of the self-referential `.mcpb-cache` symlink ELOOP bug and fixing auto-memory path translation on HostBackend
- **[reinthal](https://github.com/reinthal)** for fixing the NixOS build breakage caused by the nixpkgs `nodePackages` removal
- **[gianluca-peri](https://github.com/gianluca-peri)** for reporting the GNOME quit accessibility issue and confirming tray behavior with AppIndicator
- **[martin152](https://github.com/martin152)** for detailed diagnosis and a complete patch for three launcher cleanup bugs: `cleanup_orphaned_cowork_daemon` self-match, `cleanup_stale_cowork_socket` socat dependency no-op, and the same self-match in `--doctor`
- **[hfyeh](https://github.com/hfyeh)** for diagnosing the Ubuntu 24.04 AppArmor unprivileged-userns block on Cowork bwrap and contributing the AppArmor profile workaround
- **[davidamacey](https://github.com/davidamacey)** for identifying and fixing the XRDP GPU compositing blank-window issue on remote desktop sessions
- **[pb3ck](https://github.com/pb3ck)** for diagnosing the Cowork `CLAUDE_CODE_OAUTH_TOKEN` env-strip bug with a working reference diff
- **[aJV99](https://github.com/aJV99)** for exporting `GDK_BACKEND=wayland` in native Wayland mode to fix XWayland fallback blur on HiDPI displays
- **[Andrej730](https://github.com/Andrej730)** for the quick-window regex readability refactor (`String.raw` + `escapeRegExp` helper) and fixing the visibility-function regex break on Claude Desktop 1.3883.0
- **[Joost-Maker](https://github.com/Joost-Maker)** for fixing the `$e` fs reference crash in cowork Patch 9 on Claude Desktop 1.3109.0 by introducing the `[$\w]+` identifier-capture pattern
- **[HumboldtJoker](https://github.com/HumboldtJoker)** for diagnosing the cowork Patch 2b silent failure on Claude Desktop 1.5354.0 — identifying that the log line was patched but session init still routed through the Swift addon
- **[zabka](https://github.com/zabka)** for identifying that `cowork-vm-service.js` was never auto-spawned on Linux and contributing a systemd-unit workaround that scoped the daemon auto-launch fix
- **[sirfaber](https://github.com/sirfaber)** for fixing the `$`-in-minified-identifier breakage of cowork Patch 2b (vm module assignment) and Patch 6 step 2 (retry-delay auto-launch) on Claude Desktop 1.5354.0
- **[ProfFlow](https://github.com/ProfFlow)** for re-fixing the RPM repodata signing regression by appending `!` to the keyid passed to `gpg --default-key`, forcing `repomd.xml` to be signed by the primary key
- **[jslatten](https://github.com/jslatten)** for fixing the KDE Plasma Wayland launcher-grouping bug by setting `pkg.desktopName` in the packaged `app.asar`'s `package.json`

For NixOS users, please refer to [k3d3's repository](https://github.com/k3d3/claude-desktop-linux-flake) for a Nix-specific implementation.  

## License

The build scripts in this repository are dual-licensed under:  
- MIT License (see [LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 (see [LICENSE-APACHE](LICENSE-APACHE))

The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).  

## Contributing

Contributions are welcome! By submitting a contribution, you agree to license it under the same dual-license terms as this project.  

For contributions related to the original Debian build scripts, please consider contributing to the [upstream repository](https://github.com/aaddrick/claude-desktop-debian).  
