// Vanilla, no bundler. Theme list comes from themes/*.json (served at
// /webui/themes/); apply writes those tokens onto :root. "system" is not a
// file: it clears the inline tokens so :root + the prefers-color-scheme
// block in app.css paint.

export var THEMES = ["system"];

var CATALOG = {};
var _appliedKeys = [];
var _current = "system";
var _catalogPromise = null;
var _picker = null;
var _list = null;
var _anchor = null;
var _open = false;
var _listeners = [];

function themeAsset(file) {
  return "/webui/themes/" + file;
}

function loadCatalog() {
  return fetch(themeAsset("catalog.json")).then(function (r) {
    if (!r.ok) throw new Error("themes catalog");
    return r.json();
  }).then(function (data) {
    var names = ["system"];
    var next = {};
    (data.themes || []).forEach(function (t) {
      if (!t || !t.id) return;
      next[t.id] = t;
      names.push(t.id);
    });
    CATALOG = next;
    THEMES = names;
    applyTheme(_current);
  }).catch(function () {
    // Serve path missing (tests, a host without themes/): picker keeps
    // "system" and any stored named theme waits until a later load.
  });
}

export function themesReady() {
  if (!_catalogPromise) _catalogPromise = loadCatalog();
  return _catalogPromise;
}

themesReady();

export function loadTheme() {
  var t = null;
  try { t = window.localStorage.getItem("clanker.theme"); } catch (e) {}
  if (!t || t === "system") return "system";
  // Catalog not in yet: keep the stored name so the fetch can apply it.
  if (THEMES.length === 1) return t;
  return THEMES.indexOf(t) === -1 ? "system" : t;
}

function applyTokens(tokens) {
  var root = document.documentElement;
  var i;
  for (i = 0; i < _appliedKeys.length; i++) root.style.removeProperty(_appliedKeys[i]);
  _appliedKeys = [];
  if (!tokens) return;
  Object.keys(tokens).forEach(function (key) {
    root.style.setProperty(key, tokens[key]);
    _appliedKeys.push(key);
  });
}

export function applyTheme(theme, opts) {
  var id = (opts && opts.toggleId) || "theme-toggle";
  _current = theme;
  if (theme === "system") {
    document.documentElement.removeAttribute("data-theme");
    applyTokens(null);
  } else {
    document.documentElement.setAttribute("data-theme", theme);
    var rec = CATALOG[theme];
    applyTokens(rec && rec.tokens ? rec.tokens : null);
  }
  var btn = document.getElementById(id);
  if (btn) {
    btn.textContent = "theme: " + theme;
    btn.setAttribute("aria-label", "Theme: " + theme);
    btn.setAttribute("aria-haspopup", "listbox");
    btn.setAttribute("aria-expanded", _open ? "true" : "false");
  }
}

function ensurePicker() {
  if (_picker) return;
  _picker = document.createElement("div");
  _picker.id = "theme-picker";
  _picker.className = "model-picker";
  _picker.hidden = true;
  _picker.innerHTML =
    '<div class="model-picker__panel" role="listbox" aria-label="Themes">' +
      '<div class="model-picker__list" id="theme-picker-list"></div>' +
    "</div>";
  document.body.appendChild(_picker);
  _list = _picker.querySelector(".model-picker__list");
  _list.addEventListener("click", function (e) {
    var row = e.target.closest("[data-theme]");
    if (!row) return;
    choose(row.getAttribute("data-theme"));
  });
  document.addEventListener("mousedown", function (e) {
    if (!_open) return;
    if (_picker.contains(e.target)) return;
    if (_anchor && _anchor.contains(e.target)) return;
    closePicker();
  });
  document.addEventListener("keydown", function (e) {
    if (!_open) return;
    if (e.key === "Escape") {
      e.preventDefault();
      closePicker();
      if (_anchor && _anchor.focus) _anchor.focus();
    }
  });
  window.addEventListener("resize", function () {
    if (_open && _anchor) positionPicker(_anchor);
  });
}

function positionPicker(anchor) {
  var panel = _picker.querySelector(".model-picker__panel");
  var rect = anchor.getBoundingClientRect();
  var width = Math.min(240, Math.max(180, window.innerWidth - 24));
  panel.style.width = width + "px";
  var left = Math.min(Math.max(12, rect.right - width), window.innerWidth - width - 12);
  panel.style.left = left + "px";
  var gap = 6;
  var spaceBelow = window.innerHeight - rect.bottom - gap;
  if (spaceBelow >= 180 || spaceBelow >= rect.top) {
    panel.style.top = (rect.bottom + gap) + "px";
    panel.style.bottom = "auto";
    panel.style.maxHeight = Math.min(360, Math.max(160, spaceBelow - 8)) + "px";
  } else {
    panel.style.bottom = (window.innerHeight - rect.top + gap) + "px";
    panel.style.top = "auto";
    panel.style.maxHeight = Math.min(360, Math.max(160, rect.top - gap - 8)) + "px";
  }
}

function renderList(current) {
  _list.textContent = "";
  THEMES.forEach(function (name) {
    var row = document.createElement("button");
    row.type = "button";
    row.className = "model-picker__option";
    row.setAttribute("role", "option");
    row.setAttribute("data-theme", name);
    row.setAttribute("aria-selected", name === current ? "true" : "false");
    if (name === current) row.classList.add("is-current");
    var rec = CATALOG[name];
    if (rec && rec.tokens && rec.tokens["--bg"]) {
      var swatch = document.createElement("span");
      swatch.style.cssText = "display:inline-block;width:10px;height:10px;border-radius:50%;flex-shrink:0;margin-right:6px";
      swatch.style.background = rec.tokens["--bg"];
      row.appendChild(swatch);
    }
    var label = document.createElement("span");
    label.className = "model-picker__option-label";
    label.textContent = name;
    row.appendChild(label);
    _list.appendChild(row);
  });
}

function openPicker(anchor, current) {
  ensurePicker();
  if (_anchor && _anchor !== anchor) _anchor.setAttribute("aria-expanded", "false");
  _anchor = anchor;
  _open = true;
  _picker.hidden = false;
  if (anchor) anchor.setAttribute("aria-expanded", "true");
  renderList(current);
  positionPicker(anchor);
  var cur = _list.querySelector(".is-current");
  if (cur && cur.focus) cur.focus();
}

function closePicker() {
  if (!_open) return;
  _open = false;
  if (_picker) _picker.hidden = true;
  if (_anchor) _anchor.setAttribute("aria-expanded", "false");
  _anchor = null;
}

function choose(name) {
  if (name !== "system" && THEMES.indexOf(name) === -1) return;
  try { window.localStorage.setItem("clanker.theme", name); } catch (e) {}
  applyTheme(name);
  for (var i = 0; i < _listeners.length; i++) _listeners[i](name);
  closePicker();
}

export function bindThemeToggle(btn, onChange) {
  if (!btn) return;
  if (typeof onChange === "function") _listeners.push(onChange);
  btn.setAttribute("aria-haspopup", "listbox");
  btn.setAttribute("aria-expanded", "false");
  btn.addEventListener("click", function (e) {
    e.preventDefault();
    if (_open && _anchor === btn) closePicker();
    else openPicker(btn, loadTheme());
  });
}
