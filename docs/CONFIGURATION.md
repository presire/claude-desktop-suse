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
| `CLAUDE_TITLEBAR_STYLE` | `hybrid` | Titlebar mode: `hybrid` (OS frame + in-app topbar), `native` (OS frame only), `hidden` (frameless + WCO, broken on X11). See [Titlebar Style](#titlebar-style) below. |
| `CLAUDE_QUIT_ON_CLOSE` | unset | Set to `1` to quit the app when the window is closed instead of hiding to tray. |
| `CLAUDE_USE_WAYLAND` | unset | Set to `1` to use native Wayland instead of XWayland. Note: Global hotkeys won't work in native Wayland mode. |
| `CLAUDE_MENU_BAR` | unset (`auto`) | Controls menu bar behavior: `auto` (hidden, Alt toggles), `visible` / `1` (always shown), `hidden` / `0` (always hidden, Alt disabled). See [Menu Bar](#menu-bar) below. |
| `CLAUDE_WCO_NATIVE` | unset | Set to `1` to skip WCO shim overrides for diagnostic A/B testing against unmodified Chromium behavior. |

### Titlebar Style

Claude Desktop supports three titlebar modes via `CLAUDE_TITLEBAR_STYLE`:

| Value | OS Frame | In-app Topbar | Description |
|-------|----------|---------------|-------------|
| `hybrid` (default) | Yes | Yes | Native OS frame + in-app topbar (hamburger, sidebar, search, navigation). Recommended. |
| `native` | Yes | No | OS frame only. In-app topbar hidden by UA gate. Use if the topbar conflicts with your DE. |
| `hidden` | No | Yes | Frameless window with Window Controls Overlay. **Broken on X11** (topbar clicks unresponsive). |

```bash
# Use native mode (OS frame only, no in-app topbar)
CLAUDE_TITLEBAR_STYLE=native claude-desktop

# Or add to your environment permanently
export CLAUDE_TITLEBAR_STYLE=native
```

### Close-to-tray

By default, closing the main window hides it to the system tray instead of quitting the app. This keeps MCP servers, in-app schedulers, and the tray icon alive. To quit, use Ctrl+Q, the tray menu's "Quit" option, or File > Quit.

To restore the default Electron behavior (closing the window quits the app):

```bash
export CLAUDE_QUIT_ON_CLOSE=1
```

### Run on Startup (XDG Autostart)

The "Run on startup" toggle in Claude Desktop's settings writes an XDG Autostart entry to `~/.config/autostart/claude-desktop.desktop`. This is honoured by GNOME, KDE, XFCE, Cinnamon, MATE, LXQt, and other XDG-compliant desktop environments. AppImage users get the correct `Exec=` path automatically via `$APPIMAGE`.

### Wayland Support

By default, Claude Desktop uses X11 mode (via XWayland) on Wayland sessions to ensure global hotkeys work. If you prefer native Wayland and don't need global hotkeys:

```bash
# One-time launch
CLAUDE_USE_WAYLAND=1 claude-desktop

# Or add to your environment permanently
export CLAUDE_USE_WAYLAND=1
```

**Important:** Native Wayland mode doesn't support global hotkeys due to Electron/Chromium limitations with XDG GlobalShortcuts Portal. If global hotkeys (Ctrl+Alt+Space) are important to your workflow, keep the default X11 mode.

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
| `additionalROBinds` | `string[]` | Extra paths mounted read-only inside the sandbox. Accepts any absolute path except `/`, `/proc`, `/dev`, `/sys`. |
| `additionalBinds` | `string[]` | Extra paths mounted read-write inside the sandbox. **Restricted to paths under `$HOME`** for security. |
| `disabledDefaultBinds` | `string[]` | Default mounts to skip. Cannot disable critical mounts (`/`, `/dev`, `/proc`). Use with caution: disabling `/usr` or `/etc` may break tools inside the sandbox. |

### Security notes

- Paths `/`, `/proc`, `/dev`, `/sys` (and their subpaths) are always rejected
- Read-write mounts (`additionalBinds`) are restricted to paths under your home
  directory
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
