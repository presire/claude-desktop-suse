# Windows pin verification, 2026-11-11

The pin moved from `4.23118.0` to `5.1231.2`. Fresh x64 RPM, x64 AppImage and arm64 AppImage builds succeeded, the x64 AppImage passed the artifact suite apart from a launch-smoke SKIP, and the external harness passed 9/9 probes on the AppImage. RPM installation was not possible without root, and arm64 was not run on hardware. Both limitations are listed below. The previous pin's record is summarized in [DECISIONS.md D-005](DECISIONS.md).

| Check on the final code | Result | Exit code |
| --- | --- | --- |
| `bats tests` | 787 cases: 786 passed, 1 SKIP (`fetch-electron-binary` offline extraction needs the hardened extractor from a build tree; it passed in the x64 RPM build copy) | 0 |
| x64 RPM build | Built; 13 cowork patches applied; 15/15 markers; no WARNING | 0 |
| x64 AppImage build | Built; 13 cowork patches applied; 15/15 markers; no WARNING | 0 |
| arm64 AppImage cross build | Built; 13 cowork patches applied; 15/15 markers; no WARNING | 0 |
| Final `.vite/build/*.js`, Electron Node 24.22.2 `--check` | All 609 files parsed, for both architectures | 0 |
| x64 AppImage artifact suite, strict mode (`ARTIFACT_FAIL_ON_SKIP=1`) | 44 passed, 0 failed, 1 SKIP (launch smoke: `xvfb-run` is not installed on this host) | 1, from the SKIP only |
| x64 RPM artifact suite | 9 passed, 28 failed, 1 skipped. Header and payload checks passed; `rpm -ivh` failed with permission denied on `/usr/lib/sysimage/rpm/.rpm.lock` (no root), so install-dependent checks failed for environment reasons | Not zero |
| arm64 static checks | arm64 ELF `electron` 45.3.0 and node-pty `aarch64`; no runtime execution | 0 |
| x64 AppImage external harness | Nine probes passed, including window and tray | 0 |
| x64 RPM external harness | Four file probes passed; five launch probes skipped because the RPM is not installed | 77 |

## Scope and implementation

The bump moves the Windows `.nupkg` from Electron 44.9.3 to 45.2.1 (Chromium 156). Per D-004 the pin in `scripts/setup/dependencies.sh` moved to `electron@^45`, and the builds resolved 45.3.0. Two cowork patches stopped matching the new bundle and were fixed:

- **Patch 4b, auto-navigation suppression (#341).** Upstream `getDownloadStatus` became `async getDownloadStatus(){let e=await ...;return e!==X.NotDownloaded||...}`. The patch now also injects `if(process.platform==="linux")return X.NotDownloaded;` at the start of the async form. It is idempotent and still handles the legacy sync form. The marker regex in `scripts/cowork-patch-markers.tsv` accepts both forms. The async regex tolerates whitespace, and its callback replacement rewrites only the matched method and keeps `$` in the enum name verbatim.
- **`wvm-` tmpdir bundle-local proof.** The call-site regex counted the staging helper's own `function name(e,t){` definition as a call site. In the new bundle another async function that uses `.origin` sits right before it, so the proof failed. A lookbehind now excludes `function\s+`, and every other helper call except a file-name-only `basename(H(...))` must carry the origin proof, otherwise the result is a WARNING.

New fixtures in `tests/cowork-latest-patches.bats` cover the `5.1231.2` shapes, a byte-idempotent replay, a decoy async method with whitespace and a `$$` enum, and an unproven staging call far from the anchors. An independent review found the last three defects; their regressions failed on the earlier patch and pass now. The `tests/node-floor.bats` fixture now declares Electron 45.2.1. `_PATCH_EFFECT_ALLOWLIST` still has the same seven entries, and all seven were verified to still no-op on `5.1231.2`.

Electron 45 registers the tray StatusNotifierItem under its unique bus name (for example `:1.4007/StatusNotifierItem`) instead of `org.kde.StatusNotifierItem-<pid>-<n>`. The external harness `tray_sni` probe now falls back to resolving the unique name's owner PID through `org.freedesktop.DBus.GetConnectionUnixProcessID` and checks that PID is in the launch process group. The new case in `tests/external-harness.bats` failed against the old harness and passes now.

The Electron 45 breaking changes were reviewed: the sandboxed preload lost the `Buffer`, `setImmediate`, `events`, `timers` and `url` polyfills, `ipcRenderer` is a native `EventEmitter`, `window.open` children are sandboxed, and synchronous `safeStorage` is deprecated. `scripts/wco-shim.js` only requires `electron`, and `frame-fix-*.js` and `claude-native-stub.js` run in the main process, so no shim changed.

The source remains Anthropic's Windows `.nupkg`; no official Linux `.deb`, APT, Nix, AUR or Worker policy was imported. Low-level behavior stays in Bats; the external harness records only file probes and public L2 reachability.

## Inputs and artifacts

Both inputs were downloaded from the official Windows release endpoints for `5.1231.2`. Their SHA-1 and size matched the official `RELEASES` entries.

| Arch | Input size | Verified SHA-256 |
| --- | ---: | --- |
| x64 | 264,890,967 B | `2efd25c2ae8cd7150c2a4759b29877365d4c854a1b81f9934d71aba0ccb1ee87` |
| arm64 | 258,384,413 B | `0ace6e0b61f1ed3b6abeb4002ff1208a5244348d23b7eb4f9bf7cfa19a1642bc` |

The final artifacts are under `/tmp/cds-bump/final2/art/`.

| Artifact under `/tmp/cds-bump/final2/art/` | Size | SHA-256 |
| --- | ---: | --- |
| `x64-rpm/claude-desktop-5.1231.2-1.x86_64.rpm` | 187,186,421 B | `e94c2838fffc3c99c9b84aadbd2e45a3d9e029ceb16634c5d00f98c37023f40c` |
| `x64-appimage/claude-desktop-5.1231.2-amd64.AppImage` | 227,342,840 B | `63299b1340b31783728ddfc1440419c88841025e5c2f6adf84e289be3a0db7a2` |
| `arm64-appimage/claude-desktop-5.1231.2-arm64.AppImage` | 223,242,760 B | `f210d6d3c01c8793149460300fa43423c50899657923fc07799a3b3741dd1078` |

The builds ran in fresh source copies at `/tmp/cds-bump/final2/{x64-rpm,x64-appimage,arm64-appimage}/src`, with logs in `/tmp/cds-bump/final2/{x64-rpm,x64-appimage,arm64-appimage}/build.log`:

```bash
bash build.sh --build rpm --arch amd64 --clean no
bash build.sh --build appimage --arch amd64 --clean no
bash build.sh --build appimage --arch arm64 --clean no
bash scripts/verify-patches.sh build/electron-app
```

Each command ran in its corresponding copy, and `scripts/verify-patches.sh` reported 15/15 markers for each build. The final `.vite/build/*.js` files were syntax-checked with the x64 build's Electron and `ELECTRON_RUN_AS_NODE=1`. This is host-side syntax validation, not arm64 runtime evidence.

## External harness probes

`scripts/external-harness.sh` created fresh HOME and XDG config, cache, data, state and runtime directories for each run. It launched the original AppImage through its normal launcher, without inspector, DevTools, CDP or remote debugging. The AppImage ran on the real display. The harness only stopped its own process group.

For the AppImage, the retained log directory is `/tmp/opencode/claude-desktop-suse-logs.3117882/`. Each row's log name is relative to that directory; the complete expected/actual values and timestamps are in `/tmp/cds-bump/final2/harness-appimage-amd64.jsonl`.

| Probe | Expected | Actual | Exit | Log |
| --- | --- | --- | ---: | --- |
| `launcher` | Executable launcher | AppImage path | 0 | `launcher.log` |
| `desktop_entry` | Desktop entry exists | `Exec=AppRun %u` | 0 | `desktop-entry.log` |
| `app_asar` | `resources/app.asar` exists | 113,560,978 bytes | 0 | `app-asar.log` |
| `desktop_wm_class` | `StartupWMClass` present | `io.github.presire.claude-desktop-suse` | 0 | `wm-class.log` |
| `launch_process` | Normal launcher remains alive | PID 3117981 | 0 | `launcher-process.log` |
| `process_log_state` | Launcher log while alive | `launcher.log` exists | 0 | `launcher.log` |
| `window_reachability` | PID-owned matching X11/XWayland window | `0x3900003`; matching WM_CLASS | 0 | `window.log` |
| `window_title` | Readable title | `Claude` | 0 | `window.log` |
| `tray_sni` | PID-owned StatusNotifierItem | StatusNotifierItem owned by PID 3118040 is registered | 0 | `tray.log` |

The `tray_sni` row is the case the harness change covers: PID 3118040 was resolved through the unique bus name's owner and matched against the launch process group.

For the RPM, logs are under `/tmp/opencode/claude-desktop-suse-logs.3118472/` and full results are in `/tmp/cds-bump/final2/harness-rpm-amd64.jsonl`. File probes `launcher`, `desktop_entry`, `app_asar` and `desktop_wm_class` passed with exit 0: the extracted launcher was executable, the desktop entry used `/usr/bin/claude-desktop`, the asar was 113,560,955 bytes, and the class was `claude-desktop`. Their log basenames match the AppImage rows above. `launch_process`, `process_log_state`, `window_reachability`, `window_title` and `tray_sni` each recorded exit 77/SKIP: the target RPM is not installed, so its normal `/usr/bin/claude-desktop` launch is unavailable. Their log basenames are the probe IDs plus `.log`.

## Evidence files

All paths below are absolute. They sit in tmpfs `/tmp` and are local evidence, not committed fixtures.

- `/tmp/cds-bump/final2/{x64-rpm,x64-appimage,arm64-appimage}/build.log`: final builds.
- `/tmp/cds-bump/final2/art/`: the three final artifacts listed above.
- `/tmp/cds-bump/final2/appimage.log`: x64 AppImage artifact suite, strict mode.
- `/tmp/cds-bump/final2/rpm.log`: x64 RPM artifact suite.
- `/tmp/cds-bump/final2/common.log`: common artifact checks.
- `/tmp/cds-bump/final/unsq.log`: arm64 AppImage extraction of the build before the review fixes (`unsquashfs`, exit 2 from xattr restore); the final arm64 build was checked from its build tree (aarch64 ELF `electron`, 15/15 markers, 609 files parsed).
- `/tmp/cds-bump/final2/harness-{appimage,rpm}-amd64.jsonl`: external harness results.
- `/tmp/opencode/claude-desktop-suse-logs.3117882/` (AppImage) and `/tmp/opencode/claude-desktop-suse-logs.3118472/` (RPM): retained harness probe logs.

## Scope decisions, limitations and warnings

- RPM installation was not possible without root: `rpm -ivh` failed with permission denied on `/usr/lib/sysimage/rpm/.rpm.lock`. Installation was not retried through another path, tool, container or host. The RPM artifact suite's install-dependent checks therefore failed for environment reasons, and only its header and payload checks count as evidence. The RPM was not launched by the harness.
- `xvfb-run` is not installed on this host, so the AppImage artifact suite skipped launch smoke and strict mode exited 1 because of that SKIP alone. The external harness did launch the AppImage on the real display, and all nine probes passed.
- arm64 was not run on hardware, which was previously ruled out of scope by the user. Cross building, parsing and static checks are the available arm64 evidence.
- `unsquashfs` wrote the arm64 payload files but could not restore xattrs without privilege, returning 2. No privilege change or relabel workaround was attempted, and complete extraction with preserved attributes is not claimed.
