# Cowork VM Daemon — Learnings

## Architecture Overview

Cowork mode on Linux uses a custom Node.js daemon
([`scripts/cowork-vm-service.js`](../../scripts/cowork-vm-service.js))
that replaces the Windows cowork-vm-service. The Electron app talks to
it over a Unix domain socket at
`$XDG_RUNTIME_DIR/cowork-vm-service.sock` using length-prefixed JSON —
the same wire format as the Windows named pipe.

The daemon is forked by **Patch 6** in the
`patch_cowork_linux()` function (`scripts/patches/cowork.sh`), which
injects auto-launch code into the Electron app's retry loop for the
VM-service connection.

## Daemon Lifecycle

1. First connect attempt: the app tries `$XDG_RUNTIME_DIR/cowork-vm-service.sock`.
2. `ENOENT` / `ECONNREFUSED`: retry loop catches the error (the
   `ECONNREFUSED` branch is Linux-only, added by Patch 6 step 1 so
   stale sockets don't bypass retry).
3. Auto-launch (Patch 6 step 2): the injected code forks the daemon
   via `child_process.fork()` with `detached:true`, stdio redirected
   to `~/.config/Claude/logs/cowork_vm_daemon.log`.
4. Spawn cooldown: `FUNC._lastSpawn = Date.now()` — subsequent
   iterations only re-fork after 10 s have elapsed. This replaces the
   old one-shot `_svcLaunched` boolean so the retry loop can recover
   after mid-session daemon death (issue #408).
5. Retry: the loop waits and reconnects, which now succeeds.

## Issue #408 — Daemon Recovery

### Root cause (one-shot guard)

Before the fix, Patch 6 injected:

```javascript
process.platform==="linux" && !FUNC._svcLaunched && (
    FUNC._svcLaunched = true,
    /* fork daemon */
)
```

`FUNC._svcLaunched` was set on the first successful spawn and never
cleared, so when the daemon died mid-session the retry loop saw the
guard already set and skipped the re-fork. The client looped forever
on `connect ENOENT`.

### Fix (rate-limited respawn)

Timestamp-based cooldown replaces the boolean:

```javascript
process.platform==="linux" &&
(!FUNC._lastSpawn || Date.now() - FUNC._lastSpawn > 1e4) &&
(FUNC._lastSpawn = Date.now(), /* fork daemon */)
```

10 s is short enough that the retry loop (which sleeps on the order of
seconds between iterations) recovers promptly after a crash, and long
enough that a crash-looping daemon can't turn into a fork bomb.

### Secondary cause (preserved images block recovery)

The app's `_ue()` / `deleteVMBundle()` function deletes a whitelist of
reinstall files on auto-reinstall. Upstream deliberately preserves
`sessiondata.img` and `rootfs.img.zst` to avoid re-download.

On 1.2773.0 those preserved files put the daemon into an unstartable
state that persists across app restart and OS reboot. The client's
symptom is `connect ENOENT` (daemon never got far enough to create the
socket) rather than `ECONNREFUSED` (daemon started, crashed, socket
stayed). RayCharlizard (2026-04-16) confirmed that manually wiping
`~/.config/Claude/vm_bundles/claudevm.bundle/` is required to recover,
even after rolling back the AppImage to a known-good version.

### Fix (extend delete list — Patch 6b)

`scripts/patches/cowork.sh` now matches the `const NAME=["rootfs.img",...]` array at
module level and appends `"sessiondata.img"` and `"rootfs.img.zst"` if
they're not already present. The auto-reinstall path now wipes these
too. Trade-off: the next successful startup re-downloads/re-extracts
these files. Acceptable because auto-reinstall only runs after startup
has already failed — biasing toward recovery over re-download
avoidance is correct.

Not included in the delete list: `~/.config/Claude/claude-code-vm/`.
That's CLI-binary storage (`2.1.x/claude`), unrelated to the VM
daemon, and has its own version-check logic at `this.vmStorageDir`
inside the app. Wiping it would just force a slow re-download of the
CLI on every auto-reinstall.

## Silent Death — Now Logged

Before the fix the daemon was forked with `stdio:"ignore"`, and its
internal `log()` function was gated by `COWORK_VM_DEBUG=1`, so a crash
left no trace anywhere.

Two changes together make crashes visible:

1. **Patch 6 (client side)** redirects the forked daemon's stdout +
   stderr to `~/.config/Claude/logs/cowork_vm_daemon.log`. Any
   Node-level crash dump (uncaught exception pre-handler, native
   assertion, etc.) now lands in that file.
2. **`cowork-vm-service.js` (daemon side)** adds `logLifecycle()` —
   an always-on writer that bypasses `DEBUG` for startup, SIGTERM,
   SIGINT, `uncaughtException`, `unhandledRejection`, and `exit`
   events. It also proactively `mkdirSync`'s the log directory so the
   first write doesn't get swallowed if the daemon is the first thing
   writing under `~/.config/Claude/logs/`.

Interpreting the log after a failure:

| Last line | Diagnosis |
|-----------|-----------|
| `lifecycle startup ...` + gap + no further entries | SIGKILL'd (OOM killer, `kill -9`, etc.) — no handler fires |
| `lifecycle startup` + `lifecycle listening` + nothing else | Daemon running fine but died by signal with no handler (rare; check `dmesg`) |
| `lifecycle uncaughtException ...` | JS-level crash, stack is in the log entry |
| `lifecycle SIGTERM received` + `lifecycle exit code=0` | Clean app-initiated shutdown |
| No `startup` entry at all | `fork()` didn't complete; check launcher.log for `[cowork-autolaunch]` errors |

## Key Files

- [`scripts/patches/cowork.sh`](../../scripts/patches/cowork.sh)
  inside `patch_cowork_linux()` — Patch 6 (auto-launch + stdio pipe +
  rate limiter) and Patch 6b (reinstall array extension). Search for
  `# Patch 6` anchors; line numbers drift between upstream releases.
- [`scripts/cowork-vm-service.js`](../../scripts/cowork-vm-service.js)
  lines ~49-86 — log infrastructure, including `logLifecycle()`.
- [`scripts/cowork-vm-service.js`](../../scripts/cowork-vm-service.js)
  lines ~2399-2440 — signal handlers and entry point.
- [`scripts/launcher-common.sh`](../../scripts/launcher-common.sh) — `--doctor` checks.
- [`docs/cowork-linux-handover.md`](../cowork-linux-handover.md) — architecture reference.

## Diagnostic Commands

```bash
# Is the daemon running?
pgrep -af cowork-vm-service

# Socket present?
ls -la "${XDG_RUNTIME_DIR:-/tmp}/cowork-vm-service.sock"

# Watch lifecycle events as they happen
tail -f ~/.config/Claude/logs/cowork_vm_daemon.log

# Look for the last startup / exit pair
grep -E 'lifecycle (startup|exit|SIGTERM|SIGINT|uncaughtException|unhandledRejection)' \
    ~/.config/Claude/logs/cowork_vm_daemon.log | tail -20

# Find any orphan sockets
lsof -U 2>/dev/null | grep -iE 'cowork|claude'

# Force a respawn test: kill daemon, watch client log for reconnect
pkill -9 -f cowork-vm-service.js
tail -f ~/.cache/claude-desktop-suse/launcher.log

# Find the daemon script inside a mounted AppImage
find /tmp -path '*claude*cowork-vm-service*' 2>/dev/null
```

## Testing Notes

- **Host-direct** (`COWORK_VM_BACKEND=host`): no isolation, direct
  execution. Matches the `--doctor` "host-direct (no isolation, via
  override)" line. This is what issue #408 was reported against.
- **Bwrap** (`COWORK_VM_BACKEND=bwrap`): Bubblewrap sandbox; requires
  `bwrap` installed.
- **KVM** (`COWORK_VM_BACKEND=kvm`): full VM; requires QEMU, KVM,
  rootfs image.
- **Debug** (`COWORK_VM_DEBUG=1` or `CLAUDE_LINUX_DEBUG=1`): verbose
  logging via the existing `log()` path. `logLifecycle()` is always
  on regardless of this flag.
- **Force-cooldown test**: kill the daemon, relaunch a Cowork session
  within 10 s — the guard should block that single retry. Wait 10 s
  and retry: should succeed. Confirms the cooldown boundary.

## RPC Surface and Concurrent Dispatch (2026-11)

The Windows client calls several RPCs that older SUSE daemons did not
register. They are now in the `METHODS` table in
[`scripts/cowork-vm-service.js`](../../scripts/cowork-vm-service.js):

| RPC | Host / bwrap | KVM |
|-----|--------------|-----|
| `sendGuestResponse` | logs and returns `{}` (no guest) | `handler not registered: sendGuestResponse (unsupported on KVM backend: guest wire protocol unverified)` |
| `getSessionsDiskInfo` | `statfsSync(os.homedir())`, `sessions: []` | `handler not registered: getSessionsDiskInfo (unsupported on KVM backend: guest wire protocol unverified)` |
| `deleteSessionDirs` | `{deleted: [], errors: {}}` | `handler not registered: deleteSessionDirs (unsupported on KVM backend: guest wire protocol unverified)` |
| `pruneSessionCaches` | empty result, `freedBytes: 0` | `handler not registered: pruneSessionCaches (unsupported on KVM backend: guest wire protocol unverified)` |
| `getNetworkDrives` | `{drives: []}` | `{drives: []}` |
| `getMemoryInfo` | `os.totalmem()` / `os.freemem()`, plus `/proc/meminfo` `MemAvailable` as `availableBytes` | same |

`runEdrExtension` is intentionally not registered. It throws
`handler not registered: runEdrExtension`; the client treats both that
message and `unknown method: <name>` as its `unsupported` outcome.
`refreshGuestProxy` is likewise left unregistered on purpose. The
dispatcher's unknown-method error must stay lowercase
(`unknown method: <name>`): the client compares
`error.message === "unknown method: refreshGuestProxy"` exactly.

The four KVM disk methods are registered handlers that deliberately
reject with the `handler not registered:` prefix so the Windows client
classifies them as `unsupported`, not as a hard failure. The trailing
`(unsupported on KVM backend: guest wire protocol unverified)` keeps the
reason visible in logs. Do not drop the prefix when
editing the message; `tests/cowork-rpc-dispatch.bats` asserts both the
exact text and the client-side prefix classification.

### Guest reverse requests are disabled

An earlier revision inferred a guest→host request frame from the host→
guest request path, re-emitted `type: "request"` frames as events, and
answered them through `sendGuestResponse`. No guest image or independent
capture ever confirmed that shape, so the daemon no longer forwards it:
`type: "request"` frames are logged as unhandled, `sendGuestResponse`
returns the explicit unsupported error above on KVM, and no pending-id
set exists. The verified host/bwrap behaviour is unchanged. Enable this
again only with a captured guest protocol, and add a test that fails on
the unverified shape.

### VM lifecycle serialization

`VMManager.startVM` and `VMManager.stopVM` share a FIFO
(`_enqueueVMLifecycle`). Without it, two pipelined `startVM` calls both
passed the `this.running` check, each created an overlay and session
directory, and the second overwrote `sessionDir`, leaking the first and
starting two QEMU processes. `isRunning`/`isGuestConnected` do not enter
the queue, so status reads stay responsive while a start or stop runs.

A start is abortable rather than merely queued. `KvmBackend` gives
`startVM` a per-start token (`_beginStartup`), and both QMP negotiation
and guest readiness observe it: `_connectQmp` retries on a closed socket
and stops at `qmpConnectTimeout` even when a peer accepts but never sends
`"return"`, while `_waitForGuest` clears its poll/deadline timers and
resolves when the token is cancelled. `VMManager.stopVM` cancels queued
and active starts (`VM stop requested`), calls `backend.requestStop()`,
then enqueues the stop. The stop reaches the backend only after the
aborted start settles, so it still cannot overlap a half-created VM; the
start RPC fails instead of pinning the queue forever.

Shutdown is not a queued stop. `VMManager.beginShutdown` rejects queued
and active starts, sets a latch that rejects every later start, aborts the
current startup, and drains the queue. `shutdown()` calls the backend's
`stopVM` directly (or reuses an already-running stop) and waits at most
`shutdownTimeout` (30s). The server sets its shutdown guard, calls
`server.close()` before waiting, and only then exits, so a start cannot
slip in after the final stop. When that deadline expires, `shutdown()`
calls `backend.forceCleanup()` before returning: it SIGKILLs the owned
QEMU, kills virtiofsd/socat, closes the QMP/guest connections and bridge
server, and removes the session directory, so `process.exit(0)` never
leaves a half-started VM behind. `_sendQmpCommand` keeps the socket it
wrote to and rejects with `QMP connection closed` when that socket
closes, so a concurrent `stopVM` waiting on `system_powerdown` settles
instead of its 10s timer dereferencing a `_qmpClient` that cleanup has
already cleared.

Every startup step checks the token: after each wait (virtiofsd socket,
QMP, guest) and before each resource it creates (overlay, virtiofsd,
session disk, smol-bin conversion, QEMU). The virtiofsd socket poll uses a
cancellation-aware delay, and a cancelled `startVM` runs `forceCleanup()`
in its catch path. The trade-off: a start that is blocked in a
synchronous `qemu-img` conversion is not interruptible by the token; its
own 300s timeout bounds it, it also blocks the shutdown timer, and the
post-conversion check still prevents QEMU from being spawned afterwards.

### Why dispatch is concurrent

The old frame loop awaited `handleRequest` inside `socket.on('data')`, so
a `startVM` that waited on QMP blocked `isRunning` and every other request
on the same socket. The loop now parses all complete frames synchronously
and calls `handleRequest` per frame, writing each reply when it resolves.
The client matches replies by `id`, so out-of-order completion is safe;
the daemon still writes each frame in one `writeMessage` call, so partial
frames never interleave.

`tests/cowork-rpc-dispatch.bats` covers the shapes above per backend, the
exact error strings, split/batched frames, request-id echo, disabled
guest forwarding, and concurrency. The concurrency case runs the KVM
backend with fake `qemu-img`/`qemu-system-x86_64` PATH entries: `startVM`
parks in the QMP wait while `isRunning` must answer first, with a bounded
timeout and no fixed sleeps. The lifecycle case drives `VMManager` with
gated fake `startVM`/`stopVM` promises and one event-loop turn instead of
sleeps: a second start must not reach the backend until the first
settles, and a stop aborts the pending start before it runs, while
`isRunning` still answers. The QMP case uses local Unix sockets that
never answer, close immediately, or hang until cancellation; each call
must settle inside a bounded `withDeadline`. It also negotiates normally
and requires `system_powerdown`/`quit` to reach the same socket, which is
then destroyed. The KVM-cancel case requests a stop while a fake
virtiofsd socket is still pending and asserts that no session disk,
smol-bin conversion or QEMU follows, and that virtiofsd and the session
directory are reclaimed. The force-cleanup case checks the same reclaim
for a running VM. The guest-wait case cancels
a real bridge listen and requires the wait promise to resolve. The
shutdown case gates a start, a queued start, a stop and a second
shutdown: it asserts the stop runs before the queued start, queued and
new starts reject `Shutting down`, the queue never runs the start after
the final stop, an active stop is reused (one `stop` call), and a stop
that never settles still returns within `shutdownTimeout` after one
`forceCleanup()`. Mutation checks confirm the lifecycle test fails when
dispatch is not serialized, an unguarded start would show up as `start:b`
after `stop` in the shutdown test, re-clearing `_qmpClient` after a
successful negotiation fails the QMP case, dropping the post-wait token
checks spawns QEMU in the KVM-cancel case, and removing the deadline
`forceCleanup()` fails the shutdown case.

