// Vanilla, no bundler. Pure theme logic extracted from app.js 370-391.

export var THEMES = ["system", "light", "dark", "mocha", "latte", "frappe", "macchiato", "tokyonight", "tokyonight-storm", "tokyonight-day"];

export function loadTheme() {
  var t = null;
  try { t = window.localStorage.getItem("clanker.theme"); } catch (e) {}
  return THEMES.indexOf(t) === -1 ? "system" : t;
}

export function getTheme() {
  try {
    var t = window.localStorage.getItem("clanker.theme");
    if (THEMES.indexOf(t) !== -1) return t;
  } catch (e) {}
  return "system";
}

export function setTheme(theme) {
  try { window.localStorage.setItem("clanker.theme", theme); } catch (e) {}
}

export function applyTheme(theme, opts) {
  var id = (opts && opts.toggleId) || "theme-toggle";
  if (theme === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", theme);
  var btn = document.getElementById(id);
  if (btn) btn.textContent = "theme: " + theme;
}

export function cycleTheme(opts) {
  var cur = loadTheme();
  var next = THEMES[(THEMES.indexOf(cur) + 1) % THEMES.length];
  try { window.localStorage.setItem("clanker.theme", next); } catch (e) {}
  applyTheme(next, opts);
  return next;
}

// Backward compat for classic app.js global (kept duplicated there for now).
if (typeof window !== "undefined") {
  window.THEMES = window.THEMES || THEMES;
}
