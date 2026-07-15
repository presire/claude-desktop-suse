#!/usr/bin/env bats
#
# frame-fix-menu.bats
# Tests the pure menu-injection helper without loading Electron.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

NODE_PREAMBLE='
const {
    findViewSubmenu,
    hasFullscreenItem,
    injectFullscreenItem,
} = require("'"${SCRIPT_DIR}"'/../scripts/frame-fix-menu.js");

class MockMenuItem {
    constructor(options) {
        Object.assign(this, options);
    }
}

class MockMenu {
    constructor(items = []) {
        this.items = items;
    }

    append(item) {
        this.items.push(item);
    }
}

function assert(condition, message) {
    if (!condition) {
        process.stderr.write("ASSERTION FAILED: " + message + "\n");
        process.exit(1);
    }
}

function assertEqual(actual, expected, message) {
    assert(actual === expected,
        message + " expected=" + JSON.stringify(expected) +
        " actual=" + JSON.stringify(actual));
}
'

@test "findViewSubmenu: finds Electron viewMenu role" {
	run node -e "${NODE_PREAMBLE}
const submenu = new MockMenu();
const menu = new MockMenu([{ role: 'viewMenu', submenu }]);
assertEqual(findViewSubmenu(menu), submenu, 'viewMenu role');
"
	[[ "$status" -eq 0 ]]
}

@test "findViewSubmenu: finds submenu by locale-independent content roles" {
	run node -e "${NODE_PREAMBLE}
const submenu = new MockMenu([
    { role: 'reload' },
    { role: 'zoomIn' },
]);
const menu = new MockMenu([{ label: '表示', submenu }]);
assertEqual(findViewSubmenu(menu), submenu, 'view content roles');
"
	[[ "$status" -eq 0 ]]
}

@test "findViewSubmenu: finds localized label with mnemonic" {
	local node_script="${NODE_PREAMBLE}
const submenu = new MockMenu();
const menu = new MockMenu([{ label: '&View', submenu }]);
assertEqual(findViewSubmenu(menu), submenu, 'mnemonic label');
"
	run node -e "$node_script"
	[[ "$status" -eq 0 ]]
}

@test "findViewSubmenu: returns null when no View menu exists" {
	run node -e "${NODE_PREAMBLE}
const menu = new MockMenu([{ label: 'File', submenu: new MockMenu() }]);
assertEqual(findViewSubmenu(menu), null, 'missing View menu');
"
	[[ "$status" -eq 0 ]]
}

@test "injectFullscreenItem: appends only inside existing View submenu" {
	run node -e "${NODE_PREAMBLE}
const submenu = new MockMenu([{ role: 'reload' }]);
const menu = new MockMenu([{ label: '表示', submenu }]);
const topLevelCount = menu.items.length;
const injected = injectFullscreenItem(menu, MockMenuItem);
assertEqual(injected, true, 'injected');
assertEqual(menu.items.length, topLevelCount, 'top-level item count');
assertEqual(submenu.items.length, 2, 'submenu item count');
const item = submenu.items[1];
assertEqual(item.role, 'togglefullscreen', 'role');
assertEqual(item.accelerator, 'F11', 'accelerator');
assertEqual(item.visible, true, 'visibility');
"
	[[ "$status" -eq 0 ]]
}

@test "injectFullscreenItem: is idempotent" {
	run node -e "${NODE_PREAMBLE}
const submenu = new MockMenu([{ role: 'reload' }]);
const menu = new MockMenu([{ label: '表示', submenu }]);
assertEqual(injectFullscreenItem(menu, MockMenuItem), true, 'first injection');
assertEqual(injectFullscreenItem(menu, MockMenuItem), false, 'second injection');
assertEqual(submenu.items.length, 2, 'no duplicate item');
assert(hasFullscreenItem(submenu), 'fullscreen item exists');
"
	[[ "$status" -eq 0 ]]
}

@test "injectFullscreenItem: skips an existing F11 item" {
	run node -e "${NODE_PREAMBLE}
const existing = new MockMenuItem({
    role: 'togglefullscreen',
    accelerator: 'F11',
});
const submenu = new MockMenu([existing]);
const menu = new MockMenu([{ label: 'View', submenu }]);
assertEqual(injectFullscreenItem(menu, MockMenuItem), false, 'existing item');
assertEqual(submenu.items.length, 1, 'no duplicate item');
"
	[[ "$status" -eq 0 ]]
}

@test "injectFullscreenItem: fails closed when View submenu is missing" {
	run node -e "${NODE_PREAMBLE}
const menu = new MockMenu([{ label: 'Help', submenu: new MockMenu() }]);
assertEqual(injectFullscreenItem(menu, MockMenuItem), false, 'missing submenu');
assertEqual(menu.items.length, 1, 'no top-level fallback');
"
	[[ "$status" -eq 0 ]]
}
