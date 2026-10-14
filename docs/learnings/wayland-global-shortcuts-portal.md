[< Back to learnings](./)

# Wayland global shortcuts via the XDG GlobalShortcuts portal

Quick Entry's global hotkey (`Ctrl+Alt+Space`) is focus-bound on modern GNOME Wayland; the native-Wayland path routes it through the XDG GlobalShortcuts portal (a merged `--enable-features=…,GlobalShortcutsPortal`), opt-in on GNOME via `CLAUDE_USE_WAYLAND=1` — which fixes GNOME ≤ 49. GNOME 50 / xdg-desktop-portal ≥ 1.20 was blocked by an upstream Electron gap ([electron/electron#51875](https://github.com/electron/electron/issues/51875)), fixed in Chromium 152 / Electron 44, the major this build pins ([D-004](../DECISIONS.md)). The upstream GNOME 50 retest ([claude-desktop-debian#805](https://github.com/aaddrick/claude-desktop-debian/issues/805)) showed that fix is necessary but not sufficient: the portal also needs an installed `<app-id>.desktop`. Here the RPM ships it and the AppImage launcher writes a hidden one ([§ The desktop-id gate](#the-desktop-id-gate-gnome-50-retest-805)); neither has been retested on an openSUSE GNOME 50 session.

## The problem (#404)

Upstream registers Quick Entry's hotkey with a raw `globalShortcut.register()` (build-reference `index.js:499416`) and has no portal fallback. On X11 that becomes an X11 key grab. The launcher historically defaulted *every* Wayland session to XWayland (`--ozone-platform=x11`) precisely so that grab would keep working.

That stopped working on GNOME. mutter (GNOME ≥ 49) no longer honours XWayland-side global key grabs, so the grab only fires when the Claude window already has focus — the opposite of "open Claude from everywhere." The symptom is intermittent (a brief compositor state can make it appear to work, then it stops), which sent more than one reporter chasing ghosts.

## The launcher change (necessary, not sufficient)

Electron ≥ 35 exposes Chromium's `GlobalShortcutsPortal` feature; this build installs Electron 44 (`electron_major` in `scripts/setup/dependencies.sh`, tracking the major in the Windows `.nupkg` per D-004). Under the **native Wayland ozone platform** the feature is *supposed* to route `globalShortcut.register()` through the `org.freedesktop.portal.GlobalShortcuts` D-Bus interface instead of an X11 grab. So `build_electron_args` adds `GlobalShortcutsPortal` to the native-Wayland feature set.

GNOME Wayland is **not** auto-flipped to native Wayland. `detect_display_backend` still only auto-forces Niri (no XWayland at all). The reason: GNOME Wayland is the default session for a large slice of users, and moving it off mature XWayland is a rendering / IME / HiDPI / fractional-scaling risk — shipped on argv-only verification, and through Electron 43 the portal route was a no-op on GNOME 50 anyway. GNOME users opt in with `CLAUDE_USE_WAYLAND=1`, which works after the one-time portal dialog: on GNOME ≤ 49 as-is, and on GNOME 50 once the app id resolves to an installed entry (upstream-verified, see below). Auto-selecting native Wayland on GNOME is deferred to a follow-up gated on a real "still renders correctly" check, not just "the flag reached argv."

KDE/Sway/Hyprland likewise stay on XWayland by default (opt in with `=1`).

## Two traps that bite

- **`GlobalShortcutsPortal` is inert under XWayland.** The feature lives in Chromium's ozone/wayland layer. Passing the flag while `--ozone-platform=x11` does nothing. The flag and `--ozone-platform=wayland` are a package deal — that's why the launcher flips the backend, not just appends a flag.

- **Chromium honours only the *last* `--enable-features=` switch.** Two separate `--enable-features=A` `--enable-features=B` on one command line silently drops `A`. `build_electron_args` can need two sets (`WindowControlsOverlay` for hidden titlebars; `UseOzonePlatform,WaylandWindowDecorations,GlobalShortcutsPortal` for native Wayland), so it accumulates into one `enable_features` array and emits a single comma-joined `--enable-features=` at the end.

## Why GNOME 50 was broken through Electron 43 — and how it was proven

This is the upstream diagnosis record. On Fedora 44 / GNOME 50.2 / xdg-desktop-portal **1.21.2**, `globalShortcut.register()` returned `false` and the portal was **never contacted** (no `CreateSession`, no `BindShortcuts`). The feature flag had zero observable effect:

| ozone backend | `GlobalShortcutsPortal` flag | `register()` | portal `CreateSession` |
|---|---|---|---|
| wayland | enabled | `false` | 0 |
| wayland | default (no flag) | `false` | 0 |
| wayland | disabled | `false` | 0 |
| x11 (XWayland) | enabled | `true` | 0 (X11 grab; mutter ignores it → focus-bound, the #404 symptom) |

Reproduced identically on Electron **40.6.1, 41.5.0, 41.7.1, and 42.3.3** (latest at the time), with the relevant app-id fixes already present (electron#49988 → backported to `41-x-y` via #50051). So the Electron *version* was not the variable.

**Root cause (pinned to source on both sides):** xdg-desktop-portal grew a host-app identity step — non-sandboxed apps must call `org.freedesktop.host.portal.Registry.Register(app_id)` (added in **1.20**, commit `8fd5bdd5ec`), and GlobalShortcuts `CreateSession` now hard-rejects an empty app id (`src/global-shortcuts.c` `handle_create_session()` → `NOT_ALLOWED "An app id is required"`, added in **1.21.0**, commit `38dd2c03f2`). Chromium did not make that call in the normal case: `components/dbus/xdg/portal.cc` `PortalRegistrar::OnServiceChecked()` only called `Register()` when starting its transient systemd scope *failed* — when the scope started (`kUnitStarted`, the usual path; the browser creates `app-<id>-<pid>.scope`) it skipped `Register()`, assuming the portal derives the app id from the scope. On portal 1.21 that derivation is gone, so the connection had an empty app id and `CreateSession` (issued from `ui/base/accelerators/global_accelerator_listener/global_accelerator_listener_linux.cc`) was rejected. Confirmed on plain Chromium 151 (HEAD) and Chrome 149, not just Electron.

**Proof the portal itself works** — a ~60-line Python client that performs the missing `Registry.Register` call (reverse-DNS app id backed by a `.desktop` file, launched in a matching `app-<id>.scope` via `systemd-run --user --scope`) drives the whole flow and receives `Activated` from an *unfocused* window:

```
Registry.Register('com.example.GsPortalProof') OK
CreateSession OK
BindShortcuts OK -> id='open-quick-entry' trigger='Press <Control><Alt>space'
*** ACTIVATED *** (press #1)   *** ACTIVATED *** (press #2)
```

Secondary gate: GNOME's backend also discarded an id that was neither reverse-DNS nor backed by an installed `.desktop` (`gnome-control-center-global-shortcuts-provider: Discarded shortcut bind request … invalid app_id >gsportalproof<`). The id Chromium registers is not the executable name but the asar `desktopName` minus `.desktop`, and `scripts/patches/app-asar.sh` sets that per format:

| Format | `desktopName` | Registered app id | Installed entry |
|---|---|---|---|
| RPM | `claude-desktop.desktop` | `claude-desktop` | `/usr/share/applications/claude-desktop.desktop` |
| AppImage | `io.github.presire.claude-desktop-suse.desktop` | `io.github.presire.claude-desktop-suse` | none until the launcher writes one |

The AppImage id is reverse-DNS. The RPM id has an installed entry but no dot (the name is kept for KDE Plasma window grouping, #562); whether GNOME 50's backend accepts it is untested.

Why it works on GNOME ≤ 49: older xdg-desktop-portal derived the app id from the systemd scope automatically and did not require `Registry.Register`.

Filed upstream: [electron/electron#51875](https://github.com/electron/electron/issues/51875) and the underlying Chromium bug at [crbug 520262204](https://issues.chromium.org/issues/520262204). **Resolved upstream:** Chromium CL 8102824 ("Register app ID with the portal even when a systemd scope started", 2026-07-20) shipped in Chromium 152; the Electron issue closed 2026-08-23 as fixed in Electron 44 with no cherry-pick to 42/43. This build installs Electron 44, so the gap above is history for what we ship.

## The desktop-id gate (GNOME 50 retest, #805)

Upstream retested 2026-09-29 on Ubuntu 26.04.1, GNOME Shell 50.1 (Wayland), xdg-desktop-portal 1.21.1, xdg-desktop-portal-gnome 50.0, Electron 44.4.3 / Chromium 152.0.7977.130, with `dbus-monitor` on the portal interfaces. Electron 44 does now call `Registry.Register` — and the portal refused it because no entry for the id was installed:

```
Registry.Register('com.anthropic.Claude')
  -> org.freedesktop.portal.Error.Failed: Could not register app ID: App info not found for 'com.anthropic.Claude'
GlobalShortcuts.CreateSession
  -> org.freedesktop.portal.Error.NotAllowed: An app id is required
BindShortcuts: never called.  Activated: 0.
```

xdg-desktop-portal ≥ 1.20 resolves the id through `GDesktopAppInfo`, so it accepts an id only when `<id>.desktop` is installed in the data dirs the portal sees. `gdbus call … org.freedesktop.host.portal.Registry.Register <id> '{}'` reproduces that without the app (an id with an installed entry returns `()`). With a hidden user-level `<id>.desktop` in place, the same run went through: `Register` OK, `CreateSession` OK, the GNOME permission dialog, `BindShortcuts` OK, `Activated` with another app focused, and no duplicate dash icon. The default XWayland launch stayed focus-bound, so `CLAUDE_USE_WAYLAND=1` remains the opt-in.

In this repo the id is ours to choose (`app-asar.sh` writes `desktopName`; Electron's init sets `CHROME_DESKTOP` from it, overriding any launcher env), and `tests/launcher-prelaunch-calls.bats` fails if the id a launcher passes stops matching it. The RPM therefore already ships the entry the portal needs. The AppImage has no install step, so `ensure_portal_app_id_entry` (`scripts/launcher-common.sh`) runs after `detect_display_backend` in both launchers and:

- writes `$XDG_DATA_HOME/applications/<id>.desktop` (`NoDisplay=true`, `Exec=<launcher> %u`, `MimeType=x-scheme-handler/claude;`, no `StartupWMClass`, marker `X-Claude-Desktop-Suse-Portal-Alias=true`) only on native Wayland and only when no `<id>.desktop` exists in `XDG_DATA_DIRS`. On the RPM the system entry exists, so the call writes nothing. Once written, the entry becomes the `claude://` handler: the app calls `setAsDefaultProtocolClient('claude')` on every startup, which points `x-scheme-handler/claude` at `<id>.desktop` in `~/.config/mimeapps.list`. Without `%u`, GIO launches (the browser's sign-in callback) drop the URL and sign-in never finishes (upstream #916); ask `gio mime x-scheme-handler/claude`, not `xdg-mime query default`. Because that `mimeapps.list` line outlives the native Wayland launch, an existing marked entry is kept current on any backend;
- deletes its own marked entry as soon as a system entry for the id appears, so it stops shadowing it (a user-data-dir file wins over a system one with the same id);
- leaves any other entry in place and logs `Left portal app-id entry … in place`, except an app-generated entry (`X-Claude-Generated=true`) whose `TryExec` no longer resolves, e.g. a rotated AppImage mount path. GLib rejects such an entry, so the portal would again answer `App info not found`; `_portal_entry_is_stale_generated` treats it as dead and replaces it.

## Side effect: the Secret portal `app_id` (#913)

`Registry.Register` is not scoped to GlobalShortcuts. Chromium 152 calls it once per launch, under `--ozone-platform=x11` as well, and its `os_crypt` `SecretPortalKeyProvider` then calls `org.freedesktop.portal.Secret.RetrieveSecret` from the same D-Bus connection. So the desktop-id gate above also decides which key gnome-keyring hands out. Applied to this repo's ids (derived from the upstream measurements and the launcher logic, not measured on openSUSE):

| Launch | `<id>.desktop` | `Register` | Secret portal `app_id` |
|---|---|---|---|
| RPM, any backend | `/usr/share/applications/claude-desktop.desktop` | OK | `claude-desktop` |
| AppImage, XWayland, never launched on native Wayland | absent | `App info not found` | `""` |
| AppImage, native Wayland (`CLAUDE_USE_WAYLAND=1`) | written by `ensure_portal_app_id_entry` | OK | `io.github.presire.claude-desktop-suse` |
| AppImage, XWayland after one native-Wayland launch | still present (the launcher no-ops on X11) | OK | `io.github.presire.claude-desktop-suse` |

gnome-keyring keys the portal secret on the `app_id`, so each value gets its own `org.freedesktop.portal.Secret` item ("Application key for <id>") with a different random secret. The empty-`app_id` item is shared by every unregistered host app. The RPM and the AppImage share `~/.config/Claude` but register different ids, so switching formats also switches portal keys.

Upstream measured the flip as harmless (2026-10-03; xdg-desktop-portal 1.21.1, gnome-keyring 50, Electron 44.4.3): portal init succeeds (`os_crypt.portal.prev_init_success: true` in `Local State`), yet cookies are still written with the `v11` prefix (the libsecret `Claude Safe Storage` key), and Electron `safeStorage` uses that same libsecret item. All persistent claude.ai cookies survived an `""` → id → `""` round trip with unchanged `creation_utc`. The binary carries a `kSecretPortalKeyProviderUseForEncryption` feature, which appears off in that build.

**Re-check on Electron bumps.** If Chromium starts encrypting with the portal key (`v12` cookies), any `app_id` change (the first `CLAUDE_USE_WAYLAND=1` AppImage launch, or switching between the RPM and the AppImage) makes existing cookies undecryptable and costs one re-login at that launch. With the app closed, `sqlite3 ~/.config/Claude/Cookies "SELECT DISTINCT substr(encrypted_value, 1, 3) FROM cookies"` printing only `v11` means the portal key is still unused for encryption.

How upstream tested it: a private `dbus-run-session` running its own `gnome-keyring-daemon --unlock` and `xdg-desktop-portal -r`, a throwaway `HOME` and `XDG_*_HOME`, and the app launched directly; the `app_id` is the second argument of `org.freedesktop.impl.portal.Secret.RetrieveSecret` in `dbus-monitor`. Two traps: on gnome-keyring 50 an empty unlock password creates no `login` collection, so both Chromium and the portal fall into `CreateCollection` prompts that open `gcr-prompter` dialogs on the real screen; and `XDG_RUNTIME_DIR` must be a short path (the keyring control socket hits the 108-byte socket-path limit). Let claude.ai set its own cookies and stop the app with SIGTERM to the main PID only, or the cookie store never flushes.

## First-run UX and escape hatch

When the portal path engages, GNOME shows a **one-time permission dialog** the first time the shortcut is registered; the user must accept it to bind the shortcut. Expected portal behaviour, not a bug. A dismissed or denied dialog persists in the portal permission store and later `globalShortcut.register()` calls then fail silently; clearing the stored decision with `flatpak permission-reset <app-id>` (`claude-desktop` or `io.github.presire.claude-desktop-suse`; the store is shared with non-Flatpak apps) should re-trigger the dialog on the next launch — untested here.

`CLAUDE_USE_WAYLAND` is tri-state: `1` forces native Wayland, `0` forces XWayland (skipping auto-detect), unset auto-detects. The `0` value is the escape hatch for a GNOME user who hits a native-Wayland rendering regression and wants the old XWayland behaviour back (losing global-shortcut-from-unfocused in the process).

## wlroots caveat (Niri / Sway / Hyprland)

The portal flag is harmless where the compositor's portal has no GlobalShortcuts backend, but does nothing useful there. wlroots' `xdg-desktop-portal-wlr` ships no GlobalShortcuts implementation, so on Niri `BindShortcuts` fails with `error code 5` (upstream's known-failing `S14` detector).

## Tests / anchors

- `tests/launcher-common.bats` — `detect_display_backend` (XWayland default, `CLAUDE_USE_WAYLAND=1`, Niri auto-force) and `build_electron_args` native-Wayland cases. No test pins `GlobalShortcutsPortal` or the single merged `--enable-features=` yet.
- `tests/launcher-common.bats` — `ensure_portal_app_id_entry` cases: write on native Wayland, no-op on X11/XWayland, own alias kept current on any backend and not rewritten when unchanged, system entry removes own alias, foreign entries untouched, stale app-generated entry replaced, empty launcher or id is a no-op.
- `tests/launcher-prelaunch-calls.bats` — pins the call in both launchers after `detect_display_backend` and checks the id against `desktopName` in `scripts/patches/app-asar.sh`.
- Upstream-only detectors: `tools/test-harness/src/runners/S12_global_shortcuts_portal_flag.spec.ts`, `S14_quick_entry_from_other_focus_niri.spec.ts` in `claude-desktop-debian`.
- Upstream blockers (both resolved, fixed in Electron 44 / Chromium 152): [electron/electron#51875](https://github.com/electron/electron/issues/51875), Chromium [crbug 520262204](https://issues.chromium.org/issues/520262204).
