#!/usr/bin/env bats
# Tests for Linux compatibility shims in scripts/frame-fix-wrapper.js.

setup() {
	WRAPPER="$BATS_TEST_DIRNAME/../scripts/frame-fix-wrapper.js"
}

@test "frame-fix-wrapper: shims Win32 hookWindowMessage APIs on Linux before super() finishes" {
	run node -e '
const Module = require("module");
const EventEmitter = require("events");
const wrapperPath = process.argv[1];

const fakeApp = new EventEmitter();
fakeApp.isReady = () => false;
fakeApp.on = fakeApp.on.bind(fakeApp);
fakeApp.once = fakeApp.once.bind(fakeApp);
fakeApp.getPath = () => "/tmp";
fakeApp.getName = () => "Claude";
fakeApp.getAppPath = () => "/tmp";
fakeApp.getVersion = () => "7.37095.0";
fakeApp.getLoginItemSettings = () => ({ openAtLogin: false });
fakeApp.setLoginItemSettings = () => {};
fakeApp.whenReady = () => Promise.resolve();
fakeApp.dock = null;

class FakeBrowserWindow extends EventEmitter {
  constructor(opts) {
    super();
    this.opts = opts;
    this.webContents = new EventEmitter();
    this.webContents.insertCSS = () => Promise.resolve("");
    this.webContents.setWindowOpenHandler = () => {};
    this.webContents.isDestroyed = () => false;
    this.webContents.focus = () => {};
    this.webContents.executeJavaScript = () => Promise.resolve();
    this.setMenuBarVisibility = () => {};
    this.setIcon = () => {};
    this.isDestroyed = () => false;
    // Simulate Electron emitting browser-window-created inside _init (during super())
    fakeApp.emit("browser-window-created", {}, this);
  }
  static getAllWindows() { return []; }
}

const fakeElectron = {
  app: fakeApp,
  BrowserWindow: FakeBrowserWindow,
  Menu: {
    setApplicationMenu() {},
    getApplicationMenu() { return null; },
    buildFromTemplate(t) { return t; }
  },
  nativeImage: { createFromPath() { return { isEmpty: () => true }; } },
  powerSaveBlocker: { start() { return 1; }, stop() {}, isStarted() { return false; } },
  autoUpdater: new EventEmitter(),
  screen: { getPrimaryDisplay() { return { workAreaSize: { width: 1280, height: 800 } }; } },
};

const origLoad = Module._load;
Module._load = function(id, parent, isMain) {
  if (id === "electron") return fakeElectron;
  return origLoad.apply(this, arguments);
};

require(wrapperPath);
const electron = require("electron");

let hookCalledInInit = false;
electron.app.on("browser-window-created", (_evt, win) => {
  win.hookWindowMessage(0x001a, () => {});
  if (win.isWindowMessageHooked(0x001a) !== false) {
    throw new Error("expected isWindowMessageHooked to return false");
  }
  win.unhookWindowMessage(0x001a);
  win.unhookAllWindowMessages();
  hookCalledInInit = true;
});

const w = new electron.BrowserWindow({ width: 800, height: 600 });
if (!hookCalledInInit) throw new Error("browser-window-created did not run");
if (typeof w.hookWindowMessage !== "function") throw new Error("missing hookWindowMessage");
console.log("OK");
' "$WRAPPER"
	[[ $status -eq 0 ]]
	[[ "$output" == *"OK"* ]]
}

@test "frame-fix-wrapper: shims Win32 hookWindowMessage APIs on a plain BaseWindow on Linux" {
	run node -e '
const Module = require("module");
const EventEmitter = require("events");
const wrapperPath = process.argv[1];

const fakeApp = new EventEmitter();
fakeApp.isReady = () => false;
fakeApp.on = fakeApp.on.bind(fakeApp);
fakeApp.once = fakeApp.once.bind(fakeApp);
fakeApp.getPath = () => "/tmp";
fakeApp.getName = () => "Claude";
fakeApp.getAppPath = () => "/tmp";
fakeApp.getVersion = () => "7.37095.0";
fakeApp.getLoginItemSettings = () => ({ openAtLogin: false });
fakeApp.setLoginItemSettings = () => {};
fakeApp.whenReady = () => Promise.resolve();
fakeApp.dock = null;

// Owner reassignment in 7.37095.0 hooks the message during construction.
class FakeBaseWindow extends EventEmitter {
  constructor(opts) {
    super();
    this.opts = opts;
    this.hookWindowMessage(0x001a, () => {});
  }
}

const fakeElectron = {
  app: fakeApp,
  BrowserWindow: class FakeBrowserWindow extends EventEmitter {},
  BaseWindow: FakeBaseWindow,
  Menu: {
    setApplicationMenu() {},
    getApplicationMenu() { return null; },
    buildFromTemplate(t) { return t; }
  },
  nativeImage: { createFromPath() { return { isEmpty: () => true }; } },
  powerSaveBlocker: { start() { return 1; }, stop() {}, isStarted() { return false; } },
  autoUpdater: new EventEmitter(),
  screen: { getPrimaryDisplay() { return { workAreaSize: { width: 1280, height: 800 } }; } },
};

const origLoad = Module._load;
Module._load = function(id, parent, isMain) {
  if (id === "electron") return fakeElectron;
  return origLoad.apply(this, arguments);
};

require(wrapperPath);
const electron = require("electron");

const win = new electron.BaseWindow({ width: 640, height: 480 });
win.hookWindowMessage(0x0010, () => {});
if (win.isWindowMessageHooked(0x0010) !== false) {
  throw new Error("expected isWindowMessageHooked to return false");
}
win.unhookWindowMessage(0x0010);
win.unhookAllWindowMessages();
if (typeof electron.BaseWindow.prototype.hookWindowMessage !== "function") {
  throw new Error("missing BaseWindow hookWindowMessage");
}
console.log("OK");
' "$WRAPPER"
	[[ $status -eq 0 ]]
	[[ "$output" == *"OK"* ]]
}
