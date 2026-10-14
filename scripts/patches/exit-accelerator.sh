#===============================================================================
# Add Ctrl+Q accelerator to the Exit menu item.
#
# Sourced by: build.sh
# Sourced globals: (none)
# Modifies globals: (none)
#===============================================================================

patch_exit_accelerator() {
	echo 'Patching Exit menu item to add Ctrl+Q accelerator...'
	if ! INDEX_JS="$main_js" node << 'EXIT_ACCELERATOR_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code;
try {
    code = fs.readFileSync(indexJs, 'utf8');
} catch (e) {
    console.warn('  WARNING: cannot read ' + indexJs + ' — skipping');
    process.exit(0);
}

// Anchor on i18n ids, which survive re-minification: 2.37337.1 dropped
// the description string the old anchor relied on. The Exit label
// (7fdcqxofEs) appears in both the application File menu and the tray
// context menu. Only the File menu entry gets the accelerator: Electron
// builds the X11 tray menu through GTK with a null accel group, so an
// accelerator there trips `GTK_IS_ACCEL_GROUP (accel_group)` without
// adding a working shortcut. The File menu Exit follows Settings
// (qHPWFPPXPZ); the tray Exit follows "Show App" (DQTgg21B7g).
const q = '[`"\']';
const id = (value) => 'id:\\s*' + q + value + q;
const exitRe = new RegExp(id('7fdcqxofEs') +
    '(?:\\s*,\\s*description:\\s*' + q + '[^`"\']*' + q + ')?' +
    '\\s*\\}\\s*\\)\\s*,\\s*(accelerator:|click:)', 'g');
const settingsRe = new RegExp(id('qHPWFPPXPZ'), 'g');
const showAppRe = new RegExp(id('DQTgg21B7g'), 'g');
const lastMarker = (re, start, end) => {
    let last = -1;
    for (const m of code.substring(start, end).matchAll(re)) {
        last = start + m.index;
    }
    return last;
};
const appMenuSites = [...code.matchAll(exitRe)].filter((m) => {
    const start = Math.max(0, m.index - 2000);
    const settings = lastMarker(settingsRe, start, m.index);
    return settings !== -1 && settings > lastMarker(showAppRe, start, m.index);
});

if (appMenuSites.length !== 1) {
    console.warn('  WARNING: application menu Exit item matched ' +
        appMenuSites.length + ' sites (expected 1) — skipping');
    process.exit(0);
}
const site = appMenuSites[0];
if (site[1] === 'accelerator:') {
    console.log('  Exit menu accelerator already present');
    process.exit(0);
}
const at = site.index + site[0].length - site[1].length;
code = code.slice(0, at) + 'accelerator:"CmdOrCtrl+Q",' + code.slice(at);
fs.writeFileSync(indexJs, code);
console.log('  Added CmdOrCtrl+Q accelerator to the application menu' +
    ' Exit item (tray menu unchanged)');
EXIT_ACCELERATOR_PATCH
	then
		echo '  WARNING: Exit menu accelerator patch failed' >&2
	fi
	echo '##############################################################'
}
