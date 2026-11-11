[< Back to README](../README.md)

# Decision Log

This log captures direction-level decisions that shape what this project does and — just as importantly — what it explicitly does not do. Each entry records the decision, the rationale at the time it was made, and the trade-offs accepted.

Decisions are not deleted. If a decision is revisited, the entry is marked `Superseded` and a new entry links back to it. This preserves the reasoning so future contributors don't have to relitigate settled questions without context.

**Format.** Each decision has a stable ID (`D-NNN`), a status, a decision date, an owner, and a short list of affected stakeholders. Decisions do not need to be long — they need to be clear about what was chosen and what was refused.

**Adding a new decision.** Append a new H2 section with the next `D-NNN` ID, add a row to the index, and keep the entry tightly scoped to one direction call. If a decision touches multiple areas, split it.

**Revisiting a decision.** Open an issue that cites the decision ID and describes what's materially changed since the original call. Don't open a PR that violates a recorded decision without first getting the decision reopened.

## Index

| ID | Date | Status | Title |
| --- | --- | --- | --- |
| [D-001](#d-001--auto-update-stays-in-the-package-manager-lane) | 2026-05-10 | Accepted | Auto-update stays in the package-manager lane |
| [D-002](#d-002--scope-limited-to-opensusesle-on-rpm-and-appimage) | 2026-05-10 | Accepted | Scope limited to openSUSE/SLE on RPM and AppImage |
| [D-003](#d-003--electron-zip-extraction-uses-the-electron-maintained-hardened-extractor) | 2026-09-17 | Accepted | Electron zip extraction uses the Electron-maintained hardened extractor |
| [D-004](#d-004--the-build-tracks-the-electron-major-shipped-in-the-windows-nupkg) | 2026-10-14 | Accepted | The build tracks the Electron major shipped in the Windows nupkg |
| [D-005](#d-005--builds-default-to-a-verified-claude-release) | 2026-10-14 | Accepted | Builds default to a verified Claude release |
| [D-006](#d-006--patches-that-change-nothing-fail-the-build) | 2026-10-23 | Accepted | Patches that change nothing fail the build |

---

## D-001 — Auto-update stays in the package-manager lane

- **Status:** Accepted
- **Decided:** 2026-05-10
- **Owner:** @presire
- **Stakeholders:** openSUSE / SLE users on RPM; AppImage users; external contributors proposing auto-update features

### Context

This decision is inherited (with adaptations) from the upstream `claude-desktop-debian` project's [D-001](https://github.com/aaddrick/claude-desktop-debian/blob/main/docs/DECISIONS.md). The reasoning applies equally to the SUSE fork.

A contributor submitted a proposal that added nightly cron-driven update scripts covering both Claude Desktop (rebuild-and-reinstall from source) and the Claude Code CLI (via `claude update`). The same PR contained an unrelated fix for GPU compositing on XRDP sessions. The XRDP portion was salvaged and merged. This entry records why the auto-update portion was declined at the direction level.

### Decision

**This project does not ship an in-tree auto-updater.** Updates are delivered exclusively through:

1. The user's **zypper** workflow on openSUSE/SLE (when installing the published `.rpm`)
2. **AppImageUpdate / embedded zsync info** as the sanctioned direction if and when AppImage auto-update is prioritized

No cron-driven, systemd-timer-driven, or in-app rebuild-and-reinstall flows will be merged.

### Rationale

- **The platform that matters already has the right answer.** openSUSE / SLE users get updates through `zypper`, the OS's update stack — the thing users configure, audit, and trust. Standing up a parallel path inside this project fragments the experience and duplicates machinery that already works.
- **The DE-neutral answer for AppImage is AppImageUpdate, not a bespoke updater.** A parallel AppImage update path would mean owning process detection, session-aware safety checks, and sudo escalation across every desktop environment, session manager, notification system, and sandboxing model (Flatpak, Snap, Wayland, X11, systemd-inhibit, screen locks). AppImage already has a sanctioned update mechanism; if we ever close that gap, we close it by embedding zsync info in the release artifact.
- **Security surface.** An unattended updater running from cron with broad `zypper install` privileges in a user's git clone is a large ambient capability for the project to own. RPM `%post` scripts mean that `NOPASSWD: /usr/bin/zypper install *` is effectively passwordless root for anyone who can place a file on disk — a surface that does not exist when the user runs `zypper up` through the OS's package manager directly.
- **Upstream parity.** The Windows and Mac builds of Claude Desktop do not auto-update via cron. They use platform-native mechanisms. A Linux-specific cron updater would make this project's update behavior diverge from the expectations users carry in from the upstream product.
- **Maintenance tail.** Every session manager, notification system, sandboxing runtime, and "is the user actively using the app" heuristic becomes this project's problem to keep working across distros, indefinitely. The blast radius of a broken updater is "the app stops working cleanly for a fraction of users until they figure out how to intervene" — and we would own that 24/7.

### Consequences

- **Accepted trade-off.** AppImage users have no first-party auto-update path. Their options are: re-download the AppImage manually, use Gear Lever, or switch to the RPM package format.
- **Future work.** If AppImage auto-update becomes a priority, the sanctioned path is integrating zsync metadata into the release artifact and documenting `AppImageUpdate` usage — not a new cron script.
- **Contributor guidance.** PRs proposing in-tree auto-update mechanisms should reference this decision and are expected to be declined by default. Requests to reopen should be filed as issues that cite `D-001` and describe what's materially changed.
- **In-place upgrade detection.** The frame-fix wrapper does watch for `app.asar` replacement on disk (typical of `zypper up` on a running app) and surfaces a "click to restart" notification. That is detection, not an update mechanism — `zypper` still drives the actual upgrade.

### Alternatives Considered

- **Cron-driven auto-updater.** Rejected — rationale above.
- **Systemd-timer variant.** Same concerns; the scheduling mechanism is not the hard part.
- **Watch-mode "update when idle" daemon.** Worse on balance — owning an always-on daemon that decides when the user is "idle enough" for an update is a larger maintenance surface than the cron approach and carries the same security footprint.
- **AppImageUpdate / zsync integration.** Accepted as the sanctioned direction if AppImage auto-update is ever prioritized. Not implemented today; recorded here so future contributors know which direction is open.

---

## D-002 — Scope limited to openSUSE/SLE on RPM and AppImage

- **Status:** Accepted
- **Decided:** 2026-05-10
- **Owner:** @presire
- **Stakeholders:** openSUSE / SLE users; users of other RPM-based distros; contributors

### Context

This fork was created to repackage Claude Desktop for the openSUSE / SLE ecosystem after the upstream `claude-desktop-debian` project diverged toward Debian/Ubuntu specifics (APT repository, AUR package, Nix flake) that don't apply on SUSE.

When porting features from upstream we have to decide which non-SUSE-specific machinery to carry over.

### Decision

**This project's supported output formats are `.rpm` (zypper-installable) and `.AppImage` only.** Specifically excluded:

- `.deb` packaging
- APT repository hosting
- AUR (Arch) packaging
- Nix flake / NixOS module
- Cloudflare Worker / `gh-pages` distribution infrastructure

Imported upstream patches are SUSE-adapted: package-manager hints reference `zypper`, the package-status check uses `rpm -q`, log paths use `claude-desktop-suse`, and the desktop-file naming follows the SUSE convention.

### Rationale

- **Build surface vs. user surface.** Supporting every distribution doubles or triples the maintenance surface for a single-maintainer fork. The upstream project covers Debian/Ubuntu/Fedora/Arch/NixOS; users on those platforms should use upstream.
- **No duplication of upstream effort.** Where the upstream project supports a distro, the right answer is to route users there rather than maintain a second packaging path here.
- **Cleaner patch porting.** Stripping non-SUSE branches out of imported scripts (e.g. `doctor.sh`'s package-manager dispatcher) makes future upstream merges cheaper, not more expensive — the diff is smaller and the SUSE-specific assumptions are explicit.

### Consequences

- **Accepted trade-off.** Fedora/RHEL users on `dnf` are not first-class targets of this fork even though their package format is the same as ours. They can install the `.rpm` manually but the build defaults assume openSUSE/SLE.
- **Imported docs.** Upstream learning docs (`docs/learnings/*.md`) are imported as-is for the patch-engineering content. References to `apt`, `gh-pages`, AUR, Nix etc. inside them are left intact when they're contextual; they're rewritten only when they describe something we actually use (e.g. log paths, build invocations).
- **Tests.** Test fixtures and harnesses are imported when the patch they exercise is also imported.

### Alternatives Considered

- **Mirror upstream's full distro matrix.** Rejected — too large a maintenance surface for a single-maintainer fork; route users to upstream for non-SUSE distros instead.
- **Strip imported docs of all non-SUSE references.** Rejected — many upstream issue numbers and architectural notes are still relevant context. We rewrite only the lines that drive runtime behavior on SUSE.

### References

- Upstream project: <https://github.com/aaddrick/claude-desktop-debian>
- Upstream `D-001` (auto-update): <https://github.com/aaddrick/claude-desktop-debian/blob/main/docs/DECISIONS.md>

---

## D-003 — Electron zip extraction uses the Electron-maintained hardened extractor

- **Status:** Accepted
- **Decided:** 2026-09-17
- **Owner:** @presire
- **Stakeholders:** openSUSE / SLE users on RPM and AppImage; contributors touching `scripts/setup/`

### Context

`setup_electron_asar()` installs `electron@^41` into the build work directory. npm 12 blocks lifecycle scripts by default, so that install no longer runs Electron's own `postinstall` (`node install.js`); `node_modules/electron/dist/` stays empty and the build falls back to `scripts/setup/fetch-electron-binary.js`. That script downloads the release archive with `@electron/get` and must then extract it itself.

The obvious extractor is the npm `extract-zip` package, and the build used to install it explicitly. It is unmaintained — the last release is `2.0.1` from 2020-06-10 — and it carries two advisories with no patched release, so "upgrade" is not available as a remedy: `GHSA-jmr9-qjv8-65gv` / `CVE-2026-56876` (unvalidated symlink target from archive entries) and `GHSA-7pqw-9j4j-h8q3` / `CVE-2026-19693` (arbitrary file write through symlink entries).

### Decision

**`scripts/setup/fetch-electron-binary.js` extracts the Electron archive with `@electron-internal/extract-zip`, pinned exactly to `1.0.5`.** The `extract-zip` dependency is dropped from `scripts/setup/dependencies.sh`.

- `@electron/get` stays — it performs the download and the checksum verification.
- The extractor is pinned by exact version, not a `^` range.
- Extraction always targets a freshly created, empty directory.

### Rationale

- **The threat model matches the use case exactly.** The extractor's `SECURITY.md` puts "extracting checksum-verified Electron distribution archives" in scope, and explicitly excludes untrusted archives and reused destinations pre-seeded with attacker-controlled content. That is how this build uses it, and nothing else.
- **The vulnerable pattern is removed, not merely patched.** The fork resolves symlink targets in a deferred pass with a bounded walk over both the archive and the on-disk tree, and re-checks containment afterwards (fail-closed). It has no published advisories.
- **It is already in the dependency tree.** `electron@41.10.7` depends on it (`^1.0.1`) and its own `install.js` calls the same `extract(zipPath, { dir })` API. Adopting it removes `extract-zip` and its transitive subtree while adding nothing new.
- **The exact pin is deliberate even though `^` is available.** The fork documents its API as internal to the Electron project and warns that the API may change. Pinning stops a future release from silently changing behaviour underneath us; correctness within the pin is backed by the `electron@41` range this project already tracks.
- **It is the extraction path the app's own installer uses.** Staying on the same path as Electron's supported installer keeps the build closer to the supported surface.

### Consequences

- **Do not relax the pin or "modernise" it to `^`.** The `@electron-internal/*` namespace is a fork of a package this decision deliberately rejected; a floating range reintroduces exactly the risk recorded here. Upgrading Electron is the trigger to re-evaluate the pin — not a routine dependency bump.
- **Do not reuse extraction destinations.** The threat model excludes destinations that already contain attacker-controlled entries. Extract into a fresh directory every time, which the build already does.
- **The fork itself would load on Node 20.** The fork declares `engines.node >= 22.12.0` because it is normally `require`d as ESM. The build loads it through a dynamic `import()` resolved with `createRequire(...).resolve()`, which is verified working on Node 20.18.1 and Node 22.23.1. The build now enforces Node 22.12.0 anyway (`NODE_MIN_VERSION` in `scripts/setup/dependencies.sh`, required by `@electron/asar` 4.x), and `setup_nodejs()` downloads Node 22.23.2 on an older host.
- **Accepted trade-off.** A build-time dependency on a package documented as "internal to Electron". The mitigations are the exact pin and the fact that `electron@41` constrains it too.

### Alternatives Considered

- **System `unzip`** (the build already has a cache-only fallback in `scripts/setup/dependencies.sh`). Produces byte-identical output for this archive and adds no npm dependency, but it is not a security improvement: openSUSE ships Info-ZIP `UnZip 6.00 of 20 April 2009`, whose path containment is implicit rather than contractual, which honours `$UNZIP` / `$UNZIPOPT` from the environment, and which returns non-zero on benign warnings that a build script checking exit status must then special-case. The existing fallback also only reads an already-populated `~/.cache/electron`, so it is not a drop-in primary path. Rejected as the primary extractor.
- **Keep `extract-zip` and accept the advisories.** Rejected — our input is a checksum-verified archive, but the extractor is the last component to touch it and neither advisory has a fix.
- **`yauzl`, `unzipper`, `fflate`, `adm-zip`.** Rejected — none of them creates symlinks for the caller, so the traversal-sensitive part would become ours to write and maintain, or (`fflate`) they target in-memory use and do not fit an on-disk extraction.

### References

- Hardened extractor: <https://github.com/electron/extract-zip>
- Unpatched advisories on upstream `extract-zip`: `GHSA-jmr9-qjv8-65gv`, `GHSA-7pqw-9j4j-h8q3`
- Electron's own installer path: `node_modules/electron/install.js` (`extract(zipPath, { dir })`)

---

## D-004 — The build tracks the Electron major shipped in the Windows nupkg

- **Status:** Accepted
- **Decided:** 2026-10-14
- **Owner:** @presire
- **Stakeholders:** openSUSE / SLE users on RPM and AppImage; contributors touching `scripts/setup/` and the launcher

### Context

`setup_electron_asar()` pinned `electron@^41` because `electron@42.0.0` dropped the `postinstall` that populates `node_modules/electron/dist/` (#584). D-003 moved that job to `scripts/setup/fetch-electron-binary.js`, so the original reason for the pin no longer holds. Meanwhile the Windows nupkg moved ahead: `1.44121.4` bundles Electron 42.10.0 and `2.37337.1` bundles Electron 44.7.0 (Chromium 152).

Chromium 152 / Electron 44 registers the app id with the `xdg-desktop-portal` host Registry (`org.freedesktop.host.portal.Registry.Register`). Portal 1.20+ needs that registration for the GlobalShortcuts and Secret portals on native Wayland, and it rejects ids that have no installed `<id>.desktop` file.

### Decision

**The build installs `electron@^45`, the major that the current Windows nupkg ships.** When Anthropic moves the nupkg to a new Electron major, the pin in `scripts/setup/dependencies.sh` moves with it.

- `setup_electron_asar()` compares the major in `node_modules/electron/dist/version` with the pin and reinstalls on mismatch, so `--clean no` never reuses an older Electron.
- The launcher writes a hidden `<desktopName>.desktop` entry under `$XDG_DATA_HOME/applications/` on native Wayland when no system entry with that id exists, so the portal accepts the registration.

### Rationale

- **The app code is built for the Electron it ships with.** Running a newer `app.asar` on an older Electron is the riskier direction; matching the major keeps the main-process APIs the bundle calls available.
- **Portal registration only exists from Electron 44.** Without it, native Wayland sessions cannot use the GlobalShortcuts portal through the registered id.
- **D-003 re-evaluated.** `electron@44.7.2` depends on `@electron/get ^5.0.0` and `@electron-internal/extract-zip ^1.0.1`, exactly like `electron@41.10.7`; `1.0.5` is still the newest release. The exact extractor pin stays.

### Consequences

- **Electron 42–45 breaking changes reviewed for the shims.** Unity APIs (`app.isUnityRunning`, Linux badge count and progress bar), rounded frameless corners, and WCO following the native title-bar layout do not touch `frame-fix-wrapper.js`, `frame-fix-menu.js`, `wco-shim.js` or `claude-native-stub.js`. Electron 45 (sandboxed preload lost the `Buffer`, `setImmediate`, `events`, `timers` and `url` polyfills, `ipcRenderer` is a native `EventEmitter`, `window.open` children are sandboxed, synchronous `safeStorage` is deprecated) needs no shim change either: `scripts/wco-shim.js` only requires `electron`, and `frame-fix-*.js` and `claude-native-stub.js` run in the main process.
- **node-pty is unaffected.** It is built with the host Node through node-gyp against N-API, not against the Electron ABI.
- **A new nupkg major is a manual bump.** The pin is not derived from the nupkg at build time; a mismatch shows up as a review item when a new upstream version is adopted.

## D-005 — Builds default to a verified Claude release

- **Status:** Accepted
- **Decided:** 2026-10-14
- **Owner:** @presire
- **Stakeholders:** openSUSE / SLE users on RPM and AppImage; contributors touching `scripts/setup/`, `scripts/patches/` and `.github/workflows/release.yml`

### Context

Without `--claude-version`, `resolve_latest_url()` used to download whatever Anthropic's `RELEASES` file listed as newest. The patch scripts anchor on strings in the minified bundle, and those strings move between releases: `2.37337.1` arrived with a fatal `--add-dir` anchor miss and six patches that skipped with a warning. An unpinned build therefore either failed or produced a package that was missing fixes.

`RELEASES` lists only the newest release, so its SHA-1 disappears as soon as a release is superseded. A pinned `--claude-version` without `--claude-sha256` then downloaded unverified. CI pinned version and SHA-256 by hand in `release.yml`, separately from local builds.

### Decision

**A build without `--claude-version` downloads `CLAUDE_PINNED_VERSION` and verifies it against the SHA-256 pinned for the target architecture** (`CLAUDE_PINNED_SHA256_AMD64` / `_ARM64` in `scripts/setup/detect-host.sh`).

- `--claude-version latest` keeps the old behavior: the newest `RELEASES` entry, SHA-1 verified, no SHA-256 pin.
- `--claude-version X.Y.Z` uses the pinned SHA-256 only when X.Y.Z is the pin; otherwise only `--claude-sha256` (or a `RELEASES` SHA-1) verifies it.
- `--claude-sha256` always replaces the pinned hash; `--exe` never uses the pin.
- The arm64 feed serves `AnthropicClaude-X.Y.Z-full.nupkg` under `/win32/arm64/`, not an `-arm64-full` name, which returns 404.
- `release.yml` builds the default pin and fails when a tag's `+claudeX.Y.Z` names a different version.

### Rationale

- **Reproducible, verified input.** The same commit always builds from the same verified nupkg, after `RELEASES` has moved on.
- **One pin for local and CI builds.** The version and both SHA-256 values live next to the code that consumes them. The build workflows (`test-artifacts.yml`, `release.yml`) also name the version as `CLAUDE_DESKTOP_VERSION` and pass it with `--claude-version`, so CI never builds anything else; a step fails the job when it differs from `CLAUDE_PINNED_VERSION`, and `tests/claude-version-pin.bats` checks the same. The hashes stay only in `detect-host.sh`.
- **Updates stay a reviewed step.** New releases need patch re-anchoring anyway; adopting one means bumping the version and both hashes after every patch applies cleanly.

### Consequences

- **Upstream fixes arrive only with a pin bump.** Use `--claude-version latest` to try a new release before bumping.
- **A withdrawn nupkg breaks the default build.** Anthropic still serves superseded nupkgs (`1.44121.4`, `2.110.0` checked); if one is withdrawn, the pin has to move.
- **Upstream drift is reported, not applied.** `.github/workflows/check-claude-version.yml` runs daily, compares Anthropic's Windows `RELEASES` feeds (x64 and arm64) with `CLAUDE_PINNED_VERSION`, and opens or updates one issue when a newer release appears; the pin, both SHA-256 values and the workflows' `CLAUDE_DESKTOP_VERSION` still move only through the manual, patch-verified bump above.

### Pin history

- **2026-11-11: `4.23118.0` → `5.1231.2`.** Both Windows nupkgs were downloaded; their SHA-1 and size matched the official `RELEASES` entries (x64 264,890,967 B; arm64 258,384,413 B) and the SHA-256 values were computed locally (x64 `2efd25c2ae8cd7150c2a4759b29877365d4c854a1b81f9934d71aba0ccb1ee87`; arm64 `0ace6e0b61f1ed3b6abeb4002ff1208a5244348d23b7eb4f9bf7cfa19a1642bc`). The nupkg moves from Electron 44.9.3 to 45.2.1 (Chromium 156), so per D-004 the pin in `scripts/setup/dependencies.sh` moved to `electron@^45`; these builds resolved 45.3.0. Two cowork patches stopped matching and were fixed. (a) Patch 4b, the auto-navigation suppression (#341): upstream `getDownloadStatus` became `async getDownloadStatus(){let e=await ...;return e!==X.NotDownloaded||...}`, so the patch now also injects `if(process.platform==="linux")return X.NotDownloaded;` at the start of the async form (idempotent; the legacy sync form is still handled), and the marker regex in `scripts/cowork-patch-markers.tsv` accepts both forms. (b) The `wvm-` tmpdir bundle-local proof: its call-site regex counted the staging helper's own `function name(e,t){` definition as a call site, and in the new bundle another async function using `.origin` sits right before it, so the proof failed; a lookbehind now excludes `function\s+`, and every other helper call except a file-name-only `basename(H(...))` must carry the origin proof or the result is a WARNING. The async regex is whitespace tolerant and its replacement is a callback, so only the matched method is rewritten and `$` in the enum name is kept verbatim; both defects were found by an independent review and are covered by regressions that fail on the earlier patch. New fixtures in `tests/cowork-latest-patches.bats` cover the `5.1231.2` shapes and a byte-idempotent replay, and the `tests/node-floor.bats` fixture now declares Electron 45.2.1. `_PATCH_EFFECT_ALLOWLIST` is unchanged at the same seven entries, and they still no-op on `5.1231.2`. The external harness needed a change too: Electron 45 registers the tray StatusNotifierItem under its unique bus name (for example `:1.4007/StatusNotifierItem`) instead of `org.kde.StatusNotifierItem-<pid>-<n>`, so `tray_sni` now falls back to the owner PID from `org.freedesktop.DBus.GetConnectionUnixProcessID` and checks that PID is in the launch process group; the new case in `tests/external-harness.bats` failed against the old harness and passes now. Final Bats: 787 cases, 786 passed and 1 SKIP (the offline extractor case needs a build tree; it passed in the x64 RPM build copy). Fresh x64 RPM, x64 AppImage and arm64 AppImage builds all exited 0 with no WARNING, applied 13 cowork patches and reported 15/15 markers each; Electron's Node 24.22.2 parsed all 609 `.vite/build/*.js` files for both architectures. The x64 AppImage artifact suite with `ARTIFACT_FAIL_ON_SKIP=1` passed 44 checks with 0 failures and one SKIP (launch smoke: `xvfb-run` is not installed on this host), so strict mode exited 1 only because of that SKIP. The RPM artifact suite's header and payload checks passed, but `rpm -ivh` failed with permission denied on `/usr/lib/sysimage/rpm/.rpm.lock` (no root), so its install-dependent checks failed for environment reasons and installation was not retried through another path. The external harness on the AppImage passed 9/9 probes, including window and tray; on the RPM, the 4 file probes passed and the 5 launch probes SKIPped with exit 77 because the RPM is not installed. arm64 evidence is a cross build, parsing and static checks only (arm64 ELF `electron` 45.3.0, node-pty `aarch64`); `unsquashfs` exited 2 only because it cannot restore xattrs without privilege. See [the verification record](PORTING-VERIFICATION.md) for commands, hashes, logs and limitations.
- **2026-11-06: `4.4212.0` → `4.23118.0`.** Both Windows nupkgs were downloaded and their SHA-256 values matched `detect-host.sh` (x64 261,350,107 B; arm64 255,277,532 B); the builds also checked the official `RELEASES` metadata. The nupkg bundles Electron 44.9.3, within D-004's `electron@^44`; these builds resolved 44.10.2. The file-manager port now uses build-only `acorn@8.19.0` to distinguish executable code from comments and strings and to parse both input and output, including `using` syntax. Final Bats: 782 passed, no SKIP; the bounded independent Oracle review found no remaining issue. Fresh x64 RPM, x64 AppImage and arm64 AppImage builds all exited 0, with whole-stage byte-identical replay and 15/15 markers each. Electron's Node 24.22.2 parsed both architectures' final main chunks. After the user installed `xvfb-run`, the final x64 AppImage passed all 45 artifact checks with `ARTIFACT_FAIL_ON_SKIP=1`, no SKIP and exit 0, including Xvfb launch readiness; its separate isolated external harness passed all nine probes, including the window and tray. Automated RPM checks covered its header and extracted payload (21 passes); installation was not retried after the prior permission denial, and automated RPM L2 was skipped. The user confirmed normal RPM installation and startup manually. The user also removed physical-disk `/tmp` builds and arm64 hardware execution from the required scope: the builds used tmpfs `/tmp`, and arm64 evidence consists of cross building, parsing and static payload checks. Earlier artifact counts from before the file-manager fixes are not evidence for this code. See [the verification record](PORTING-VERIFICATION.md) for commands, hashes, logs, scope decisions and limitations.
- **2026-10-30: `3.6556.1` → `4.4212.0`.** Both architectures' nupkgs were downloaded from `downloads.claude.ai`; their size and SHA-1 matched the `RELEASES` entries (x64 249,184,945 B, arm64 243,249,411 B) and the SHA-256 values were computed locally. `4.4212.0` still bundles Electron 44.9.3, inside D-004's `electron@^44`. The release moves resources into archives: the 43 locale JSON files no longer sit next to `app.asar` but ship inside it at `resources/i18n` (where the main process reads them), `claude-browser-shim.js` moved into `app.asar/resources`, and the bundled web pages are now `ion-dist.asar`, which the packaged app reads as a regular file from `process.resourcesPath`. Locale staging now accepts the in-asar layout and `copy_cowork_resources` stages `ion-dist.asar`; the 3.x layout still works. Every patch stage applied on x64 and on an arm64 cross build with no anchor misses and the same seven allowlisted no-ops, `scripts/verify-patches.sh` reported 15/15 markers for both bundles, the repack invariance check passed, and a `PATCH_STAGE_RERUN=1` pass on arm64 left the bundle unchanged. The x64 `.rpm` (48 passed) and `.AppImage` (45 passed) artifact suites ran with `ARTIFACT_FAIL_ON_SKIP=1` and no SKIP; the AppImage launch needs a font installed (Chromium aborts in `SkFontMgr_FontConfigInterface` without one), so the CI AppImage job now installs `dejavu-fonts`.
- **2026-10-23: `2.42304.2` → `3.6556.1`.** The major jump is an upstream renumbering (`2.42304.2` on 2026-10-19, `3.1623.0` on 2026-10-20), not a new application. Both architectures' nupkgs were downloaded from `downloads.claude.ai`; their size and SHA-1 matched the `RELEASES` entries (x64 250,490,503 B, arm64 244,773,984 B) and the SHA-256 values were computed locally. Every patch stage applied on x64 and on an arm64 cross build with no anchor misses, `scripts/verify-patches.sh` reported 15/15 markers for both bundles the repack invariance check passed, and a `PATCH_STAGE_RERUN=1` pass left both bundles unchanged. `3.6556.1` bundles Electron 44.9.3, inside D-004's `electron@^44`. The bump also fixed locale staging (the release ships 43 locale JSON files, 30 of them without a region suffix) and pins node-pty to `1.2.0-beta.14`, the version the app declares, which ships Linux N-API prebuilds (npm's `latest` 1.1.0 does not, and npm 12 blocks its build script).
- **2026-10-19: `2.42304.0` → `2.42304.2`.** Both architectures' nupkgs were downloaded from `downloads.claude.ai`; their SHA-1 and size matched the `RELEASES` entries and the SHA-256 values were computed locally. Every patch stage ran against both bundles with no anchor misses (`scripts/verify-patches.sh`: 15/15 markers, `PATCH_STAGE_RERUN=1` left the bundle unchanged), identical to the `2.42304.0` result. `2.42304.2` still bundles Electron 44.7.2, so D-004 needs no change. Unlike `2.42304.0`, it is the release `RELEASES` lists, so a SHA-1 cross-check exists until it is superseded.
- **2026-10-19: `2.37337.1` → `2.42304.0`.** Both architectures' nupkgs were downloaded from `downloads.claude.ai`, the SHA-256 values were computed locally (the size and MD5 matched the storage ETag), and every patch stage was run against both bundles: no anchor misses, `scripts/verify-patches.sh` reported all markers present, and a `PATCH_STAGE_RERUN=1` pass left the bundle unchanged. `2.42304.0` still bundles Electron 44.7.2, so D-004 needs no change. `RELEASES` no longer lists `2.42304.0` (it lists a newer `2.42304.2`), so the pinned SHA-256 is the only checksum for this release.

---

## D-006 — Patches that change nothing fail the build

- **Status:** Accepted
- **Decided:** 2026-10-23
- **Owner:** @presire
- **Stakeholders:** openSUSE / SLE users on RPM and AppImage; contributors editing `scripts/patches/`

### Context

The patch stage rewrites minified JavaScript inside the Windows `.nupkg` bundle with anchored regexes and small Node/sed edits. When an anchor is missing, most patch functions print a diagnostic. A function that finds its anchor but produces no byte change is harder to see: it can mean the upstream release already contains the fix, or that the anchor matched the wrong shape and the patch was silently a no-op. `scripts/verify-patches.sh` checks 15 markers after the stage, but not every function has a marker, and a marker can be satisfied by another patch, so it cannot catch every regression.

Debian's build has the same problem and solves it with a "G10" patch-effect check plus a patch-zero / patch-retirement contract tied to the official Linux `.deb` patch series. SUSE does not consume that series: the build input is Anthropic's Windows `.nupkg`, and the patch functions are applied directly to the extracted `app.asar`. There is no `debian/patches` numbering, no patch-zero artifact, and nothing to retire, so that contract does not transfer.

### Decision

**Every function in `_run_suse_patch_stage` runs with a digest of `app.asar.contents/.vite/build` taken before and after it. An unchanged digest fails the stage unless the function is listed in `_PATCH_EFFECT_ALLOWLIST` with a one-line reason and, in that run, reached its reviewed no-op branch (`_declare_patch_noop`). A patch function that returns non-zero fails the stage.**

- The digest reuses `_patch_bundle_digest`. Every stage patch writes under `.vite/build`; `install_node_pty` writes outside it but runs after the stage, so the narrower scope is exact and cheap.
- Patch functions run in the current shell. The tray patches publish `electron_var` / `electron_var_re` globals that later patches read; capturing output in a subshell would drop them.
- `_PATCH_EFFECT_ALLOWLIST` in `scripts/patches/_common.sh` holds only documented no-ops, each with its reason. On `5.1231.2` (as on `4.23118.0`, `4.4212.0` and `3.6556.1`) it has seven entries: `extract_electron_variable` (writes no file), and six functions whose own early-return branch detects that the upstream bundle already provides the behaviour (`fix_native_theme_references`, `patch_tray_menu_handler`, `patch_tray_inplace_update`, `patch_menu_bar_default`, `patch_linux_claude_code`, `patch_virtiofsd_probe`).
- Allowlisting alone is not enough: each listed function calls `_declare_patch_noop` only in the branch that proves the no-op (upstream already has the behaviour, or the function never writes). A listed function whose anchor drifted reaches no such branch and fails with `... is allowlisted but did not reach its reviewed no-op branch`.
- The `PATCH_STAGE_RERUN=1` replay passes `no-check`: every patch is expected to be a no-op on an already-patched tree. The existing whole-stage `_check_patch_stage_idempotent` check is unchanged.
- **Debian's patch-zero / patch_retirement contract is not adopted.** SUSE patches the Windows nupkg bundle, not the official Linux `.deb`; there is no patch series to zero out or retire. The per-patch digest plus a small reviewed allowlist is the SUSE equivalent of G10.

### Rationale

- **The failure lands on the patch that caused it.** The message names the function, so a pin bump that breaks one anchor no longer ships a partially patched bundle or relies on a later marker check.
- **Intentional no-ops stay visible.** An allowlist entry is a reviewed claim about the pinned release, with its reason in the same line, instead of a silent `return` buried in a patch file.
- **No new artifact or format.** The check is two digests around each function and reuses the existing helper; it adds no file to the package and no state to the build.

### Consequences

- Adding a patch function forces an allowlist decision when it intentionally writes nothing; adding a new no-op without a reason fails the build.
- A pin bump can now fail with `Patch effect: '<function>' left ... byte-identical`. The fix is to re-anchor the patch; allowlisting is only for a proven intentional no-op on that release.
- The digest adds one SHA-256 pass over `.vite/build` on each side of each patch, which is small compared with `asar extract` and the patch itself.
- Debian's G10 remains a reference for the idea only; its patch-zero machinery must not be ported.

### Alternatives Considered

- **Rely on `scripts/verify-patches.sh` alone.** Rejected: it checks markers after the whole stage, covers only 15 markers, and cannot attribute a missing change to a function.
- **Fail every no-op with no allowlist.** Rejected: some functions never write by design (`extract_electron_variable`), and a patch that correctly finds upstream already fixed should not fail the build.
- **Adopt Debian's patch-zero / patch_retirement contract.** Rejected: the build input is the Windows nupkg, not the official Linux `.deb`, so there is no Debian patch series to zero or retire.
