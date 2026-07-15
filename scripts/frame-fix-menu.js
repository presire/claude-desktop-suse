'use strict';

const VIEW_LABELS = new Set([
  'view', '表示', 'ansicht', 'affichage', 'vista', 'visualizar',
  'ver', '보기', '查看', '檢視', 'visualizzazione', 'weergave',
  'widok', 'vy', 'näkymä',
]);

const VIEW_ROLES = new Set([
  'reload', 'forcereload', 'zoomin', 'zoomout', 'resetzoom',
  'toggledevtools',
]);

function normalizeLabel(label) {
  return typeof label === 'string'
    ? label.replace(/&/g, '').trim().toLowerCase()
    : '';
}

function hasViewRole(item) {
  return typeof item?.role === 'string'
    && item.role.toLowerCase() === 'viewmenu';
}

function hasViewContent(item) {
  return Array.isArray(item?.submenu?.items)
    && item.submenu.items.some((child) => (
      typeof child?.role === 'string'
      && VIEW_ROLES.has(child.role.toLowerCase())
    ));
}

function findViewSubmenu(menu) {
  if (!Array.isArray(menu?.items)) return null;

  const roleMatch = menu.items.find(hasViewRole);
  if (roleMatch?.submenu) return roleMatch.submenu;

  const contentMatch = menu.items.find(hasViewContent);
  if (contentMatch?.submenu) return contentMatch.submenu;

  const labelMatch = menu.items.find((item) => (
    item?.submenu && VIEW_LABELS.has(normalizeLabel(item.label))
  ));
  return labelMatch?.submenu || null;
}

function hasFullscreenItem(submenu) {
  return Array.isArray(submenu?.items) && submenu.items.some((item) => {
    const role = typeof item?.role === 'string'
      ? item.role.toLowerCase()
      : '';
    const label = normalizeLabel(item?.label);
    const accelerator = typeof item?.accelerator === 'string'
      ? item.accelerator.toLowerCase()
      : '';
    return role === 'togglefullscreen'
      || accelerator === 'f11'
      || label.includes('full screen');
  });
}

function injectFullscreenItem(menu, menuItemFactory) {
  const submenu = findViewSubmenu(menu);
  if (!submenu) {
    console.warn('[Frame Fix] No View submenu found; F11 not registered');
    return false;
  }
  if (hasFullscreenItem(submenu)) return false;

  submenu.append(new menuItemFactory({
    label: 'Toggle Full Screen',
    role: 'togglefullscreen',
    accelerator: 'F11',
    visible: true,
  }));
  console.log('[Frame Fix] Injected F11 fullscreen into existing View submenu');
  return true;
}

module.exports = {
  findViewSubmenu,
  hasFullscreenItem,
  injectFullscreenItem,
};
