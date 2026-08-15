// Vanilla, no bundler. Tools list — derived view over plugins + filter, with
// row rendering, detail, toggles and config editing. Keeps the list itself as
// a derived state (toolState) so filter and data cannot disagree.
import { scrollTo as vendorScrollTo } from "./vendor.js";
import { fmtBytes as utilFmtBytes } from "./utils.js";
import { showLoadError } from "./ui.js";

var _el = null;
var _allToolsHolder = null;
var _toolState = null;
var _clip = null;
var _readJson = null;
var _scrollTo = vendorScrollTo;

/* The list groups by each tool's manifest `category` (already sent by
   /api/plugins, already shown as a detail-view tag) so the surface reads as
   a handful of sections instead of a wall of a hundred rows. Which sections
   you have folded away is a property of how you are browsing right now, not
   of the tools, so it lives in this browser like the rail's day-groups do. */
function loadCollapsedToolGroups() {
  try { return JSON.parse(window.localStorage.getItem("clanker.toolGroupsCollapsed") || "[]"); } catch (e) { return []; }
}
var collapsedToolGroups = loadCollapsedToolGroups();
function isToolGroupCollapsed(g) { return collapsedToolGroups.indexOf(g) !== -1; }
function toggleToolGroupCollapsed(g) {
  var at = collapsedToolGroups.indexOf(g);
  if (at === -1) collapsedToolGroups.push(g); else collapsedToolGroups.splice(at, 1);
  try { window.localStorage.setItem("clanker.toolGroupsCollapsed", JSON.stringify(collapsedToolGroups)); } catch (e) {}
  renderTools(null);
}

function groupLabel(cat) { return cat.charAt(0).toUpperCase() + cat.slice(1); }

export function renderTools(filterText) {
  _toolState.val = {
    tools: _allToolsHolder.list,
    filter: (filterText == null ? _el.toolFilter.value : filterText).trim().toLowerCase()
  };
}

function buildToolRow(t) {
  var row = document.createElement("div");
  row.className = "tool-row";
  var name = document.createElement("button");
  name.type = "button";
  name.className = "tool-name";
  name.textContent = t.name;
  name.setAttribute("aria-label", "Show details for " + t.name);
  name.addEventListener("click", function () { showToolDetail(t); });
  row.appendChild(name);
  if (t.core) {
    var tag = document.createElement("span");
    tag.className = "tool-tag";
    tag.textContent = "core";
    row.appendChild(tag);
  } else {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "tool-toggle";
    btn.dataset.on = String(!!t.enabled);
    btn.textContent = t.enabled ? "on" : "off";
    btn.setAttribute("aria-pressed", String(!!t.enabled));
    btn.setAttribute("aria-label", (t.enabled ? "Disable " : "Enable ") + t.name);
    btn.addEventListener("click", function () { toggleTool(t, btn); });
    row.appendChild(btn);
  }
  if (t.transform) {
    var tr = document.createElement("span");
    tr.className = "tool-tag";
    tr.textContent = "transform " + t.transform.phase;
    row.appendChild(tr);
  }
  if (t.llm) {
    var llm = document.createElement("span");
    llm.className = "tool-tag";
    llm.textContent = "llm";
    row.appendChild(llm);
  }
  (t.tags || []).forEach(function (tagName) {
    var tg = document.createElement("span");
    tg.className = "tool-tag";
    tg.textContent = tagName;
    row.appendChild(tg);
  });
  if (t.config_editable && t.config_editable.length) row.appendChild(buildToolConfig(t));
  var desc = document.createElement("span");
  desc.className = "tool-desc";
  var text = (t.description || "").trim();
  var stop = text.indexOf(". ");
  desc.textContent = stop > 0 && stop < 160 ? text.slice(0, stop + 1) : _clip(text, 160);
  desc.title = text;
  row.appendChild(desc);
  return row;
}

function buildToolConfig(t) {
  var details = document.createElement("details");
  details.className = "tool-config";
  var summary = document.createElement("summary");
  summary.textContent = "settings";
  details.appendChild(summary);
  var body = document.createElement("div");
  body.className = "tool-config-body";
  var inputs = {};
  t.config_editable.forEach(function (key) {
    var current = (t.config || {})[key];
    var field = document.createElement("div");
    field.className = "tool-field";
    var id = "cfg-" + t.name + "-" + key;
    var label = document.createElement("label");
    label.setAttribute("for", id);
    label.textContent = key;
    field.appendChild(label);
    var input = document.createElement("input");
    input.id = id;
    input.type = typeof current === "number" ? "number" : "text";
    input.value = current === undefined || current === null ? "" : String(current);
    input.dataset.kind = typeof current;
    field.appendChild(input);
    inputs[key] = input;
    body.appendChild(field);
  });
  var save = document.createElement("button");
  save.type = "button";
  save.className = "tool-config-save";
  save.textContent = "Save";
  save.addEventListener("click", function () { saveToolConfig(t, inputs, save); });
  body.appendChild(save);
  details.appendChild(body);
  return details;
}

function saveToolConfig(t, inputs, btn) {
  var next = {};
  var bad = null;
  Object.keys(inputs).forEach(function (key) {
    var input = inputs[key];
    if (input.dataset.kind === "number") {
      var n = Number(input.value);
      if (input.value.trim() === "" || !isFinite(n)) { bad = key; return; }
      next[key] = n;
    } else if (input.dataset.kind === "boolean") {
      next[key] = input.value.trim().toLowerCase() === "true";
    } else {
      next[key] = input.value;
    }
  });
  if (bad) {
    _el.toolsStatus.textContent = t.name + ": " + bad + " must be a number.";
    return;
  }
  btn.disabled = true;
  fetch("/api/plugins/config", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: t.name, config: next })
  }).then(function (r) {
    return r.json().then(function (data) {
      if (!r.ok || !data.ok) throw new Error(data.error || ("HTTP " + r.status));
      return data;
    });
  }).then(function () {
    t.config = next;
    _el.toolsStatus.textContent = "Saved settings for " + t.name + ".";
  }).catch(function (err) {
    _el.toolsStatus.textContent = "Could not save " + t.name + ": " + err.message;
  }).finally(function () {
    btn.disabled = false;
  });
}

export function showToolDetail(t) {
  _el.toolDetail.textContent = "";
  _el.toolDetail.hidden = false;
  var head = document.createElement("div");
  head.className = "run-detail-head";
  var titleWrap = document.createElement("span");
  var title = document.createElement("span");
  title.className = "run-detail-title";
  title.textContent = t.name;
  titleWrap.appendChild(title);
  var meta = document.createElement("span");
  meta.className = "run-detail-meta";
  var tags = [];
  if (t.core) tags.push("core");
  if (t.category) tags.push(t.category);
  if (t.llm) tags.push("calls the model");
  if (t.sequential) tags.push("sequential");
  if (t.check) tags.push("check");
  if (t.transform) tags.push("transform " + t.transform.phase + " (order " + t.transform.order + ")");
  (t.tags || []).forEach(function (tagName) { tags.push(tagName); });
  tags.push(t.enabled ? "enabled" : "disabled");
  meta.textContent = "  " + tags.join("  \u00b7  ");
  titleWrap.appendChild(meta);
  head.appendChild(titleWrap);
  var closeBtn = document.createElement("button");
  closeBtn.type = "button";
  closeBtn.className = "secondary run-detail-close";
  closeBtn.textContent = "Close";
  closeBtn.addEventListener("click", function () {
    _el.toolDetail.hidden = true;
    _el.toolDetail.textContent = "";
  });
  head.appendChild(closeBtn);
  _el.toolDetail.appendChild(head);
  var desc = document.createElement("p");
  desc.className = "tool-detail-desc";
  desc.textContent = t.description || "(no description)";
  _el.toolDetail.appendChild(desc);
  // Shown only when it actually differs: an unmigrated tool's llm_description
  // is a duplicate of description, and repeating it teaches nothing.
  if (t.llm_description && t.llm_description !== t.description) {
    var llmDesc = document.createElement("p");
    llmDesc.className = "tool-detail-llm-desc";
    var llmLabel = document.createElement("strong");
    llmLabel.textContent = "For the model: ";
    llmDesc.appendChild(llmLabel);
    llmDesc.appendChild(document.createTextNode(t.llm_description));
    _el.toolDetail.appendChild(llmDesc);
  }
  var schema = t.input_schema;
  var props = schema && schema.properties ? Object.keys(schema.properties) : [];
  if (props.length) {
    var required = (schema.required || []);
    var list = document.createElement("dl");
    list.className = "tool-params";
    props.forEach(function (key) {
      var spec = schema.properties[key] || {};
      var dt = document.createElement("dt");
      dt.textContent = key;
      if (required.indexOf(key) !== -1) {
        var req = document.createElement("span");
        req.className = "tool-req";
        req.textContent = " required";
        dt.appendChild(req);
      }
      list.appendChild(dt);
      var dd = document.createElement("dd");
      dd.textContent = (spec.type || "any") + (spec.description ? " \u2014 " + spec.description : "");
      list.appendChild(dd);
    });
    _el.toolDetail.appendChild(sectionTitle("Accepts"));
    _el.toolDetail.appendChild(list);
  }
  _el.toolDetail.appendChild(sectionTitle("Sandbox"));
  var policy = document.createElement("dl");
  policy.className = "tool-params";
  [["Network", t.network_allow, "no network"],
   ["Filesystem", t.fs_prefixes, "no filesystem access"],
   ["Commands", t.exec_allow, "the harness default set"]].forEach(function (row) {
    var dt = document.createElement("dt");
    dt.textContent = row[0];
    policy.appendChild(dt);
    var dd = document.createElement("dd");
    dd.textContent = row[1] && row[1].length ? row[1].join(", ") : row[2];
    if (!(row[1] && row[1].length)) dd.className = "tool-none";
    policy.appendChild(dd);
  });
  _el.toolDetail.appendChild(policy);
  _scrollTo(_el.toolDetail, "nearest");
  closeBtn.focus();
}

function sectionTitle(text) {
  var h = document.createElement("h3");
  h.className = "tool-detail-h";
  h.textContent = text;
  return h;
}

export function toggleTool(t, btn) {
  var want = !t.enabled;
  btn.disabled = true;
  fetch("/api/plugins", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: t.name, on: want })
  }).then(_readJson).then(function () {
    t.enabled = want;
    btn.dataset.on = String(want);
    btn.textContent = want ? "on" : "off";
    btn.setAttribute("aria-pressed", String(want));
    btn.setAttribute("aria-label", (want ? "Disable " : "Enable ") + t.name);
    _el.toolsStatus.textContent = (want ? "Enabled " : "Disabled ") + t.name;
  }).catch(function (err) {
    _el.toolsStatus.textContent = "Could not switch " + t.name + ": " + err.message;
  }).finally(function () {
    btn.disabled = false;
  });
}

export function loadTools() {
  return fetch("/api/plugins")
    .then(_readJson)
    .then(function (data) {
      _allToolsHolder.list.length = 0; Array.prototype.push.apply(_allToolsHolder.list, data.plugins || []);
      renderTools(_el.toolFilter.value);
    })
    .catch(function (err) {
      var msg = "Could not load tools: " + err.message;
      _el.toolsStatus.textContent = msg;
      showLoadError(_el.tools, msg, loadTools);
    });
}

// Exported so the Prompts view can load templates and skills independently.
export { loadWorkflows, loadSkills };

/* Workflows live next to skills: GET /api/workflows mirrors the same
   discovery (workflows/ plus .cursor/workflows as fallback, missing → []). */
function loadWorkflows() {
  var box = document.getElementById("workflows");
  var status = document.getElementById("workflows-status");
  if (!box) return Promise.resolve();
  return fetch("/api/workflows")
    .then(_readJson)
    .then(function (data) {
      var list = (data && data.workflows) || [];
      box.textContent = "";
      box.hidden = false;
      if (!list.length) {
        var emptyWf = document.createElement("p");
        emptyWf.className = "run-empty";
        emptyWf.textContent = "No templates on file. Add a markdown file under workflows/.";
        box.appendChild(emptyWf);
        if (status) status.textContent = "No workflows.";
        return;
      }
      list.forEach(function (wf) {
        var card = document.createElement("div");
        card.className = "skill-card";
        var name = document.createElement("span");
        name.className = "skill-name";
        name.textContent = wf.name;
        card.appendChild(name);
        if (wf.arg_hint) {
          var hint = document.createElement("span");
          hint.className = "skill-meta";
          hint.textContent = wf.arg_hint;
          card.appendChild(hint);
        }
        var meta = document.createElement("span");
        meta.className = "skill-meta";
        meta.textContent = wf.rel_path;
        card.appendChild(meta);
        if (wf.chain) {
          var chainTag = document.createElement("span");
          chainTag.className = "tool-tag";
          chainTag.textContent = "chain";
          card.appendChild(chainTag);
        }
        (wf.tags || []).forEach(function (tagName) {
          var tg = document.createElement("span");
          tg.className = "tool-tag";
          tg.textContent = tagName;
          card.appendChild(tg);
        });
        if (wf.description) {
          var desc = document.createElement("p");
          desc.className = "skill-desc";
          desc.textContent = wf.description;
          card.appendChild(desc);
        }
        box.appendChild(card);
      });
      if (status) status.textContent = list.length + (list.length === 1 ? " workflow." : " workflows.");
    })
    .catch(function () {
      var msg = "Could not load templates.";
      if (status) status.textContent = "Could not load workflows.";
      showLoadError(box, msg, loadWorkflows);
    });
}

/* The Skills list under the tool rows: GET /api/skills mirrors the system
   prompt's discovery (same dir, same filters, same sort), so this can never
   disagree with what the agent actually has in context. Best-effort — a
   skills failure must not take the tools list down with it. */
function loadSkills() {
  var box = document.getElementById("skills");
  var status = document.getElementById("skills-status");
  if (!box) return Promise.resolve();
  return fetch("/api/skills")
    .then(_readJson)
    .then(function (data) {
      var list = (data && data.skills) || [];
      box.textContent = "";
      box.hidden = false;
      if (!list.length) {
        var emptySk = document.createElement("p");
        emptySk.className = "run-empty";
        emptySk.textContent = "No skills on file. Add a markdown file under skills/.";
        box.appendChild(emptySk);
        if (status) status.textContent = "No skills.";
        return;
      }
      list.forEach(function (sk) {
        var card = document.createElement("div");
        card.className = "skill-card";
        var name = document.createElement("span");
        name.className = "skill-name";
        name.textContent = sk.title || sk.name.replace(/\.md$/, "");
        card.appendChild(name);
        var meta = document.createElement("span");
        meta.className = "skill-meta";
        meta.textContent = sk.name + "  \u00b7  " + utilFmtBytes(sk.bytes);
        card.appendChild(meta);
        if (sk.description) {
          var desc = document.createElement("p");
          desc.className = "skill-desc";
          desc.textContent = sk.description;
          card.appendChild(desc);
        }
        box.appendChild(card);
      });
      if (status) status.textContent = list.length + (list.length === 1 ? " skill." : " skills.");
    })
    .catch(function () {
      var msg = "Could not load skills.";
      if (status) status.textContent = msg;
      showLoadError(box, msg, loadSkills);
    });
}

export function bindTools(ctx) {
  _el = ctx.el;
  _allToolsHolder = ctx.allToolsHolder;
  _toolState = ctx.toolState;
  _clip = ctx.clip;
  _readJson = ctx.readJson;
  _scrollTo = ctx.scrollTo || _scrollTo;
  // renderer that was previously inline as bind(el.tools, toolState, ...)
  if (ctx.bind && ctx.T && ctx.UI) {
    ctx.bind(_el.tools, _toolState, function (s) {
      var shown = !s.filter ? s.tools : s.tools.filter(function (t) {
        return t.name.toLowerCase().indexOf(s.filter) !== -1 ||
          (t.description || "").toLowerCase().indexOf(s.filter) !== -1 ||
          (t.tags || []).some(function (tagName) { return tagName.toLowerCase().indexOf(s.filter) !== -1; });
      });
      _el.toolsStatus.textContent = s.filter
        ? shown.length + (shown.length === 1 ? " tool matches." : " tools match.")
        : "";
      if (!shown.length) {
        if (s.filter) {
          return ctx.T.p({ class: "run-empty" },
            "No tool matches “" + s.filter + "”. ",
            ctx.T.button({
              type: "button",
              class: "secondary",
              onclick: function () {
                _el.toolFilter.value = "";
                renderTools("");
                if (_el.toolFilter.focus) _el.toolFilter.focus();
              }
            }, "Clear filter"));
        }
        return ctx.UI.empty("No tools registered. `zig build tools` compiles them.");
      }

      // Groups a filter matched stay open regardless of stored collapse
      // state: a search result hidden behind an earlier fold reads as a bug,
      // not a feature.
      var filtering = !!s.filter;
      var groups = {};
      var order = [];
      shown.forEach(function (t) {
        var cat = t.category || "other";
        if (!groups[cat]) { groups[cat] = []; order.push(cat); }
        groups[cat].push(t);
      });
      order.sort(function (a, b) {
        if (a === b) return 0;
        if (a === "other") return 1;
        if (b === "other") return -1;
        return a < b ? -1 : 1;
      });

      var out = [];
      order.forEach(function (cat) {
        var items = groups[cat];
        var collapsed = !filtering && isToolGroupCollapsed(cat);
        var head = ctx.T.button({
          type: "button",
          class: "tool-group",
          "aria-expanded": String(!collapsed),
          "aria-label": (collapsed ? "Expand " : "Collapse ") + groupLabel(cat),
          title: (collapsed ? "Show " : "Hide ") + items.length + (items.length === 1 ? " tool" : " tools") + " in " + groupLabel(cat),
          onclick: function () { toggleToolGroupCollapsed(cat); }
        }, ctx.T.span({ class: "tool-group-caret" }, collapsed ? "▸" : "▾"),
          ctx.T.span({ class: "tool-group-name" }, groupLabel(cat)),
          ctx.T.span({ class: "tool-group-count" }, String(items.length)));
        out.push(head);
        if (collapsed) return;
        items.forEach(function (t) { out.push(buildToolRow(t)); });
      });
      return out;
    });
  }
  var timer = null;
  _el.toolFilter.addEventListener("input", function () {
    if (timer) window.clearTimeout(timer);
    timer = window.setTimeout(function () { renderTools(_el.toolFilter.value); }, 120);
  });
}
