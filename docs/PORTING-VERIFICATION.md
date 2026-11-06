# Windows pin and portable feature verification, 2026-11-06

The file-manager fix and the AppImage automated checks pass. The user confirmed normal RPM installation and startup manually and removed physical-disk `/tmp` builds and arm64 hardware execution from the required scope. Automated RPM installation results and other limitations remain distinguished below.

| Check on the final code | Result | Exit code |
| --- | --- | --- |
| `bats tests` | 782 passed; no SKIP | 0 |
| File-manager focused Bats | 36 passed | 0 |
| `shellcheck -x build.sh`, file-manager shellcheck, parser `node --check` | Passed | 0 |
| Independent Oracle review | Nine saved counterexamples rejected without changing content, inode or mtime; normal GLib roundtrip passed; both pristine arch copies applied and replayed byte-identically | 0 for normal inputs; 1 for rejected inputs |
| x64 RPM build, with `PATCH_STAGE_RERUN=1` | Built; byte-identical whole-stage replay; 15/15 markers | 0 |
| x64 AppImage build, with `PATCH_STAGE_RERUN=1` | Built; byte-identical whole-stage replay; 15/15 markers | 0 |
| arm64 AppImage cross build, with `PATCH_STAGE_RERUN=1` | Built; byte-identical whole-stage replay; 15/15 markers | 0 |
| Final x64/arm64 main chunks, Electron Node 24.22.2 `--check` | Parsed on the x64 host | 0 |
| x64 AppImage artifact suite, strict mode, after the user installed `xvfb-run` | 45 passed, 0 failed, no SKIP; Xvfb startup reached ready state | 0 |
| x64 RPM header checks | Four passed; no installation attempted | 0 |
| x64 RPM extracted-payload checks | 17 passed; no SKIP | 0 |
| arm64 AppImage extracted-payload checks | 20 static checks passed; no runtime execution | 0 |
| x64 AppImage external harness | Nine probes passed | 0 |
| x64 RPM external harness | Four file probes passed; five L2 probes skipped because the RPM is not installed | 77 |
| RPM manual installation and startup | User reported normal operation; not an automated result from this session | Not supplied |

## Scope and implementation

The inherited portable work consists of launcher repair of app-generated file-manager entries, Linux support and correct `Exec`/`TryExec` serialization in Anthropic's generator, and terminal DA1 reply handling. The source remains Anthropic's Windows `.nupkg`; no official Linux `.deb`, APT, Nix, AUR or Worker policy was imported. The low-level behavior remains in Bats; the external harness records only file probes and public L2 reachability.

The generator patch previously treated fixed-width text searches as code boundaries. It now parses the whole chunk with build-only `acorn@8.19.0`, selects actual function and array-element positions, and applies the known whitespace-tolerant source patterns only at those positions. It checks decoded percent-call arguments and menu keys, rejects ambiguous or incomplete transformations, and parses the output before its atomic write. Parser version checks are part of build setup, and the standalone Bats workflow installs the same exact version.

The regressions were run before each fix and failed for the intended reason. They cover the 16,384-character boundary and distant false function, Node 22's unsupported `using` syntax, false quote/percent anchors, helpers moved into comments, duplicate and whitespace-spelled keys, detached quote functions, and `return` automatic semicolon insertion. Named function expressions, Windows behavior and byte-identical replay remain covered. Unknown shapes stop without replacing the chunk. The final Oracle review was bounded to these contracts and did not audit unrelated subsystems.

## Inputs and artifacts

Both inputs were downloaded from the official Windows release endpoints for `4.23118.0`.

| Arch | Input size | Verified SHA-256 |
| --- | ---: | --- |
| x64 | 261,350,107 B | `f26ce9fc2132d9aeaf82867dc6c23e963280ed7cdefdcd15f57fdfc673036ddd` |
| arm64 | 255,277,532 B | `a5ec6c080f98671526d5dd8c99d28df3e11b027a9c305929ea4f328297cd7223` |

The final artifacts were copied into the ignored repository `build/` directory for inspection.

| Artifact under `build/` | SHA-256 |
| --- | --- |
| `artifacts-amd64/claude-desktop-4.23118.0-1.x86_64.rpm` | `04703643638e115da920166bb14a1a2948f75423136449177c81ee232b40f62a` |
| `artifacts-amd64/claude-desktop-4.23118.0-amd64.AppImage` | `c9b86d584366b77eeb269dd2821fbb60a49f712006fb6923274325173739e452` |
| `artifacts-arm64/claude-desktop-4.23118.0-arm64.AppImage` | `42b20fd28a5b2fa2c5ccbe5935fa23313bad40aa6a15e667449762155bcba9df` |

The builds used fresh source copies at these paths, with the final parser and patch copied into each before the final build:

- `/tmp/opencode/claude-desktop-suse-rpm-amd64.4yJ2EW`
- `/tmp/opencode/claude-desktop-suse-appimage-amd64.nYpSJF`
- `/tmp/opencode/claude-desktop-suse-appimage-arm64.FfEloc`

```bash
PATCH_STAGE_RERUN=1 bash build.sh --build rpm --arch amd64 --clean no
PATCH_STAGE_RERUN=1 bash build.sh --build appimage --arch amd64 --clean no
PATCH_STAGE_RERUN=1 bash build.sh --build appimage --arch arm64 --clean no
bash scripts/verify-patches.sh build/electron-app
```

Each command ran in its corresponding copy. The final `build/electron-app/app.asar.contents/.vite/build/index.chunk-CUXoxsyW.js` (x64) and `index.chunk-BSfxK6a2.js` (arm64) were syntax-checked with the x64 build's Electron and `ELECTRON_RUN_AS_NODE=1`. This is host-side syntax validation, not arm64 runtime evidence.

## External harness probes

`scripts/external-harness.sh` created fresh HOME and XDG config, cache, data, state and runtime directories for each run. It launched the original AppImage through its normal launcher, without inspector, DevTools, CDP or remote debugging. `xprop` and `dbus-1-tools` were installed. The harness only stopped its own process group.

For the AppImage, the retained log directory is `/tmp/opencode/claude-desktop-suse-logs.250703/`. Each row's log name is relative to that directory; the complete expected/actual values and timestamps are in `build/harness-appimage-amd64-final.jsonl`.

| Probe | Expected | Actual | Exit | Log |
| --- | --- | --- | ---: | --- |
| `launcher` | Executable launcher | Final x64 AppImage executable | 0 | `launcher.log` |
| `desktop_entry` | Desktop entry exists | `Exec=AppRun %u`; correct desktop file | 0 | `desktop-entry.log` |
| `app_asar` | `resources/app.asar` exists | 110,753,261 bytes | 0 | `app-asar.log` |
| `desktop_wm_class` | `StartupWMClass` present | `io.github.presire.claude-desktop-suse` | 0 | `wm-class.log` |
| `launch_process` | Normal launcher remains alive | PID 251705 | 0 | `launcher-process.log` |
| `process_log_state` | Launcher log while alive | `launcher.log` exists | 0 | `launcher.log` |
| `window_reachability` | PID-owned matching X11/XWayland window | `0x3a00004`; matching WM_CLASS | 0 | `window.log` |
| `window_title` | Readable title | `Claude` | 0 | `window.log` |
| `tray_sni` | PID-owned StatusNotifierItem | `StatusNotifierItem-251764-` registered | 0 | `tray.log` |

For the RPM, logs are under `/tmp/opencode/claude-desktop-suse-logs.251177/` and full results are in `build/harness-rpm-amd64-final.jsonl`. File probes `launcher`, `desktop_entry`, `app_asar` and `desktop_wm_class` passed with exit 0: the extracted launcher was executable, the desktop entry used `/usr/bin/claude-desktop`, the asar was 110,753,238 bytes, and the class was `claude-desktop`. Their log basenames match the AppImage rows above. `launch_process`, `process_log_state`, `window_reachability`, `window_title` and `tray_sni` each recorded exit 77/SKIP: the target RPM is not installed, so its normal `/usr/bin/claude-desktop` launch is unavailable. Their log basenames are the probe IDs plus `.log`.

## Evidence files

All paths below are relative to this repository. `build/` is ignored and these logs are local evidence, not committed fixtures.

- `build/bats-final-current.log`: final 782-case Bats run.
- `build/file-manager-final.log`: final 36 focused cases.
- `build/oracle-regressions-red.log`, `build/oracle-second-regressions-red.log`: additional Oracle cases failing before their fixes.
- `build/oracle-fm-final-rWfD9R/{results,runtime-results,pristine-results}.json`: final independent review results, with fixture logs beside them.
- `build/build-{rpm-amd64,appimage-amd64,appimage-arm64}-final.log`: final builds and whole-stage replay results.
- `build/markers-{rpm-amd64,appimage-amd64,appimage-arm64}-final.log`: 15/15 markers for each final build.
- `build/artifact-appimage-amd64-final.log`: 44 passes and the missing-`xvfb-run` SKIP, strict exit 1.
- `build/artifact-appimage-amd64-xvfb.log`: subsequent strict run after `xvfb-run` installation; 45 passes, no failures or SKIP, exit 0. This is the current AppImage suite result.
- `build/artifact-rpm-header-final.log`, `build/artifact-rpm-payload-final.log`: non-installation RPM checks only.
- `build/appimage-arm64-extract-final.log`: extraction attribute failure, exit 2.
- `build/artifact-appimage-arm64-static-final.log`: static checks on the files produced by that extraction, exit 0.
- `build/harness-{appimage,rpm}-amd64-final.{jsonl,log}`: final external harness results and retained log locations.

## Scope decisions, limitations and warnings

- `/tmp` is tmpfs. The three builds succeeded there. The user subsequently removed the physical-disk `/tmp` requirement; no mount configuration or other people's data was changed.
- `tests/test-artifact-rpm.sh` installs and removes the package. It was not run after the earlier RPM-lock permission denial, and installation was not attempted through another path, tool, container or host. The user subsequently confirmed that manual RPM installation and startup work normally. This manual confirmation is separate from the automated header/payload results and the file-only harness; the automated installation suite remains unrun.
- The first AppImage artifact suite run skipped launch smoke because `xvfb-run` was missing and returned strict exit 1. After the user installed it, the same final AppImage passed all 45 checks with `ARTIFACT_FAIL_ON_SKIP=1`, including launch readiness under Xvfb, with no SKIP and exit 0. The rerun used a fresh HOME under `build/qa-home-xvfb.nyR4bN` and isolated XDG config, cache, data, state and runtime directories. No production or test code was changed for this rerun.
- `unsquashfs` wrote the arm64 payload files but could not restore `security.selinux` xattrs without privilege, returning 2. No `-no-xattrs`, privilege change or relabel workaround was attempted. The 20 static content checks on those files passed separately; complete extraction with preserved attributes is not claimed.
- Arm64 execution on real hardware was not performed and the user subsequently confirmed that it is not required for this task. Cross building, parsing and static checks are the available arm64 evidence.
- All three final npm build logs report `3 moderate severity vulnerabilities`. Their dependency causes were not investigated in this scope. The RPM build also reports that the host name `SUSE16` could not be canonicalized.
- Bats emitted existing BW02 warnings about minimum-version declarations. `git diff --check` reports the inherited Markdown trailing spaces in the protected `README.md` change and the pre-existing `docs/BUILDING.md` pin line; those lines were not cleaned up.
- TypeScript LSP diagnostics were unavailable because that server is not installed. Executable parser syntax, ShellCheck, Bats, real-input parsing and independent review provided the checks above; no LSP installation was performed.
- Previously denied reads/listings and the FUSE access denials for `/run/user/1000/doc` and `/run/user/1000/gvfs` were not worked around. Existing Claude settings, user data and processes were not modified or collected. The final AppImage artifact test mounted normally through FUSE.
- No commit was created. Existing user changes, including `README.md`, remain in place. Earlier artifact/harness results from before the final parser changes were not reused as final evidence.
