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
| `CLAUDE_DISABLE_GPU` | unset | Set to `1` to disable hardware acceleration. Workaround for Chromium GPU process FATAL crashes (#583). Auto-recovers on next launch after a GPU FATAL is detected in the launcher log. |
| `CLAUDE_PASSWORD_STORE` | unset (auto-detect) | Override Chromium's `--password-store` backend. When unset, the launcher probes D-Bus for `kwallet6` (KDE Plasma 6) or `gnome-libsecret` (GNOME Keyring) and selects the working keyring automatically. Fixes session persistence on desktops where Electron's `safeStorage` reports encryption unavailable (#593). |
| `CLAUDE_QUIT_ON_CLOSE` | unset | Set to `1` to make window close actively quit the app via `app.quit()` instead of hiding to tray. Rides upstream's own quit-in-progress guard. |
| `CLAUDE_KEEP_AWAKE` | unset | Set to `0` to suppress the `powerSaveBlocker` sleep inhibitor that upstream holds indefinitely on Linux (no lifecycle management). Useful on laptops where Claude Desktop prevents sleep. |
| `CLAUDE_GTK_IM_MODULE` | unset | Override `GTK_IM_MODULE` for Electron only. Useful when IBus integration breaks input (#549). |

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

**Note:** On GNOME 50 / xdg-desktop-portal ≥ 1.20 the portal route is currently a no-op because Electron/Chromium doesn't perform the new host `Registry.Register` app-id handshake (filed upstream as electron/electron#51875). On those versions, prefer `CLAUDE_USE_WAYLAND=0` or unset.


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
