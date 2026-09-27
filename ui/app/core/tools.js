// Vanilla, no bundler. Tools list — derived view over plugins + filter, with
// row rendering, detail, toggles and config editing. Keeps the list itself as
// a derived state (toolState) so filter and data cannot disagree.
import { scrollTo as vendorScrollTo } from "./vendor.js";
import { fmtBytes as utilFmtBytes, plural as utilPlural, searchFold } from "./utils.js";
import { showLoadError, UI } from "./ui.js";
import { toolCategoryLabel, compareToolCategories } from "./labels.js";

var _el = null;
var _allToolsHolder = null;
var _toolState = null;
var _clip = null;
var _readJson = null;
var _scrollTo = vendorScrollTo;

/* The list groups by each tool's manifest `category` (already sent by
   /api/plugins) so the surface reads as a handful of sections instead of
   a wall of a hundred rows. Headings come from toolCategoryLabel; order
   from compareToolCategories. Which sections you have folded away is a
   property of how you are browsing right now, not of the tools, so it
   lives in this browser like the rail's day-groups do. */
/* The Tools view's own shapes, on top of the shared tool-row family in
   core/ui.js. The disclosure chevron is the Tailwind source's
   `.disclosure-caret`: a masked chevron on a `::before`, in both mask
   spellings, which no utility composes. */
/* A skill or workflow card: name and meta on one line, description below. */
var SKILL_CARD_CLASS = "border-b border-rule px-0 py-3 [&_input[type=checkbox]]:mr-2 [&_input[type=checkbox]]:align-middle";
var SKILL_NAME_CLASS = "mr-4 font-mono text-sm font-bold text-fg";
var SKILL_META_CLASS = "font-mono text-xs tabular-nums text-fg-muted";
var SKILL_DESC_CLASS = "mt-1 font-sans text-sm text-fg-muted wrap-anywhere";

var TOOL_CONFIG_CLASS = "my-1 basis-full";
var TOOL_CONFIG_SUMMARY_CLASS = "disclosure-caret cursor-pointer list-none py-0.5 font-mono text-sm text-fg-muted focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1";
var TOOL_CONFIG_BODY_CLASS = "ml-4 flex flex-wrap items-end gap-x-2 gap-y-2 border-l border-dashed border-rule pl-3 pt-1";
var TOOL_FIELD_CLASS = "flex flex-col gap-1 [&_input]:min-h-8 [&_input]:min-w-32 [&_input]:rounded-plate-sm [&_input]:border [&_input]:border-border [&_input]:bg-surface [&_input]:px-2 [&_input]:py-0.5 [&_input]:font-mono [&_input]:text-sm [&_input]:text-fg [&_input:focus]:border-accent [&_label]:m-0 [&_label]:text-sm [&_label]:uppercase [&_label]:tracking-label [&_label]:text-fg-muted";
var TOOL_CONFIG_SAVE_CLASS = "min-h-8 cursor-pointer rounded-plate-sm border border-border bg-surface px-3 py-0.5 font-mono text-sm font-semibold text-fg-muted enabled:hover:border-accent enabled:hover:text-fg";
var TOOL_TOGGLE_CLASS = "min-h-8 cursor-pointer rounded-plate-sm border border-border bg-surface px-3 py-0.5 font-mono text-sm font-semibold text-fg-muted shadow-[var(--bevel-raised)] enabled:hover:border-accent enabled:hover:text-fg enabled:active:translate-y-px enabled:active:shadow-[var(--bevel-pressed)] focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1 motion-reduce:active:transform-none data-[on=true]:border-ok data-[on=true]:text-ok data-[on=true]:before:mr-2 data-[on=true]:before:inline-block data-[on=true]:before:h-[0.5em] data-[on=true]:before:w-[0.5em] data-[on=true]:before:rounded-full data-[on=true]:before:bg-lamp-dome data-[on=true]:before:align-middle data-[on=true]:before:shadow-[var(--lamp-ring),var(--lamp-glow)] data-[on=true]:before:content-['']";
var TOOL_DETAIL_DESC_CLASS = "mt-1 mb-3 max-w-measure font-mono text-sm text-fg wrap-anywhere";
var TOOL_DETAIL_LLM_DESC_CLASS = "-mt-1 mb-3 max-w-measure font-mono text-xs text-fg-muted wrap-anywhere [&_strong]:font-bold [&_strong]:text-fg-muted";
var TOOL_DETAIL_H_CLASS = "mt-3 mb-1 font-mono text-sm font-bold uppercase tracking-label text-fg-muted";
var TOOL_PARAMS_CLASS = "m-0 grid grid-cols-[10rem_1fr] gap-x-4 gap-y-0.5 font-mono text-sm max-[40rem]:grid-cols-1 [&_dd]:m-0 [&_dd]:text-fg-muted [&_dd]:wrap-anywhere [&_dt]:font-bold [&_dt]:normal-case [&_dt]:tracking-normal [&_dt]:text-fg [&_dt]:wrap-anywhere max-[40rem]:[&_dt]:mt-2";
var TOOL_REQ_CLASS = "font-normal text-danger";
var TOOL_NONE_CLASS = "italic";

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

function groupLabel(cat) { return toolCategoryLabel(cat); }

export function renderTools(filterText) {
  _toolState.val = {
    tools: _allToolsHolder.list,
    filter: (filterText == null ? _el.toolFilter.value : filterText).trim()
  };
}

/* Set by a failed `loadTools` and read by the panel's render, so the failure
   and its retry survive every re-render the filter triggers. */
var _toolLoadError = null;

function buildToolRow(t) {
  var row = document.createElement("div");
  row.className = UI.toolRow.row;
  var name = document.createElement("button");
  name.type = "button";
  name.className = UI.toolRow.name;
  name.textContent = t.name;
  name.setAttribute("aria-label", "Show details for " + t.name);
  name.addEventListener("click", function () { showToolDetail(t); });
  row.appendChild(name);
  if (t.core) {
    var tag = document.createElement("span");
    tag.className = UI.toolRow.tag;
    tag.textContent = "core";
    row.appendChild(tag);
  } else {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = TOOL_TOGGLE_CLASS;
    btn.dataset.on = String(!!t.enabled);
    btn.textContent = t.enabled ? "on" : "off";
    btn.setAttribute("aria-pressed", String(!!t.enabled));
    btn.setAttribute("aria-label", (t.enabled ? "Disable " : "Enable ") + t.name);
    btn.addEventListener("click", function () { toggleTool(t, btn); });
    row.appendChild(btn);
  }
  if (t.transform) {
    var tr = document.createElement("span");
    tr.className = UI.toolRow.tag;
    tr.textContent = "transform " + t.transform.phase;
    row.appendChild(tr);
  }
  if (t.llm) {
    var llm = document.createElement("span");
    llm.className = UI.toolRow.tag;
    llm.textContent = "llm";
    row.appendChild(llm);
  }
  (t.tags || []).forEach(function (tagName) {
    var tg = document.createElement("span");
    tg.className = UI.toolRow.tag;
    tg.textContent = tagName;
    row.appendChild(tg);
  });
  if (t.config_editable && t.config_editable.length) row.appendChild(buildToolConfig(t));
  var desc = document.createElement("span");
  desc.className = UI.toolRow.desc;
  var text = (t.description || "").trim();
  var stop = text.indexOf(". ");
  desc.textContent = stop > 0 && stop < 160 ? text.slice(0, stop + 1) : _clip(text, 160);
  desc.title = text;
  row.appendChild(desc);
  return row;
}

/** Which kind of value a settings field holds. The descriptor's declared
 *  type (config_types, from the manifest's shipped default) wins: `typeof`
 *  on the current value typed a key with no override yet as "undefined" and
 *  saved it back as a string, and it re-derived a poisoned override's wrong
 *  type forever. `typeof current` stays as the fallback for a third-party
 *  manifest that ships no default. */
export function configFieldKind(t, key, current) {
  var declared = t.config_types ? t.config_types[key] : undefined;
  if (declared === "number" || declared === "boolean" || declared === "string") return declared;
  return typeof current;
}

function buildToolConfig(t) {
  var details = document.createElement("details");
  details.className = TOOL_CONFIG_CLASS;
  var summary = document.createElement("summary");
  summary.className = TOOL_CONFIG_SUMMARY_CLASS;
  summary.textContent = "settings";
  details.appendChild(summary);
  var body = document.createElement("div");
  body.className = TOOL_CONFIG_BODY_CLASS;
  var inputs = {};
  t.config_editable.forEach(function (key) {
    var current = (t.config || {})[key];
    var kind = configFieldKind(t, key, current);
    var field = document.createElement("div");
    field.className = TOOL_FIELD_CLASS;
    var id = "cfg-" + t.name + "-" + key;
    var label = document.createElement("label");
    label.setAttribute("for", id);
    label.textContent = key;
    field.appendChild(label);
    var input = document.createElement("input");
    input.id = id;
    input.type = kind === "number" ? "number" : "text";
    input.value = current === undefined || current === null ? "" : String(current);
    input.dataset.kind = kind;
    field.appendChild(input);
    inputs[key] = input;
    body.appendChild(field);
  });
  var save = document.createElement("button");
  save.type = "button";
  save.className = TOOL_CONFIG_SAVE_CLASS;
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
  head.className = UI.runDetail.head;
  var titleWrap = document.createElement("span");
  var title = document.createElement("span");
  title.className = UI.runDetail.title;
  title.textContent = t.name;
  titleWrap.appendChild(title);
  var meta = document.createElement("span");
  meta.className = UI.runDetail.meta;
  var tags = [];
  if (t.core) tags.push("core");
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
  closeBtn.className = "secondary";
  closeBtn.textContent = "Close";
  closeBtn.addEventListener("click", function () {
    _el.toolDetail.hidden = true;
    _el.toolDetail.textContent = "";
  });
  head.appendChild(closeBtn);
  _el.toolDetail.appendChild(head);
  var desc = document.createElement("p");
  desc.className = TOOL_DETAIL_DESC_CLASS;
  desc.textContent = t.description || "(no description)";
  _el.toolDetail.appendChild(desc);
  // Shown only when it actually differs: an unmigrated tool's llm_description
  // is a duplicate of description, and repeating it teaches nothing.
  if (t.llm_description && t.llm_description !== t.description) {
    var llmDesc = document.createElement("p");
    llmDesc.className = TOOL_DETAIL_LLM_DESC_CLASS;
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
    list.className = TOOL_PARAMS_CLASS;
    props.forEach(function (key) {
      var spec = schema.properties[key] || {};
      var dt = document.createElement("dt");
      dt.textContent = key;
      if (required.indexOf(key) !== -1) {
        var req = document.createElement("span");
        req.className = TOOL_REQ_CLASS;
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
  policy.className = TOOL_PARAMS_CLASS;
  [["Network", t.network_allow, "no network"],
   ["Filesystem", t.fs_prefixes, "no filesystem access"],
   ["Commands", t.exec_allow, "the harness default set"]].forEach(function (row) {
    var dt = document.createElement("dt");
    dt.textContent = row[0];
    policy.appendChild(dt);
    var dd = document.createElement("dd");
    dd.textContent = row[1] && row[1].length ? row[1].join(", ") : row[2];
    if (!(row[1] && row[1].length)) dd.className = TOOL_NONE_CLASS;
    policy.appendChild(dd);
  });
  _el.toolDetail.appendChild(policy);
  _scrollTo(_el.toolDetail, "nearest");
  closeBtn.focus();
}

function sectionTitle(text) {
  var h = document.createElement("h3");
  h.className = TOOL_DETAIL_H_CLASS;
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
      _toolLoadError = null;
      _allToolsHolder.list.length = 0; Array.prototype.push.apply(_allToolsHolder.list, data.plugins || []);
      renderTools(_el.toolFilter.value);
    })
    .catch(function (err) {
      var msg = "Could not load tools: " + err.message;
      _toolLoadError = msg;
      _el.toolsStatus.textContent = msg;
      showLoadError(_el.tools, msg, loadTools);
      // The filter input sits outside the bound panel, so typing in it re-runs
      // the bind and would replace the failure above — and its retry — with
      // "no tool matches" on top of a list that never loaded. The render reads
      // `_toolLoadError` so the panel keeps saying so.
      renderTools(_el.toolFilter.value);
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
        card.className = SKILL_CARD_CLASS;
        var name = document.createElement("span");
        name.className = SKILL_NAME_CLASS;
        name.textContent = wf.name;
        card.appendChild(name);
        if (wf.arg_hint) {
          var hint = document.createElement("span");
          hint.className = SKILL_META_CLASS;
          hint.textContent = wf.arg_hint;
          card.appendChild(hint);
        }
        var meta = document.createElement("span");
        meta.className = SKILL_META_CLASS;
        meta.textContent = wf.rel_path;
        card.appendChild(meta);
        if (wf.chain) {
          var chainTag = document.createElement("span");
          chainTag.className = UI.toolRow.tag;
          chainTag.textContent = "chain";
          card.appendChild(chainTag);
        }
        (wf.tags || []).forEach(function (tagName) {
          var tg = document.createElement("span");
          tg.className = UI.toolRow.tag;
          tg.textContent = tagName;
          card.appendChild(tg);
        });
        if (wf.description) {
          var desc = document.createElement("p");
          desc.className = SKILL_DESC_CLASS;
          desc.textContent = wf.description;
          card.appendChild(desc);
        }
        box.appendChild(card);
      });
      if (status) status.textContent = utilPlural(list.length, { one: "workflow.", other: "workflows." });
    })
    .catch(function () {
      var msg = "Could not load templates.";
      if (status) status.textContent = "Could not load workflows.";
      showLoadError(box, msg, loadWorkflows);
    });
}

/* The Skills list under the tool rows: GET /api/skills relays the skills
   guest (same discovery as the system prompt). Disabled skills stay in the
   list so they can be turned back on. Best-effort: a skills failure must
   not take the tools list down with it. */
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
        card.className = SKILL_CARD_CLASS;
        // Not named `box`: this callback used to shadow the #skills container
        // with the checkbox, so the card was appended into its own checkbox,
        // a hierarchy cycle the DOM refuses, which made any non-empty skills
        // list render as "Could not load skills."
        var check = document.createElement("input");
        check.type = "checkbox";
        check.checked = sk.enabled !== false;
        check.title = check.checked ? "Included in the system prompt" : "Off: not sent to the model";
        check.addEventListener("change", function () {
          check.disabled = true;
          fetch("/api/skills", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name: sk.name, enabled: check.checked })
          })
            .then(_readJson)
            .then(function () { return loadSkills(); })
            .catch(function (err) {
              check.checked = !check.checked;
              if (status) status.textContent = "Skill: " + err.message;
            })
            .then(function () { check.disabled = false; });
        });
        card.appendChild(check);
        var name = document.createElement("span");
        name.className = SKILL_NAME_CLASS;
        name.textContent = sk.title || sk.name.replace(/\.md$/, "");
        card.appendChild(name);
        var meta = document.createElement("span");
        meta.className = SKILL_META_CLASS;
        meta.textContent = sk.name + "  \u00b7  " + utilFmtBytes(sk.bytes);
        card.appendChild(meta);
        if (sk.description) {
          var desc = document.createElement("p");
          desc.className = SKILL_DESC_CLASS;
          desc.textContent = sk.description;
          card.appendChild(desc);
        }
        box.appendChild(card);
      });
      if (status) status.textContent = utilPlural(list.length, { one: "skill.", other: "skills." });
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
      if (_toolLoadError) {
        _el.toolsStatus.textContent = _toolLoadError;
        return ctx.T.p({ class: "run-empty" },
          _toolLoadError + " ",
          ctx.T.button({ type: "button", class: "secondary", onclick: loadTools }, "Try again"));
      }
      var shown = !s.filter ? s.tools : s.tools.filter(function (t) {
        var f = searchFold(s.filter);
        return searchFold(t.name).indexOf(f) !== -1 ||
          searchFold(t.description || "").indexOf(f) !== -1 ||
          searchFold(t.category || "").indexOf(f) !== -1 ||
          searchFold(toolCategoryLabel(t.category)).indexOf(f) !== -1 ||
          (t.tags || []).some(function (tagName) { return searchFold(tagName).indexOf(f) !== -1; });
      });
      _el.toolsStatus.textContent = s.filter
        ? utilPlural(shown.length, { one: "tool matches.", other: "tools match." })
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
      order.sort(compareToolCategories);

      var out = [];
      order.forEach(function (cat) {
        var items = groups[cat];
        var collapsed = !filtering && isToolGroupCollapsed(cat);
        var head = ctx.T.button({
          type: "button",
          class: UI.toolRow.group,
          "aria-expanded": String(!collapsed),
          "aria-label": (collapsed ? "Expand " : "Collapse ") + groupLabel(cat),
          title: (collapsed ? "Show " : "Hide ") + utilPlural(items.length, { one: "tool", other: "tools" }) + " in " + groupLabel(cat),
          onclick: function () { toggleToolGroupCollapsed(cat); }
        }, ctx.T.span({ class: UI.toolRow.groupCaret }, collapsed ? "▸" : "▾"),
          ctx.T.span({ class: UI.toolRow.groupName }, groupLabel(cat)),
          ctx.T.span({ class: UI.toolRow.groupCount }, String(items.length)));
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
