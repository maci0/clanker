// Models view — what the configured providers offer, a provider's live
// /models listing, and models.dev discovery, so finding a model to add to
// config.toml no longer needs a terminal (`clanker providers models|catalog`
// are the same data). Read-only by design: config.toml stays hand-edited,
// matching `providers fill`'s own never-writes-config stance.
import { readJson, fmtInt } from "../core/utils.js";

function table(headers, rows) {
  var wrap = document.createElement("div");
  wrap.className = "usage-wrap";
  var t = document.createElement("table");
  t.className = "usage";
  var thead = document.createElement("thead");
  var hr = document.createElement("tr");
  headers.forEach(function (h) {
    var th = document.createElement("th");
    th.textContent = h;
    hr.appendChild(th);
  });
  thead.appendChild(hr);
  t.appendChild(thead);
  var tbody = document.createElement("tbody");
  rows.forEach(function (cells) {
    var tr = document.createElement("tr");
    cells.forEach(function (c, i) {
      var td = document.createElement("td");
      td.textContent = c;
      if (i > 0 && /^[\d.,$]/.test(c)) td.className = "num";
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
  t.appendChild(tbody);
  wrap.appendChild(t);
  return wrap;
}

function empty(text) {
  var p = document.createElement("p");
  p.className = "usage-empty";
  p.textContent = text;
  return p;
}

function status(msg) {
  var el = document.getElementById("models-status");
  if (el) el.textContent = msg;
}

function loadConfigured() {
  var box = document.getElementById("models-configured");
  var providerSel = document.getElementById("models-live-provider");
  if (!box) return Promise.resolve();
  return fetch("/api/providers")
    .then(readJson)
    .then(function (d) {
      box.textContent = "";
      if (providerSel) providerSel.textContent = "";
      var rows = [];
      (d.providers || []).forEach(function (prov) {
        if (providerSel) {
          var opt = document.createElement("option");
          opt.value = prov.name;
          opt.textContent = prov.name;
          providerSel.appendChild(opt);
        }
        (prov.models || []).forEach(function (m) {
          rows.push([
            prov.name,
            m.display || m.name,
            m.category || "",
            m.context_window ? fmtInt(m.context_window) : "",
            m.cost_per_1m_input != null ? "$" + m.cost_per_1m_input : "",
            m.cost_per_1m_output != null ? "$" + m.cost_per_1m_output : "",
            m.name === prov.default_model ? "default" : ""
          ]);
        });
      });
      if (!rows.length) {
        box.appendChild(empty("No providers configured. Add [providers.<name>] in config.toml."));
        return;
      }
      box.appendChild(table(["provider", "model", "category", "ctx", "in $/1M", "out $/1M", ""], rows));
    })
    .catch(function (err) {
      box.textContent = "";
      box.appendChild(empty("Could not load providers: " + err.message));
    });
}

function loadLive() {
  var out = document.getElementById("models-live-out");
  var sel = document.getElementById("models-live-provider");
  var btn = document.getElementById("models-live-btn");
  if (!out || !sel || !sel.value) return;
  btn.disabled = true;
  out.textContent = "";
  out.appendChild(empty("Asking " + sel.value + "…"));
  fetch("/api/providers/models?name=" + encodeURIComponent(sel.value))
    .then(readJson)
    .then(function (d) {
      out.textContent = "";
      var rows = (d.models || []).map(function (m) {
        return [m.id, m.context ? fmtInt(m.context) : ""];
      });
      if (!rows.length) {
        out.appendChild(empty("The provider listed no models."));
        return;
      }
      out.appendChild(table(["id", "ctx"], rows));
      status(rows.length + " models from " + sel.value + ".");
    })
    .catch(function (err) {
      out.textContent = "";
      out.appendChild(empty("Could not list: " + err.message));
    })
    .finally(function () { btn.disabled = false; });
}

function searchCatalog() {
  var out = document.getElementById("models-catalog-out");
  var q = document.getElementById("models-catalog-q");
  var btn = document.getElementById("models-catalog-btn");
  if (!out || !q) return;
  var query = q.value.trim();
  if (query.length < 2) {
    out.textContent = "";
    out.appendChild(empty("Type at least 2 characters."));
    return;
  }
  btn.disabled = true;
  out.textContent = "";
  out.appendChild(empty("Searching models.dev…"));
  fetch("/api/catalog?q=" + encodeURIComponent(query))
    .then(readJson)
    .then(function (d) {
      out.textContent = "";
      var rows = (d.models || []).map(function (m) {
        var caps = [];
        if (m.reasoning) caps.push("reasoning");
        if (m.tool_call) caps.push("tools");
        return [
          m.provider + "/" + m.id,
          m.context ? fmtInt(m.context) : "",
          m.cost_in != null ? "$" + m.cost_in : "",
          m.cost_out != null ? "$" + m.cost_out : "",
          caps.join(", ")
        ];
      });
      if (!rows.length) {
        out.appendChild(empty("No catalog entry matches \"" + query + "\"."));
        return;
      }
      out.appendChild(table(["provider/model", "ctx", "in $/1M", "out $/1M", "capabilities"], rows));
      status(rows.length + (d.truncated ? "+ (truncated)" : "") + " catalog matches.");
      if (d.truncated) {
        out.appendChild(empty("Showing the first " + rows.length + " matches — narrow the query for more specific results."));
      }
    })
    .catch(function (err) {
      out.textContent = "";
      out.appendChild(empty("Catalog search failed: " + err.message));
    })
    .finally(function () { btn.disabled = false; });
}

export function loadModelsView() {
  return loadConfigured();
}

var bound = false;
export function bindModels() {
  if (bound) return;
  bound = true;
  var liveBtn = document.getElementById("models-live-btn");
  if (liveBtn) liveBtn.addEventListener("click", loadLive);
  var catBtn = document.getElementById("models-catalog-btn");
  if (catBtn) catBtn.addEventListener("click", searchCatalog);
  var q = document.getElementById("models-catalog-q");
  if (q) q.addEventListener("keydown", function (e) {
    if (e.key === "Enter") { e.preventDefault(); searchCatalog(); }
  });
  var refresh = document.getElementById("models-refresh");
  if (refresh) refresh.addEventListener("click", function () { loadModelsView(); });
}
