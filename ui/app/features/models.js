// Models view — what the configured providers offer, a provider's live
// /models listing, and models.dev discovery. Save writes config.local.toml
// only (never the shared config.toml), after an explicit confirm.
import { readJson, fmtInt, fmtBytes, providerUnusableReason, wireRefresh } from "../core/utils.js";
import { paintTomlInto } from "../core/vendor.js";

function askConfirm(message, opts) {
  return import("../core/ui.js").then(function (mod) { return mod.uiConfirm(message, opts); });
}

/* Generic grid builder. Shares only the .usage-wrap/.usage presentation classes
   with core/usage.js — whose renderUsageTable is a fixed-column token-stat
   renderer with a totals footer, built on the T factory. It cannot express these
   heterogeneous columns, the per-row control cells (the "config.toml" buttons),
   or the absence of a totals row, so this is deliberately its own grid rather
   than a copy of that renderer. */
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

function failWithRetry(host, message, retryFn) {
  if (!host) return;
  host.textContent = "";
  var p = empty(message + " ");
  var btn = document.createElement("button");
  btn.type = "button";
  btn.className = "secondary";
  btn.textContent = "Try again";
  btn.addEventListener("click", retryFn);
  p.appendChild(btn);
  host.appendChild(p);
}

/* One status line per panel. The view used to share a single #models-status
   for Configured, Live and Discover, and only successes wrote it — so a
   stale "12 catalog matches." kept being announced after a live listing had
   just failed. Which line a message lands on is data, so the mapping is a
   pure function the test can hold still. */
export function modelsStatusId(panel) {
  if (panel === "live") return "models-live-status";
  if (panel === "catalog") return "models-catalog-status";
  return "models-status";
}

function status(msg, panel) {
  var el = document.getElementById(modelsStatusId(panel));
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
   `[providers."google-vertex-anthropic"]` is a long id; a name with a
   `.` in it still has to be quoted. */
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
    // a provider, and clanker resolves it against [providers.*]. The catalog
    // classifier already picked kind/auth/base from the models.dev npm
    // package, so the snippet can write the provider table rather than
    // asking the operator to invent it.
    if (m.kind) {
      lines.push("[providers." + tomlKey(provider) + "]");
      lines.push("kind = " + tomlStr(m.kind));
      if (m.base_url) lines.push("base_url = " + tomlStr(m.base_url));
      else if (m.kind === "vertex_anthropic" || m.kind === "vertex") {
        lines.push("# set project, location, service_account_file (base_url is optional)");
      } else if (m.kind === "azure_openai") {
        lines.push("# set base_url to https://<resource>.openai.azure.com");
      }
      if (m.auth && m.auth !== "api_key") lines.push("auth = " + tomlStr(m.auth));
      if (m.api_key_env) lines.push("api_key_env = " + tomlStr(m.api_key_env));
      if (m.path) lines.push("path = " + tomlStr(m.path));
      lines.push("");
    } else {
      lines.push("# " + provider + " has no [providers." + tomlKey(provider) + "] table yet.");
      lines.push("# Add one (kind, base_url, api_key_env) before this entry.");
    }
  }
  lines.push("[models." + tomlStr(provider + "/" + m.id) + "]");
  lines.push("provider = " + tomlStr(provider));
  if (m.context) lines.push("context_window = " + m.context);
  // The field a hand-typed snippet forgets most expensively: without it the
  // entry takes config.Model's 1024-token default and truncates every answer.
  if (m.output) lines.push("max_tokens = " + m.output);
  if (m.display) lines.push("display = " + tomlStr(m.display));
  // models.dev's own field only says the model accepts a temperature
  // parameter, not what to set it to; 0.7 matches sampling_profiles.zig's
  // chat default rather than leaving a fresh entry at the provider's own
  // default (often 1.0, noisier than clanker's other chat traffic).
  if (m.temperature_ok) lines.push("temperature = 0.7");
  if (m.cost_in != null) lines.push("cost_per_1m_input = " + m.cost_in);
  if (m.cost_out != null) lines.push("cost_per_1m_output = " + m.cost_out);
  if (m.capabilities && m.capabilities.length) {
    lines.push("capabilities = [" + m.capabilities.map(tomlStr).join(", ") + "]");
  }
  return lines.join("\n") + "\n";
}

var snippetModel = null;

function hideSnippet() {
  var host = document.getElementById("models-snippet");
  if (host) host.hidden = true;
}

function showSnippet(m) {
  var host = document.getElementById("models-snippet");
  var body = document.getElementById("models-snippet-body");
  if (!host || !body) return;
  hideEditPanel();
  snippetModel = m;
  var title = document.getElementById("models-snippet-title");
  if (title) title.textContent = m.provider + "/" + m.id;
  body.textContent = configSnippet(m, configuredProviders, providersKnown);
  host.hidden = false;
  var copy = document.getElementById("models-snippet-copy");
  if (copy) copy.textContent = "Copy";
  resetSaveButtons();
  setSnippetNote("");
  status("config.local.toml entry for " + m.provider + "/" + m.id + ".");
  try { host.scrollIntoView({ behavior: "smooth", block: "nearest" }); } catch (_) {}
}

function resetSaveButtons() {
  var save = document.getElementById("models-snippet-save");
  var def = document.getElementById("models-snippet-default");
  if (save) { save.disabled = false; save.textContent = "Save to config.local.toml"; }
  if (def) { def.disabled = false; def.textContent = "Set as default"; }
}

function setSnippetNote(text) {
  var note = document.getElementById("models-snippet-note");
  if (!note) return;
  note.textContent = text;
  note.hidden = !text;
}

function postConfig(path, payload, btn, confirmMessage, doneLabel) {
  if (!snippetModel) return;
  askConfirm(confirmMessage, { confirmLabel: "Save", title: "Write config.local.toml" }).then(function (yes) {
    if (!yes) return;
    if (btn) btn.disabled = true;
    fetch(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload)
    })
      .then(readJson)
      .then(function (d) {
        if (!d.ok) throw new Error(d.error || "write failed");
        if (btn) btn.textContent = doneLabel;
        setSnippetNote("Saved to config.local.toml. " + (d.applied || "The server reloads into it."));
        status("Wrote " + (d.path || "config.local.toml") + ".");
      })
      .catch(function (err) {
        if (btn) { btn.disabled = false; btn.textContent = "Retry"; }
        setSnippetNote("Could not save: " + err.message);
      });
  });
}

function saveSnippet() {
  if (!snippetModel) return;
  postConfig(
    "/api/config/model",
    { provider: snippetModel.provider, model: snippetModel.id },
    document.getElementById("models-snippet-save"),
    "Save " + snippetModel.provider + "/" + snippetModel.id + " to config.local.toml?",
    "Saved"
  );
}

function saveDefault() {
  if (!snippetModel) return;
  postConfig(
    "/api/config/default",
    { provider: snippetModel.provider, model: snippetModel.id },
    document.getElementById("models-snippet-default"),
    "Set " + snippetModel.provider + "/" + snippetModel.id + " as the default model in config.local.toml?",
    "Default set"
  );
}

/* `navigator.clipboard` exists only in a secure context, and `clanker serve`
   speaks plain http — on `http://192.168.0.5:8080` it is undefined, which is
   the setup this server is built for. So the snippet is on screen and
   selectable whether or not a copy is possible, and Copy is the shortcut:
   when it cannot work it says so rather than silently doing nothing. */
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
  btn.textContent = "config.local.toml";
  btn.setAttribute("aria-label", "Show the config.local.toml entry for " + m.provider + "/" + m.id);
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
      // Parallel to `rows`: null for an ordinary row, or {group, variant}
      // so the post-render pass can fold alias variants (several local
      // names sharing one wire SKU, e.g. grok4.6-coding / grok4.6-general)
      // behind one toggle row.
      var rowMeta = [];
      (d.providers || []).forEach(function (prov) {
        // Inventory, deliberately unfiltered: a configured-but-unkeyed
        // provider stays listed here (the chat picker is what hides it).
        // Its rows are dimmed below and the notice under the table names
        // the server's reason.
        var uncallableReason = providerUnusableReason(prov);
        if (providerSel) {
          var opt = document.createElement("option");
          opt.value = prov.name;
          opt.textContent = prov.name;
          providerSel.appendChild(opt);
        }
        var bySku = {};
        (prov.models || []).forEach(function (m) {
          var sku = m.id || m.name;
          (bySku[sku] = bySku[sku] || []).push(m);
        });
        (prov.models || []).forEach(function (m) {
          var entry = {
            provider: prov.name, model: m.name, id: m.id || "", display: m.display || "", category: m.category || "",
            enabled: m.enabled !== false,
            context_window: m.context_window, max_tokens: m.max_tokens, rpm: m.rpm,
            temperature: m.temperature, top_p: m.top_p, reasoning_effort: m.reasoning_effort,
            cost_per_1m_input: m.cost_per_1m_input, cost_per_1m_output: m.cost_per_1m_output,
            capabilities: m.capabilities || []
          };
          var sku = m.id || m.name;
          var variants = bySku[sku];
          var groupKey = prov.name + "/" + sku;
          if (variants.length > 1 && variants[0] === m) {
            // First variant carries the fold row for the whole group.
            rows.push([
              "",
              prov.name,
              groupToggle(m.display || sku, variants.length, groupKey),
              "", "", "", "", "", ""
            ]);
            rowMeta.push({ group: groupKey, head: true, uncallable: uncallableReason });
          }
          rows.push([
            enabledCheckbox(entry),
            prov.name,
            m.display || m.name,
            m.category || "",
            m.context_window ? fmtInt(m.context_window) : "",
            m.cost_per_1m_input != null ? "$" + m.cost_per_1m_input : "",
            m.cost_per_1m_output != null ? "$" + m.cost_per_1m_output : "",
            m.name === prov.default_model ? "default" : "",
            editButton(entry)
          ]);
          rowMeta.push(variants.length > 1
            ? { group: groupKey, variant: true, uncallable: uncallableReason }
            : (uncallableReason ? { uncallable: uncallableReason } : null));
        });
      });
      // Before the early return below: a config with providers but no declared
      // models still fills the select, and the choice still has to survive.
      if (providerSel) restoreProvider(providerSel, chosen);
      if (!rows.length) {
        var msg = configuredProviders.length
          ? "Providers are configured, but none list a model here. Use Add model… or Discover below."
          : "No models configured yet. Use Add model… above, or search Discover below.";
        var none = empty(msg + " ");
        var start = document.createElement("button");
        start.type = "button";
        start.className = "primary";
        start.textContent = "Add model…";
        start.addEventListener("click", function () {
          var add = document.getElementById("models-add");
          if (add) add.click();
        });
        none.appendChild(start);
        box.appendChild(none);
        return;
      }
      // Providers this serve process cannot call, named with the server's
      // reason — the same wording idea as `clanker providers check` printing
      // "not configured". Their model rows stay in the table (inventory),
      // dimmed; only the chat picker hides them.
      var uncallable = (d.providers || []).filter(function (p) { return p && p.usable === false; });
      if (uncallable.length) {
        box.appendChild(empty("Not callable from this server: " + uncallable.map(function (p) {
          return p.name + " — " + providerUnusableReason(p);
        }).join("; ") + ". Still listed below; the chat picker hides them."));
      }
      box.appendChild(table(["enabled", "provider", "model", "category", "ctx", "in $/1M", "out $/1M", "", ""], rows));
      // Fold pass: hide variant rows behind their group's toggle row, and
      // dim the rows of a provider the server marked not callable.
      var trs = box.querySelectorAll("tbody tr");
      trs.forEach(function (tr, i) {
        var meta = rowMeta[i];
        if (meta && meta.variant) {
          tr.hidden = true;
          tr.className = "models-variant-row";
          tr.setAttribute("data-group", meta.group);
        }
        if (meta && meta.uncallable) {
          tr.classList.add("models-uncallable-row");
          tr.title = "Not callable from this server: " + meta.uncallable;
        }
      });
    })
    .catch(function (err) {
      failWithRetry(box, "Could not load providers: " + err.message, loadConfigured);
    });
}

function modelEntryPayload(entry) {
  var payload = { provider: entry.provider, model: entry.model, enabled: entry.enabled !== false };
  ["id", "display", "category", "reasoning_effort"].forEach(function (key) {
    if (entry[key]) payload[key] = entry[key];
  });
  ["context_window", "max_tokens", "rpm", "temperature", "top_p", "cost_per_1m_input", "cost_per_1m_output"].forEach(function (key) {
    if (entry[key] != null) payload[key] = entry[key];
  });
  if (entry.capabilities && entry.capabilities.length) payload.capabilities = entry.capabilities;
  return payload;
}

function saveModelEntry(entry, checkbox) {
  checkbox.disabled = true;
  return fetch("/api/config/model/set", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(modelEntryPayload(entry))
  }).then(readJson).then(function (d) {
    if (!d.ok) throw new Error(d.error || "write failed");
    checkbox.disabled = false;
    status((entry.enabled ? "Enabled " : "Disabled ") + entry.provider + "/" + entry.model + ".");
    window.dispatchEvent(new CustomEvent("clanker:model-visibility"));
  }).catch(function (err) {
    entry.enabled = !entry.enabled;
    checkbox.checked = entry.enabled;
    checkbox.disabled = false;
    status("Could not update " + entry.provider + "/" + entry.model + ": " + err.message + ".");
  });
}

function enabledCheckbox(entry) {
  var label = document.createElement("label");
  label.className = "models-enabled-toggle";
  var checkbox = document.createElement("input");
  checkbox.type = "checkbox";
  checkbox.checked = entry.enabled !== false;
  checkbox.setAttribute("aria-label", (checkbox.checked ? "Disable " : "Enable ") + entry.provider + "/" + entry.model);
  checkbox.addEventListener("change", function () {
    entry.enabled = checkbox.checked;
    checkbox.setAttribute("aria-label", (checkbox.checked ? "Disable " : "Enable ") + entry.provider + "/" + entry.model);
    saveModelEntry(entry, checkbox);
  });
  label.appendChild(checkbox);
  return label;
}

/* One SKU under several local names folds behind this row: the chevron
   toggle shows/hides every tr carrying the group's data-group. */
function groupToggle(label, count, groupKey) {
  var btn = document.createElement("button");
  btn.type = "button";
  btn.className = "secondary models-group-toggle";
  btn.setAttribute("aria-expanded", "false");
  btn.textContent = "▸ " + label + " · " + count + " variants";
  btn.addEventListener("click", function () {
    var open = btn.getAttribute("aria-expanded") === "true";
    btn.setAttribute("aria-expanded", String(!open));
    btn.textContent = (open ? "▸ " : "▾ ") + label + " · " + count + " variants";
    // Attribute-value comparison instead of a selector: the key is data,
    // not selector syntax, so no escaping questions.
    document.querySelectorAll("tr[data-group]").forEach(function (tr) {
      if (tr.getAttribute("data-group") === groupKey) tr.hidden = open;
    });
  });
  return btn;
}

function editButton(entry) {
  var btn = document.createElement("button");
  btn.type = "button";
  btn.className = "secondary models-snippet-btn";
  btn.textContent = "Edit";
  btn.setAttribute("aria-label", "Edit " + entry.provider + "/" + entry.model);
  btn.addEventListener("click", function () { showEditPanel(entry, false); });
  return btn;
}

/* ---- edit / add: form fields instead of a read-only snippet -------------
   Config replaces a model wholesale by table key on every load, so the form
   is always pre-filled with the model's current values (loadConfigured's
   entry, or all-blank for "Add model…") rather than left for the user to
   guess what to fill in — an edit that omitted a field would silently reset
   it to config.Model's struct default on the next `clanker serve` restart. */

var editEntry = null;
var editIsNew = false;

function editField(id) { return document.getElementById(id); }

function showEditPanel(entry, isNew) {
  var host = document.getElementById("models-edit");
  if (!host) return;
  hideSnippet();
  editEntry = entry;
  editIsNew = !!isNew;
  var title = document.getElementById("models-edit-title");
  if (title) title.textContent = isNew ? "Add a model" : entry.provider + "/" + entry.model;
  editField("models-edit-provider").value = entry.provider || "";
  editField("models-edit-provider").disabled = !isNew;
  editField("models-edit-model").value = entry.model || "";
  editField("models-edit-model").disabled = !isNew;
  editField("models-edit-id").value = entry.id || "";
  editField("models-edit-display").value = entry.display || "";
  editField("models-edit-category").value = entry.category || "";
  editField("models-edit-context").value = entry.context_window != null ? entry.context_window : "";
  editField("models-edit-max-tokens").value = entry.max_tokens != null ? entry.max_tokens : "";
  editField("models-edit-temperature").value = entry.temperature != null ? entry.temperature : "";
  editField("models-edit-top-p").value = entry.top_p != null ? entry.top_p : "";
  editField("models-edit-reasoning").value = entry.reasoning_effort || "";
  editField("models-edit-cost-in").value = entry.cost_per_1m_input != null ? entry.cost_per_1m_input : "";
  editField("models-edit-cost-out").value = entry.cost_per_1m_output != null ? entry.cost_per_1m_output : "";
  editField("models-edit-rpm").value = entry.rpm != null ? entry.rpm : "";
  editField("models-edit-capabilities").value = (entry.capabilities || []).join(", ");
  var removeBtn = document.getElementById("models-edit-remove");
  if (removeBtn) removeBtn.hidden = isNew;
  var save = document.getElementById("models-edit-save");
  if (save) { save.disabled = false; save.textContent = isNew ? "Add model" : "Save changes"; }
  setTomlMode(false);
  setEditNote("");
  host.hidden = false;
  try { host.scrollIntoView({ behavior: "smooth", block: "nearest" }); } catch (_) {}
}

function hideEditPanel() {
  var host = document.getElementById("models-edit");
  if (host) host.hidden = true;
  editEntry = null;
}

function setEditNote(text) {
  var note = document.getElementById("models-edit-note");
  if (!note) return;
  note.textContent = text;
  note.hidden = !text;
}

function numOrNull(id) {
  var v = editField(id).value;
  if (v === "" || v == null) return null;
  var n = Number(v);
  return isNaN(n) ? null : n;
}

function editPayload() {
  var provider = editField("models-edit-provider").value.trim();
  var model = editField("models-edit-model").value.trim();
  var payload = { provider: provider, model: model, enabled: !editEntry || editEntry.enabled !== false };
  var sku = editField("models-edit-id").value.trim();
  if (sku) payload.id = sku;
  var context = numOrNull("models-edit-context");
  if (context != null) payload.context_window = context;
  var maxTok = numOrNull("models-edit-max-tokens");
  if (maxTok != null) payload.max_tokens = maxTok;
  var temp = numOrNull("models-edit-temperature");
  if (temp != null) payload.temperature = temp;
  var topP = numOrNull("models-edit-top-p");
  if (topP != null) payload.top_p = topP;
  var reasoning = editField("models-edit-reasoning").value;
  if (reasoning) payload.reasoning_effort = reasoning;
  var display = editField("models-edit-display").value.trim();
  if (display) payload.display = display;
  var category = editField("models-edit-category").value.trim();
  if (category) payload.category = category;
  var costIn = numOrNull("models-edit-cost-in");
  if (costIn != null) payload.cost_per_1m_input = costIn;
  var costOut = numOrNull("models-edit-cost-out");
  var rpm = numOrNull("models-edit-rpm");
  if (rpm != null) payload.rpm = rpm;
  if (costOut != null) payload.cost_per_1m_output = costOut;
  var caps = editField("models-edit-capabilities").value.split(",").map(function (s) { return s.trim(); }).filter(Boolean);
  if (caps.length) payload.capabilities = caps;
  return payload;
}

/* ---- raw table mode (the OpenShift YAML-tab pattern, in TOML) ----------- */

var tomlMode = false;

/** The `[models."p/m"]` block the form currently describes. */
function editToml() {
  var p = editPayload();
  var lines = ["[models." + tomlStr(p.provider + "/" + p.model) + "]"];
  lines.push("provider = " + tomlStr(p.provider));
  if (p.enabled === false) lines.push("enabled = false");
  if (p.id) lines.push("id = " + tomlStr(p.id));
  if (p.context_window != null) lines.push("context_window = " + p.context_window);
  if (p.max_tokens != null) lines.push("max_tokens = " + p.max_tokens);
  if (p.temperature != null) lines.push("temperature = " + p.temperature);
  if (p.top_p != null) lines.push("top_p = " + p.top_p);
  if (p.reasoning_effort) lines.push("reasoning_effort = " + tomlStr(p.reasoning_effort));
  if (p.display) lines.push("display = " + tomlStr(p.display));
  if (p.category) lines.push("category = " + tomlStr(p.category));
  if (p.cost_per_1m_input != null) lines.push("cost_per_1m_input = " + p.cost_per_1m_input);
  if (p.cost_per_1m_output != null) lines.push("cost_per_1m_output = " + p.cost_per_1m_output);
  if (p.rpm != null) lines.push("rpm = " + p.rpm);
  if (p.capabilities && p.capabilities.length) lines.push("capabilities = [" + p.capabilities.map(tomlStr).join(", ") + "]");
  return lines.join("\n") + "\n";
}

function paintEditToml() {
  var text = document.getElementById("models-edit-toml-text");
  var code = document.getElementById("models-edit-toml-code");
  if (text && code) paintTomlInto(text, code);
}

function setTomlMode(on) {
  tomlMode = on;
  var form = document.getElementById("models-edit-form");
  var editor = document.getElementById("models-edit-toml-editor");
  var toggle = document.getElementById("models-edit-toml");
  var save = document.getElementById("models-edit-save");
  if (!form || !editor) return;
  form.hidden = on;
  editor.hidden = !on;
  if (toggle) toggle.setAttribute("aria-pressed", String(on));
  if (save) save.textContent = on ? "Save TOML" : (editIsNew ? "Add model" : "Save changes");
  if (on) {
    var text = document.getElementById("models-edit-toml-text");
    if (text) { text.value = editToml(); paintEditToml(); }
    setEditNote("Editing the raw table. Saving validates the whole config first; an invalid table is refused and nothing is written.");
  } else {
    setEditNote("");
  }
}

function saveTomlEdit() {
  var text = document.getElementById("models-edit-toml-text");
  var btn = document.getElementById("models-edit-save");
  if (!text) return;
  if (btn) btn.disabled = true;
  fetch("/api/config/table/set", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ block: text.value })
  })
    .then(readJson)
    .then(function (d) {
      if (!d.ok) throw new Error(d.error || "write failed");
      setEditNote("Saved to config.local.toml. " + (d.applied || "Hot reload applies it."));
      loadConfigured();
    })
    .catch(function (err) {
      setEditNote("Refused: " + err.message + " — the running config is unchanged.");
    })
    .finally(function () { if (btn) btn.disabled = false; });
}

function saveEdit() {
  if (tomlMode) return saveTomlEdit();
  var payload = editPayload();
  if (!payload.provider || !payload.model) {
    setEditNote("Provider and model ID are both required.");
    return;
  }
  var btn = document.getElementById("models-edit-save");
  if (btn) btn.disabled = true;
  fetch("/api/config/model/set", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  })
    .then(readJson)
    .then(function (d) {
      if (!d.ok) throw new Error(d.error || "write failed");
      setEditNote("Saved to config.local.toml. " + (d.applied || "The server reloads into it."));
      status("Wrote " + (d.path || "config.local.toml") + " for " + payload.provider + "/" + payload.model + ".");
      if (btn) btn.disabled = false;
      loadConfigured();
    })
    .catch(function (err) {
      if (btn) btn.disabled = false;
      setEditNote("Could not save: " + err.message);
    });
}

function removeEdit() {
  if (!editEntry || editIsNew) return;
  var btn = document.getElementById("models-edit-remove");
  var name = editEntry.provider + "/" + editEntry.model;
  askConfirm("Remove \"" + name + "\" from config.local.toml? A model only declared in the shared config.toml cannot be removed here.", {
    danger: true,
    confirmLabel: "Remove",
    title: "Remove model"
  }).then(function (yes) {
    if (!yes) return;
    if (btn) btn.disabled = true;
    fetch("/api/config/model/remove", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ provider: editEntry.provider, model: editEntry.model })
    })
      .then(readJson)
      .then(function (d) {
        if (!d.ok) throw new Error(d.error || "remove failed");
        if (btn) { btn.disabled = false; btn.textContent = "Remove"; }
        if (d.removed) {
          setEditNote("Removed from config.local.toml. " + (d.applied || "The server reloads into it."));
          status("Removed " + name + ".");
          loadConfigured();
        } else {
          setEditNote("Not in config.local.toml — it must be declared in the shared config.toml, which this page never edits.");
        }
      })
      .catch(function (err) {
        if (btn) { btn.disabled = false; btn.textContent = "Remove"; }
        setEditNote("Could not remove: " + err.message);
      });
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
        status("The provider listed no models.", "live");
        return;
      }
      out.appendChild(table(["id", "ctx"], rows));
      status(rows.length + " models from " + sel.value + ".", "live");
    })
    .catch(function (err) {
      status("Could not list models: " + err.message, "live");
      failWithRetry(out, "Could not list: " + err.message, loadLive);
    })
    .finally(function () { btn.disabled = false; });
}

var catalogSearching = false;
function syncCatalogBtn() {
  var q = document.getElementById("models-catalog-q");
  var btn = document.getElementById("models-catalog-btn");
  if (!btn) return;
  var tooShort = !q || q.value.trim().length < 2;
  btn.disabled = catalogSearching || tooShort;
  btn.title = catalogSearching ? "Searching…" : (tooShort
    ? "Type at least 2 characters"
    : "Search the models.dev catalog");
}

function searchCatalog() {
  var out = document.getElementById("models-catalog-out");
  var q = document.getElementById("models-catalog-q");
  if (!out || !q) return;
  var query = q.value.trim();
  if (query.length < 2) {
    out.textContent = "";
    out.appendChild(empty("Type at least 2 characters."));
    syncCatalogBtn();
    return;
  }
  catalogSearching = true;
  syncCatalogBtn();
  out.textContent = "";
  // The panel names a model from the result set being replaced.
  hideSnippet();
  out.appendChild(empty("Searching catalog…"));
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
        out.appendChild(empty("No catalog entry matches \"" + query + "\". Try another name, or refresh the catalog."));
        status("No catalog entry matches \"" + query + "\".", "catalog");
        return;
      }
      out.appendChild(table(["provider/model", "ctx", "in $/1M", "out $/1M", "capabilities", ""], rows));
      status(rows.length + (d.truncated ? "+ (truncated)" : "") + " catalog matches.", "catalog");
      if (d.truncated) {
        out.appendChild(empty("Showing the first " + rows.length + " matches — narrow the query for more specific results."));
      }
    })
    .catch(function (err) {
      status("Catalog search failed: " + err.message, "catalog");
      failWithRetry(out, "Catalog search failed: " + err.message, searchCatalog);
    })
    .finally(function () { catalogSearching = false; syncCatalogBtn(); });
}

function refreshCatalog() {
  var out = document.getElementById("models-catalog-out");
  var btn = document.getElementById("models-catalog-refresh");
  if (btn) btn.disabled = true;
  if (out) {
    out.textContent = "";
    out.appendChild(empty("Downloading models.dev into the local catalog…"));
  }
  fetch("/api/catalog/refresh", { method: "POST" })
    .then(readJson)
    .then(function (d) {
      var n = typeof d.bytes === "number" ? d.bytes : 0;
      status("Catalog refreshed (" + fmtBytes(n) + "). Search uses the new snapshot.", "catalog");
      if (out) {
        out.textContent = "";
        out.appendChild(empty("Catalog updated. Search again to see current matches."));
      }
    })
    .catch(function (err) {
      status("Catalog refresh failed: " + err.message, "catalog");
      failWithRetry(out, "Catalog refresh failed: " + err.message, refreshCatalog);
    })
    .finally(function () { if (btn) btn.disabled = false; });
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
  var catRefresh = document.getElementById("models-catalog-refresh");
  if (catRefresh) catRefresh.addEventListener("click", refreshCatalog);
  var q = document.getElementById("models-catalog-q");
  if (q) {
    q.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); searchCatalog(); }
    });
    q.addEventListener("input", syncCatalogBtn);
  }
  syncCatalogBtn();
  var refresh = document.getElementById("models-refresh");
  wireRefresh(refresh, loadModelsView);
  var copy = document.getElementById("models-snippet-copy");
  if (copy) copy.addEventListener("click", copySnippet);
  var save = document.getElementById("models-snippet-save");
  if (save) save.addEventListener("click", saveSnippet);
  var def = document.getElementById("models-snippet-default");
  if (def) def.addEventListener("click", saveDefault);
  var close = document.getElementById("models-snippet-close");
  if (close) close.addEventListener("click", hideSnippet);
  var add = document.getElementById("models-add");
  if (add) add.addEventListener("click", function () {
    showEditPanel({
      provider: "", model: "", id: "", display: "", category: "",
      context_window: 131072, max_tokens: 1024, rpm: null,
      temperature: null, top_p: null, reasoning_effort: "",
      cost_per_1m_input: null, cost_per_1m_output: null, capabilities: []
    }, true);
  });
  var editSave = document.getElementById("models-edit-save");
  if (editSave) editSave.addEventListener("click", saveEdit);
  var editRemove = document.getElementById("models-edit-remove");
  if (editRemove) editRemove.addEventListener("click", removeEdit);
  var editClose = document.getElementById("models-edit-close");
  if (editClose) editClose.addEventListener("click", hideEditPanel);
  var tomlToggle = document.getElementById("models-edit-toml");
  if (tomlToggle) tomlToggle.addEventListener("click", function () { setTomlMode(!tomlMode); });
  var tomlText = document.getElementById("models-edit-toml-text");
  if (tomlText) {
    tomlText.addEventListener("input", paintEditToml);
    tomlText.addEventListener("scroll", function () {
      var pre = tomlText.previousElementSibling;
      if (pre) { pre.scrollTop = tomlText.scrollTop; pre.scrollLeft = tomlText.scrollLeft; }
    });
  }
}
