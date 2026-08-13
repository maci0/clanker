// Vanilla, no bundler. Model/provider picker + sampling controls + enter-to-send toggle.

// Mutable state the module owns.
var _providerCache = [];
var _modelIndex = [];

var _el = null;
var _readJson = null;
var _fmtInt = null;
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
        // Grouped by provider (the outer shape); category only orders the
        // models inside each group. Uncategorized models sort last rather
        // than jumping ahead of every categorized peer.
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
          opt.textContent = label + (meta.length ? "  .  " + meta.join("  .  ") : "");
          if (prov.name === d.default && m.name === prov.default_model) opt.selected = true;
          group.appendChild(opt);
          _modelIndex.push({ value: value, provider: prov.name, model: m.name, label: label, meta: meta.join("  ·  ") });
        });
        _el.modelSelect.appendChild(group);
      });
      // Populate the fallback-provider selector: None + each configured provider.
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
    })
    .catch(function () {
      var opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "config default";
      _el.modelSelect.appendChild(opt);
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
  _el.submit.textContent = _el.enterSends.checked ? "Run (Enter)" : "Run (Ctrl+Enter)";
}

export function bindModelPicker(ctx) {
  _el = ctx.el;
  _readJson = ctx.readJson;
  _fmtInt = ctx.fmtInt;
  _allUsage = ctx.allUsage;
  _renderUsage = ctx.renderUsage;
  _renderContextMeter = ctx.renderContextMeter;
  _providerCacheHolder = ctx.providerCacheHolder || null;

  _el.modelSelect.addEventListener("change", function () {
    try { window.localStorage.setItem("clanker.model", _el.modelSelect.value); } catch (e) {}
    _renderContextMeter();
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
