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
| Device registry | Local Cowork registration record (`pk1:` device-key row, keyless `keyless:`/`kl1:` pair, pending `pku1:`, or stale `none:`); informational only and never prints identifiers |
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

Files the nupkg ships in `app.asar.unpacked` other than `.node` modules stay
unpacked after the repack (`Upstream unpacked files kept unpacked: N`).
On Linux, the built-in GitHub MCP server ships only as a Windows PE executable
(`resources/github-mcp/github-mcp-server.exe`), so `patch_pe_sidecar_linux_guard`
fails fast with an explicit unsupported-on-Linux error instead of trying to
spawn the `.exe`. `CLAUDE_DESKTOP_GITHUB_MCP_BINARY` can point at a Linux
binary, but it only takes effect in unpackaged development builds
(`!app.isPackaged`); packaged RPM/AppImage builds ignore it. Microsoft 365's
Windows native runtime
(`msal-node-runtime.node`) is pruned during staging and its `.mjs` entry point
catches the missing module cleanly without loading `msalruntime.dll`.
`Repack invariance check FAILED: upstream unpacked file was packed into
app.asar: <path>` means `asar pack` ignored that entry of the `--unpack` set;
`... is missing from app.asar.contents: <path>` means the extracted tree no
longer has the file, so the repack cannot place it; `... contains glob syntax`
means the name cannot be expressed in the `--unpack` set. Recheck the asar
CLI version (`ASAR_PINNED_VERSION`) and the pinned nupkg layout.

### Build stops with `Tripwire (FM-1)` or `JS parse check`

`Tripwire (FM-1): <piece> is gone from the bundle` means the pinned release
changed how it writes the "Send to Claude" / "Open in Claude Code" entries.
`heal_file_manager_entries` finds those entries by that shape, so it would
silently stop repairing them. Re-check `patch_file_manager_entries_linux`
and the launcher heal against the new bundle, then update the tripwire.

`JS parse check: the patch stage left unparsable JavaScript:` lists each
`.vite/build` file a patch changed or added that `acorn@8.19.0` cannot
parse. Fix the patch that wrote it; the bundle would otherwise fail only
when Electron loads that chunk.

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

### Build stops with `Linux file-manager entry patch failed`

Read the preceding `ERROR` line. The patch requires build-only
`acorn@8.19.0` and a known, unambiguous generator shape. Build setup installs
and verifies that version; standalone Bats runs need the prerequisite in
[Building](BUILDING.md#nodejs-and-asar).

`cannot parse main-process JS`, `cannot parse the file-manager` or
`incomplete or ambiguous file-manager serialization` means the patch could
not establish the executable function, its unique Exec/TryExec entries, or
the complete applied transformation. It leaves the input chunk unchanged.
Recheck the Windows pin and update the anchored transformation with a
regression fixture; do not bypass the parser or the output check. Node 22's
lack of `using` support does not disable this validation.

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

Cloud tasks use a device registration so the remote-tools bridge can reach the
machine. This build replaces the Windows `@ant/claude-native` module with a
JavaScript stub, so the Windows-native device-key path is unavailable. The
pinned bundle still recognises a keyless local registration row
(`keyless:<uuid>` → `kl1:<uuid>`) alongside the other row types. `--doctor`
reports the state it finds in `~/.config/Claude/ant-device-registry.json`:

- `Device registry: registered (device key present)` — a `pk1:` device-key row
  exists.
- `Device registry: local registration record present (keyless)` — a keyless
  `keyless:<uuid>` → `kl1:<uuid>` pair exists. This says only that the local
  registration record is on disk; it does not prove the registration was
  accepted.
- `Device registry: device key not yet confirmed by the server` — only a
  `pku1:` pending row exists.
- `Device registry: not registered` — the file holds only stale `none:` rows.
  Existing on-device sessions keep working; new cloud tasks may show "Not
  linked to a computer" until the device is linked again. When the file
  contains no recognized row at all (for example an empty `{}`, or a corrupt
  or otherwise unrecognized entry), nothing is printed for it.
- `Device registry: cannot verify without python3 or node` — no JSON parser is
  available, so the check does not guess whether the file holds a registration.

Only a **top-level** `keyless:<uuid>` key whose value is exactly `kl1:<uuid>`
with lowercase hexadecimal UUIDs (matching upstream `bYa()`) counts. A
half-written pair, a `kl1:` value under another key, a pair nested inside an
object, and a corrupt file are all ignored, and precedence is `pk1:` → keyless
pair → `pku1:` → `none:`.

The check is informational only: it never changes the doctor exit status,
never prints the file or any account ID/UUID/key from it (it contains account
identifiers) and never edits it. Nothing is shown when the file does not exist
(Cowork not used yet).

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
   (Note: the global hotkey then depends on the XDG GlobalShortcuts
   portal and compositor support; see
   [Global Hotkey Not Working (Wayland)](#global-hotkey-not-working-wayland).)

### Cowork on AppArmor-blocked Systems (#351)

On distributions with AppArmor that block unprivileged user namespaces
(e.g., some hardened openSUSE configurations), the bwrap sandbox probe may
fail. `--doctor` will report this with an AppArmor hint.

**Workaround:** Create a local AppArmor profile that allows user namespaces
for bwrap. See the upstream [AppArmor workaround documentation](https://github.com/aaddrick/claude-desktop-debian/issues/351)
for the exact profile content.

### Cowork KVM backend falls back to virtio-9p (virtiofsd not found)

The KVM backend shares the home directory through `virtiofsd` when the
binary is available and falls back to QEMU's built-in virtio-9p otherwise
(lower performance). `virtiofsd` usually lives outside `PATH`
(`/usr/libexec/virtiofsd`, `/usr/lib/qemu/virtiofsd`, or
`/usr/lib/virtiofsd`), so the daemon probes those absolute paths after
`PATH`; no symlink is needed.

Install the package and re-run the doctor:

```bash
sudo zypper install virtiofsd
claude-desktop --doctor
```

The doctor uses the same probe order and prints
`virtiofsd: found at <path>`. A missing binary is only a warning when
`COWORK_VM_BACKEND=kvm` selects the KVM backend; otherwise it is
informational. If `COWORK_VM_VIRTIOFSD_BIN` is set, it must point at an
executable file: the daemon does not fall back to other locations in that
case.

### Cowork disk cleanup is empty on the host and bwrap backends

`getSessionsDiskInfo`, `deleteSessionDirs` and `pruneSessionCaches` are
RPCs the Windows client uses for VM session images. The host and bwrap
backends have no session images, so they report the home filesystem's
`totalBytes`/`freeBytes` with `sessions: []`, and the delete/prune calls
return empty results. This is expected, not a failed cleanup.

The KVM backend does not forward these calls: the guest sdk-daemon
wire protocol is unverified, so each one fails explicitly with
`handler not registered: <method> (unsupported on KVM backend: guest
wire protocol unverified)`. The daemon does not invent a guest reply.
The `handler not registered:` prefix is deliberate: the Windows client
only classifies a reply as `unsupported` when it starts with that marker
(or `unknown method:`), so dropping it turns an optional cleanup into a
hard error even though the explanation is still present. KVM session
directories are removed by `stopVM` regardless of these RPCs.

### Cowork reports `unsupported` for EDR and proxy refresh

The daemon does not register `runEdrExtension`, and `refreshGuestProxy`
is not a method in this build. The client maps the daemon's
`handler not registered: runEdrExtension` and
`unknown method: refreshGuestProxy` replies to its `unsupported`
outcome, so Cowork continues without the Windows EDR extension or proxy
refresh. The exact lowercase `unknown method: <name>` text is part of that
contract; changing its case makes the client treat the reply as a hard
failure.

### Cowork stays responsive while the VM starts

The daemon parses every length-prefixed frame synchronously and dispatches
each request independently, so a slow `startVM` no longer blocks later
requests on the same connection. Replies still carry the original request
`id`; clients that pipeline requests can match them in any order.

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

### File-manager actions do nothing or show no icon

Claude Desktop's Nautilus scripts and Dolphin service menus are generated by
the app. The SUSE build enables this Linux generator and patches it so
startup-generated `Exec=` and `TryExec=` values are already serialized for the
Desktop Entry format. On every start, and again after Electron exits, the
launcher also rewrites generated entries so they call the installed launcher
instead of the raw Electron binary or a `/tmp/.mount_*` AppImage path that
disappears when the app quits. Paths with quotes, dollar signs, or backslashes
are handled by the same escaping rules, including when the launcher later
repairs the entry. "Send to Claude" menus keep their Nautilus script
reference; the script's launcher path is repaired separately.

The repair pass recognizes this installation's own application tree from the
location of `launcher-common.sh`, so a non-default RPM prefix such as
`/usr/lib64` works and another live RPM or AppImage installation is left
alone. Entries whose target no longer exists are repaired regardless of which
installation created them.

Check `~/.cache/claude-desktop-suse/launcher.log` for
`Healed file-manager entry ... (FM-1)`. Only entries carrying
`X-Claude-Generated=true` are changed; files you created in
`~/.local/share/nautilus/scripts`, `~/.local/share/kio/servicemenus`, or
`~/.local/share/kservices5/ServiceMenus` are left alone. If an action was
generated by an older release and lacks the marker, remove and re-create it
from Claude Desktop's settings.

`claude-desktop --doctor` lists the generated entries and warns when an
entry's launcher target no longer exists, a SendTo menu's Nautilus script is
missing, an entry cannot be parsed, or the icon named by `Icon=` is not
installed in either the user or system theme. Starting and quitting Claude
through the launcher once repairs the entries and installs the icon.

When a service menu is present, the launcher installs the icon named in its
`Icon=` line (normally `electron.png`) into
`~/.local/share/icons/hicolor/256x256/apps/`. An icon you placed at that
path yourself is never overwritten. KDE caches service menus; if Dolphin
still shows the old entry, run `kbuildsycoca6` (Plasma 6) or
`kbuildsycoca5` (Plasma 5) and reopen Dolphin.

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
