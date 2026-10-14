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

# Build input is the Windows `.nupkg` resolved by the build pipeline.
# Do not use a Linux `.deb` as build input.
```

### Claude version

By default the build downloads the Claude release that the patch scripts are
verified against (`CLAUDE_PINNED_VERSION` in `scripts/setup/detect-host.sh`,
currently `2.37337.1`) and checks it against the SHA-256 pinned for the target
architecture (see [D-005](DECISIONS.md#d-005--builds-default-to-a-verified-claude-release)).
A mismatch aborts the build.

```bash
./build.sh --claude-version latest            # Newest release in RELEASES (SHA-1 verified; patches may not apply)
./build.sh --claude-version X.Y.Z \
  --claude-sha256 HASH                        # Another release, verified against your hash
```

A version other than the pin is checksum-verified only with `--claude-sha256`
or while Anthropic's `RELEASES` file still lists it (it lists only the newest
release).

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

The AppImage build uses `appimagetool` from `PATH` when present; otherwise it
downloads a pinned `appimagetool` release and the pinned static type2 runtime
and verifies both against SHA-256 values recorded in
`scripts/packaging/appimage.sh` (a mismatch aborts the build). The resulting
AppImage needs `fusermount3` (`fuse3`) but not `libfuse2`. Local builds embed
no update information; release builds (`GITHUB_ACTIONS`) embed the
`gh-releases-zsync` update information and fail if `appimagetool` does not
produce the `.zsync` file.

## Artifact Validation

Validate built RPM and AppImage artifacts with the existing low-level checks, then use the [artifact and external harness runbook](HARNESS.md) for isolated L2 verification.

```bash
./tests/test-artifact-rpm.sh <artifact-dir>
./tests/test-artifact-appimage.sh <artifact-dir>
```

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Resolves the official Windows `.nupkg` build input
2. Extracts application resources from the nupkg
3. Replaces Windows-specific native modules with Linux-compatible implementations
4. Applies Linux-specific patches (frame fixes, tray integration, Cowork mode)
5. Repackages as one of:
   - **RPM package (.rpm)**: For openSUSE, SUSE Linux Enterprise
   - **AppImage**: Portable, distribution-agnostic executable

### Build Process

The build script (`build.sh`) handles:
- Dependency checking and installation (via zypper), including build tools
  (`gcc`, `gcc-c++`, `make`, `python3`) needed to compile the `node-pty`
  native module (#401)
- Dynamic version resolution from official release server
- Resource extraction from Windows installer
- Icon processing for Linux desktop standards
- Native module replacement (claude-native stub, node-pty)
- 10+ application patches for Linux compatibility
- Package generation based on selected format

> **Note on the Electron version:** the build installs `electron@^44`, the
> major shipped inside the current Windows `.nupkg` (see D-004 in
> [DECISIONS.md](DECISIONS.md)). A work directory kept with `--clean no` that
> still holds a different Electron major is reinstalled automatically.
> `electron@42.0.0` and later have no postinstall script that populates
> `node_modules/electron/dist/`; `scripts/setup/fetch-electron-binary.js`
> downloads the binary instead (see upstream issue #584).

### Manual Updates

If you need to build with a specific version, provide the corresponding
Windows `.nupkg` through the build pipeline. Do not use a Linux `.deb` as the
build input.
