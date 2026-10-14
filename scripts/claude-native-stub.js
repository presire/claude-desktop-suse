// Stub implementation of claude-native for Linux
// Uses Electron's native Linux support where possible instead of no-ops
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);

// Helper: get the focused BrowserWindow (lazy-loaded to avoid circular deps)
// Filters destroyed windows from fallback to avoid errors like
// flashFrame() on a destroyed window or getIsMaximized() on a popup.
// Note: isVisible() is intentionally NOT checked — flashFrame() must work
// on minimized (non-visible) windows, which is its primary use case.
function getWindow() {
  try {
    const { BrowserWindow } = require('electron');
    const focused = BrowserWindow.getFocusedWindow();
    if (focused) return focused;
    // TODO: Fallback may return a popup window; callers like
    // getIsMaximized() may behave unexpectedly on popups.
    const win = BrowserWindow.getAllWindows().find(
      (w) => !w.isDestroyed()
    );
    return win || null;
  } catch (e) {
    console.warn('[Claude Native Stub] getWindow() failed:', e);
    return null;
  }
}

// AuthRequest stub - not available on Linux, will cause fallback to system browser
class AuthRequest {
  static isAvailable() {
    return false;
  }

  async start(url, scheme, windowHandle) {
    throw new Error('AuthRequest not available on Linux');
  }

  cancel() {
    // no-op
  }
}

// safe-fs: the bundle opens a root directory once and then reaches every
// path below it through *Beneath(rootFd, segments, ...) so a symlink can't
// redirect a write outside the root. It closes the returned fds itself with
// fs.close, and reads the error code from a leading "CODE: " in the message.
// Linux stand-in for openat(): walk /proc/self/fd/<dirFd>/<segment> one
// component at a time with O_NOFOLLOW, so a symlinked directory fails with
// ENOTDIR and a symlinked leaf with ELOOP, which the bundle treats as an
// unsafe path.
const fs = require('fs');
const { promisify } = require('util');

const fsp = fs.promises;
const fsOpen = promisify(fs.open);
const fsClose = promisify(fs.close);
const { O_RDONLY, O_DIRECTORY, O_NOFOLLOW } = fs.constants;

function fsError(code, message) {
  const err = new Error(`${code}: ${message}`);
  err.code = code;
  return err;
}

function atFd(dirFd, name) {
  return `/proc/self/fd/${dirFd}/${name}`;
}

function checkSegments(segments) {
  if (!Array.isArray(segments) || segments.length === 0) {
    throw fsError('EINVAL', 'empty path below the root');
  }
  for (const seg of segments) {
    if (seg === '..') {
      throw fsError('EXDEV', 'path escapes the root directory');
    }
    if (typeof seg !== 'string' || seg === '' || seg === '.' ||
        seg.includes('/') || seg.includes('\0')) {
      throw fsError('EINVAL', `invalid path segment: ${JSON.stringify(seg)}`);
    }
  }
}

async function atLeaf(rootFd, segments, fn) {
  checkSegments(segments);
  let dirFd = rootFd;
  try {
    for (const seg of segments.slice(0, -1)) {
      const next = await fsOpen(atFd(dirFd, seg),
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
      if (dirFd !== rootFd) await fsClose(dirFd);
      dirFd = next;
    }
    return await fn(atFd(dirFd, segments[segments.length - 1]));
  } finally {
    if (dirFd !== rootFd) await fsClose(dirFd).catch(() => undefined);
  }
}

// Process memory: read from /proc. The bundle maps every missing field to
// null. creationTime only has to be stable per process (pid-reuse check).
const USER_HZ = 100; // /proc clock-tick unit, fixed on Linux
let bootTimeMs;

async function readBootTimeMs() {
  if (bootTimeMs === undefined) {
    const m = /^btime (\d+)$/m.exec(await fsp.readFile('/proc/stat', 'utf8'));
    bootTimeMs = m ? Number(m[1]) * 1000 : null;
  }
  return bootTimeMs;
}

async function readProcStat(pid) {
  const raw = await fsp.readFile(`/proc/${pid}/stat`, 'utf8');
  // comm (field 2) may contain spaces; fields after it start at state (3).
  const f = raw.slice(raw.lastIndexOf(')') + 2).split(' ');
  const bootMs = await readBootTimeMs();
  return {
    parentPid: Number(f[1]),
    cpuSeconds: (Number(f[11]) + Number(f[12])) / USER_HZ,
    creationTime: bootMs === null
      ? null : bootMs + Math.round(Number(f[19]) * 1000 / USER_HZ),
  };
}

async function readProcMemory(pid) {
  const raw = await fsp.readFile(`/proc/${pid}/status`, 'utf8');
  const kb = (key) => {
    const m = new RegExp(`^${key}:\\s+(\\d+) kB$`, 'm').exec(raw);
    return m ? Number(m[1]) * 1024 : null;
  };
  return { rss: kb('VmRSS'), anon: kb('RssAnon'), swap: kb('VmSwap') };
}

// A process that exits mid-read is reported as null, like the native build.
const orNull = (promise) => promise.catch(() => null);

module.exports = {
  getWindowsVersion: () => "10.0.0",

  // Windows-only native methods with no Linux equivalent. Newer upstream
  // (Claude Desktop >= 1.13576.0) calls readRegistryValues() and
  // getWindowsElevationType() UNCONDITIONALLY at startup — the
  // managed-config / enterprise-policy lookup — from the top level of
  // index.pre.js and index.js. The bundle only guards the native module
  // being null (e.g. `(o=g2())==null?void 0:o.readRegistryValues(r)`),
  // not the method being absent, so a missing method throws
  // "<method> is not a function" during top-level execution, before the
  // logger and main window exist. index.pre.js installs an empty
  // uncaughtException handler early, so the throw is swallowed: the
  // process stays alive in the event loop but no window ever appears.
  // Stub these as neutral no-ops (no registry, no MSIX package, no UAC
  // on Linux) so the `?? []` / `?? "default"` consumers proceed. Fixing
  // the stub covers every call site at the source and is robust against
  // re-minification. Fixes the "hangs indefinitely, app window never
  // shows up" regression (#729).
  readRegistryValues: () => [],
  writeRegistryValue: () => {},
  writeRegistryDword: () => {},
  getWindowsElevationType: () => "default",
  getCurrentPackageFamilyName: () => null,
  // Cloud-sync folder lookup (OneDrive etc.) iterates these with for...of
  // when a folder is picked; non-iterable results break "Add folder".
  enumRegistrySubkeys: () => [],
  enumRegistryValues: () => [],

  openRootDir: (dirPath) => fsOpen(dirPath, O_RDONLY | O_DIRECTORY),
  openBeneath: (rootFd, segments, flags, mode) =>
    atLeaf(rootFd, segments, (p) => fsOpen(p, flags | O_NOFOLLOW, mode)),
  mkdirBeneath: (rootFd, segments, mode) =>
    atLeaf(rootFd, segments, (p) => fsp.mkdir(p, { mode })),
  renameBeneath: (rootFd, from, to) =>
    atLeaf(rootFd, from, (src) =>
      atLeaf(rootFd, to, (dst) => fsp.rename(src, dst))),
  unlinkBeneath: (rootFd, segments) =>
    atLeaf(rootFd, segments, (p) => fsp.unlink(p)),
  rmdirBeneath: (rootFd, segments) =>
    atLeaf(rootFd, segments, (p) => fsp.rmdir(p)),
  statBeneath: (rootFd, segments) =>
    atLeaf(rootFd, segments, (p) => fsp.lstat(p)),

  // Rows for rootPid and its descendants.
  readProcessTree: async (rootPid) => {
    const children = new Map();
    const stats = new Map();
    for (const name of await fsp.readdir('/proc')) {
      if (!/^\d+$/.test(name)) continue;
      const pid = Number(name);
      const stat = await orNull(readProcStat(pid));
      if (!stat) continue;
      stats.set(pid, stat);
      if (!children.has(stat.parentPid)) children.set(stat.parentPid, []);
      children.get(stat.parentPid).push(pid);
    }
    const rows = [];
    const queue = stats.has(rootPid) ? [rootPid] : [];
    while (queue.length > 0) {
      const pid = queue.shift();
      const mem = await orNull(readProcMemory(pid));
      const { parentPid, cpuSeconds, creationTime } = stats.get(pid);
      rows.push({
        pid,
        parentPid,
        workingSetBytes: mem?.rss ?? null,
        privateWorkingSetBytes: mem?.anon ?? null,
        commitBytes: null,
        cpuSeconds,
        creationTime,
      });
      queue.push(...(children.get(pid) ?? []));
    }
    return rows;
  },
  // One entry per pid, in order; footprint = private resident + swapped.
  readProcessFootprints: (pids) => Promise.all(pids.map((pid) => orNull(
    Promise.all([readProcStat(pid), readProcMemory(pid)])
      .then(([stat, mem]) => ({
        footprintBytes: mem.anon === null ? null : mem.anon + (mem.swap ?? 0),
        commitBytes: null,
        creationTime: stat.creationTime,
      }))
  ))),

  setWindowEffect: () => {},
  removeWindowEffect: () => {},

  // Functional on Linux via Electron's native support
  getIsMaximized: () => {
    const win = getWindow();
    return win ? win.isMaximized() : false;
  },

  // Fixes: #149 - KDE Plasma: Window demands attention
  // flashFrame is natively supported on Linux Electron.
  // frame-fix-wrapper.js auto-clears on window focus.
  flashFrame: (flash) => {
    const win = getWindow();
    if (win) win.flashFrame(typeof flash === 'boolean' ? flash : true);
  },
  clearFlashFrame: () => {
    const win = getWindow();
    if (win) win.flashFrame(false);
  },

  showNotification: () => {},

  // Progress bar is natively supported on Linux (Unity/KDE/GNOME)
  setProgressBar: (progress) => {
    const win = getWindow();
    if (win && typeof progress === 'number') {
      win.setProgressBar(Math.max(0, Math.min(1, progress)));
    }
  },
  clearProgressBar: () => {
    const win = getWindow();
    if (win) win.setProgressBar(-1);
  },

  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey,
  AuthRequest
};
