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

---

## D-001 — Auto-update stays in the package-manager lane

- **Status:** Accepted
- **Decided:** 2026-05-10
- **Owner:** @presire
- **Stakeholders:** openSUSE / SLE users on RPM; AppImage users; external contributors proposing auto-update features

### Context

This decision is inherited (with adaptations) from the upstream `claude-desktop-debian` project's [D-001](https://github.com/aaddrick/claude-desktop-debian/blob/main/docs/DECISIONS.md). The reasoning applies equally to the SUSE fork.

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
- **Maintenance tail.** Every session manager, notification system, sandboxing runtime, and "is the user actively using the app" heuristic becomes this project's problem to keep working across distros, indefinitely.

### Consequences

- **Accepted trade-off.** AppImage users have no first-party auto-update path. Their options are: re-download the AppImage manually, use Gear Lever, or switch to the RPM package format.
- **Future work.** If AppImage auto-update becomes a priority, the sanctioned path is integrating zsync metadata into the release artifact and documenting `AppImageUpdate` usage — not a new cron script.
- **In-place upgrade detection.** The frame-fix wrapper does watch for `app.asar` replacement on disk (typical of `zypper up` on a running app) and surfaces a "click to restart" notification. That is detection, not an update mechanism — `zypper` still drives the actual upgrade.

### Alternatives Considered

- **Cron-driven auto-updater.** Rejected — rationale above.
- **Systemd-timer variant.** Same concerns; the scheduling mechanism is not the hard part.
- **Watch-mode "update when idle" daemon.** Worse on balance — owning an always-on daemon that decides when the user is "idle enough" for an update is a larger maintenance surface than the cron approach and carries the same security footprint.
- **AppImageUpdate / zsync integration.** Accepted as the sanctioned direction if AppImage auto-update is ever prioritized.

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
