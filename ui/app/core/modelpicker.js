// Vanilla, no bundler. Model/provider picker: hidden <select> as the value
// store, popover UI (search + provider groups) as the operator surface.

import { icon } from "./icons.js";

var _providerCache = [];
var _modelIndex = [];

var _el = null;
var _readJson = null;
var _fmtInt = null;
var _allUsage = null;
var _renderUsage = null;
var _renderContextMeter = null;
var _providerCacheHolder = null;
var _onModelChange = null;

var _picker = null;
var _search = null;
var _list = null;
var _anchor = null;
var _active = -1;
var _flat = [];
var _open = false;

export function getProviderCache() { return _providerCache; }
export function getModelIndex() { return _modelIndex; }

function ensurePill(btn) {
  if (!btn) return;
  var name = btn.querySelector(".model-chip__name");
  if (!name) {
    var text = (btn.textContent || "").trim() || "…";
    btn.textContent = "";
    name = document.createElement("span");
    name.className = "model-chip__name";
    name.textContent = text;
    btn.appendChild(name);
  }
  var chev = btn.querySelector(".model-chip__chevron");
  if (!chev) {
    chev = document.createElement("span");
    chev.className = "model-chip__chevron";
    chev.setAttribute("aria-hidden", "true");
    chev.appendChild(icon("chevronDown", 12));
    btn.appendChild(chev);
  }
}

export function setModelChipLabel(btn, text, title) {
  if (!btn) return;
  ensurePill(btn);
  var name = btn.querySelector(".model-chip__name");
  if (name) name.textContent = text;
  if (title != null) btn.title = title;
}

function ensurePickerDom() {
  if (_picker) return;
  _picker = document.createElement("div");
  _picker.id = "model-picker";
  _picker.className = "model-picker";
  _picker.hidden = true;
  _picker.innerHTML =
    '<div class="model-picker__panel">' +
      '<input type="search" class="model-picker__search" placeholder="Search models…" autocomplete="off" role="combobox" aria-expanded="true" aria-label="Search models" aria-controls="model-picker-list" aria-owns="model-picker-list" aria-autocomplete="list">' +
      '<div class="model-picker__list" id="model-picker-list" role="listbox" tabindex="-1"></div>' +
    "</div>";
  document.body.appendChild(_picker);
  _search = _picker.querySelector(".model-picker__search");
  _list = _picker.querySelector(".model-picker__list");

  _search.addEventListener("input", function () {
    renderList(_search.value);
  });
  _search.addEventListener("keydown", onSearchKey);
  _list.addEventListener("click", function (e) {
    var row = e.target.closest("[data-value]");
    if (!row) return;
    selectValue(row.getAttribute("data-value"));
  });
  _picker.addEventListener("mousedown", function (e) {
    // Keep focus in the panel when clicking rows (avoid blur-close races).
    if (e.target !== _search) e.preventDefault();
  });
  document.addEventListener("mousedown", function (e) {
    if (!_open) return;
    if (_picker.contains(e.target)) return;
    if (_anchor && _anchor.contains(e.target)) return;
    dismissModelPicker();
  });
  document.addEventListener("keydown", function (e) {
    if (!_open) return;
    if (e.key === "Escape") {
      e.preventDefault();
      dismissModelPicker();
      return;
    }
    // Combobox: Tab dismisses. Options are tabindex=-1 (arrows only).
    if (e.key === "Tab") {
      e.preventDefault();
      var from = _anchor;
      closeModelPicker();
      focusAdjacent(from, e.shiftKey);
    }
  });
  window.addEventListener("resize", function () {
    if (_open && _anchor) positionPicker(_anchor);
  });
}

function focusAdjacent(from, backwards) {
  if (!from || !from.focus) return;
  var nodes = document.querySelectorAll(
    'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
  );
  var list = [];
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i];
    if (n.closest && n.closest(".model-picker")) continue;
    if (n.offsetParent === null && n !== document.activeElement) continue;
    list.push(n);
  }
  var idx = list.indexOf(from);
  if (idx < 0) {
    from.focus();
    return;
  }
  var next = backwards ? list[idx - 1] : list[idx + 1];
  if (next && next.focus) next.focus();
  else from.focus();
}

function dismissModelPicker() {
  var back = closeModelPicker();
  if (back && back.focus) back.focus();
}

function onSearchKey(e) {
  if (e.key === "ArrowDown") {
    e.preventDefault();
    moveActive(1);
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    moveActive(-1);
  } else if (e.key === "Enter") {
    e.preventDefault();
    if (_active >= 0 && _flat[_active]) selectValue(_flat[_active].value);
  } else if (e.key === "Escape") {
    e.preventDefault();
    dismissModelPicker();
  }
}

function moveActive(delta) {
  if (!_flat.length) return;
  _active = (_active + delta + _flat.length) % _flat.length;
  paintActive();
  var row = _list.querySelector('[data-index="' + _active + '"]');
  if (row && row.scrollIntoView) row.scrollIntoView({ block: "nearest" });
}

function paintActive() {
  var rows = _list.querySelectorAll(".model-picker__option");
  var activeId = null;
  for (var i = 0; i < rows.length; i++) {
    var on = Number(rows[i].getAttribute("data-index")) === _active;
    rows[i].classList.toggle("is-active", on);
    rows[i].setAttribute("aria-selected", on ? "true" : "false");
    if (on) activeId = rows[i].id;
  }
  if (_search) {
    if (activeId) _search.setAttribute("aria-activedescendant", activeId);
    else _search.removeAttribute("aria-activedescendant");
  }
}

function renderList(query) {
  var q = (query || "").trim().toLowerCase();
  _list.textContent = "";
  _flat = [];
  _active = -1;
  var current = (_el && _el.modelSelect && _el.modelSelect.value) || "";

  var byProv = {};
  var order = [];
  _modelIndex.forEach(function (m) {
    var hay = (m.label + " " + m.provider + " " + m.model + " " + (m.meta || "")).toLowerCase();
    if (q && hay.indexOf(q) === -1) return;
    if (!byProv[m.provider]) {
      byProv[m.provider] = [];
      order.push(m.provider);
    }
    byProv[m.provider].push(m);
  });

  if (!order.length) {
    var empty = document.createElement("p");
    empty.className = "model-picker__empty";
    empty.textContent = q ? "No models match." : "No models configured.";
    _list.appendChild(empty);
    return;
  }

  order.forEach(function (prov) {
    var group = document.createElement("div");
    group.className = "model-picker__group";
    var title = document.createElement("div");
    title.className = "model-picker__group-title";
    title.textContent = prov;
    group.appendChild(title);
    byProv[prov].forEach(function (m) {
      var idx = _flat.length;
      _flat.push(m);
      var row = document.createElement("button");
      row.type = "button";
      row.id = "model-picker-option-" + idx;
      row.className = "model-picker__option";
      row.setAttribute("role", "option");
      row.tabIndex = -1;
      row.setAttribute("data-value", m.value);
      row.setAttribute("data-index", String(idx));
      row.setAttribute("aria-selected", m.value === current ? "true" : "false");
      if (m.value === current) {
        row.classList.add("is-current");
        if (_active < 0) _active = idx;
      }
      var label = document.createElement("span");
      label.className = "model-picker__option-label";
      label.textContent = m.label;
      row.appendChild(label);
      if (m.meta) {
        var meta = document.createElement("span");
        meta.className = "model-picker__option-meta";
        meta.textContent = m.meta;
        row.appendChild(meta);
      }
      group.appendChild(row);
    });
    _list.appendChild(group);
  });
  if (_active < 0 && _flat.length) _active = 0;
  paintActive();
}

function positionPicker(anchor) {
  var panel = _picker.querySelector(".model-picker__panel");
  var rect = anchor.getBoundingClientRect();
  var gap = 6;
  var width = Math.min(360, Math.max(280, window.innerWidth - 24));
  panel.style.width = width + "px";
  var left = Math.min(Math.max(12, rect.left), window.innerWidth - width - 12);
  panel.style.left = left + "px";
  var spaceBelow = window.innerHeight - rect.bottom - gap;
  var spaceAbove = rect.top - gap;
  var preferBelow = spaceBelow >= 240 || spaceBelow >= spaceAbove;
  if (preferBelow) {
    panel.style.top = (rect.bottom + gap) + "px";
    panel.style.bottom = "auto";
    panel.style.maxHeight = Math.min(420, Math.max(180, spaceBelow - 8)) + "px";
  } else {
    panel.style.bottom = (window.innerHeight - rect.top + gap) + "px";
    panel.style.top = "auto";
    panel.style.maxHeight = Math.min(420, Math.max(180, spaceAbove - 8)) + "px";
  }
}

function setExpanded(on) {
  [_el && _el.headerModel, _el && _el.composerModel].forEach(function (btn) {
    if (btn) btn.setAttribute("aria-expanded", on ? "true" : "false");
  });
}

export function openModelPicker(anchor) {
  ensurePickerDom();
  if (!_modelIndex.length && _el && _el.modelSelect && _el.modelSelect.options.length) {
    // Index may be empty if load failed partially; rebuild from select.
  }
  _anchor = anchor || _el.composerModel || _el.headerModel;
  if (!_anchor) return;
  _open = true;
  _picker.hidden = false;
  setExpanded(true);
  positionPicker(_anchor);
  _search.value = "";
  renderList("");
  _search.focus();
  _search.select();
}

export function closeModelPicker() {
  if (!_open) return;
  _open = false;
  if (_picker) _picker.hidden = true;
  setExpanded(false);
  var back = _anchor;
  _anchor = null;
  return back;
}

export function toggleModelPicker(anchor) {
  if (_open && _anchor === anchor) dismissModelPicker();
  else openModelPicker(anchor);
}

function selectValue(value) {
  if (!_el || !_el.modelSelect) return;
  _el.modelSelect.value = value;
  try { window.localStorage.setItem("clanker.model", value); } catch (e) {}
  _el.modelSelect.dispatchEvent(new Event("change", { bubbles: true }));
  if (_renderContextMeter) _renderContextMeter();
  if (_onModelChange) _onModelChange();
  dismissModelPicker();
}

export function loadProviders() {
  return fetch("/api/providers")
    .then(_readJson)
    .then(function (d) {
      _providerCache = d.providers || [];
      if (_providerCacheHolder) { _providerCacheHolder.list.length = 0; Array.prototype.push.apply(_providerCacheHolder.list, _providerCache); }
      if (_allUsage && _allUsage.length) _renderUsage(null);
      _el.modelSelect.textContent = "";
      _modelIndex = [];
      (d.providers || []).forEach(function (prov) {
        var group = document.createElement("optgroup");
        group.label = prov.name;
        var models = (prov.models || []).slice().sort(function (a, b) {
          var ac = a.category || "", bc = b.category || "";
          if (!ac !== !bc) return ac ? -1 : 1;
          if (ac !== bc) return ac < bc ? -1 : 1;
          return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
        });
        models.forEach(function (m) {
          var value = prov.name + " " + m.name;
          var label = m.display || m.name;
          var meta = [];
          if (m.category) meta.push(m.category);
          if (m.context_window) meta.push(_fmtInt(m.context_window) + " ctx");
          if (m.cost_per_1m_input != null || m.cost_per_1m_output != null) {
            meta.push("$" + (m.cost_per_1m_input != null ? m.cost_per_1m_input : "?") +
                       " / $" + (m.cost_per_1m_output != null ? m.cost_per_1m_output : "?") + " per 1M");
          }
          var opt = document.createElement("option");
          opt.value = value;
          opt.textContent = label + (meta.length ? "  ·  " + meta.join("  ·  ") : "");
          if (prov.name === d.default && m.name === prov.default_model) opt.selected = true;
          group.appendChild(opt);
          _modelIndex.push({ value: value, provider: prov.name, model: m.name, label: label, meta: meta.join("  ·  ") });
        });
        _el.modelSelect.appendChild(group);
      });
      if (_el.fallbackProvider) {
        var fbSaved = null;
        try { fbSaved = window.localStorage.getItem("clanker.fallback"); } catch (e) {}
        _el.fallbackProvider.textContent = "";
        var none = document.createElement("option");
        none.value = "";
        none.textContent = "None (no auto-retry)";
        _el.fallbackProvider.appendChild(none);
        (d.providers || []).forEach(function (prov) {
          var opt = document.createElement("option");
          opt.value = prov.name;
          opt.textContent = prov.name;
          _el.fallbackProvider.appendChild(opt);
        });
        if (fbSaved && _el.fallbackProvider.querySelector('option[value="' + fbSaved.replace(/\"/g, "") + '"]')) {
          _el.fallbackProvider.value = fbSaved;
        }
      }
      var saved = null;
      try { saved = window.localStorage.getItem("clanker.model"); } catch (e) {}
      if (saved && _el.modelSelect.querySelector('option[value="' + saved.replace(/\"/g, "") + '"]')) {
        _el.modelSelect.value = saved;
      }
      if (_onModelChange) _onModelChange();
      if (_open) renderList(_search ? _search.value : "");
    })
    .catch(function () {
      var opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "config default";
      _el.modelSelect.appendChild(opt);
      if (_onModelChange) _onModelChange();
    });
}

export function runOptions() {
  var out = {};
  var raw = (_el.modelSelect.value || "").trim();
  var sp = raw.indexOf(" ");
  if (sp !== -1) {
    out.provider = raw.slice(0, sp);
    out.model = raw.slice(sp + 1).trim();
    if (!out.model) delete out.model;
  } else if (raw) {
    out.provider = raw;
  }
  out.fallbackProvider = fallbackProviderValue();
  var t = parseFloat(_el.paramTemp.value);
  if (!isNaN(t)) out.temperature = t;
  var tp = parseFloat(_el.paramTopP.value);
  if (!isNaN(tp)) out.top_p = tp;
  return out;
}

export function fallbackProviderValue() {
  return (_el.fallbackProvider && _el.fallbackProvider.value) || "";
}

export function syncSubmitLabel() {
  // Icon-only send control: the shortcut hint rides the tooltip and the
  // accessible name, not visible text.
  var hint = _el.enterSends.checked ? "Run (Enter)" : "Run (Ctrl+Enter)";
  _el.submit.title = hint;
  _el.submit.setAttribute("aria-label", hint);
}

export function bindModelPicker(ctx) {
  _el = ctx.el;
  _readJson = ctx.readJson;
  _fmtInt = ctx.fmtInt;
  _allUsage = ctx.allUsage;
  _renderUsage = ctx.renderUsage;
  _renderContextMeter = ctx.renderContextMeter;
  _providerCacheHolder = ctx.providerCacheHolder || null;
  _onModelChange = ctx.onModelChange || null;

  ensurePill(_el.headerModel);
  ensurePill(_el.composerModel);
  ensurePickerDom();

  _el.modelSelect.addEventListener("change", function () {
    try { window.localStorage.setItem("clanker.model", _el.modelSelect.value); } catch (e) {}
    _renderContextMeter();
    if (_onModelChange) _onModelChange();
  });

  try { _el.enterSends.checked = window.localStorage.getItem("clanker.entersends") === "1"; } catch (e) {}
  _el.enterSends.addEventListener("change", function () {
    try { window.localStorage.setItem("clanker.entersends", _el.enterSends.checked ? "1" : "0"); } catch (e) {}
    syncSubmitLabel();
  });

  if (_el.fallbackProvider) {
    _el.fallbackProvider.addEventListener("change", function () {
      try { window.localStorage.setItem("clanker.fallback", _el.fallbackProvider.value); } catch (e) {}
    });
  }
}
