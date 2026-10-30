[< Back to README](../README.md)

# Building from Source

## Prerequisites

- openSUSE Leap 15.5+ / openSUSE Tumbleweed / SUSE Linux Enterprise 15 SP5+
- Git, gcc-c++, make
- Python 3.8+
- Basic build tools (automatically installed by the script via zypper)

### Node.js and asar

The build requires Node.js **22.12.0 or newer** (`NODE_MIN_VERSION` in
`scripts/setup/dependencies.sh`). That floor is the `engines.node`
constraint of `@electron/asar` 4.x: npm only warns when it is not met and
installs a wrapper that then refuses to run. On an older host the setup
step downloads a local Node 22.23.2 into `build/node/` instead of using
the system one.

The asar that repacks `app.asar` after the patch stage is pinned to
`@electron/asar@4.3.1` (`ASAR_PINNED_VERSION` in
`scripts/setup/dependencies.sh`), because its output ships inside the
`.rpm` and `.AppImage`. A work directory kept with `--clean no` that holds
another asar version is reinstalled, and the build fails if the staged
asar does not report the pinned version. Bumping the pin is a deliberate
one-line change.

`scripts/verify-patches.sh` extracts an `.asar` input with the first
runnable asar it finds: `ASAR_BIN`, `build/node_modules/.bin/asar`, then
`asar` on `PATH`. It never downloads one. Run `./build.sh` once to stage
the local copy, or point `ASAR_BIN` at a working CLI.

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
currently `4.4212.0`) and checks it against the SHA-256 pinned for the target
architecture (see [D-005](DECISIONS.md#d-005--builds-default-to-a-verified-claude-release)).
A mismatch aborts the build.
The CI build workflows pass the same version explicitly
(`CLAUDE_DESKTOP_VERSION` in `.github/workflows/test-artifacts.yml` and
`release.yml`) and fail when it differs from `CLAUDE_PINNED_VERSION`, so a pin
bump updates `detect-host.sh` and both workflows together.

```bash
./build.sh --claude-version latest            # Newest release in RELEASES (SHA-1 verified; patches may not apply)
./build.sh --claude-version X.Y.Z \
  --claude-sha256 HASH                        # Another release, verified against your hash
```

A version other than the pin is checksum-verified only with `--claude-sha256`
or while Anthropic's `RELEASES` file still lists it (it lists only the newest
release).

### Building arm64 packages on an x64 host

`--arch arm64` builds an aarch64 `.rpm` or `.AppImage` on an x86_64 host. The
Electron runtime is fetched for the target architecture (`ELECTRON_TARGET_ARCH`
passed to `scripts/setup/fetch-electron-binary.js`), and a kept work dir
(`--clean no`) whose `node_modules/electron/dist/electron` is for another
architecture is re-fetched rather than reused.

```bash
./build.sh --build rpm --arch arm64
./build.sh --build appimage --arch arm64
```

To run the artifact checks for an arm64 package on an x64 host, register
qemu-user binfmt (`sudo zypper install qemu-linux-user`) and run them in an
arm64 container, e.g. `podman run --arch arm64 registry.opensuse.org/opensuse/leap:16.0`.
Startup under emulation is much slower than on real hardware.

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

The RPM suite installs and removes the package, so run it as root in a
disposable container (for example rootless `podman` with
`opensuse/leap:16`); it refuses to run where `claude-desktop` is already
installed. Both suites check that no Windows PE `.node` module ships in
`app.asar.unpacked`.

A check that cannot run in the current environment (no `/dev/fuse`, no
`appstreamcli`, no unprivileged smoke user, ...) is reported as SKIP and
does not fail the suite. Set `ARTIFACT_FAIL_ON_SKIP=1` to turn any SKIP
into a non-zero exit.

`.github/workflows/test-artifacts.yml` does this in CI: it builds the
x86_64 `.rpm` and `.AppImage` in an `opensuse/leap:16.0` container, then
runs each suite in its own container job with `ARTIFACT_FAIL_ON_SKIP=1`.
The RPM suite runs as root; the AppImage suite gets `/dev/fuse` and
`SYS_ADMIN` for the FUSE mount check and runs as an unprivileged user,
because Electron refuses to start as root without `--no-sandbox`.

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Resolves the official Windows `.nupkg` build input
2. Extracts application resources from the nupkg
3. Replaces Windows-specific native modules with Linux-compatible implementations
   and drops every Windows PE `*.node` the nupkg ships (node-pty's
   `conpty.node` / `conpty_console_list.node`, the `claude-native` binding,
   office365-mcp's `msal-node-runtime.node`). Files are matched by their
   `MZ` header, not by path, so the step is the same for x64 and arm64; the
   repack invariance check fails the build if one reaches
   `app.asar.unpacked`. Other Windows payload (`github-mcp-server.exe`,
   `msalruntime*.dll`) is not a Node module and is left as shipped.
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

#### Patch effect check

Each per-feature patch runs with a digest of
`app.asar.contents/.vite/build` taken before and after it. A patch that
leaves the digest unchanged fails the build:

```
Patch effect: '<function>' left app.asar.contents/.vite/build byte-identical.
```

That usually means the pinned release changed the minified shape the
patch anchors on. Fix the anchor; do not silence the check. Intentional
no-ops are listed with a one-line reason in `_PATCH_EFFECT_ALLOWLIST` in
`scripts/patches/_common.sh` — for example `extract_electron_variable`,
which only records a variable and never writes a file, or patches whose
upstream release already provides the behaviour. An allowlisted function
passes only when it also calls `_declare_patch_noop` from that reviewed
branch, so an allowlisted patch whose anchor drifted still fails. A patch
function that returns non-zero fails the stage with
`Patch stage: <function> failed (exit N)`. `PATCH_STAGE_RERUN=1`
skips this per-patch check on its second pass because every patch is
expected to be a no-op there; the whole-stage idempotency check still
runs.

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
