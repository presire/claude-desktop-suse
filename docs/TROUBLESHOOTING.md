[< Back to README](../README.md)

# Troubleshooting

## Built-in Diagnostics

Run the `--doctor` flag to check your system for common issues:

```bash
# RPM install
claude-desktop --doctor

# AppImage
./claude-desktop-*.AppImage --doctor
```

This runs a series of checks and prints pass/fail results with
suggested fixes:

| Check | What it verifies |
|-------|-----------------|
| Installed version | Package version via `rpm -qf`; for the AppImage, the `X-AppImage-Version` stamped into its desktop entry |
| Display server | Wayland/X11 detection and mode |
| Input method | IBus/GTK immodule sanity (ibus-gtk3 installed, cache fresh, XWayland routing note) |
| Electron binary | Existence and version |
| Chrome sandbox | Correct permissions (4755/root) for the RPM; informational only for the AppImage, which always runs with `--no-sandbox` |
| Effective sandbox | Whether the sandbox is actually engaged at runtime (the RPM passes `--no-sandbox` on Wayland unless `CLAUDE_FORCE_SANDBOX=1`) |
| SingletonLock | Stale lock (dead PID), a live holder that is not recognized as Claude Desktop (informational; Electron clears a recycled-PID lock itself on start), and a lock that is a regular file instead of a symlink |
| Cowork daemon | A `cowork-vm-service` daemon left behind after the UI quit |
| MCP config | JSON validity and server count |
| Node.js | Version (v20+ recommended for MCP) |
| Desktop entry | `.desktop` file presence |
| Disk space | Free space on config partition |
| Log file | Log file size |

Example output:
```
Claude Desktop Diagnostics
================================

[PASS] Installed version: 1.1.4498-1.3.15
[PASS] Display server: Wayland (WAYLAND_DISPLAY=wayland-0)
[PASS] Electron: found at /usr/lib/claude-desktop/node_modules/electron/dist/electron
[PASS] Chrome sandbox: permissions OK
[PASS] SingletonLock: no lock file (OK)
[PASS] MCP config: valid JSON
[PASS] Node.js: v22.14.0
[PASS] Desktop entry: /usr/share/applications/claude-desktop.desktop
[PASS] Disk space: 632284MB free
[PASS] Log file: 1352KB

All checks passed.
```

When opening an issue, include the output of `--doctor` to help with diagnosis.

## Application Logs

Runtime logs are available at:
```
~/.cache/claude-desktop-suse/launcher.log
```

## Common Issues

### External harness shows FAIL or SKIP for a probe

Read the structured JSONL result and the retained `log_path` before rerunning. The [artifact and external harness runbook](HARNESS.md) explains the expected fields, isolated XDG directories, environment-limited `SKIP` results, and why native Wayland window queries are not reported as successful L2 checks.

### In-app Topbar Not Displaying After Upgrade

If the in-app topbar (hamburger menu, sidebar toggle, search, navigation) does not appear after upgrading to a version with WCO shim support, clear the application cache:

```bash
# Close Claude Desktop completely, then:
rm -rf ~/.config/Claude
```

Restart Claude Desktop and log in again. The topbar should now be visible in the default hybrid titlebar mode.

### Window Scaling Issues

If the window doesn't scale correctly on first launch:
1. Right-click the Claude Desktop tray icon
2. Select "Quit" (do not force quit)
3. Restart the application

This allows the application to save display settings properly.

### Chromium GPU Process FATAL / Repeated Crashes (#583)

If Claude Desktop crashes repeatedly on startup or after a few minutes,
`--doctor` may report recent Electron crashes. The most common cause on
Linux is Chromium GPU process exhaustion.

The launcher now auto-recovers from this: when the previous launch died
to a Chromium GPU-process FATAL signature, the next launch automatically
applies safe GPU flags and stays recovered on subsequent launches
instead of oscillating crash/work/crash. Override with
`CLAUDE_DISABLE_GPU=0`. Detection also covers the launch right after
`launcher.log` rotated (5 MiB cap): the previous session is then read from
`launcher.log.1`.

**Manual workarounds:**

1. **Disable hardware acceleration in Settings** (persistent):
   - Launch Claude Desktop (may need a few tries)
   - Settings → Appearance → disable "Hardware acceleration" → restart

2. **Use the `CLAUDE_DISABLE_GPU` environment variable** (persistent via env):
   ```bash
   export CLAUDE_DISABLE_GPU=1
   claude-desktop
   ```

3. **For XRDP sessions**, GPU compositing is auto-disabled — no action needed.

### "Claude has an important security update. Update it with apt ..."

What is known:

- The banner text is not in this package: neither the local `app.asar` nor
  `ion-dist` contains it, so it comes from the remote claude.ai web UI that
  Claude Desktop loads.
- This fork disables Electron's auto-updater (D-001), so the local app neither
  checks for updates nor raises this banner itself.
- The `apt` wording matches Anthropic's Linux install documentation, which
  covers only the official Debian/Ubuntu package. It does not apply to this
  RPM/AppImage build.
- No public security advisory or minimum-version notice explains the banner.

What is not known: when the service shows it. It was observed on `2.42304.2`
after upstream moved to `3.x` releases, which suggests a server-side check of
the app version, but the condition is not documented and could not be
verified. Updating is therefore a troubleshooting step, not a guaranteed fix.

To check whether a newer release makes it go away, first note the version you
run, then update:

```bash
claude-desktop --version                     # version you are running
```

- **RPM from a repository:** `sudo zypper refresh && sudo zypper update claude-desktop`
  (Tumbleweed: `sudo zypper dup`).
- **Locally built RPM:** pull this repository, rebuild (the default build uses
  the pinned release in `scripts/setup/detect-host.sh`), then
  `sudo zypper install ./claude-desktop-VERSION-ARCH.rpm`.
- **AppImage:** update with AppImageUpdate (zsync) or download the newer
  AppImage.

Quit Claude Desktop completely (tray → Quit) and start it again afterwards.
If the banner remains on the newest pinned release, `./build.sh --claude-version latest`
builds the newest upstream release for comparison (patches are not verified
against it). Report the result together with `claude-desktop --version`.

### Build warnings about missing upstream resources

Some resources that the Windows nupkg used to ship, or that only exist for
Windows, are absent from current releases. The build reports them and
continues:

- `Warning: SSH helpers not found at .../claude-ssh` — 3.x ships only Windows
  `claude-ssh-*.exe` helpers, so there is no Linux SSH helper to stage.
  SSH remote-session features that need the Linux helper binary cannot work in
  this build.
- `Warning: cowork-plugin-shim.sh not found` — not shipped in current
  releases; nothing to stage.
- `Warning: smol-bin VHDX not found` — the KVM Cowork backend then reaches the
  SDK through virtiofs. The default bwrap backend is unaffected.

`Removed Windows-only native module: ...` lines are expected: the nupkg ships
Windows PE `*.node` files (node-pty `conpty`, the `claude-native` binding,
`msal-node-runtime.node`) that Linux cannot load, and the build drops them.
If the build instead stops with
`Repack invariance check FAILED: Windows PE native module unpacked: <path>`,
a staging step added a Windows `.node` after the prune ran; the package would
ship a module that fails to load, so the build refuses to continue.
`Cannot list native modules under: <dir>` or
`Cannot read native module header: <file>` means the scan itself failed
(permissions or I/O); the build stops rather than assume nothing is there.

### Build stops with `Patch effect: '<function>' left ... byte-identical`

The patch stage digests `app.asar.contents/.vite/build` before and after
every patch function. An unchanged digest means the function ran but wrote
nothing. The message names the function, and the usual cause is that the
pinned release changed the minified shape around its anchor.

Fix the anchor in `scripts/patches/<feature>.sh` and rebuild. If upstream
genuinely already provides the behaviour, add the function to
`_PATCH_EFFECT_ALLOWLIST` in `scripts/patches/_common.sh` with a one-line
reason, call `_declare_patch_noop` in the branch that detects it, and
verify it against the pinned bundle.

`Patch effect: '<function>' is allowlisted but did not reach its reviewed
no-op branch` means the same drift for an allowlisted function: it wrote
nothing without passing through its `_declare_patch_noop` branch. Fix the
anchor rather than the allowlist. `Patch stage: <function> failed (exit N)`
means the patch function itself returned an error; read the lines above it. Do not delete the check or
widen the digest to silence it. `PATCH_STAGE_RERUN=1` is exempt by design:
its second pass expects every patch to be a no-op.

### Cowork fails with `ENAMETOOLONG` on encrypted home directories (#590)

On eCryptfs-encrypted home directories (or any filesystem with
`NAME_MAX < 200`), Cowork's VM bundle paths can exceed the filesystem's
component-name limit, causing `ENAMETOOLONG` failures at daemon startup.
`--doctor` surfaces this with a `NAME_MAX` check.

**Workarounds:**

1. **LUKS-encrypted volume + `pam_mount`**: Move the Claude config dir
   onto a LUKS-encrypted block device (full `NAME_MAX` support) and bind
   it via `pam_mount` at login. This preserves encryption at rest without
   the eCryptfs filename-length penalty.

2. **Symlink workaround**: Symlink `~/.config/Claude` to a non-encrypted
   location (e.g. `/var/lib/claude-desktop/$USER` with appropriate
   permissions) if encryption at rest is not required.

### New Cowork cloud tasks show "Not linked to a computer"

Cloud tasks need a hardware-backed device key so the remote-tools bridge can
attest the machine. This build replaces the Windows `@ant/claude-native`
module with a JavaScript stub, so Linux has no such key and the app records
the device as unregistered. `--doctor` reports the state it finds in
`~/.config/Claude/ant-device-registry.json`:

- `Device registry: not registered — Linux has no hardware-backed device key`
  — expected on this build; it is an upstream gap, not a local fault.
  Existing on-device sessions keep working.
- `Device registry: registered` / `device key not yet confirmed by the server`
  — a key-backed row exists.

The check is informational only: it never changes the doctor exit status,
never prints the file (it contains account identifiers) and never edits it.
Nothing is shown when the file does not exist (Cowork not used yet).

### Input Method (IBus) Issues (#549)

If keyboard input in the chat doesn't work correctly (e.g., characters not
appearing, IME composition broken):

1. Ensure `ibus-gtk3` is installed:
   ```bash
   sudo zypper install ibus-gtk3
   ```

2. Refresh the GTK immodules cache:
   ```bash
   sudo gtk-query-immodules-3.0 --update-cache
   ```

3. If IBus integration is still broken, override the IM module for Electron only:
   ```bash
   CLAUDE_GTK_IM_MODULE=xim claude-desktop
   ```

4. On Wayland sessions, Electron runs via XWayland by default (for global
   hotkey support). The IBus path then goes through XIM, which is lossy for
   some IMEs. Use native Wayland to get full IME support:
   ```bash
   CLAUDE_USE_WAYLAND=1 claude-desktop
   ```
   (Note: global hotkeys won't work in native Wayland mode.)

### Cowork on AppArmor-blocked Systems (#351)

On distributions with AppArmor that block unprivileged user namespaces
(e.g., some hardened openSUSE configurations), the bwrap sandbox probe may
fail. `--doctor` will report this with an AppArmor hint.

**Workaround:** Create a local AppArmor profile that allows user namespaces
for bwrap. See the upstream [AppArmor workaround documentation](https://github.com/aaddrick/claude-desktop-debian/issues/351)
for the exact profile content.

### Global Hotkey Not Working (Wayland)

If the global hotkey (Ctrl+Alt+Space) doesn't work:

1. Check your logs at `~/.cache/claude-desktop-suse/launcher.log`
2. "Using X11 backend via XWayland" (the default) - the hotkey is grabbed
   through X11 and should work
3. "Using native Wayland backend" (`CLAUDE_USE_WAYLAND=1`) - the hotkey is
   registered through the XDG GlobalShortcuts portal. GNOME and KDE Plasma
   show a one-time permission dialog that must be accepted. wlroots-based
   compositors (Sway, Hyprland, ...) have no GlobalShortcuts portal backend,
   so the hotkey is unavailable there; unset `CLAUDE_USE_WAYLAND` to fall back
   to XWayland
4. With xdg-desktop-portal ≥ 1.20, a log line such as `App info not found`
   from the portal means the app id has no desktop entry. The RPM installs
   `claude-desktop.desktop`; the AppImage launcher writes
   `~/.local/share/applications/io.github.presire.claude-desktop-suse.desktop`
   on native Wayland (look for `Wrote portal app-id entry` in the launcher
   log). A file with that name that the launcher did not write is left in
   place (`Left portal app-id entry ... in place`)

See [CONFIGURATION.md](CONFIGURATION.md) for more details on the `CLAUDE_USE_WAYLAND` environment variable.

### Tray icon is black on a dark Cinnamon panel

Upstream picks `TrayIconLinux.png` (black glyph) or `TrayIconLinux-Dark.png` (white glyph) from the GTK colour scheme and a GNOME check. Cinnamon often pairs a dark panel with a light GTK scheme, so the black glyph lands on a dark tray.

The launcher auto-detects Cinnamon themes whose name contains `dark` (via `gsettings get org.cinnamon.theme name`) and sets `CLAUDE_TRAY_USE_DARK_ICON=1`. Override it manually if needed:

```bash
# force the white glyph (dark panels)
CLAUDE_TRAY_USE_DARK_ICON=1 claude-desktop

# force the black glyph (light panels)
CLAUDE_TRAY_USE_DARK_ICON=0 claude-desktop
```

Persist either value in `~/.config/claude-desktop-suse/environment`. `claude-desktop --doctor` reports which mode is in effect (preset, Cinnamon auto-detect, or upstream selection). See [Tray Icon](CONFIGURATION.md#tray-icon-claude_tray_use_dark_icon).

### Taskbar shows a duplicate or generic icon (#779)

Chromium/Electron sets the X11 `WM_CLASS` and Wayland `app_id` from the asar
`package.json` `desktopName`, not from the launcher's `--class` argument. The
desktop entry's `StartupWMClass` must therefore be that value without the
`.desktop` suffix: `claude-desktop` for the RPM and
`io.github.presire.claude-desktop-suse` for the AppImage. A custom desktop
override copied from an older release with `StartupWMClass=Claude` will show a
second, ungrouped taskbar icon; update the line to match your format.

### "Run on startup" starts the wrong install or nothing at all

The app writes `~/.config/autostart/claude-desktop.desktop` (under
`$XDG_CONFIG_HOME` when set). On every start the launcher checks its `Exec`
command: when that command ends in `/claude-desktop` and no longer exists
or is not executable (for example an unmounted AppImage
`/tmp/.mount_claude*` path, or a removed package), it is rewritten to the
current launcher and `launcher.log` records
`Healed autostart Exec: <old> -> <new> (AUTO-1)`. A command that still
runs, such as the RPM's `/usr/bin/claude-desktop` seen from an AppImage
launch, is left alone and logged as `still runs; leaving it`. To move
"Run on startup" to a different install, toggle the setting off and on
again from that install.

### Claude offers to attach `app.asar` or opens in Cowork mode

The bundled Electron loads `resources/app.asar` on its own, so the
launchers no longer pass that path on the command line. When it was
passed, Electron handed it to the app as a file to open, which showed an
"attach `app.asar`" prompt or reopened the window in Cowork mode. The
RPM launcher still passes the path only when it falls back to an
`electron` found on `PATH`, because that binary boots its own default app
otherwise. If you see the prompt, check that a custom wrapper or
`.desktop` override is not adding `app.asar` to the command line.

### AppImage Does Not Start (FUSE)

The AppImage uses the static type2 runtime, so it does **not** need `libfuse2`.
It needs the `fusermount3` helper and access to `/dev/fuse`:

```bash
sudo zypper install fuse3
```

Where FUSE is unavailable (containers, some hardened hosts), run it without
mounting:

```bash
./claude-desktop-*.AppImage --appimage-extract-and-run
```

### AppImage Sandbox Warning

The AppImage runs from a nosuid FUSE mount, so Electron's setuid
`chrome-sandbox` helper cannot work there. Chromium's user-namespace
sandbox is used instead, and the launcher probes at startup whether
unprivileged user namespaces actually work: it checks
`user.max_user_namespaces`, `kernel.unprivileged_userns_clone` and
`kernel.apparmor_restrict_unprivileged_userns`, then tries to create the
namespaces Chromium's zygote needs.

- Namespaces work: the AppImage keeps the Chromium sandbox enabled.
- Namespaces are blocked (hardened kernel, container seccomp, AppArmor
  userns restriction): the launcher adds `--no-sandbox` and logs
  `Chromium sandbox disabled: <reason>` to
  `~/.cache/claude-desktop-suse/launcher.log`.
- `CLAUDE_FORCE_SANDBOX=1` keeps the sandbox enabled even when the probe
  reports a block (the launcher logs a warning). Chromium may then abort
  on launch, so use it only while fixing the namespace restriction.

Run `claude-desktop --doctor` to see which case applies: the
`Chrome sandbox:` lines report the probe reason or that the namespace
sandbox is engaged. If the probe reports a blocking sysctl, adjust it in
`/etc/sysctl.d/` and apply with `sudo sysctl --system`.

For enhanced security when userns is permanently unavailable, consider
using the .rpm package instead, or running the AppImage within a
separate sandbox (e.g. bubblewrap).

### Authentication Errors (401)

If you encounter recurring "API Error: 401" messages after periods of inactivity, the cached OAuth token may need to be cleared. This is an upstream application issue reported in [#156](https://github.com/aaddrick/claude-desktop-debian/issues/156).

To fix manually (credit: [MrEdwards007](https://github.com/MrEdwards007)):

1. Close Claude Desktop completely
2. Edit `~/.config/Claude/config.json`
3. Remove the line containing `"oauth:tokenCache"` (and any trailing comma if needed)
4. Save the file and restart Claude Desktop
5. Log in again when prompted

A scripted solution is also available at the bottom of [this comment](https://github.com/aaddrick/claude-desktop-debian/issues/156#issuecomment-2682547498).

## Uninstallation

### For .rpm packages (openSUSE/SUSE)

```bash
# Remove package
sudo zypper remove claude-desktop
# Or: sudo rpm -e claude-desktop
```

### For AppImages

1. Delete the `.AppImage` file
2. Remove the `.desktop` file from `~/.local/share/applications/`, including
   the hidden `io.github.presire.claude-desktop-suse.desktop` portal alias
3. If using Gear Lever, use its uninstall option

### Remove user configuration (all formats)

```bash
rm -rf ~/.config/Claude
```
