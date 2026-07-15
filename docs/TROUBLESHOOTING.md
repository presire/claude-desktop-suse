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
| Installed version | Package version via rpm |
| Display server | Wayland/X11 detection and mode |
| Input method | IBus/GTK immodule sanity (ibus-gtk3 installed, cache fresh, XWayland routing note) |
| Electron binary | Existence and version |
| Chrome sandbox | Correct permissions (4755/root) |
| SingletonLock | Stale lock file detection |
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
`CLAUDE_DISABLE_GPU=0`.

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

If the global hotkey (Ctrl+Alt+Space) doesn't work, ensure you're not running in native Wayland mode:

1. Check your logs at `~/.cache/claude-desktop-suse/launcher.log`
2. Look for "Using X11 backend via XWayland" - this means hotkeys should work
3. If you see "Using native Wayland backend", unset `CLAUDE_USE_WAYLAND` or ensure it's not set to `1`

**Note:** Native Wayland mode doesn't support global hotkeys due to Electron/Chromium limitations with XDG GlobalShortcuts Portal.

See [CONFIGURATION.md](CONFIGURATION.md) for more details on the `CLAUDE_USE_WAYLAND` environment variable.

### AppImage Sandbox Warning

AppImages run with `--no-sandbox` due to electron's chrome-sandbox requiring root privileges for unprivileged namespace creation. This is a known limitation of AppImage format with Electron applications.

For enhanced security, consider:
- Using the .rpm package instead
- Running the AppImage within a separate sandbox (e.g., bubblewrap)
- Using Gear Lever's integrated AppImage management for better isolation

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
2. Remove the `.desktop` file from `~/.local/share/applications/`
3. If using Gear Lever, use its uninstall option

### Remove user configuration (all formats)

```bash
rm -rf ~/.config/Claude
```
