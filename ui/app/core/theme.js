// Vanilla, no bundler. Pure theme logic extracted from app.js 370-391.

export var THEMES = ["system", "light", "dark", "mocha", "latte", "frappe", "macchiato", "tokyonight", "tokyonight-storm", "tokyonight-day", "hackerman"];

export function loadTheme() {
  var t = null;
  try { t = window.localStorage.getItem("clanker.theme"); } catch (e) {}
  return THEMES.indexOf(t) === -1 ? "system" : t;
}

export function applyTheme(theme, opts) {
  var id = (opts && opts.toggleId) || "theme-toggle";
  if (theme === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", theme);
  var btn = document.getElementById(id);
  if (btn) btn.textContent = "theme: " + theme;
}


