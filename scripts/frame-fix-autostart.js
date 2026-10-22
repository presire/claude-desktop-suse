// StartupWMClass derivation shared by the runtime autostart writer.
//
// Chromium turns the asar package.json desktopName into the runtime
// X11 WM_CLASS / Wayland app_id by stripping the .desktop suffix. It
// ignores --class, productName, and Electron's app.name, so an
// autostart entry written with app.name never groups with the window
// it launches (#779). Keep this pure so tests can exercise it without
// loading Electron.

function desktopNameToWMClass(desktopName) {
  if (typeof desktopName !== 'string' || !desktopName.endsWith('.desktop')) {
    return '';
  }
  return desktopName.slice(0, -'.desktop'.length);
}

module.exports = { desktopNameToWMClass };
