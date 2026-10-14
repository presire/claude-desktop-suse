[< Back to README](../README.md)

# Configuration

## MCP Configuration

Model Context Protocol settings are stored in:
```
~/.config/Claude/claude_desktop_config.json
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_USE_WAYLAND` | unset (auto-detect) | Tri-state: `1` forces native Wayland (Quick Entry hotkey routed via XDG GlobalShortcuts portal), `0` forces XWayland, unset auto-detects. See [Wayland Support](#wayland-support) below. |
| `CLAUDE_MENU_BAR` | unset (`auto`) | Controls menu bar behavior: `auto` (hidden, Alt toggles on keyup only), `visible` / `1` (always shown), `hidden` / `0` (always hidden, Alt disabled). See [Menu Bar](#menu-bar) below. |
| `CLAUDE_TITLEBAR_STYLE` | unset (`hybrid`) | Controls window decoration style: `hybrid` (system frame + in-app topbar), `native` (system frame, no in-app topbar), `hidden` (frameless WCO — broken on X11, kept for diagnostics). See [Titlebar Style](#titlebar-style) below. |
| `COWORK_VM_BACKEND` | unset (auto-detect) | Force a specific Cowork isolation backend: `kvm` (full VM), `bwrap` (bubblewrap namespace sandbox), or `host` (no isolation). See [Cowork Backend](#cowork-backend) below. |
| `CLAUDE_DISABLE_GPU` | unset (auto) | `1` passes `--disable-gpu` (software rendering through SwiftShader; the software rasterizer stays enabled so the window still paints). Unset: the launcher adds `--disable-gpu` automatically after a GPU FATAL is detected in the launcher log (#583) and on XRDP sessions. `0` suppresses both automatic triggers. |
| `CLAUDE_FORCE_SANDBOX` | unset | RPM only. Set to `1` to keep the Chromium sandbox enabled on Wayland, where the launcher otherwise passes `--no-sandbox`. Has no effect on the AppImage, which always runs with `--no-sandbox` because FUSE mounts drop the setuid bit of `chrome-sandbox`. `--doctor` reports whether the sandbox is engaged at runtime. |
| `CLAUDE_PASSWORD_STORE` | unset (auto-detect) | Override Chromium's `--password-store` backend. When unset, the launcher probes D-Bus for `kwallet6` (KDE Plasma 6) or `gnome-libsecret` (GNOME Keyring) and selects the working keyring automatically. Fixes session persistence on desktops where Electron's `safeStorage` reports encryption unavailable (#593). |
| `CLAUDE_QUIT_ON_CLOSE` | unset | Set to `1` to make window close actively quit the app via `app.quit()` instead of hiding to tray. Rides upstream's own quit-in-progress guard. |
| `CLAUDE_KEEP_AWAKE` | unset | Set to `0` to suppress the `powerSaveBlocker` sleep inhibitor that upstream holds indefinitely on Linux (no lifecycle management). Useful on laptops where Claude Desktop prevents sleep. |
| `CLAUDE_GTK_IM_MODULE` | unset | Override `GTK_IM_MODULE` for Electron only. Useful when IBus integration breaks input (#549). |

### Persistent Launcher Environment

GUI launches can read the supported launcher variables from:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/claude-desktop-suse/environment
```

Use one `KEY=value` entry per line. Blank lines and lines beginning with `#` are ignored; values already present in the environment take precedence, and keys outside the launcher allowlist are ignored. The supported keys are `CLAUDE_USE_WAYLAND`, `CLAUDE_PASSWORD_STORE`, `CLAUDE_GTK_IM_MODULE`, `CLAUDE_DISABLE_GPU`, `CLAUDE_TITLEBAR_STYLE`, `CLAUDE_MENU_BAR`, `CLAUDE_KEEP_AWAKE`, `CLAUDE_FORCE_SANDBOX`, and `COWORK_VM_BACKEND`.

Each applied key is recorded in the launcher log as `Config: KEY=value (from <file>)`, and each ignored key as `Config: ignoring unrecognized key 'KEY' in <file>`, so a misspelled key is visible. `claude-desktop --doctor` reads the same file, so its checks see the settings a GUI launch uses.

```text
# Persistent launcher settings
CLAUDE_TITLEBAR_STYLE=native
CLAUDE_MENU_BAR=visible
```

### Wayland Support

By default, Claude Desktop uses X11 mode (via XWayland) on Wayland sessions to ensure the global hotkey (Ctrl+Alt+Space) works through a standard X11 key grab. If you prefer native Wayland rendering:

```bash
# One-time launch
CLAUDE_USE_WAYLAND=1 claude-desktop

# Or add to your environment permanently
export CLAUDE_USE_WAYLAND=1
```

With `CLAUDE_USE_WAYLAND=1`, the Quick Entry hotkey is routed through the XDG GlobalShortcuts portal instead of an X11 grab, so it keeps working on native Wayland compositors that implement the portal (KDE Plasma Wayland, Sway, Hyprland). On GNOME Wayland the portal route works on GNOME ≤ 49 after a one-time permission dialog.

**`CLAUDE_USE_WAYLAND` is tri-state:**

- `1` — force native Wayland (portal-routed Quick Entry, native IME, `GDK_BACKEND=wayland` exported to fix XWayland blur on HiDPI)
- `0` — force XWayland (X11 key grab, classic Electron behavior)
- unset — auto-detect (XWayland by default for the safest rendering/IME path)

**Note:** xdg-desktop-portal ≥ 1.20 (GNOME 50 and newer KDE) only serves apps that register an app id through the host `Registry.Register` call, and refuses ids without an installed `<id>.desktop`. The build ships Electron 44, which registers the asar `desktopName` minus `.desktop` (electron/electron#51875): `claude-desktop` for the RPM (covered by `/usr/share/applications/claude-desktop.desktop`) and `io.github.presire.claude-desktop-suse` for the AppImage. On native Wayland the AppImage launcher writes a hidden alias `~/.local/share/applications/io.github.presire.claude-desktop-suse.desktop` (`NoDisplay=true`, Exec pointing at the AppImage, `x-scheme-handler/claude`). An alias the launcher wrote is kept current on later starts, removed again once a system entry with the same id exists, and a file the launcher did not write is never touched.


### Menu Bar

By default, the menu bar is hidden but can be toggled with the Alt key (`auto` mode). On KDE Plasma and other DEs where Alt is heavily used, this can cause layout shifts. Use `CLAUDE_MENU_BAR` to control the behavior:

| Value | Menu visible | Alt toggles | Use case |
|-------|-------------|-------------|----------|
| unset / `auto` | No | Yes | Default — hidden, Alt toggles |
| `visible` / `1` / `true` / `yes` / `on` | Yes | No | Stable layout, no shift on Alt |
| `hidden` / `0` / `false` / `no` / `off` | No | No | Menu fully disabled, Alt free |

```bash
# Always show the menu bar (no layout shift on Alt)
CLAUDE_MENU_BAR=visible claude-desktop

# Or add to your environment permanently
export CLAUDE_MENU_BAR=visible
```

### Titlebar Style

Claude Desktop's web UI includes a custom topbar (hamburger menu, sidebar toggle, search, back/forward, Cowork ghost). On Windows / macOS the bundle gates rendering on `display-mode: window-controls-overlay`; on Linux a shim convinces the bundle to render anyway. Use `CLAUDE_TITLEBAR_STYLE` to choose the layout:

| Value | Frame | In-app topbar | Window controls drawn by | Notes |
|-------|-------|--------------|--------------------------|-------|
| unset / `hybrid` | system | Yes | Desktop environment | **Default.** Stacked layout — DE-drawn titlebar on top, in-app topbar below. Topbar buttons clickable. |
| `native` | system | No | Desktop environment | When the stacked layout looks wrong on your DE, or you don't need the in-app topbar. |
| `hidden` | frameless | Yes | Chromium (WCO region) | Matches Windows / macOS upstream config. **Broken on Linux X11** — topbar buttons unresponsive due to a Chromium-level implicit drag region for `frame:false` windows. Kept for diagnostic / Wayland investigation. |

```bash
# Switch to the bare native experience (no in-app topbar)
CLAUDE_TITLEBAR_STYLE=native claude-desktop

# Or add to your environment permanently
export CLAUDE_TITLEBAR_STYLE=native
```

Run `claude-desktop --doctor` to confirm the resolved titlebar style. The doctor output also flags `hidden` mode as broken on Linux and unrecognized values as fallbacks to `hybrid`.

## Cowork Backend

Cowork mode auto-detects the best available isolation backend:

| Priority | Backend | Isolation | Detection |
|----------|---------|-----------|-----------|
| 1 | bubblewrap | Namespace sandbox | `bwrap` installed and functional |
| 2 | KVM | Full QEMU/KVM VM | `/dev/kvm` (r/w) + `qemu-system-x86_64` + `/dev/vhost-vsock` |
| 3 | host | None (direct execution) | Always available |

To override auto-detection:

```bash
# Force bubblewrap (recommended if KVM times out)
COWORK_VM_BACKEND=bwrap claude-desktop

# Force host mode (no isolation)
COWORK_VM_BACKEND=host claude-desktop

# Make permanent via desktop entry override
mkdir -p ~/.local/share/applications/
cat > ~/.local/share/applications/claude-desktop.desktop << 'EOF'
[Desktop Entry]
Name=Claude
Exec=env COWORK_VM_BACKEND=bwrap /usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF
```

Run `claude-desktop --doctor` to see which backend is selected and which dependencies are available.

## Cowork Sandbox Mounts

When using Cowork mode with the BubbleWrap (bwrap) backend, you can customize
the sandbox mount points via `~/.config/Claude/claude_desktop_linux_config.json`
(a dedicated config for the Linux port, separate from the official
`claude_desktop_config.json`):

```json
{
  "preferences": {
    "coworkBwrapMounts": {
      "additionalROBinds": ["/opt/my-tools", "/nix/store"],
      "additionalBinds": ["/home/user/shared-data"],
      "disabledDefaultBinds": ["/etc"]
    }
  }
}
```

| Key | Type | Description |
|-----|------|-------------|
| `additionalROBinds` | `(string \| {src, dst})[]` | Extra paths mounted read-only inside the sandbox. Accepts any absolute path except `/`, `/proc`, `/dev`, `/sys`. |
| `additionalBinds` | `(string \| {src, dst})[]` | Extra paths mounted read-write inside the sandbox. **`src` is restricted to paths under `$HOME`** for security; `dst` is unconstrained. |
| `disabledDefaultBinds` | `string[]` | Default mounts to skip. Cannot disable critical mounts (`/`, `/dev`, `/proc`). Use with caution: disabling `/usr` or `/etc` may break tools inside the sandbox. |

### Distinct host/sandbox paths (`{src, dst}` form)

By default a string entry like `"/opt/tools"` mounts the host path at the
*same* path inside the sandbox. To map a host directory to a different path
inside the sandbox, use the object form `{ "src": "...", "dst": "..." }`.

The most common use case is making `/tmp` persistent across Bash tool calls.
Each Bash invocation spawns a fresh `bwrap` with `--tmpfs /tmp` and
`--die-with-parent`, so the default `/tmp` is wiped between calls. Mapping a
host cache directory onto `/tmp` keeps state across calls without exposing the
host's real `/tmp`:

```json
{
  "preferences": {
    "coworkBwrapMounts": {
      "additionalBinds": [
        { "src": "/home/user/.cache/claude-tmp", "dst": "/tmp" }
      ],
      "disabledDefaultBinds": ["/tmp"]
    }
  }
}
```

`disabledDefaultBinds: ["/tmp"]` is required to remove the default
`--tmpfs /tmp` so the bind takes effect.

The string and object forms can be mixed freely in the same array.

> **Caution:** Mapping `dst` onto a default RO mount (`/usr`, `/etc`, `/bin`,
> `/sbin`, `/lib`, `/lib64`) silently replaces it inside the sandbox; you
> almost never want this, and `--doctor` will warn if you do.

### Security notes

- Paths `/`, `/proc`, `/dev`, `/sys` (and their subpaths) are always rejected
  for both `src` and `dst`
- For read-write mounts (`additionalBinds`), `src` must be under your home
  directory. `dst` has no `$HOME` constraint — that is the entire purpose of
  the object form (e.g. mapping onto `/tmp`)
- The core sandbox structure (`--tmpfs /`, `--unshare-pid`, `--die-with-parent`,
  `--new-session`) cannot be modified
- Mount order is enforced: user mounts cannot override security-critical
  read-only mounts
- Paths containing `..` segments are rejected. Symlinks are resolved the way
  the kernel will resolve them before the forbidden-path and `$HOME` checks,
  so a link under `$HOME` that points at `/etc` is rejected for read-write
  mounts
- The daemon never creates missing host directories outside `$HOME`; such a
  mount is skipped and logged instead

### Applying changes

The daemon reads the configuration at startup. After editing the config file,
restart the daemon:

```bash
pkill -f cowork-vm-service
```

The daemon will be automatically relaunched on the next Cowork session.

### Diagnostics

Run `claude-desktop --doctor` to see your custom mount configuration and any
warnings about potentially dangerous settings.

## Build Options

### Dark-mode Tray Icons (`--dark`)

By default, the tray icon is selected at runtime based on your desktop theme (`nativeTheme.shouldUseDarkColors`). If automatic detection does not work correctly for your environment, you can bake dark-mode icons (white, for dark panels) into the build:

```bash
./build.sh --dark
```

This replaces `TrayIconTemplate.png` (and `@2x`, `@3x` variants) with their `TrayIconTemplate-Dark.png` counterparts at build time, so the tray icon is always visible on dark system panels regardless of runtime theme detection.

## Application Logs

Runtime logs are available at:
```
~/.cache/claude-desktop-suse/launcher.log
```

Electron's stdout/stderr pass through a filter before reaching the log:
consecutive identical lines are collapsed into
`[launcher] last line repeated N more times`, and a single session stops
writing after `ELECTRON_LOG_CAP_BYTES` bytes (default 20 MiB) with a
`[launcher] output cap ... reached` marker, so a renderer stuck in an error
loop cannot fill the disk. The launcher's own lines are not capped.

> **Note:** Quit Claude Desktop (tray menu, **Quit**) before hand-editing
> `~/.config/Claude/claude_desktop_config.json`. The running app rewrites the
> file from its in-memory state, so edits made while it runs can be lost. The
> launcher keeps rotated backups of it in
> `~/.cache/claude-desktop-suse/config-backups/`.
