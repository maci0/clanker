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
      // A cell is text, or a control: the catalog's rows carry a per-row
      // "config.toml" button in their last column.
      if (c && c.nodeType === 1) td.appendChild(c);
      else {
        td.textContent = c;
        if (i > 0 && /^[\d.,$]/.test(c)) td.className = "num";
      }
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

/* ---- config.toml snippets for discovered models -------------------------
   The view's whole point is that finding a model to add to config.toml does
   not need a terminal, and it stopped one step short: it showed you the
   numbers and left you to hand-type the TOML from them, which is where the
   context window gets a digit wrong and `max_tokens` gets forgotten.
   `clanker providers fill` already prints exactly the right block; this is
   that block, from the same catalog fields and the same capability
   vocabulary (`catalogCapabilities` in cli.zig, shared by both), so the page
   and the CLI cannot hand out different snippets. Still read-only: it hands
   you text to paste, it does not write config.toml, matching `providers
   fill`'s own stance. */

// Which providers config.toml already declares, and whether we actually know.
// Not knowing is different from knowing the list is empty: it decides whether
// the snippet is allowed to claim a provider is missing.
var configuredProviders = [];
var providersKnown = false;

/* A bare TOML key is `[A-Za-z0-9_-]+`; anything else has to be quoted, and
   `[providers."muse-spark-1.1"]` in this repo's own config.toml is the case
   that proves it is not hypothetical. */
function tomlKey(name) {
  return /^[A-Za-z0-9_-]+$/.test(String(name)) ? String(name) : tomlStr(name);
}

/* These ids come off a third-party fetch and land inside a double-quoted TOML
   string, so a backslash or a quote in one would produce a snippet that pastes
   and then fails to parse. */
function tomlStr(value) {
  return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

/** The `[models."<provider>/<id>"]` block for one catalog entry. Pure, and
 *  exported so the text asserted in a test is the text the button shows. */
export function configSnippet(m, configured, known) {
  var lines = [];
  var provider = m.provider;
  if (known && (configured || []).indexOf(provider) === -1) {
    // The models table alone would be rejected at startup: a model entry names
    // a provider, and clanker resolves it against [providers.*]. Saying so beats
    // handing over something that looks complete.
    lines.push("# " + provider + " has no [providers." + tomlKey(provider) + "] table yet.");
    lines.push("# Add one (kind, base_url, api_key_env) before this entry.");
  }
  lines.push("[models." + tomlStr(provider + "/" + m.id) + "]");
  lines.push("provider = " + tomlStr(provider));
  if (m.context) lines.push("context_window = " + m.context);
  // The field a hand-typed snippet forgets most expensively: without it the
  // entry takes config.Model's 1024-token default and truncates every answer.
  if (m.output) lines.push("max_tokens = " + m.output);
  if (m.display) lines.push("display = " + tomlStr(m.display));
  if (m.cost_in != null) lines.push("cost_per_1m_input = " + m.cost_in);
  if (m.cost_out != null) lines.push("cost_per_1m_output = " + m.cost_out);
  if (m.capabilities && m.capabilities.length) {
    lines.push("capabilities = [" + m.capabilities.map(tomlStr).join(", ") + "]");
  }
  return lines.join("\n") + "\n";
}

function hideSnippet() {
  var host = document.getElementById("models-snippet");
  if (host) host.hidden = true;
}

function showSnippet(m) {
  var host = document.getElementById("models-snippet");
  var body = document.getElementById("models-snippet-body");
  if (!host || !body) return;
  var title = document.getElementById("models-snippet-title");
  if (title) title.textContent = m.provider + "/" + m.id;
  body.textContent = configSnippet(m, configuredProviders, providersKnown);
  host.hidden = false;
  var copy = document.getElementById("models-snippet-copy");
  if (copy) copy.textContent = "Copy";
  status("config.toml entry for " + m.provider + "/" + m.id + ".");
  try { host.scrollIntoView({ behavior: "smooth", block: "nearest" }); } catch (_) {}
}

/* `navigator.clipboard` exists only in a secure context, and `clanker serve`
   speaks plain http — on `http://192.168.0.5:8080` it is undefined, which is
   the setup this server is built for. So the snippet is on screen and
   selectable whether or not a copy is possible, and Copy is the shortcut: when
   it cannot work it says so rather than silently doing nothing, which is what
   the Prompts view's own Copy still does. */
function copySnippet() {
  var btn = document.getElementById("models-snippet-copy");
  var body = document.getElementById("models-snippet-body");
  if (!btn || !body) return;
  var clip = typeof navigator !== "undefined" && navigator.clipboard;
  if (!clip || !clip.writeText) {
    btn.textContent = "Select it";
    status("The browser only offers the clipboard to a secure origin, and this page is plain http. The snippet is selectable.");
    return;
  }
  clip.writeText(body.textContent).then(function () {
    btn.textContent = "Copied";
    window.setTimeout(function () { btn.textContent = "Copy"; }, 1200);
  }, function () {
    btn.textContent = "Select it";
    status("The browser refused the clipboard. The snippet is selectable.");
  });
}

function snippetButton(m) {
  var btn = document.createElement("button");
  btn.type = "button";
  btn.className = "secondary models-snippet-btn";
  btn.textContent = "config.toml";
  btn.setAttribute("aria-label", "Show the config.toml entry for " + m.provider + "/" + m.id);
  btn.addEventListener("click", function () { showSnippet(m); });
  return btn;
}

/* Puts the chosen provider back after the <select> has been refilled.
   Which provider you are about to ask is a choice, and it has to outlive the
   list being rebuilt — but emptying a <select> throws its selection away, and
   refilling it leaves whichever option lands first selected instead (the HTML
   "ask for a reset" algorithm). Assigning a value no option carries leaves
   selectedIndex at -1 and the control blank, so a provider that has since been
   removed from config.toml has to be detected and stepped back to the first
   option deliberately rather than left showing nothing. */
function restoreProvider(sel, wanted) {
  if (!wanted) return;
  sel.value = wanted;
  if (sel.value === wanted) return;
  // The provider is gone from config.toml. The first option stands, and any
  // live listing still on screen belongs to a provider the select no longer
  // names — leaving it there reads as the new selection's models.
  sel.selectedIndex = 0;
  var out = document.getElementById("models-live-out");
  if (out) {
    out.textContent = "";
    out.appendChild(empty(wanted + " is no longer configured. Pick a provider and list again."));
  }
}

function loadConfigured() {
  var box = document.getElementById("models-configured");
  var providerSel = document.getElementById("models-live-provider");
  if (!box) return Promise.resolve();
  // Read before the refill, restored after it. loadModelsView() runs on every
  // entry to the view and behind Refresh, so without this the choice was lost
  // both times and the next "List models" quietly asked a different provider.
  var chosen = providerSel ? providerSel.value : "";
  return fetch("/api/providers")
    .then(readJson)
    .then(function (d) {
      box.textContent = "";
      if (providerSel) providerSel.textContent = "";
      // Recorded for the config.toml snippets: a discovered model whose
      // provider is not declared needs a [providers.*] table too, and only
      // this response knows which ones there are.
      configuredProviders = (d.providers || []).map(function (p) { return p.name; });
      providersKnown = true;
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
      // Before the early return below: a config with providers but no declared
      // models still fills the select, and the choice still has to survive.
      if (providerSel) restoreProvider(providerSel, chosen);
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
  // The panel names a model from the result set being replaced.
  hideSnippet();
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
          caps.join(", "),
          snippetButton(m)
        ];
      });
      if (!rows.length) {
        out.appendChild(empty("No catalog entry matches \"" + query + "\"."));
        return;
      }
      out.appendChild(table(["provider/model", "ctx", "in $/1M", "out $/1M", "capabilities", ""], rows));
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
  var copy = document.getElementById("models-snippet-copy");
  if (copy) copy.addEventListener("click", copySnippet);
  var close = document.getElementById("models-snippet-close");
  if (close) close.addEventListener("click", hideSnippet);
}
