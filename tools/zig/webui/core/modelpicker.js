// Vanilla, no bundler. Model/provider picker + sampling controls + enter-to-send toggle.
import { fuzzyMatch as utilFuzzyMatch } from "./utils.js";

// Mutable state the module owns.
var _providerCache = [];
var _modelIndex = [];
var _modelListIndex = 0;

var _el = null;
var _readJson = null;
var _fmtInt = null;
var _fuzzyMatch = utilFuzzyMatch;
var _allUsage = null;
var _renderUsage = null;
var _renderContextMeter = null;
var _providerCacheHolder = null;

export function getProviderCache() { return _providerCache; }
export function getModelIndex() { return _modelIndex; }

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
        (prov.models || []).forEach(function (m) {
          var value = prov.name + " " + m.name;
          var label = m.display || m.name;
          var meta = [];
          if (m.context_window) meta.push(_fmtInt(m.context_window) + " ctx");
          if (m.cost_per_1m_input != null || m.cost_per_1m_output != null) {
            meta.push("$" + (m.cost_per_1m_input != null ? m.cost_per_1m_input : "?") +
                       " / $" + (m.cost_per_1m_output != null ? m.cost_per_1m_output : "?") + " per 1M");
          }
          var opt = document.createElement("option");
          opt.value = value;
          opt.textContent = label + (meta.length ? "  .  " + meta.join("  .  ") : "");
          if (prov.name === d.default && m.name === prov.default_model) opt.selected = true;
          group.appendChild(opt);
          _modelIndex.push({ value: value, provider: prov.name, model: m.name, label: label, meta: meta.join("  ·  ") });
        });
        _el.modelSelect.appendChild(group);
      });
      var saved = null;
      try { saved = window.localStorage.getItem("clanker.model"); } catch (e) {}
      if (saved && _el.modelSelect.querySelector('option[value="' + saved.replace(/"/g, "") + '"]')) {
        _el.modelSelect.value = saved;
      }
      syncModelSearchLabel();
    })
    .catch(function () {
      var opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "config default";
      _el.modelSelect.appendChild(opt);
      syncModelSearchLabel();
    });
}

export function syncModelSearchLabel() {
  var entry = null;
  for (var i = 0; i < _modelIndex.length; i++) {
    if (_modelIndex[i].value === _el.modelSelect.value) { entry = _modelIndex[i]; break; }
  }
  _el.modelSearch.value = entry ? entry.provider + " / " + entry.label : "";
}

export function renderModelList() {
  var q = _el.modelSearch.value.trim().toLowerCase();
  var matches = _modelIndex.filter(function (e) { return _fuzzyMatch(q, e.provider + " " + e.label); });
  _el.modelList.textContent = "";
  if (!matches.length) { hideModelList(); return; }
  if (_modelListIndex >= matches.length) _modelListIndex = 0;
  var lastProvider = null;
  matches.forEach(function (entry, i) {
    if (entry.provider !== lastProvider) {
      lastProvider = entry.provider;
      var header = document.createElement("li");
      header.className = "palette-kind-header";
      header.textContent = entry.provider;
      header.setAttribute("role", "presentation");
      _el.modelList.appendChild(header);
    }
    var li = document.createElement("li");
    li.className = "palette-item";
    li.id = "model-item-" + i;
    li.setAttribute("role", "option");
    li.setAttribute("aria-selected", String(i === _modelListIndex));
    var label = document.createElement("span");
    label.className = "palette-label";
    label.textContent = entry.label;
    li.appendChild(label);
    if (entry.meta) {
      var meta = document.createElement("span");
      meta.className = "model-meta";
      meta.textContent = entry.meta;
      li.appendChild(meta);
    }
    li.addEventListener("mousedown", function (e) {
      e.preventDefault();
      selectModel(entry);
    });
    _el.modelList.appendChild(li);
  });
  _el.modelList.hidden = false;
  _el.modelSearch.setAttribute("aria-expanded", "true");
  _el.modelSearch.setAttribute("aria-activedescendant", "model-item-" + _modelListIndex);
  _el.modelList.setAttribute("data-count", String(matches.length));
  return matches;
}

export function hideModelList() {
  _el.modelList.hidden = true;
  _el.modelList.textContent = "";
  _el.modelSearch.setAttribute("aria-expanded", "false");
  _el.modelSearch.removeAttribute("aria-activedescendant");
}

export function selectModel(entry) {
  _el.modelSelect.value = entry.value;
  _el.modelSelect.dispatchEvent(new Event("change"));
  hideModelList();
  _el.modelSearch.blur();
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
  var t = parseFloat(_el.paramTemp.value);
  if (!isNaN(t)) out.temperature = t;
  var tp = parseFloat(_el.paramTopP.value);
  if (!isNaN(tp)) out.top_p = tp;
  return out;
}

export function syncSubmitLabel() {
  _el.submit.textContent = _el.enterSends.checked ? "Run (Enter)" : "Run (Ctrl+Enter)";
}

export function bindModelPicker(ctx) {
  _el = ctx.el;
  _readJson = ctx.readJson;
  _fmtInt = ctx.fmtInt;
  _allUsage = ctx.allUsage;
  _renderUsage = ctx.renderUsage;
  _renderContextMeter = ctx.renderContextMeter;
  _fuzzyMatch = ctx.fuzzyMatch || utilFuzzyMatch;
  _providerCacheHolder = ctx.providerCacheHolder || null;

  _el.modelSelect.addEventListener("change", function () {
    try { window.localStorage.setItem("clanker.model", _el.modelSelect.value); } catch (e) {}
    _renderContextMeter();
    syncModelSearchLabel();
  });

  _el.modelSearch.addEventListener("focus", function () {
    _el.modelSearch.select();
    renderModelList();
  });
  _el.modelSearch.addEventListener("input", function () { _modelListIndex = 0; renderModelList(); });
  _el.modelSearch.addEventListener("focusout", function (e) {
    if (e.relatedTarget && _el.modelList.contains(e.relatedTarget)) return;
    window.setTimeout(function () {
      if (document.activeElement === _el.modelSearch || _el.modelList.contains(document.activeElement)) return;
      hideModelList(); syncModelSearchLabel();
    }, 120);
  });
  _el.modelSearch.addEventListener("keydown", function (e) {
    if (_el.modelList.hidden) return;
    var items = _el.modelList.querySelectorAll(".palette-item");
    if (!items.length) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      _modelListIndex = (_modelListIndex + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
      renderModelList();
      return;
    }
    if (e.key === "Escape") {
      e.preventDefault();
      hideModelList();
      syncModelSearchLabel();
      _el.modelSearch.blur();
      return;
    }
    if (e.key === "Enter") {
      e.preventDefault();
      var matches = renderModelList() || [];
      if (matches[_modelListIndex]) selectModel(matches[_modelListIndex]);
      return;
    }
  });

  try { _el.enterSends.checked = window.localStorage.getItem("clanker.entersends") === "1"; } catch (e) {}
  _el.enterSends.addEventListener("change", function () {
    try { window.localStorage.setItem("clanker.entersends", _el.enterSends.checked ? "1" : "0"); } catch (e) {}
    syncSubmitLabel();
  });
}
