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
- **The verified Node floor is 20, not the declared 22.12.** The fork declares `engines.node >= 22.12.0` because it is normally `require`d as ESM. The build loads it through a dynamic `import()` resolved with `createRequire(...).resolve()`, which is verified working on Node 20.18.1 (the version `setup_nodejs()` downloads on a fresh host) and Node 22.23.1. `npm` only warns on an `engines` mismatch.
- **Accepted trade-off.** A build-time dependency on a package documented as "internal to Electron". The mitigations are the exact pin and the fact that `electron@41` constrains it too.

### Alternatives Considered

- **System `unzip`** (the build already has a cache-only fallback in `scripts/setup/dependencies.sh`). Produces byte-identical output for this archive and adds no npm dependency, but it is not a security improvement: openSUSE ships Info-ZIP `UnZip 6.00 of 20 April 2009`, whose path containment is implicit rather than contractual, which honours `$UNZIP` / `$UNZIPOPT` from the environment, and which returns non-zero on benign warnings that a build script checking exit status must then special-case. The existing fallback also only reads an already-populated `~/.cache/electron`, so it is not a drop-in primary path. Rejected as the primary extractor.
- **Keep `extract-zip` and accept the advisories.** Rejected — our input is a checksum-verified archive, but the extractor is the last component to touch it and neither advisory has a fix.
- **`yauzl`, `unzipper`, `fflate`, `adm-zip`.** Rejected — none of them creates symlinks for the caller, so the traversal-sensitive part would become ours to write and maintain, or (`fflate`) they target in-memory use and do not fit an on-disk extraction.

### References

- Hardened extractor: <https://github.com/electron/extract-zip>
- Unpatched advisories on upstream `extract-zip`: `GHSA-jmr9-qjv8-65gv`, `GHSA-7pqw-9j4j-h8q3`
- Electron's own installer path: `node_modules/electron/install.js` (`extract(zipPath, { dir })`)
