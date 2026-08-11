document.addEventListener("DOMContentLoaded", function () {
"use strict";

var el = {
  form: document.getElementById("task-form"),
  task: document.getElementById("task"),
  attachments: document.getElementById("attachments"),
  submit: document.getElementById("submit"),
  cancel: document.getElementById("cancel"),
  refresh: document.getElementById("refresh"),
  hint: document.getElementById("hint"),
  transcript: document.getElementById("transcript"),
  instance: document.getElementById("instance"),
  instanceChip: document.getElementById("instance-chip"),
  peers: document.getElementById("peers"),
  peersChip: document.getElementById("peers-chip"),
  sessionChip: document.getElementById("session-chip"),
  newChat: document.getElementById("new-chat"),
  themeToggle: document.getElementById("theme-toggle"),
  runsRefresh: document.getElementById("runs-refresh"),
  runFilter: document.getElementById("run-filter"),
  runStatus: document.getElementById("run-status"),
  rail: document.getElementById("rail"),
  railList: document.getElementById("rail-list"),
  railContext: document.getElementById("rail-context"),
  railToggle: document.getElementById("rail-toggle"),
  sessionTitle: document.getElementById("session-title"),
  railScrim: document.getElementById("rail-scrim"),
  promptList: document.getElementById("prompt-list"),
  promptSave: document.getElementById("prompt-save"),
  contextMeter: document.getElementById("context-meter"),
  sessionStatus: document.getElementById("session-status"),
  sessionFork: document.getElementById("session-fork"),
  sessionRename: document.getElementById("session-rename"),
  sessionMove: document.getElementById("session-move"),
  sessionDelete: document.getElementById("session-delete"),
  chatRoom: document.getElementById("chat-room"),
  chatLog: document.getElementById("chat-log"),
  chatForm: document.getElementById("chat-form"),
  chatText: document.getElementById("chat-text"),
  chatSend: document.getElementById("chat-send"),
  chatRefresh: document.getElementById("chat-refresh"),
  chatStatus: document.getElementById("chat-status"),
  goals: document.getElementById("goals"),
  goalsRefresh: document.getElementById("goals-refresh"),
  goalForm: document.getElementById("goal-form"),
  goalObjective: document.getElementById("goal-objective"),
  goalCriterion: document.getElementById("goal-criterion"),
  goalsStatus: document.getElementById("goals-status"),
  usage: document.getElementById("usage"),
  usageRefresh: document.getElementById("usage-refresh"),
  tools: document.getElementById("tools"),
  toolFilter: document.getElementById("tool-filter"),
  toolsRefresh: document.getElementById("tools-refresh"),
  toolsStatus: document.getElementById("tools-status"),
  toolDetail: document.getElementById("tool-detail"),
  runSelect: document.getElementById("run-select"),
  runGraph: document.getElementById("run-graph"),
  runDetail: document.getElementById("run-detail"),
  sessionFilter: document.getElementById("session-filter"),
  sessionCompact: document.getElementById("session-compact"),
  sessionExport: document.getElementById("session-export"),
  sessionCopy: document.getElementById("session-copy"),
  runCopy: document.getElementById("run-copy"),
  board: document.getElementById("board"),
  boardEmpty: document.getElementById("board-empty"),
  cardForm: document.getElementById("card-form"),
  cardTitle: document.getElementById("card-title"),
  cardColumn: document.getElementById("card-column"),
  cardDetail: document.getElementById("card-detail"),
  boardMine: document.getElementById("board-mine"),
  boardRefresh: document.getElementById("board-refresh"),
  boardStatus: document.getElementById("board-status"),
  boardRoom: document.getElementById("board-room"),
  webuiPlugins: document.getElementById("webui-plugins"),
  webuiPluginsRefresh: document.getElementById("webui-plugins-refresh"),
  webuiPluginsStatus: document.getElementById("webui-plugins-status"),
  logSelect: document.getElementById("log-select"),
  logView: document.getElementById("log-view"),
  logsRefresh: document.getElementById("logs-refresh"),
  logsStatus: document.getElementById("logs-status"),
  palette: document.getElementById("palette"),
  paletteOpen: document.getElementById("palette-open"),
  paletteInput: document.getElementById("palette-input"),
  paletteList: document.getElementById("palette-list"),
  help: document.getElementById("help"),
  helpOpen: document.getElementById("help-open"),
  helpClose: document.getElementById("help-close"),
  shortcuts: document.getElementById("shortcuts"),
  transcriptEmpty: document.getElementById("transcript-empty"),
  suggestions: document.getElementById("suggestions"),
  modelSelect: document.getElementById("model-select"),
  paramTemp: document.getElementById("param-temp"),
  paramTopP: document.getElementById("param-topp"),
  enterSends: document.getElementById("enter-sends"),
  planMode: document.getElementById("plan-mode"),
  turnFilter: document.getElementById("turn-filter"),
  turnFilterCount: document.getElementById("turn-filter-count"),
  scrollBottom: document.getElementById("scroll-bottom"),
  sessionExportJson: document.getElementById("session-export-json"),
  textPrompt: document.getElementById("text-prompt"),
  textPromptForm: document.getElementById("text-prompt-form"),
  textPromptTitle: document.getElementById("text-prompt-title"),
  textPromptLabel: document.getElementById("text-prompt-label"),
  textPromptInput: document.getElementById("text-prompt-input"),
  textPromptOptions: document.getElementById("text-prompt-options"),
  textPromptHint: document.getElementById("text-prompt-hint"),
  textPromptCancel: document.getElementById("text-prompt-cancel")
};

/* ---------- components ----------

   One vocabulary for the whole sheet, built on VanJS. Every view below is
   written in these, so a control cannot drift into its own spelling of a
   button, a label or an empty state — which is how the page ended up with two
   Refresh behaviours and three status conventions before this existed.

   van.tags builds real DOM nodes and sets text as text, so nothing here can
   introduce markup from data. */

var T = van.tags;

/* State a view derives from. `bind` runs its render whenever the state
   changes and never on any other occasion, which is what removes the manual
   "clear the container and rebuild" that lost focus and half-typed edits. */
function bind(node, state, render) {
  van.derive(function () {
    var value = state.val;
    node.textContent = "";
    var built = render(value);
    if (built == null) return;
    if (Array.isArray(built)) built.forEach(function (n) { if (n) van.add(node, n); });
    else van.add(node, built);
  });
}

/* ---------- icons ----------

   Drawn, not typed. A star glyph and a multiplication sign were standing in
   for an icon system, which means they inherited the text face's weight and
   could not share a stroke with anything. These are one 24-grid, one 1.75
   stroke, square cap, and they take their colour from the text around them. */

var ICON_PATHS = {
  // A survey marker: the pin that says this layer matters.
  pin: ["M12 3.5v9", "M7.5 12.5h9l-1.5 3h-6z", "M12 15.5v5"],
  // Struck through: remove this entry.
  strike: ["M5.5 5.5l13 13", "M18.5 5.5l-13 13"],
  // A rule and tick: the depth column itself.
  log: ["M6 4v16", "M6 8h5", "M6 13h8", "M6 18h4"],
  // Loupe over the sheet.
  find: ["M11 4.5a6.5 6.5 0 100 13 6.5 6.5 0 000-13z", "M16 16l3.5 3.5"],
  // A sample vial: one recorded run.
  sample: ["M9.5 3.5h5", "M10.5 3.5v6L7 19a1.5 1.5 0 001.4 2h7.2a1.5 1.5 0 001.4-2l-3.5-9.5v-6"],
  // Two sheets: a copy.
  copy: ["M8.5 8.5h10v11h-10z", "M5.5 15.5v-11h10"],
  // A gate that held.
  held: ["M5 12.5l4.5 4.5L19 7.5"],
  // Deposited: an arrow settling onto the rule.
  deposit: ["M12 4v12", "M7.5 11.5L12 16l4.5-4.5", "M5 20h14"],
  // Disclosure, pointing at what it opens.
  chevron: ["M9 6l6 6-6 6"],
  // A question, drawn rather than typed.
  help: ["M9 9a3 3 0 114 2.8c-.8.4-1 1-1 1.7v.5", "M12 17.5v.01"]
};

function icon(name, size) {
  var paths = ICON_PATHS[name];
  if (!paths) return document.createElement("span");
  var ns = "http://www.w3.org/2000/svg";
  var svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", String(size || 16));
  svg.setAttribute("height", String(size || 16));
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.75");
  svg.setAttribute("stroke-linecap", "square");
  svg.setAttribute("stroke-linejoin", "miter");
  // Decorative in every use here: each icon sits beside or inside a control
  // that already carries its own accessible name.
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");
  svg.classList.add("icon");
  paths.forEach(function (d) {
    var path = document.createElementNS(ns, "path");
    path.setAttribute("d", d);
    svg.appendChild(path);
  });
  return svg;
}

var UI = {
  /* A button in the sheet's vocabulary. `kind` is "primary" for the one
     action a view exists for, "danger" for one that destroys, absent for the
     rest. */
  button: function (label, onclick, opts) {
    opts = opts || {};
    var cls = "secondary";
    if (opts.kind === "danger") cls += " danger";
    var attrs = {
      type: "button",
      class: opts.kind === "primary" ? "" : cls,
      onclick: onclick
    };
    if (opts.label) attrs["aria-label"] = opts.label;
    if (opts.title) attrs.title = opts.title;
    if (opts.icon) return T.button(attrs, icon(opts.icon, 14), label);
    return T.button(attrs, label);
  },

  /* A printed label above its field, the way the sheet labels every column. */
  field: function (id, label, control) {
    return [T.label({ for: id }, label), control];
  },

  /* Said in the product's own voice: what is absent, and what would put
     something here. Never an apology, never a shrug. */
  empty: function (text) {
    return T.p({ class: "run-empty" }, text);
  },

  /* A measurement. Mono, tabular, so a column of them lines up. */
  meta: function (text) {
    return T.span({ class: "meta" }, text);
  },

  /* A row of controls with one rhythm. */
  bar: function (children) {
    return T.div({ class: "toolbar-actions" }, children);
  },

  /* The heading a section is named by, with its controls on the same rule. */
  head: function (title, controls) {
    return T.div({ class: "section-head" }, T.h2(title), controls || null);
  }
};


/* Fetches a vendored library on first use and caches the promise, so the
   ~200 KB of d3-dag + highlight.js stays off the initial load of a page
   whose common visit needs neither. Every caller must tolerate rejection:
   the graph falls back to an error line, code blocks stay unhighlighted. */
var vendorLoads = {};
function loadVendor(file, ready) {
  if (vendorLoads[file]) return vendorLoads[file];
  vendorLoads[file] = ready() ? Promise.resolve() : new Promise(function (resolve, reject) {
    var s = document.createElement("script");
    s.src = "/webui/vendor/" + file;
    s.onload = function () {
      if (ready()) resolve();
      else reject(new Error(file + " loaded but exported nothing"));
    };
    s.onerror = function () { reject(new Error("could not load " + file)); };
    document.head.appendChild(s);
  });
  return vendorLoads[file];
}

function loadD3() {
  return loadVendor("d3-dag.min.js", function () { return !!(window.d3 && window.d3.dagStratify); });
}

var tomlRegistered = false;
function loadHljs() {
  return loadVendor("hljs.min.js", function () { return !!window.hljs; }).then(registerToml);
}

// highlight.js doesn't ship a TOML grammar in any of its distributed
// bundles (it lives in a separate, unpublished third-party repo) — a
// small hand-written one is simpler and more honest than pulling in a
// whole extra vendored file for one language. className values match the
// .hljs-* tokens already themed above (attr/string/number/literal/
// comment/meta), so no new CSS is needed.
function registerToml() {
  if (tomlRegistered) return;
  tomlRegistered = true;
  window.hljs.registerLanguage("toml", function (hljs) {
    return {
      name: "TOML",
      case_insensitive: false,
      contains: [
        hljs.COMMENT("#", "$"),
        { className: "section", begin: /^\s*\[+/, end: /\]+/ },
        { className: "attr", begin: /^\s*[A-Za-z0-9_.-]+(?=\s*=)/ },
        { className: "meta", begin: /\b\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?)?\b/ },
        { className: "literal", begin: /\b(true|false)\b/ },
        hljs.QUOTE_STRING_MODE,
        hljs.APOS_STRING_MODE,
        hljs.C_NUMBER_MODE
      ]
    };
  });
}

/* Motion the CSS can't reach: scrollIntoView's smooth behavior is a JS
   argument, so the @media blocks above never see it. */
var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
function scrollTo(node, block) {
  node.scrollIntoView({ block: block, behavior: reducedMotion.matches ? "auto" : "smooth" });
}

/* The async clipboard API is undefined outside a secure context, which is
   exactly what `clanker serve` is when reached over a LAN address rather
   than localhost. Failing silently there left a dead button, so the text
   gets selected instead and the label says what to press. */
/* The server explains itself — "sessions module disabled", "no such model for
   that provider", "an image exceeds the 4 MB limit" — and the page used to
   replace all of it with a status code, so a switched-off module read as a
   broken page. Every response goes through here. */
function readJson(r) {
  return r.json().then(function (d) {
    if (!r.ok) throw new Error((d && d.error) || "HTTP " + r.status);
    return d;
  }, function () {
    // A body that is not JSON at all still has to fail with something useful.
    if (!r.ok) throw new Error("HTTP " + r.status);
    return {};
  });
}

function copyText(text, btn, restoreLabel, selectTarget) {
  function restore() {
    window.setTimeout(function () { btn.textContent = restoreLabel; }, 1400);
  }
  function selectInstead() {
    var sel = window.getSelection && window.getSelection();
    if (selectTarget && sel && document.createRange) {
      var range = document.createRange();
      range.selectNodeContents(selectTarget);
      sel.removeAllRanges();
      sel.addRange(range);
      btn.textContent = "Selected — press Ctrl+C";
    } else {
      btn.textContent = "Copy unavailable";
    }
    restore();
  }
  if (!navigator.clipboard || !window.isSecureContext) return selectInstead();
  navigator.clipboard.writeText(text).then(function () {
    btn.textContent = "Copied";
    restore();
  }, selectInstead);
}

var busy = false;
var controller = null;
var elapsedTimer = null;
var sessionId = loadSession();

function newSessionId() {
  if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
  return "sess-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
}

function loadSession() {
  var id = null;
  try { id = window.localStorage.getItem("clanker.session"); } catch (e) {}
  if (!id) id = newSessionId();
  try { window.localStorage.setItem("clanker.session", id); } catch (e) {}
  return id;
}

function renderSessionChip() {
  el.sessionChip.textContent = "session " + sessionId.slice(0, 8);
}

var THEMES = ["system", "light", "dark"];

function loadTheme() {
  var t = null;
  try { t = window.localStorage.getItem("clanker.theme"); } catch (e) {}
  return THEMES.indexOf(t) === -1 ? "system" : t;
}

function applyTheme(theme) {
  if (theme === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", theme);
  el.themeToggle.textContent = "theme: " + theme;
}

var theme = loadTheme();
applyTheme(theme);

el.themeToggle.addEventListener("click", function () {
  theme = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length];
  try { window.localStorage.setItem("clanker.theme", theme); } catch (e) {}
  applyTheme(theme);
});

el.newChat.addEventListener("click", function () {
  if (busy) return;
  sessionId = newSessionId();
  try { window.localStorage.setItem("clanker.session", sessionId); } catch (e) {}
  el.transcript.textContent = "";
  // createTurn hides the empty state and nothing ever put it back, so after
  // one run plus New chat the area became the ambiguity the empty state was
  // written to remove.
  syncTranscriptEmpty();
  renderSessionChip();
  // The new conversation has no server-side record until its first turn is
  // saved, so it is offered as a pending option rather than waiting for a
  // reload to make it selectable.
  renderSessionOptions(knownSessions);
  el.sessionStatus.textContent = "Started a new conversation.";
  el.task.focus();
});

// ---- conversations: switch between saved sessions ----------------------

var knownSessions = [];

function fmtBytes(n) {
  if (n < 1024) return n + " B";
  if (n < 1024 * 1024) return Math.round(n / 1024) + " KB";
  return (n / (1024 * 1024)).toFixed(1) + " MB";
}

/* Shortening that ends on a word. Slicing at a fixed character cut names in
   half ("repl: write a markdow…"), which reads as a rendering fault rather
   than as a title too long to show. Falls back to the hard cut when a single
   word is longer than the budget. */
function clip(text, max) {
  if (text.length <= max) return text;
  var cut = text.slice(0, max);
  var space = cut.lastIndexOf(" ");
  return (space > max * 0.6 ? cut.slice(0, space) : cut).replace(/[\s,;:.\-]+$/, "") + "\u2026";
}

function sessionLabel(s) {
  var title = (s.title || "").replace(/\s+/g, " ").trim() || "(untitled)";
  title = clip(title, 56);
  var label = title + "  ·  " + s.messages + (s.messages === 1 ? " msg" : " msgs");
  // Transcript weight, because agent.compact_threshold_bytes is measured in
  // exactly these bytes and compaction is otherwise invisible until it fires.
  if (typeof s.bytes === "number" && s.bytes > 0) label += "  ·  " + fmtBytes(s.bytes);
  return label;
}

/* The live session is always selectable even when the server has never seen
   it — a brand new chat has no saved file until its first turn completes,
   and dropping it from the list would make the picker disagree with what the
   composer is actually continuing. */
/* Conversations group by when they were last touched, because that is how
   you look for one: "the thing I was doing this morning", not an id. */
function recencyGroup(updated) {
  if (!updated) return "Undated";
  var day = 24 * 60 * 60;
  var now = Math.floor(Date.now() / 1000);
  var age = now - updated;
  if (age < day && new Date(updated * 1000).toDateString() === new Date().toDateString()) return "Today";
  if (age < 2 * day) return "Yesterday";
  if (age < 7 * day) return "Previous 7 days";
  if (age < 30 * day) return "Previous 30 days";
  return "Older";
}


/* Pinning lives in this browser rather than on the server: which few
   conversations you keep to hand is a property of how you are working right
   now, not of the conversation. */
function loadPins() {
  try { return JSON.parse(window.localStorage.getItem("clanker.pins") || "[]"); } catch (e) { return []; }
}
var pins = loadPins();

function isPinned(id) { return pins.indexOf(id) !== -1; }

function togglePin(id) {
  var at = pins.indexOf(id);
  if (at === -1) pins.push(id); else pins.splice(at, 1);
  try { window.localStorage.setItem("clanker.pins", JSON.stringify(pins)); } catch (e) {}
  renderSessionOptions(null);
}

/* The conversation list derives from three things: what the server knows,
   what is pinned here, and what is typed in the filter. Nothing else can put
   a row on screen, which is what stops the rail and the transcript
   disagreeing about which conversation is open. */
var railState = van.state({ sessions: [], filter: "", pins: [], current: "" });

function renderSessionOptions(sessions) {
  if (sessions) knownSessions = sessions;
  railState.val = {
    sessions: knownSessions,
    filter: el.sessionFilter ? el.sessionFilter.value.trim().toLowerCase() : "",
    pins: pins.slice(),
    current: sessionId
  };
  renderSessionTitle();
}

function railRowFor(s, current) {
  var title = (s.title || "").replace(/\s+/g, " ").trim() || "(untitled)";
  var meta = s.messages + (s.messages === 1 ? " msg" : " msgs") +
    (typeof s.bytes === "number" && s.bytes > 0 ? "  ·  " + fmtBytes(s.bytes) : "");
  var open = s.id === current;

  var row = T.button({
    type: "button",
    class: "rail-item",
    onclick: function () { switchSession(s.id); closeRailOnNarrow(); }
  }, T.span({ class: "rail-item-title" }, title), T.span({ class: "rail-item-meta" }, meta));
  if (open) row.setAttribute("aria-current", "true");

  var pin = T.button({
    type: "button",
    class: "rail-pin",
    "data-on": String(isPinned(s.id)),
    "aria-label": (isPinned(s.id) ? "Unpin " : "Pin ") + title,
    "aria-pressed": String(isPinned(s.id)),
    onclick: function () { togglePin(s.id); }
  });
  van.add(pin, icon("pin", 15));

  return T.li({ class: "rail-row" }, row, pin);
}

/* Workspaces are folders: a conversation is in exactly one, and the unnamed
   one is where everything starts. Sorted with the default first, then by name,
   so the list does not reshuffle as folders are added. */
function workspacesOf(sessions) {
  var names = {};
  sessions.forEach(function (s) { names[s.workspace || ""] = true; });
  return Object.keys(names).sort(function (a, b) {
    if (a === b) return 0;
    if (a === "") return -1;
    if (b === "") return 1;
    return a < b ? -1 : 1;
  });
}

bind(el.railList, railState, function (s) {
  var out = [];
  var ordered = s.sessions.slice().sort(function (a, b) {
    var pa = isPinned(a.id) ? 1 : 0, pb = isPinned(b.id) ? 1 : 0;
    return pa === pb ? 0 : pb - pa;
  });
  var seen = ordered.some(function (item) { return item.id === s.current; });
  var shown = 0;

  var wsList = workspacesOf(ordered);
  wsList.forEach(function (ws) {
    var inWorkspace = ordered.filter(function (item) {
      if ((item.workspace || "") !== ws) return false;
      return !s.filter || sessionLabel(item).toLowerCase().indexOf(s.filter) !== -1;
    });
    // A folder with nothing to show under the current filter is not drawn:
    // an empty heading says a folder is empty when it is only filtered out.
    if (!inWorkspace.length) return;

    // The default folder needs no name when it is the only one there is.
    var onlyDefault = ws === "" && wsList.length === 1;
    if (!onlyDefault) {
      out.push(T.li({ class: "rail-workspace", role: "presentation" },
        ws === "" ? "Conversations" : ws,
        T.span({ class: "rail-workspace-count" }, String(inWorkspace.length))));
    }

    var lastGroup = "";
    inWorkspace.forEach(function (item) {
      var group = isPinned(item.id) ? "Pinned" : recencyGroup(item.updated);
      if (group !== lastGroup) {
        out.push(T.li({ class: "rail-group", role: "presentation" }, group));
        lastGroup = group;
      }
      var row = railRowFor(item, s.current);
      if (!onlyDefault) row.classList.add("rail-folder");
      out.push(row);
      shown += 1;
    });
  });

  /* A brand new chat has no file on disk until its first turn completes;
     without this row the rail shows nothing selected while the composer is
     plainly pointed at something. */
  if (!seen && !s.filter) {
    out.unshift(T.li({ class: "rail-row" },
      T.button({ type: "button", class: "rail-item", "aria-current": "true" },
        T.span({ class: "rail-item-title" }, "New conversation"),
        T.span({ class: "rail-item-meta" }, "unsaved"))));
  }
  if (!shown && s.filter) out.push(T.li({ class: "rail-empty" }, "No conversation matches."));
  return out;
});

function renderSessionTitle() {
  var meta = currentSessionMeta();
  el.sessionTitle.textContent = meta ? sessionLabel(meta) : "New conversation  ·  unsaved";
  renderContextMeter();
}

function setRailOpen(open) {
  el.rail.setAttribute("data-open", String(open));
  el.railScrim.setAttribute("data-open", String(open));
  el.railToggle.setAttribute("aria-expanded", String(open));
  if (open) el.sessionFilter.focus();
}

function closeRailOnNarrow() {
  if (window.matchMedia && window.matchMedia("(max-width: 60rem)").matches) setRailOpen(false);
}

el.railToggle.addEventListener("click", function () {
  setRailOpen(el.rail.getAttribute("data-open") !== "true");
});
el.railScrim.addEventListener("click", function () { setRailOpen(false); });

function railItems() {
  return Array.prototype.slice.call(el.railList.querySelectorAll(".rail-item"));
}

function moveRailFocus(from, step) {
  var items = railItems();
  if (!items.length) return;
  var at = items.indexOf(from);
  var next = at === -1 ? (step > 0 ? 0 : items.length - 1) : at + step;
  if (next < 0) {
    el.sessionFilter.focus();
    return;
  }
  if (next >= items.length) next = items.length - 1;
  items[next].focus();
}

el.railList.addEventListener("keydown", function (e) {
  var item = e.target.closest ? e.target.closest(".rail-item") : null;
  if (!item) return;
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    moveRailFocus(item, e.key === "ArrowDown" ? 1 : -1);
    return;
  }
  if (e.key === "Home" || e.key === "End") {
    e.preventDefault();
    var items = railItems();
    if (items.length) items[e.key === "Home" ? 0 : items.length - 1].focus();
  }
});

el.sessionFilter.addEventListener("keydown", function (e) {
  if (e.key !== "ArrowDown") return;
  e.preventDefault();
  var items = railItems();
  if (items.length) items[0].focus();
});

el.newChat.addEventListener("click", closeRailOnNarrow);

/* The transcript is either turns or a line saying there are none; it used to
   be turns or nothing at all, which looked identical to a failed load. */
function syncTranscriptEmpty() {
  el.transcriptEmpty.hidden = el.transcript.querySelector(".turn") !== null;
}

function loadSessions() {
  return fetch("/api/sessions")
    .then(readJson)
    .then(function (data) {
      renderSessionOptions(data.sessions || []);
    })
    .catch(function () {
      // Sessions may simply be disabled; the picker still has to describe
      // the conversation the composer is using.
      renderSessionOptions([]);
    });
}

/* Replays a saved conversation into the transcript. Reuses the same turn
   card the live stream builds, so history and a just-finished turn are the
   same object rather than two renderings of the same thing that drift. */
function renderSessionHistory(messages) {
  el.transcript.textContent = "";
  var pendingTurn = null;
  var lastTask = null;
  messages.forEach(function (m) {
    if (m.role === "user") {
      // A question with no reply before the next one: close it off rather
      // than letting the next answer attach to the wrong question.
      if (pendingTurn) markTurnUnanswered(pendingTurn);
      lastTask = m.content;
      pendingTurn = createTurn(m.content);
      return;
    }
    if (!pendingTurn) {
      lastTask = null;
      pendingTurn = createTurn("(question not in this transcript)");
      var head = pendingTurn.root.querySelector(".turn-you");
      head.setAttribute("data-orphan", "true");
      head.querySelector(".turn-author").textContent = "clanker  ·  ";
    }
    appendText(pendingTurn, m.content, false);
    finalizeAnswer(pendingTurn);
    // The task is passed back so Run again and Edit & resend survive a reload;
    // the numbers cannot, because they were never saved with the session.
    renderStats(pendingTurn, {}, lastTask);
    pendingTurn = null;
  });
  if (pendingTurn) markTurnUnanswered(pendingTurn);
}

/* Appends a note about the turn's outcome into the answer itself. Inside the
   answer rather than beside it for two reasons: an empty answer otherwise
   triggers the streaming placeholder (a pulsing ellipsis that says "still
   thinking" about a turn that finished long ago), and Copy answer reads
   `textContent`, so anything outside it is silently dropped from what the
   reader pastes. */
function markTurn(turn, text) {
  var note = document.createElement("span");
  note.className = "turn-note";
  note.textContent = text;
  turn.answer.appendChild(note);
}

function markTurnUnanswered(turn) {
  markTurn(turn, "No answer was recorded for this turn.");
}

function switchSession(id) {
  if (id === sessionId) return;
  if (busy) {
    // Refused mid-run, so put the control back on the conversation that is
    // actually still running rather than leaving it pointing at one the
    // composer is not using.
    renderSessionOptions(null);
    el.sessionStatus.textContent = "Finish or stop the current run before switching conversation.";
    return;
  }
  sessionId = id;
  try { window.localStorage.setItem("clanker.session", sessionId); } catch (e) {}
  renderSessionChip();
  renderSessionOptions(null);
  el.transcript.textContent = "";
  el.sessionStatus.textContent = "Loading conversation…";
  fetch("/api/sessions/" + encodeURIComponent(id))
    .then(readJson)
    .then(function (data) {
      renderSessionHistory(data.messages || []);
      syncTranscriptEmpty();
      var n = (data.messages || []).length;
      el.sessionStatus.textContent = "Loaded " + n + (n === 1 ? " message." : " messages.");
    })
    .catch(function (err) {
      var p = document.createElement("p");
      p.className = "run-empty";
      p.textContent = "Could not load that conversation: " + err.message;
      el.transcript.appendChild(p);
      el.sessionStatus.textContent = p.textContent;
    });
}



/* Workspaces are created by naming one: there is no separate "new folder"
   step, because a folder with nothing in it is not yet a folder. */
el.sessionMove.addEventListener("click", function () {
  var meta = currentSessionMeta();
  if (!meta) {
    el.sessionStatus.textContent = "This conversation has no saved turns yet.";
    return;
  }
  var existing = workspacesOf(knownSessions).filter(function (w) { return w !== ""; });
  var hint = existing.length ? "Pick an existing one or type a new name. Leave empty for the default." : "Leave empty for the default. This will be the first workspace.";
  textPrompt({
    title: "Move to workspace", label: "Workspace", value: meta.workspace || "",
    hint: hint, suggestions: existing
  }).then(function (next) {
    if (next === null) return;
    el.sessionMove.disabled = true;
    fetch("/api/sessions/" + encodeURIComponent(sessionId), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ workspace: next.trim() })
    })
      .then(readJson)
      .then(function () {
        el.sessionStatus.textContent = next.trim()
          ? "Moved to " + next.trim() + "."
          : "Moved to the default workspace.";
        return loadSessions();
      })
      .catch(function (err) { el.sessionStatus.textContent = "Move failed: " + err.message; })
      .then(function () { el.sessionMove.disabled = false; });
  });
});

/* A conversation's title is otherwise the first 60 characters of whatever
   task opened it, which makes a picker full of them read like a list of
   prefixes. Both actions refuse to touch a conversation that has never been
   saved, since there is nothing on disk to act on yet. */
function currentSessionMeta() {
  for (var i = 0; i < knownSessions.length; i++) {
    if (knownSessions[i].id === sessionId) return knownSessions[i];
  }
  return null;
}

/* A fork is a branch you can abandon: the same messages under a new id, so
   trying a different direction never costs the conversation it came from.
   The server answers with the new id and this switches to it, because the
   point of forking is to continue in the copy. */
el.sessionFork.addEventListener("click", function () {
  if (!currentSessionMeta()) {
    el.sessionStatus.textContent = "This conversation has no saved turns yet.";
    return;
  }
  el.sessionFork.disabled = true;
  fetch("/api/sessions/" + encodeURIComponent(sessionId) + "/fork", { method: "POST" })
    .then(function (r) {
      return r.json().then(function (data) {
        if (!r.ok || !data.ok || !data.id) throw new Error(data.error || ("HTTP " + r.status));
        return data.id;
      });
    })
    .then(function (newId) {
      sessionId = newId;
      try { window.localStorage.setItem("clanker.session", sessionId); } catch (e) {}
      renderSessionChip();
      el.sessionStatus.textContent = "Forked. You are now in the copy.";
      return loadSessions();
    })
    .catch(function (err) {
      el.sessionStatus.textContent = "Could not fork: " + err.message;
    })
    .finally(function () { el.sessionFork.disabled = false; });
});

el.sessionRename.addEventListener("click", function () {
  var meta = currentSessionMeta();
  if (!meta) {
    el.sessionStatus.textContent = "This conversation has no saved turns yet.";
    return;
  }
  textPrompt({ title: "Rename conversation", label: "Title", value: meta.title || "" }).then(function (next) {
    if (next === null) return;
    next = next.trim();
    if (!next) {
      el.sessionStatus.textContent = "A conversation needs a title.";
      return;
    }
    el.sessionRename.disabled = true;
    fetch("/api/sessions/" + encodeURIComponent(sessionId), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: next })
    }).then(readJson).then(function () {
      el.sessionStatus.textContent = "Renamed to " + next + ".";
      return loadSessions();
    }).catch(function (err) {
      el.sessionStatus.textContent = "Could not rename: " + err.message;
    }).finally(function () { el.sessionRename.disabled = false; });
  });
});

el.sessionDelete.addEventListener("click", function () {
  var meta = currentSessionMeta();
  if (!meta) {
    el.sessionStatus.textContent = "This conversation has no saved turns yet.";
    return;
  }
  // Deleting a transcript cannot be undone from here, so it is confirmed.
  // The run graphs survive it: they record runs that really happened and are
  // addressed by run id, not by session.
  if (!window.confirm("Delete \"" + (meta.title || sessionId) + "\"? Its recorded runs are kept.")) return;
  el.sessionDelete.disabled = true;
  fetch("/api/sessions/" + encodeURIComponent(sessionId), { method: "DELETE" })
    .then(readJson)
    .then(function () {
      el.sessionStatus.textContent = "Deleted. Started a new conversation.";
      sessionId = newSessionId();
      try { window.localStorage.setItem("clanker.session", sessionId); } catch (e) {}
      el.transcript.textContent = "";
      renderSessionChip();
      return loadSessions();
    }).catch(function (err) {
      el.sessionStatus.textContent = "Could not delete: " + err.message;
    }).finally(function () { el.sessionDelete.disabled = false; });
});

function syncControls() {
  el.submit.disabled = busy || el.task.value.trim() === "";
  el.refresh.disabled = busy;
  el.newChat.disabled = busy;
  el.task.readOnly = busy;
  el.cancel.hidden = !busy;
  if (busy) el.submit.textContent = "Running…";
  else syncSubmitLabel();
  document.title = busy ? "Running… · clanker" : "clanker";
}

function setBusy(next) {
  busy = next;
  syncControls();
}

function startElapsed(startedAt) {
  stopElapsed();
  elapsedTimer = window.setInterval(function () {
    el.hint.textContent = "running… " + ((Date.now() - startedAt) / 1000).toFixed(1) + "s";
  }, 200);
}

function stopElapsed() {
  if (elapsedTimer) { window.clearInterval(elapsedTimer); elapsedTimer = null; }
}

/* Each submitted task gets its own turn card, appended below the last —
   a real conversation history instead of one box that forgets the past
   answer as soon as you ask another question. */
function createTurn(task) {
  if (el.transcriptEmpty) el.transcriptEmpty.hidden = true;
  var turn = document.createElement("div");
  turn.className = "turn";

  // The stratum's index, set in the margin against the depth rule.
  var depth = document.createElement("span");
  depth.className = "turn-depth";
  depth.textContent = String(el.transcript.querySelectorAll(".turn").length + 1);
  depth.setAttribute("aria-hidden", "true");
  turn.appendChild(depth);

  var you = document.createElement("div");
  you.className = "turn-you";
  // Real text, not generated content: a name in ::before is not announced,
  // not selected, not copied and not exported.
  var author = document.createElement("span");
  author.className = "turn-author";
  author.textContent = "you  ·  ";
  you.appendChild(author);
  you.appendChild(document.createTextNode(task));

  var body = document.createElement("div");
  body.className = "turn-body";

  var events = document.createElement("div");
  events.className = "turn-events";

  var answer = document.createElement("div");
  answer.className = "turn-answer";
  // aria-live rather than role="status": status carries an implicit
  // aria-atomic="true", which made every streamed chunk re-announce the
  // whole answer from the top. Explicitly atomic-false announces only the
  // new text.
  answer.setAttribute("aria-live", "polite");
  answer.setAttribute("aria-atomic", "false");

  var foot = document.createElement("div");
  foot.className = "turn-foot";

  body.appendChild(events);
  body.appendChild(answer);
  body.appendChild(foot);
  turn.appendChild(you);
  turn.appendChild(body);
  el.transcript.appendChild(turn);

  return { root: turn, events: events, answer: answer, foot: foot };
}

function appendText(turn, text, failed) {
  /* The rendered answer is not the answer: finalizeAnswer replaces the
     source with elements, so the fences, hashes, hyphens and pipes are gone
     from textContent by the time anything reads it back. Copy answer handed
     over code with no fences and Export .md produced a file that was not
     markdown. The source is kept here instead of recovered later. */
  if (!failed) turn.root.markdownSource = (turn.root.markdownSource || "") + text;
  var caret = turn.answer.querySelector(".caret");
  // Content streams in a line at a time. Extending the trailing text node
  // keeps a long answer at one node instead of one per line, which across a
  // session's worth of turns is the difference between a flat DOM and one
  // that grows with every line the agent has ever written. Failed text is
  // excluded: it needs its own <span> to stay red.
  if (!failed) {
    var tail = caret ? caret.previousSibling : turn.answer.lastChild;
    if (tail && tail.nodeType === 3) {
      tail.appendData(text);
      return;
    }
  }
  var node = document.createTextNode(text);
  if (failed) {
    var span = document.createElement("span");
    span.className = "failed";
    span.appendChild(node);
    node = span;
  }
  if (caret) turn.answer.insertBefore(node, caret);
  else turn.answer.appendChild(node);
}

function showCaret(turn, on) {
  var caret = turn.answer.querySelector(".caret");
  if (on && !caret) {
    caret = document.createElement("span");
    caret.className = "caret";
    caret.setAttribute("aria-hidden", "true");
    turn.answer.appendChild(caret);
  } else if (!on && caret) {
    caret.remove();
  }
}

/* Once a turn finishes cleanly, promote ```fenced``` code inside the plain
   answer text into <pre> blocks with their own copy button — the common
   case for a coding agent's replies. Skipped for failed/stopped turns so
   the red [error] styling already in the DOM is never flattened back to
   plain text. */

/* ---------- markdown ----------
   Answers arrive as Markdown and used to render as one flat wall of
   monospace: headings, lists and tables were literal "##" and "|" characters.
   Everything below is built with createElement and textContent, never
   innerHTML, so markup a model writes lands as visible characters and is
   never parsed as markup. */

var INLINE_RE = /(`[^`]+`)|(!\[[^\]\n]*\]\([^)\s]+\))|(\*\*[^*]+\*\*)|(\*[^*\n]+\*)|(_[^_\n]+_)|(\[[^\]\n]+\]\([^)\s]+\))|(https?:\/\/[^\s<>()]+)/;

/* Answers are model output, and a prompt-injected tool result or RAG
   document can steer the model into emitting a markdown link or image whose
   target is a `javascript:` URL. Mirrors the scheme allowlist already used
   for peer URLs below: only a scheme that cannot execute script is ever
   assigned to href/src. */
function isSafeLinkUrl(url) {
  return /^(https?:|mailto:)/i.test(url);
}

function inlineInto(parent, text) {
  while (text.length) {
    var m = INLINE_RE.exec(text);
    if (!m) { parent.appendChild(document.createTextNode(text)); return; }
    if (m.index > 0) parent.appendChild(document.createTextNode(text.slice(0, m.index)));
    var tok = m[0], node;
    if (tok.charAt(0) === "`") {
      node = document.createElement("code");
      node.textContent = tok.slice(1, -1);
    } else if (tok.slice(0, 2) === "**") {
      node = document.createElement("strong");
      inlineInto(node, tok.slice(2, -2));
    } else if (tok.charAt(0) === "*" || tok.charAt(0) === "_") {
      var before = m.index > 0 ? text.charAt(m.index - 1) : " ";
      var after = text.charAt(m.index + tok.length) || " ";
      // Intra-word underscores are identifiers, not emphasis: snake_case
      // names in an answer used to render as italics with the underscores
      // eaten.
      if (tok.charAt(0) === "_" && (/[A-Za-z0-9]/.test(before) || /[A-Za-z0-9]/.test(after))) {
        parent.appendChild(document.createTextNode(tok));
        text = text.slice(m.index + tok.length);
        continue;
      }
      node = document.createElement("em");
      inlineInto(node, tok.slice(1, -1));
    } else if (tok.slice(0, 2) === "![") {
      // An image, not a link to one: the link branch below matched the second
      // half and left the "!" behind as text.
      var isplit = tok.indexOf("](");
      var isrc = tok.slice(isplit + 2, -1);
      if (isSafeLinkUrl(isrc)) {
        node = document.createElement("img");
        node.src = isrc;
        node.alt = tok.slice(2, isplit);
        node.className = "md-img";
        node.loading = "lazy";
      } else {
        node = document.createTextNode(tok);
      }
    } else if (tok.charAt(0) === "[") {
      var split = tok.indexOf("](");
      var href = tok.slice(split + 2, -1);
      if (isSafeLinkUrl(href)) {
        node = document.createElement("a");
        node.href = href;
        node.rel = "noreferrer noopener";
        inlineInto(node, tok.slice(1, split));
      } else {
        node = document.createDocumentFragment();
        inlineInto(node, tok.slice(1, split));
      }
    } else {
      node = document.createElement("a");
      node.href = tok;
      node.rel = "noreferrer noopener";
      node.textContent = tok;
    }
    parent.appendChild(node);
    text = text.slice(m.index + tok.length);
  }
}

/* A single newline inside a paragraph is kept as a line break rather than
   collapsed to a space: agent output leans on hard-wrapped lines, and
   joining them reflows tables of numbers into prose. */
function paragraphInto(parent, lines) {
  lines.forEach(function (line, i) {
    if (i) parent.appendChild(document.createElement("br"));
    inlineInto(parent, line);
  });
}

function tableRow(tr, cells, cellTag) {
  cells.forEach(function (c) {
    var cell = document.createElement(cellTag);
    inlineInto(cell, c.trim());
    tr.appendChild(cell);
  });
}

function splitRow(line) {
  var t = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  return t.split("|");
}

function renderMarkdown(text) {
  var frag = document.createDocumentFragment();
  var lines = text.split("\n");
  var i = 0;
  /* Indentation is structure: agent output leans on nested bullets, and
     flattening a plan into one level loses what depends on what. Each level
     recurses, so a sub-list becomes a list inside its parent's item. */
  function buildList(ordered, indent) {
    var list = document.createElement(ordered ? "ol" : "ul");
    var li = null;
    var first = true;
    while (i < lines.length) {
      var line = lines[i];
      var m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
      if (!m) break;
      var depth = m[1].length;
      if (depth < indent) break;
      if (depth > indent) {
        // Deeper than this list: it belongs to the item just added.
        var childOrdered = /\d/.test(m[2]);
        var child = buildList(childOrdered, depth);
        (li || list).appendChild(child);
        continue;
      }
      var isOrdered = /\d/.test(m[2]);
      if (isOrdered !== ordered) break;
      // Keep the author's numbering. An answer that numbers eight steps and
      // writes a paragraph under each one ends the list at every paragraph, so
      // each step became its own <ol> and every one of them rendered as "1.".
      // The marker the author wrote is the number the reader should see.
      if (first && ordered) {
        var startAt = parseInt(m[2], 10);
        if (startAt > 1) list.setAttribute("start", String(startAt));
      }
      first = false;
      li = document.createElement("li");
      var text = m[3];
      // A task list is a checklist, not two literal brackets.
      var task = /^\[([ xX])\]\s+(.*)$/.exec(text);
      if (task) {
        var box = document.createElement("input");
        box.type = "checkbox";
        box.checked = task[1] !== " ";
        box.disabled = true;
        li.className = "md-task";
        li.appendChild(box);
        text = task[2];
      }
      inlineInto(li, text);
      list.appendChild(li);
      i += 1;
    }
    return list;
  }

  function flushList(ordered) {
    var indent = /^(\s*)/.exec(lines[i])[1].length;
    frag.appendChild(buildList(ordered, indent));
  }
  while (i < lines.length) {
    var line = lines[i];
    if (!line.trim()) { i += 1; continue; }
    var head = /^(#{1,6})\s+(.*)$/.exec(line);
    if (head) {
      // Answers live under the page's own h2, so the smallest heading a
      // model writes still nests below it rather than competing with it.
      var h = document.createElement("h" + Math.min(6, head[1].length + 2));
      h.className = "md-h";
      inlineInto(h, head[2]);
      frag.appendChild(h);
      i += 1;
      continue;
    }
    if (/^\s*([-*_])\s*\1\s*\1[\s\-*_]*$/.test(line)) {
      frag.appendChild(document.createElement("hr"));
      i += 1;
      continue;
    }
    if (/^\s*>\s?/.test(line)) {
      var quote = document.createElement("blockquote");
      var qlines = [];
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
        qlines.push(lines[i].replace(/^\s*>\s?/, ""));
        i += 1;
      }
      paragraphInto(quote, qlines);
      frag.appendChild(quote);
      continue;
    }
    if (/^\s*[-*+]\s+/.test(line)) { flushList(false); continue; }
    if (/^\s*\d+[.)]\s+/.test(line)) { flushList(true); continue; }
    // A table needs its separator row to be a table at all, which keeps a
    // line that merely contains a pipe from becoming one.
    if (line.indexOf("|") !== -1 && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1])) {
      var table = document.createElement("table");
      table.className = "md-table";
      var thead = document.createElement("thead");
      var htr = document.createElement("tr");
      tableRow(htr, splitRow(line), "th");
      thead.appendChild(htr);
      table.appendChild(thead);
      var tbody = document.createElement("tbody");
      i += 2;
      while (i < lines.length && lines[i].indexOf("|") !== -1 && lines[i].trim()) {
        var btr = document.createElement("tr");
        tableRow(btr, splitRow(lines[i]), "td");
        tbody.appendChild(btr);
        i += 1;
      }
      table.appendChild(tbody);
      var wrap = document.createElement("div");
      wrap.className = "md-table-wrap";
      wrap.appendChild(table);
      frag.appendChild(wrap);
      continue;
    }
    var para = [];
    while (i < lines.length && lines[i].trim() &&
           !/^(#{1,6})\s|^\s*[-*+]\s|^\s*\d+[.)]\s|^\s*>/.test(lines[i])) {
      para.push(lines[i]);
      i += 1;
    }
    var p2 = document.createElement("p");
    p2.className = "md-p";
    paragraphInto(p2, para);
    frag.appendChild(p2);
  }
  return frag;
}

function finalizeAnswer(turn) {
  if (turn.answer.querySelector(".failed")) return;
  var raw = turn.root.markdownSource || turn.answer.textContent;
  if (!raw) return;
  var frag = document.createDocumentFragment();
  var re = /```([a-zA-Z0-9_+-]*)\n?([\s\S]*?)(?:```|$)/g;
  var last = 0, m;
  while ((m = re.exec(raw))) {
    // Zero-length match at the end of the string: nothing left to promote.
    if (m[0] === "") break;
    if (m.index > last) frag.appendChild(renderMarkdown(raw.slice(last, m.index)));
    frag.appendChild(buildCodeBlock(m[1], m[2].replace(/\n$/, "")));
    last = re.lastIndex;
  }
  if (last < raw.length) frag.appendChild(renderMarkdown(raw.slice(last)));
  turn.answer.textContent = "";
  // Block elements do their own wrapping; leaving the container on pre-wrap
  // would add the source's newlines on top of the markup's.
  turn.answer.className = "turn-answer md";
  turn.answer.appendChild(frag);
}

/* JSON-shaped text (a tool result, most often) is unreadable as one line
   and hljs has no way to know it's JSON without a fence's language tag.
   Only untagged text is tried against JSON.parse: reformatting a block the
   author explicitly fenced as something else overrides a stated intent, and
   bare `42` or `"a"` parses as JSON too. */
function prettyJsonIfPossible(text) {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch (e) {
    return null;
  }
}

/* Fills codeEl with the text to display and kicks off highlighting once
   hljs has loaded. Returns what it decided, because the language is needed
   for the label and cannot be read back off codeEl.className afterwards —
   hljs appends its own "hljs" class there. */
function highlightInto(codeEl, lang, rawText) {
  var pretty = lang ? null : prettyJsonIfPossible(rawText);
  var text = pretty !== null ? pretty : rawText;
  var effectiveLang = pretty !== null ? "json" : (lang || "");
  codeEl.textContent = text;
  if (effectiveLang) {
    codeEl.className = "language-" + effectiveLang;
    loadHljs().then(function () {
      try { window.hljs.highlightElement(codeEl); } catch (e) {}
    }).catch(function () {});
  }
  return { text: text, lang: effectiveLang };
}

function buildCodeBlock(lang, code) {
  var wrap = document.createElement("div");
  wrap.className = "code-block";

  var pre = document.createElement("pre");
  var codeEl = document.createElement("code");
  var shown = highlightInto(codeEl, lang, code);
  pre.appendChild(codeEl);

  var head = document.createElement("div");
  head.className = "code-head";
  var langTag = document.createElement("span");
  langTag.className = "code-lang";
  langTag.textContent = shown.lang;
  head.appendChild(langTag);

  var copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "copy-code-btn";
  copyBtn.textContent = "Copy";
  // Copies what's actually shown (prettified JSON, not the original
  // one-line source) — that's what a person just read and expects to paste.
  copyBtn.addEventListener("click", function () {
    copyText(shown.text, copyBtn, "Copy", codeEl);
  });
  head.appendChild(copyBtn);

  wrap.appendChild(head);
  wrap.appendChild(pre);
  return wrap;
}

function addToolEvent(turn, names) {
  var row = document.createElement("div");
  row.className = "event-tool";
  var spin = document.createElement("span");
  spin.className = "spin";
  spin.setAttribute("aria-hidden", "true");
  var label = document.createElement("span");
  // The spinner beside this already marks it as running; a gear glyph here
  // would be exactly the "glyph stands in for an icon" this sheet forbids.
  label.textContent = names;
  // Shown only under prefers-reduced-motion, where the spinner is hidden.
  var state = document.createElement("span");
  state.className = "run-state";
  state.textContent = "running…";
  row.appendChild(spin);
  row.appendChild(label);
  row.appendChild(state);
  turn.events.appendChild(row);
  return row;
}

/* A streaming run called ask_user: the server sent an `ask` control event
   and is now holding the run until POST /api/ask answers it or the server's
   ask timeout fires. One button per option, grouped and labelled with the
   question so focusing a button announces both. Focus moves to the first
   option because the run is blocked — there is nothing else on the page the
   user can usefully do first. */
function addAskEvent(turn, evt) {
  if (typeof evt.id !== "number" || !Array.isArray(evt.options)) return;
  var row = document.createElement("div");
  row.className = "event-ask";
  var q = document.createElement("div");
  q.className = "ask-question";
  q.textContent = evt.question || "";
  row.appendChild(q);
  var group = document.createElement("div");
  group.className = "ask-options";
  group.setAttribute("role", "group");
  group.setAttribute("aria-label", evt.question || "Choose an option");
  evt.options.forEach(function (opt) {
    if (typeof opt !== "string") return;
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "secondary";
    btn.textContent = opt;
    btn.addEventListener("click", function () { answerAsk(row, evt.id, opt); });
    group.appendChild(btn);
  });
  row.appendChild(group);
  turn.events.appendChild(row);
  var first = group.querySelector("button");
  if (first) first.focus();
}

/* Confirm-before-write (agent.confirm_writes): the run is holding a
   write-capable tool call and asks whether it may run. Same waiting row and
   the same POST /api/ask resolution as an ask event — the answer is one of
   the server's fixed options ("allow" / "deny") — plus a preview of the
   call's arguments, because "allow git?" is not a question anyone can answer
   without seeing what git was asked to do. On timeout the server denies. */
function addConfirmEvent(turn, evt) {
  if (typeof evt.id !== "number" || !Array.isArray(evt.options)) return;
  var row = document.createElement("div");
  row.className = "event-ask event-confirm";
  var q = document.createElement("div");
  q.className = "ask-question";
  q.textContent = "Allow this " + (evt.tool || "tool") + " call?";
  row.appendChild(q);
  if (evt.args_preview) {
    var pre = document.createElement("pre");
    pre.className = "confirm-preview";
    pre.textContent = evt.args_preview;
    row.appendChild(pre);
  }
  var group = document.createElement("div");
  group.className = "ask-options";
  group.setAttribute("role", "group");
  group.setAttribute("aria-label", q.textContent);
  evt.options.forEach(function (opt) {
    if (typeof opt !== "string") return;
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "secondary";
    btn.textContent = opt;
    btn.addEventListener("click", function () { answerAsk(row, evt.id, opt); });
    group.appendChild(btn);
  });
  row.appendChild(group);
  turn.events.appendChild(row);
  /* Focus the first option, i.e. "allow": the run is blocked on this row,
     same reasoning as addAskEvent. Enter is still a deliberate keypress. */
  var first = group.querySelector("button");
  if (first) first.focus();
}

function answerAsk(row, id, opt) {
  var buttons = row.querySelectorAll("button");
  for (var i = 0; i < buttons.length; i++) buttons[i].disabled = true;
  fetch("/api/ask", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: id, answer: opt })
  }).then(readJson).then(function () {
    settleAsk(row, opt, "chevron");
  }).catch(function (err) {
    // The run may have stopped waiting (timeout, or somebody else answered);
    // re-enabled buttons would pretend otherwise, so the row settles with
    // the refusal instead.
    settleAsk(row, "[" + (err && err.message ? err.message : "the run is no longer waiting for an answer") + "]");
  });
}

/* Answered or refused, the question is settled: the buttons go away and the
   outcome stays in the transcript where the question was. `iconName` marks
   which option was chosen with the drawn icon set, not a typed arrow. */
function settleAsk(row, text, iconName) {
  var group = row.querySelector(".ask-options");
  if (group) group.remove();
  var done = document.createElement("div");
  done.className = "ask-answered";
  if (iconName) done.appendChild(icon(iconName, 12));
  done.appendChild(document.createTextNode(text));
  row.appendChild(done);
}

function settleLastToolEvent(turn, ms) {
  var rows = turn.events.querySelectorAll(".event-tool");
  if (rows.length === 0) return;
  var row = rows[rows.length - 1];
  var spin = row.querySelector(".spin");
  if (spin) spin.remove();
  var state = row.querySelector(".run-state");
  if (state) state.remove();
  var dur = document.createElement("span");
  dur.className = "dur";
  dur.textContent = ms + "ms";
  row.appendChild(dur);
}

function renderStats(turn, stats, task) {
  turn.foot.textContent = "";

  /* Did this layer hold? A turn that produced an answer held; one that was
     stopped, errored or ended early did not. */
  var failed = turn.answer.querySelector(".failed") !== null ||
    turn.answer.textContent.indexOf("[stopped]") !== -1 ||
    turn.answer.textContent.indexOf("[the run ended before it finished]") !== -1;
  var held = document.createElement("span");
  held.className = "turn-held";
  held.setAttribute("data-held", String(!failed));
  held.appendChild(icon(failed ? "strike" : "held", 14));
  held.appendChild(document.createTextNode(failed ? "did not hold" : "held"));
  turn.foot.appendChild(held);
  var parts = [];
  if (typeof stats.prompt_tokens === "number" && typeof stats.completion_tokens === "number") {
    parts.push(fmtInt(stats.prompt_tokens) + " prompt + " + fmtInt(stats.completion_tokens) + " completion");
  }
  if (typeof stats.ms === "number") parts.push(fmtMs(stats.ms));
  if (typeof stats.cost === "number" && stats.cost > 0) parts.push("$" + stats.cost.toFixed(4));
  var span = document.createElement("span");
  span.textContent = parts.join(" · ");
  turn.foot.appendChild(span);

  var copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "secondary";
  copyBtn.textContent = "Copy answer";
  copyBtn.addEventListener("click", function () {
    copyText(turn.root.markdownSource || turn.answer.textContent, copyBtn, "Copy answer", turn.answer);
  });
  turn.foot.appendChild(copyBtn);

  /* A plan turn that held is a proposal awaiting a verdict: Apply runs it
     for real, in the same conversation so the plan is in context, with plan
     mode off so the harness stops refusing writes. Failed plans get the
     ordinary Run again / Edit & resend, not an Apply for half a plan. */
  if (turn.root.getAttribute("data-plan") === "true" && !failed) {
    var applyBtn = document.createElement("button");
    applyBtn.type = "button";
    applyBtn.textContent = "Apply plan";
    applyBtn.title = "Execute the proposed plan in this conversation";
    applyBtn.addEventListener("click", function () {
      if (busy) return;
      if (el.planMode) el.planMode.checked = false;
      el.task.value = "Apply the plan you proposed above, executing its steps now.";
      el.form.requestSubmit();
    });
    turn.foot.appendChild(applyBtn);
  }

  if (task) {
    var regenBtn = document.createElement("button");
    regenBtn.type = "button";
    regenBtn.className = "secondary";
    regenBtn.textContent = "Run again";
    regenBtn.title = "Resubmit this task as a new turn";
    regenBtn.addEventListener("click", function () {
      if (busy) return;
      el.task.value = task;
      el.form.requestSubmit();
    });
    turn.foot.appendChild(regenBtn);

    var editBtn = document.createElement("button");
    editBtn.type = "button";
    editBtn.className = "secondary";
    editBtn.textContent = "Edit & resend";
    editBtn.title = "Put this task back in the composer to change it";
    editBtn.addEventListener("click", function () {
      el.task.value = task;
      el.task.focus();
      el.task.setSelectionRange(task.length, task.length);
      syncControls();
      scrollTo(el.task, "center");
    });
    turn.foot.appendChild(editBtn);
  }
}

/* Streamed bytes are content by default; a line prefixed with 0x01 is an
   out-of-band event (tool started, tool finished, error, turn done) —
   see stream_event_prefix in the server. Buffering on "\n" means a
   control line split across two network chunks is never misread as
   content. */
function makeLineSplitter(onLine) {
  var buffer = "";
  return {
    push: function (chunk) {
      buffer += chunk;
      // A control event is introduced by \x01 and terminated by a newline,
      // but the answer text before it need not end in one. Without this the
      // two share a line, the \x01 test fails because it is not at index 0,
      // and the raw {"type":"done"} JSON lands in the answer while the
      // turn's stats never render. JSON escapes control characters, so a
      // literal \x01 only ever appears as this marker.
      buffer = buffer.replace(/([^\n])\u0001/g, "$1\n\u0001");
      var lines = buffer.split("\n");
      buffer = lines.pop();
      for (var i = 0; i < lines.length; i++) onLine(lines[i], true);
    },
    flush: function () {
      if (buffer) onLine(buffer, false);
      buffer = "";
    }
  };
}

function renderStatus(status) {
  if (!status) {
    el.instanceChip.textContent = "disconnected";
    el.instanceChip.dataset.state = "down";
    el.peersChip.hidden = true;
    el.instance.textContent = "unreachable (is `clanker serve` still running?)";
    el.peers.textContent = "unknown";
    return;
  }
  var peers = status.peers || [];
  // Chat needs both: the name to mark this instance's own messages and to
  // derive DM room names, the peer list to offer a DM per peer.
  instanceName = status.instance.name;
  knownPeers = peers;
  el.instanceChip.textContent = status.instance.name;
  el.instanceChip.dataset.state = "live";
  el.peersChip.hidden = peers.length === 0;
  el.peersChip.textContent = peers.length + (peers.length === 1 ? " peer" : " peers");
  el.instance.textContent = status.instance.name + " (" + status.instance.id + ")";

  el.peers.textContent = "";
  if (peers.length === 0) {
    el.peers.textContent = "none configured";
    return;
  }
  var list = document.createElement("ul");
  peers.forEach(function (p) {
    var item = document.createElement("li");
    var name = document.createElement("b");
    name.textContent = p.name;
    item.appendChild(name);
    item.appendChild(document.createTextNode(": "));
    /* Peer URLs come from config.json; only http(s) becomes a live link so a
       hand-edited javascript: URL cannot be clicked into execution. */
    if (/^https?:\/\//i.test(p.url)) {
      var link = document.createElement("a");
      link.href = p.url;
      link.textContent = p.url;
      item.appendChild(link);
    } else {
      item.appendChild(document.createTextNode(p.url));
    }
    list.appendChild(item);
  });
  el.peers.appendChild(list);
}

function loadStatus() {
  return fetch("/api/status")
    .then(readJson)
    .then(renderStatus)
    .catch(function () { renderStatus(null); });
}

// ---- image attachments -------------------------------------------------

/* The harness has been multimodal for a while — the agent loop attaches
   ImageParts — but the composer was a text box, so the one thing you most
   want to show an agent (a screenshot of the thing you are asking about)
   could not be sent. Encoded here and posted with the run. */
var pendingImages = [];
var max_image_bytes = 4 * 1024 * 1024;

function renderAttachments() {
  el.attachments.textContent = "";
  el.attachments.hidden = pendingImages.length === 0;
  pendingImages.forEach(function (img, i) {
    var wrap = document.createElement("div");
    wrap.className = "attachment";
    var thumb = document.createElement("img");
    thumb.src = "data:" + img.mime + ";base64," + img.b64;
    thumb.alt = "Attached image " + (i + 1) + ", " + fmtBytes(img.bytes);
    wrap.appendChild(thumb);
    var rm = document.createElement("button");
    rm.type = "button";
    rm.appendChild(icon("strike", 14));
    rm.setAttribute("aria-label", "Remove attached image " + (i + 1));
    rm.addEventListener("click", function () {
      pendingImages.splice(i, 1);
      renderAttachments();
      el.hint.textContent = "";
    });
    wrap.appendChild(rm);
    el.attachments.appendChild(wrap);
  });
}

function addImageFile(file) {
  if (!file) return;
  // Silence on a dropped PDF read as the drop having failed.
  if (file.type.indexOf("image/") !== 0) {
    el.sessionStatus.textContent = "Only images can be attached; " + (file.type || "that file") + " was ignored.";
    return;
  }
  var reader = new FileReader();
  reader.onload = function () {
    // Split on the comma: a data: URL is "data:<mime>;base64,<payload>" and
    // only the payload travels.
    var comma = String(reader.result).indexOf(",");
    if (comma === -1) return;
    var b64 = String(reader.result).slice(comma + 1);
    // The server enforces the same cap on the decoded size, so measure the
    // decoded size here rather than the base64 length, which is a third larger.
    var bytes = Math.floor(b64.length * 3 / 4);
    if (bytes > max_image_bytes) {
      // #hint belongs to the elapsed ticker, and three writers were clearing
      // each other there; a refused attachment is announced and shown instead.
      el.sessionStatus.textContent = "That image is " + fmtBytes(bytes) + "; the limit is " + fmtBytes(max_image_bytes) + ".";
      return;
    }
    pendingImages.push({ mime: file.type, b64: b64, bytes: bytes });
    renderAttachments();
    el.hint.textContent = pendingImages.length + (pendingImages.length === 1 ? " image attached." : " images attached.");
  };
  reader.readAsDataURL(file);
}

el.task.addEventListener("paste", function (e) {
  var items = (e.clipboardData && e.clipboardData.items) || [];
  for (var i = 0; i < items.length; i++) {
    if (items[i].kind === "file") addImageFile(items[i].getAsFile());
  }
});

["dragenter", "dragover"].forEach(function (evt) {
  el.form.addEventListener(evt, function (e) {
    if (!e.dataTransfer) return;
    e.preventDefault();
    el.form.classList.add("dragging");
  });
});
["dragleave", "drop"].forEach(function (evt) {
  el.form.addEventListener(evt, function () { el.form.classList.remove("dragging"); });
});
el.form.addEventListener("drop", function (e) {
  if (!e.dataTransfer || !e.dataTransfer.files) return;
  e.preventDefault();
  for (var i = 0; i < e.dataTransfer.files.length; i++) addImageFile(e.dataTransfer.files[i]);
});

el.task.addEventListener("input", syncControls);

el.task.addEventListener("keydown", function (e) {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    el.form.requestSubmit();
  }
});

el.refresh.addEventListener("click", function () {
  el.refresh.disabled = true;
  loadStatus().finally(function () { el.refresh.disabled = busy; });
});

el.cancel.addEventListener("click", function () {
  if (controller) controller.abort();
});

el.form.addEventListener("submit", function (e) {
  e.preventDefault();
  var task = el.task.value.trim();
  if (busy || task === "") return;

  var isPlan = el.planMode && el.planMode.checked;
  var turn = createTurn(task);
  if (isPlan) {
    /* The badge marks the proposal turn so renderStats can offer Apply, and
       so a reader scanning back knows this answer never touched anything. */
    turn.root.setAttribute("data-plan", "true");
    var planBadge = document.createElement("span");
    planBadge.className = "plan-badge";
    planBadge.textContent = "plan";
    turn.root.querySelector(".turn-you").appendChild(planBadge);
  }
  scrollTo(turn.root, "start");

  // Submit is about to be disabled. If it holds focus, focus would fall to
  // <body> and a keyboard user would have to tab the whole page to reach
  // Stop; hand it over deliberately instead.
  var handOffFocus = document.activeElement === el.submit;
  setBusy(true);
  if (handOffFocus) el.cancel.focus();
  el.hint.textContent = "";
  showCaret(turn, true);
  turn.root.setAttribute("data-live", "true");
  var startedAt = Date.now();
  startElapsed(startedAt);
  controller = new AbortController();

  var opts = runOptions();
  var statsRendered = false;
  var splitter = makeLineSplitter(function (line) {
    if (line.charCodeAt(0) === 1) {
      var evt;
      try { evt = JSON.parse(line.slice(1)); } catch (e) { return; }
      if (evt.type === "tool_call") addToolEvent(turn, evt.names);
      else if (evt.type === "tool_result") settleLastToolEvent(turn, evt.ms);
      else if (evt.type === "ask") addAskEvent(turn, evt);
      else if (evt.type === "confirm") addConfirmEvent(turn, evt);
      else if (evt.type === "error") appendText(turn, "\n[" + evt.message + "]\n", true);
      else if (evt.type === "done") {
        renderStats(turn, evt, task);
        statsRendered = true;
      }
      return;
    }
    var stick = nearBottom();
    appendText(turn, line + "\n", false);
    if (stick) window.scrollTo(0, document.body.scrollHeight);
    else syncScrollButton();
  });

  fetch("/api/run", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      task: task,
      stream: true,
      session: sessionId,
      images: pendingImages.map(function (i) { return { mime: i.mime, b64: i.b64 }; }),
      provider: opts.provider || "",
      model: opts.model || "",
      temperature: typeof opts.temperature === "number" ? opts.temperature : null,
      top_p: typeof opts.top_p === "number" ? opts.top_p : null,
      plan: isPlan
    }),
    signal: controller.signal
  }).then(function (resp) {
    if (!resp.ok || !resp.body) throw new Error("server responded HTTP " + resp.status);
    var reader = resp.body.getReader();
    var decoder = new TextDecoder();
    return (function pump() {
      return reader.read().then(function (chunk) {
        if (chunk.done) return;
        splitter.push(decoder.decode(chunk.value, { stream: true }));
        return pump();
      });
    })();
  }).then(function () {
    splitter.flush();
    finalizeAnswer(turn);
    /* The reader resolves whenever the body ends, whether or not the agent
       ever said it was done. A dropped connection, a killed server or a
       truncating proxy left a half-finished answer with no error, no marker
       and an empty stats row — and took the task text and every attached
       image with it, as though the run had succeeded. */
    if (!statsRendered) {
      markTurn(turn, "\n[the run ended before it finished]");
      el.sessionStatus.textContent = "The run ended before it finished; your task is still in the composer.";
      return;
    }
    el.task.value = "";
    // Attachments belong to the turn that just went out, not the next one.
    pendingImages = [];
    renderAttachments();
    // The turn just gave this session its title and a newer timestamp, and a
    // first turn created it server-side at all — so the picker is refreshed
    // rather than left describing the conversation as it was before.
    loadSessions();
  }).catch(function (err) {
    splitter.flush();
    if (err && err.name === "AbortError") {
      // Was a CSS ::after on a `stopped` class, which meant Copy answer
      // handed back a truncated answer with nothing saying it had been cut
      // short, and left the state to generated content that screen readers
      // expose inconsistently.
      markTurn(turn, "\n[stopped]");
    } else {
      appendText(turn, "\n[run failed: " + err.message + "]\n", true);
    }
  }).finally(function () {
    showCaret(turn, false);
    turn.root.removeAttribute("data-live");
    // A run that errored or was stopped never emits `done`, so the turn
    // would end with no way to copy what did arrive and no way to retry the
    // task that just failed — the two things most wanted after a failure.
    // renderStats omits any number it wasn't given, so an empty stats object
    // yields just the buttons.
    if (!statsRendered) renderStats(turn, {}, task);
    // A turn appended under an active filter showed regardless of whether it
    // matched, and the count line then contradicted the screen.
    if (el.turnFilter.value.trim()) applyTurnFilter();
    stopElapsed();
    el.hint.textContent = "";
    controller = null;
    // Stop is about to be hidden; take focus back to the composer rather
    // than letting it drop to <body>.
    var focusWasOnStop = document.activeElement === el.cancel;
    setBusy(false);
    if (focusWasOnStop) el.task.focus();
  });
});


// ---- runs: pick a recorded run, draw its execution graph ----------------

function runLabel(r) {
  var task = (r.task || "").replace(/\s+/g, " ").trim();
  task = clip(task, 60);
  return r.run_id + "  ·  " + (task || "(no task)");
}

var allRuns = [];
/* Set when something asks for one particular run before the Runs view has
   loaded its list. */
var pendingRunId = null;

/* Rebuilds the <select>'s actual option list from allRuns filtered by
   substring match on task text or run id — kept as a real native <select>
   (free keyboard nav, native mobile picker) rather than a custom dropdown;
   hiding <option>s with CSS isn't reliably respected by every browser's
   native combobox rendering, but replacing the option list outright always
   works. */
function renderRunOptions(filterText) {
  var q = (filterText || "").trim().toLowerCase();
  var matches = !q ? allRuns : allRuns.filter(function (r) {
    return (r.task || "").toLowerCase().indexOf(q) !== -1 || r.run_id.toLowerCase().indexOf(q) !== -1;
  });
  var previous = el.runSelect.value;
  el.runSelect.textContent = "";
  matches.forEach(function (r) {
    var opt = document.createElement("option");
    opt.value = r.run_id;
    opt.textContent = runLabel(r);
    el.runSelect.appendChild(opt);
  });
  if (!matches.length) {
    el.runSelect.disabled = true;
    el.runGraph.textContent = "";
    // The open node detail belongs to a run that is no longer listed or
    // drawn; leaving it up would attribute one run's output to whatever is
    // selected next.
    closeNodeDetail();
    var none = document.createElement("p");
    none.className = "run-empty";
    none.textContent = q ? "No recorded runs match “" + filterText.trim() + "”." : "No runs recorded yet. Run a task and it appears here.";
    el.runGraph.appendChild(none);
    announceRunMatches(q, 0);
    return null;
  }
  el.runSelect.disabled = false;
  var wanted = matches.some(function (r) { return r.run_id === previous; }) ? previous : matches[0].run_id;
  el.runSelect.value = wanted;
  announceRunMatches(q, matches.length);
  return wanted;
}

/* The filter's whole result — how many runs matched, which one is now shown —
   is conveyed by the option list and the graph redrawing, both silent. Says
   it out loud for anyone who can't see either. Left empty while unfiltered,
   so simply loading the page announces nothing. */
function announceRunMatches(query, count) {
  if (!query) {
    el.runStatus.textContent = "";
    return;
  }
  el.runStatus.textContent = count === 0
    ? "No runs match " + query + "."
    : count + (count === 1 ? " run matches " : " runs match ") + query + ". Showing the first.";
}

function loadRuns() {
  return fetch("/api/runs")
    .then(readJson)
    .then(function (runs) {
      allRuns = runs;
      // A run asked for by name wins over the filter's first match, which was
      // otherwise a race between two graph fetches on first open.
      if (pendingRunId) {
        var want = pendingRunId;
        pendingRunId = null;
        el.runFilter.value = "";
        renderRunOptions("");
        el.runSelect.value = want;
        return loadRun(want);
      }
      var wanted = renderRunOptions(el.runFilter.value);
      if (wanted) return loadRun(wanted);
    })
    .catch(function (err) {
      showRunsError("Could not load runs: " + err.message);
    });
}

/* Failures land in #run-graph, which is a plain group — nothing would say
   them out loud. Routed through the status region so a failed Refresh is
   not silence. */
function showRunsError(message) {
  el.runGraph.textContent = "";
  var p = document.createElement("p");
  p.className = "run-empty";
  p.textContent = message;
  el.runGraph.appendChild(p);
  el.runStatus.textContent = message;
}

/* One way to open a named run, whether the view has loaded yet or not. */
function openRun(id) {
  if (viewLoaded.runs) {
    showView("runs", true);
    el.runFilter.value = "";
    renderRunOptions("");
    el.runSelect.value = id;
    return loadRun(id);
  }
  pendingRunId = id;
  showView("runs", true);
  return null;
}

function loadRun(id) {
  return fetch("/api/runs/" + encodeURIComponent(id))
    .then(readJson)
    .then(drawRun)
    .catch(function (err) {
      showRunsError("Could not load that run: " + err.message);
    });
}

function metricsFor(n) {
  if (n.kind === "llm") {
    return n.prompt_tokens + "/" + n.completion_tokens + " tok · " + n.duration_ms + "ms";
  }
  if (n.kind === "tool") {
    return n.result_bytes + " B · " + n.duration_ms + "ms";
  }
  return "answer " + n.result_bytes + " B";
}

/* The run is a chain of iterations: one llm node decides, then zero or
   more tool nodes run (in parallel when the model asked for several at
   once), then the next llm node picks up from there — until an llm node
   decides it's done and a final node closes the run. Group the flat node
   list back into that shape so it can be drawn as boxes and arrows instead
   of a bar chart pretending to be a timeline. */
function buildStages(nodes) {
  var stages = [];
  var final = null;
  nodes.forEach(function (n) {
    if (n.kind === "llm") stages.push({ iteration: n.iteration, llm: n, tools: [] });
    else if (n.kind === "tool" && stages.length) stages[stages.length - 1].tools.push(n);
    else if (n.kind === "final") final = n;
  });
  return { stages: stages, final: final };
}

var lastGraph = null;
var lastBuilt = null;
var resizeTimer = null;
window.addEventListener("resize", function () {
  if (resizeTimer) window.clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(function () {
    if (lastGraph) drawRun(lastGraph);
  }, 150);
});

function drawRun(g) {
  // Redraws also happen on window resize (same run, new layout) — only
  // close the detail panel when the run itself actually changed, not on
  // every resize while someone's mid-read of a node's output.
  if (!lastGraph || lastGraph.run_id !== g.run_id) {
    el.runDetail.hidden = true;
    el.runDetail.textContent = "";
  }
  lastGraph = g;
  el.runGraph.textContent = "";
  var nodes = g.nodes || [];

  var head = document.createElement("p");
  head.className = "run-head";
  head.textContent = g.run_id + " · " + (g.provider || "?") + " · " + g.duration_ms + "ms · " +
    g.total_prompt_tokens + " prompt + " + g.total_completion_tokens + " completion tok\n" + (g.task || "");
  el.runGraph.appendChild(head);

  if (!nodes.length) {
    var empty = document.createElement("p");
    empty.className = "run-empty";
    empty.textContent = "This run recorded no nodes.";
    el.runGraph.appendChild(empty);
    return;
  }

  var built = buildStages(nodes);
  lastBuilt = built;
  // Duration bars are scaled against the slowest node, not the run total:
  // one long LLM call would otherwise flatten every tool call to an
  // invisible sliver.
  var slowest = nodes.reduce(function (m, n) {
    return n.kind === "final" ? m : Math.max(m, n.duration_ms || 0);
  }, 0) || 1;

  // The SVG arrows that show branching/convergence are aria-hidden (each
  // node's own aria-label already covers its kind/name/metrics); without
  // this, a screen-reader user gets a flat list of nodes with no sense of
  // which tool calls ran in parallel or what fed into what.
  var summary = document.createElement("p");
  summary.className = "sr-only";
  summary.textContent = graphSummaryText(built);
  el.runGraph.appendChild(summary);

  var canvas = document.createElement("div");
  canvas.className = "run-canvas";
  // Focusable so a graph wider than the viewport can be scrolled with arrow
  // keys even when it holds nothing focusable (a run that recorded only the
  // "did not finish" marker); node boxes are buttons and reachable on their
  // own.
  canvas.tabIndex = 0;
  canvas.setAttribute("aria-label", "Scrollable execution graph diagram");
  el.runGraph.appendChild(canvas);

  // d3-dag is fetched on demand, so the first graph of a session draws one
  // network round-trip later than the rest of the page.
  loadD3().then(function () {
    // A newer run may have been requested while the library was in flight.
    if (canvas.isConnected) layoutGraph(canvas, built, slowest);
  }).catch(function (err) {
    var errEl = document.createElement("p");
    errEl.className = "run-empty";
    errEl.textContent = "Could not load the graph layout library: " + err.message;
    canvas.appendChild(errEl);
    el.runStatus.textContent = errEl.textContent;
  });
}

function graphSummaryText(built) {
  var parts = ["Execution graph:"];
  built.stages.forEach(function (stage) {
    var seg = "iteration " + stage.iteration + " called the model";
    if (stage.tools.length === 1) {
      seg += ", then ran 1 tool (" + stage.tools[0].label + ")";
    } else if (stage.tools.length > 1) {
      seg += ", then ran " + stage.tools.length + " tools in parallel (" +
        stage.tools.map(function (t) { return t.label; }).join(", ") + ")";
    }
    parts.push(seg + ".");
  });
  parts.push(built.final ? "The run ended with a final answer." : "The run ended without a final answer.");
  return parts.join(" ");
}

/* Turns the stage list into d3-dag's flat {id, parentIds} input: each llm
   node's parents are whatever fed it (the previous llm directly, or that
   iteration's tool cluster), each tool's parent is its iteration's llm,
   and a synthetic "incomplete" node closes off a run that ended without a
   final node (hit the iteration cap or the token budget) instead of
   leaving the chain dangling with no visible outcome. */
function toDagInput(built) {
  var data = [];
  var parents = [];
  built.stages.forEach(function (stage) {
    var llmId = "n" + data.length;
    data.push({ id: llmId, parentIds: parents, kind: "llm", node: stage.llm, iteration: stage.iteration });
    if (stage.tools.length) {
      parents = stage.tools.map(function (tn) {
        var tid = "n" + data.length;
        data.push({ id: tid, parentIds: [llmId], kind: "tool", node: tn });
        return tid;
      });
    } else {
      parents = [llmId];
    }
  });
  if (data.length) {
    data.push(built.final
      ? { id: "n" + data.length, parentIds: parents, kind: "final", node: built.final }
      : { id: "n" + data.length, parentIds: parents, kind: "incomplete", node: null });
  }
  return data;
}

/* Lays the DAG out with d3-dag's Sugiyama layered algorithm (proper
   crossing minimization instead of hand-rolled fan-out math — this is the
   same layered-graph technique tools like dagre/Airflow's DAG view use)
   and draws the result as accessible DOM boxes with an SVG arrow layer
   behind them. A layer wider than the viewport scrolls horizontally
   inside .run-canvas rather than wrapping or shrinking nodes. */
function layoutGraph(canvas, built, slowest) {
  var nodeW = 152, hGap = 32, vGap = 48, pad = 14;
  // The iteration-number tag hangs left of each llm node's own box (see
  // .run-iter-tag placement below), so the left edge needs extra room or
  // it clips into an unnecessary scrollbar.
  var tagPad = 42;
  var containerW = canvas.clientWidth || el.runGraph.clientWidth || 320;

  var data = toDagInput(built);
  if (!data.length) return;

  /* Build every box first and measure it. A box's height depends on its
     kind (a final node has no duration bar) and on whether its metrics line
     wraps, so it ranges from roughly 60 to 90px. The layout used to assume
     one constant instead, which put consecutive layers on top of each other
     and left every arrowhead buried under the box it pointed at. */
  data.forEach(function (d) {
    d.el = d.kind === "incomplete" ? buildIncompleteNode(nodeW) : buildNodeBox(d, slowest, nodeW);
    d.el.style.visibility = "hidden";
    canvas.appendChild(d.el);
  });
  var nodeH = 0;
  data.forEach(function (d) {
    d.h = d.el.offsetHeight;
    nodeH = Math.max(nodeH, d.h);
  });

  var dag;
  try {
    dag = window.d3.dagStratify()(data);
  } catch (e) {
    canvas.textContent = "";
    var errEl = document.createElement("p");
    errEl.className = "run-empty";
    errEl.textContent = "Could not lay out this run's graph: " + e.message;
    canvas.appendChild(errEl);
    el.runStatus.textContent = errEl.textContent;
    return;
  }
  // The tallest box sets the layer pitch, so no pair of layers can collide
  // however the shorter boxes in between are sized.
  window.d3.sugiyama().nodeSize([nodeW + hGap, nodeH + vGap])(dag);

  var xs = [], ys = [];
  for (var dn0 of dag.idescendants()) { xs.push(dn0.x); ys.push(dn0.y); }
  var minX = Math.min.apply(null, xs), maxX = Math.max.apply(null, xs);
  var minY = Math.min.apply(null, ys), maxY = Math.max.apply(null, ys);
  var graphW = maxX - minX + nodeW;
  var graphH = maxY - minY + nodeH;
  // Left-aligned, not centred. A run is usually a single chain, so centring it
  // parked a narrow column in the middle of a wide canvas with empty space on
  // both sides — the only block on the page that did not start where every
  // other block starts.
  var offsetX = pad + tagPad + nodeW / 2 - minX;
  var offsetY = pad + nodeH / 2 - minY;

  var totalW = Math.max(containerW, graphW + pad * 2 + tagPad);
  var totalH = graphH + pad * 2;
  canvas.style.height = totalH + "px";
  // No canvas.style.minWidth here on purpose: absolutely-positioned nodes
  // and the SVG edge layer (sized to totalW) create scrollable overflow
  // inside .run-canvas on their own once they exceed its box. Forcing the
  // box itself to totalW via min-width would make the *page* that wide
  // instead of scrolling inside this container.

  var svgNS = "http://www.w3.org/2000/svg";
  var svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("class", "run-edges");
  svg.setAttribute("width", totalW);
  svg.setAttribute("height", totalH);
  svg.setAttribute("aria-hidden", "true");

  var defs = document.createElementNS(svgNS, "defs");
  var marker = document.createElementNS(svgNS, "marker");
  marker.setAttribute("id", "run-arrow");
  marker.setAttribute("viewBox", "0 0 8 8");
  marker.setAttribute("refX", "7");
  marker.setAttribute("refY", "4");
  marker.setAttribute("markerWidth", "6");
  marker.setAttribute("markerHeight", "6");
  marker.setAttribute("orient", "auto-start-reverse");
  var arrowPath = document.createElementNS(svgNS, "path");
  arrowPath.setAttribute("d", "M0,0 L8,4 L0,8 z");
  arrowPath.setAttribute("fill", "var(--border)");
  marker.appendChild(arrowPath);
  defs.appendChild(marker);
  svg.appendChild(defs);

  /* Sugiyama hands back centre-to-centre polylines. Drawing them as-is put
     the arrowhead inside the opaque target box, so no arrow was ever
     visible: clip the ends back to each box's edge instead. */
  for (var link of dag.ilinks()) {
    var pts = link.points.map(function (p) { return [p.x + offsetX, p.y + offsetY]; });
    pts[0][1] = link.source.y + offsetY + link.source.data.h / 2;
    pts[pts.length - 1][1] = link.target.y + offsetY - link.target.data.h / 2 - 3;
    var d = "M" + pts[0][0] + "," + pts[0][1];
    for (var pi = 1; pi < pts.length; pi++) d += " L" + pts[pi][0] + "," + pts[pi][1];
    var path = document.createElementNS(svgNS, "path");
    path.setAttribute("d", d);
    path.setAttribute("marker-end", "url(#run-arrow)");
    svg.appendChild(path);
  }
  // Behind the boxes, which are already in the canvas from the measuring pass.
  canvas.insertBefore(svg, canvas.firstChild);

  for (var dn of dag.idescendants()) {
    var cx = dn.x + offsetX, cy = dn.y + offsetY;
    let kind = dn.data.kind, node = dn.data.node, box = dn.data.el;

    // Each box is centred on its own height, not on a shared constant.
    box.style.left = (cx - nodeW / 2) + "px";
    box.style.top = (cy - dn.data.h / 2) + "px";
    box.style.visibility = "";

    if (kind === "incomplete") continue;

    if (kind === "llm") {
      var tag = document.createElement("span");
      tag.className = "run-iter-tag";
      tag.textContent = dn.data.iteration;
      tag.style.left = (cx - nodeW / 2 - 20) + "px";
      tag.style.top = (cy - 11) + "px";
      tag.setAttribute("aria-hidden", "true");
      canvas.appendChild(tag);
    }

    box.addEventListener("click", function () {
      el.runGraph.querySelectorAll(".run-node.selected").forEach(function (n) { n.classList.remove("selected"); });
      box.classList.add("selected");
      showNodeDetail(kind, node);
    });
  }
}

function buildIncompleteNode(nodeW) {
  var stop = document.createElement("div");
  stop.className = "run-node-incomplete";
  stop.style.width = nodeW + "px";
  stop.textContent = "did not finish";
  // Real text, not aria-label: this is a plain <div> with no role, where
  // aria-label is ignored by most screen readers — so the reason, the only
  // place the *why* is stated, never reached assistive tech at all.
  var why = document.createElement("span");
  why.className = "sr-only";
  why.textContent = " — the run ended without a final answer, most likely hitting the iteration limit or the token budget.";
  stop.appendChild(why);
  return stop;
}

function buildNodeBox(d, slowest, nodeW) {
  var kind = d.kind, node = d.node;
  var box = document.createElement("button");
  box.type = "button";
  box.className = "run-node";
  box.dataset.kind = kind;
  if (node.ok === false) box.dataset.ok = "false";
  box.style.width = nodeW + "px";

  var kindEl = document.createElement("span");
  kindEl.className = "run-node-kind";
  kindEl.textContent = "";
  if (node.ok === false) kindEl.appendChild(icon("strike", 12));
  kindEl.appendChild(document.createTextNode(kind));
  box.appendChild(kindEl);

  var label = document.createElement("span");
  label.className = "run-node-label";
  label.textContent = node.label || node.detail || kind;
  // The box ellipsises a long tool name; without this only a screen-reader
  // user (via aria-label below) could find out what it was.
  label.title = label.textContent;
  box.appendChild(label);

  var metrics = document.createElement("span");
  metrics.className = "run-node-metrics";
  metrics.textContent = metricsFor(node);
  box.appendChild(metrics);

  if (kind !== "final") {
    var bar = document.createElement("span");
    bar.className = "run-node-bar";
    var barFill = document.createElement("span");
    barFill.style.width = Math.max(2, Math.round((node.duration_ms || 0) / slowest * 100)) + "%";
    bar.appendChild(barFill);
    box.appendChild(bar);
  }

  // The bar and the strike mark are decorative; the label already carries
  // kind, name, and every number a screen reader needs.
  box.setAttribute("aria-label", (node.ok === false ? "failed " : "") + kind + " " + (node.label || "") + ", " + metricsFor(node) + ". Activate to read its recorded output.");
  return box;
}

/* A collapsible tree for JSON-shaped node output — most tool results are
   JSON, and a flat highlighted blob makes a large payload (a big file
   listing, a nested API response) a wall of text with no way to collapse
   the part you don't care about. <details>/<summary> gives keyboard
   toggle and correct semantics for free, no custom ARIA needed. */
function buildJsonTree(value, keyLabel, depth) {
  if (value === null) return jsonLeaf(keyLabel, "null", "hljs-literal");
  if (typeof value === "boolean") return jsonLeaf(keyLabel, String(value), "hljs-literal");
  if (typeof value === "number") return jsonLeaf(keyLabel, String(value), "hljs-number");
  if (typeof value === "string") return jsonLeaf(keyLabel, JSON.stringify(value), "hljs-string");
  if (Array.isArray(value)) {
    var items = value.map(function (v, i) { return [String(i), v]; });
    return jsonBranch(keyLabel, items, "[", "]", items.length + (items.length === 1 ? " item" : " items"), depth);
  }
  var entries = Object.keys(value).map(function (k) { return [k, value[k]]; });
  return jsonBranch(keyLabel, entries, "{", "}", entries.length + (entries.length === 1 ? " key" : " keys"), depth);
}

function jsonLeaf(keyLabel, text, valueClass) {
  var row = document.createElement("div");
  // .json-row's ::before reserves the same width as a branch's disclosure
  // triangle, so a leaf key and a branch key at one level start at the same
  // x. Without it the left edge jitters by 1em with no relation to nesting,
  // which is the one thing a tree's left edge is supposed to encode.
  row.className = "json-row";
  if (keyLabel !== null) {
    var k = document.createElement("span");
    k.className = "json-key";
    k.textContent = keyLabel + ": ";
    row.appendChild(k);
  }
  var v = document.createElement("span");
  v.className = valueClass;
  v.textContent = text;
  row.appendChild(v);
  return row;
}

function jsonBranch(keyLabel, entries, open, close, countLabel, depth) {
  if (!entries.length) return jsonLeaf(keyLabel, open + close, "json-empty");
  var details = document.createElement("details");
  details.className = "json-node";
  // Root and its immediate children open, everything below collapsed: a tree
  // that arrives fully expanded is the wall of text it was built to replace.
  // A closed branch still says what it holds ("{ 3 keys }"), so nothing is
  // hidden that the reader can't see they are choosing not to open.
  details.open = depth < 1;
  var summary = document.createElement("summary");
  if (keyLabel !== null) {
    var k = document.createElement("span");
    k.className = "json-key";
    k.textContent = keyLabel + ": ";
    summary.appendChild(k);
  }
  var brace = document.createElement("span");
  brace.className = "json-brace";
  brace.textContent = open + " " + countLabel + " " + close;
  summary.appendChild(brace);
  details.appendChild(summary);
  var body = document.createElement("div");
  body.className = "json-children";
  entries.forEach(function (pair) { body.appendChild(buildJsonTree(pair[1], pair[0], depth + 1)); });
  details.appendChild(body);
  return details;
}

/* Populates the persistent detail panel below the graph with whatever a
   clicked node recorded: not just its size, but the actual truncated tool
   result or model output (graph.zig's Node.output; earlier versions of
   recorded runs won't have it, hence the empty-state in the CSS). */
function showNodeDetail(kind, node) {
  el.runDetail.textContent = "";
  el.runDetail.hidden = false;

  var head = document.createElement("div");
  head.className = "run-detail-head";

  var titleWrap = document.createElement("span");
  var title = document.createElement("span");
  title.className = "run-detail-title";
  title.textContent = "";
  if (node.ok === false) title.appendChild(icon("strike", 12));
  title.appendChild(document.createTextNode(kind + " · " + (node.label || node.detail || kind)));
  titleWrap.appendChild(title);
  var meta = document.createElement("span");
  meta.className = "run-detail-meta";
  meta.textContent = "  " + metricsFor(node) + (node.detail ? "  ·  " + node.detail : "");
  titleWrap.appendChild(meta);
  head.appendChild(titleWrap);

  var closeBtn = document.createElement("button");
  closeBtn.type = "button";
  closeBtn.className = "secondary run-detail-close";
  closeBtn.textContent = "Close";
  closeBtn.addEventListener("click", closeNodeDetail);
  head.appendChild(closeBtn);

  el.runDetail.appendChild(head);

  /* The server records only the first `output_preview_cap` bytes of a node's
     result (graph.zig), and a JSON document cut mid-structure no longer
     parses — so the tree below silently never appears for exactly the large
     payloads it exists to make readable. Saying so beats letting the view
     quietly degrade into a wall of text with no explanation.

     Derived rather than flagged by the server: `result_bytes` is the full
     byte length and `output` is the capped preview, so comparing them is
     exact. Both sides are byte counts, so multi-byte content cannot fake it
     the way comparing against a UTF-16 string length would. */
  var shownBytes = node.output ? new TextEncoder().encode(node.output).length : 0;
  var truncated = typeof node.result_bytes === "number" && node.result_bytes > shownBytes;
  if (truncated) {
    var note = document.createElement("p");
    note.className = "run-detail-note";
    note.textContent = "Showing the first " + shownBytes + " of " + node.result_bytes +
      " bytes — the rest was not recorded, so this is raw text rather than a parsed tree.";
    el.runDetail.appendChild(note);
  }

  // A div, not a <pre>: the JSON-tree branch fills this with interactive
  // <details> elements, and <pre> implies preformatted text content, not a
  // widget tree. .run-detail-output already sets white-space: pre-wrap
  // itself, so nothing about the flat-text case depends on the tag.
  var out = document.createElement("div");
  out.className = "run-detail-output";
  // Left truly empty (no child) when there's nothing recorded, so the
  // :empty CSS placeholder still fires.
  if (node.output) {
    var parsed;
    // Not attempted on a truncated preview: it cannot parse, and the note
    // above has already explained why the tree is missing.
    if (!truncated) {
      try { parsed = JSON.parse(node.output); } catch (e) { parsed = undefined; }
    }
    if (parsed !== undefined && typeof parsed === "object" && parsed !== null) {
      var tree = document.createElement("div");
      tree.className = "json-tree";
      tree.appendChild(buildJsonTree(parsed, null, 0));
      out.appendChild(tree);
    } else {
      var outCode = document.createElement("code");
      highlightInto(outCode, null, node.output);
      out.appendChild(outCode);
    }
  }
  el.runDetail.appendChild(out);

  scrollTo(el.runDetail, "nearest");
  // Without this, focus stays on the node button that was just activated;
  // a keyboard user tabbing onward would walk through every remaining
  // node in the graph before ever reaching this panel's Close button,
  // instead of landing on the thing that just appeared.
  closeBtn.focus();
}

/* Hides the panel and clears the graph's selection. Shared by the Close
   button and by anything that removes the run the panel is describing. */
function closeNodeDetail() {
  el.runDetail.hidden = true;
  el.runDetail.textContent = "";
  el.runGraph.querySelectorAll(".run-node.selected").forEach(function (n) { n.classList.remove("selected"); });
}

el.runSelect.addEventListener("change", function () {
  loadRun(el.runSelect.value);
});

var runFilterTimer = null;
el.runFilter.addEventListener("input", function () {
  if (runFilterTimer) window.clearTimeout(runFilterTimer);
  runFilterTimer = window.setTimeout(function () {
    var wanted = renderRunOptions(el.runFilter.value);
    // Narrowing a filter usually leaves the same run on top. Refetching and
    // relaying out the graph it is already showing costs a round trip and a
    // full remeasure of every node box for no visible change.
    if (wanted && (!lastGraph || lastGraph.run_id !== wanted)) loadRun(wanted);
  }, 120);
});

el.runsRefresh.addEventListener("click", function () {
  el.runsRefresh.disabled = true;
  loadRuns().finally(function () { el.runsRefresh.disabled = false; });
});

// ---- chat: shared rooms and direct messages between clankers -----------

/* A direct message is a room, not a second mechanism: both sides derive the
   same name from the two instance names sorted, so `dm:a|b` is the same
   channel whichever end opens it. That means DMs inherit the whole existing
   room pipeline — history, subscription, the agent's inbox — for free. */
function dmRoom(a, b) {
  return "dm:" + [dmSafeName(a), dmSafeName(b)].sort().join("|");
}

/* `|` separates the two halves of the room name, so a name containing one
   would split into three parts and make each side read the wrong partner
   out of it. Instance names are free-form config, so this is reachable. */
function dmSafeName(name) {
  return String(name).replace(/\|/g, "-");
}

/* Whichever half is not this instance. Written as "the part that isn't me"
   rather than an index so a malformed room name degrades to showing
   something plausible instead of `undefined`. */
function dmPartner(room) {
  var parts = room.slice("dm:".length).split("|");
  var mine = dmSafeName(instanceName);
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] !== mine) return parts[i];
  }
  return parts[parts.length - 1] || room;
}

function isDm(room) {
  return room.indexOf("dm:") === 0;
}

var instanceName = "";
var knownPeers = [];
var subscribedRooms = [];
var chatPoll = null;
var chatLastTs = 0;
var chatSeen = {};
var chatSeenOrder = [];
var chat_seen_cap = 500;
// Mirrors chatrooms.max_text_len in the server.
var chat_max_bytes = 4096;
var chat_poll_base_ms = 5000;
var chat_poll_max_ms = 60000;
var chatBackoff = chat_poll_base_ms;
var chatFailing = false;

function chatRoomLabel(r) {
  if (!isDm(r.room)) return "# " + r.room;
  var who = dmPartner(r.room);
  return clankerMark(who) + " " + who;
}

/* Rooms the server knows about, plus a DM entry per configured peer even
   when that conversation has no messages yet — otherwise the only way to
   start a DM would be to have already started one. */
/* The room picker derives from the rooms the server knows plus the peers this
   instance could open a DM with. It returns the room that ends up selected,
   because the caller polls it — a derivation that silently changed the
   selection would leave the log showing one room and the composer sending to
   another. */
function renderChatRooms(rooms) {
  var previous = el.chatRoom.value;

  var shared = rooms.filter(function (r) { return !isDm(r.room); });
  var dms = rooms.filter(function (r) { return isDm(r.room); });
  knownPeers.forEach(function (p) {
    if (p.name === instanceName) return;
    var room = dmRoom(instanceName, p.name);
    // A peer with no history yet still needs somewhere to be spoken to.
    if (!dms.some(function (d) { return d.room === room; })) dms.push({ room: room, messages: 0 });
  });

  el.chatRoom.textContent = "";
  van.add(el.chatRoom, [["Rooms", shared], ["Direct", dms]]
    .filter(function (pair) { return pair[1].length; })
    .map(function (pair) {
      return T.optgroup({ label: pair[0] }, pair[1].map(function (r) {
        return T.option({ value: r.room },
          chatRoomLabel(r) + (r.messages ? "  ·  " + r.messages : ""));
      }));
    }));

  var options = el.chatRoom.querySelectorAll("option");
  var empty = options.length === 0;
  el.chatRoom.disabled = empty;
  el.chatText.disabled = empty;
  el.chatSend.disabled = empty;
  if (empty) {
    el.chatStatus.textContent = "No rooms and no peers configured.";
    return null;
  }
  var wanted = Array.prototype.some.call(options, function (o) { return o.value === previous; })
    ? previous : options[0].value;
  el.chatRoom.value = wanted;
  return wanted;
}

function loadChatRooms() {
  return fetch("/api/chat/rooms")
    .then(readJson)
    .then(function (data) {
      subscribedRooms = data.subscribed || [];
      var wanted = renderChatRooms(data.rooms || []);
      if (wanted) return openChatRoom(wanted);
    })
    .catch(function (err) {
      el.chatRoom.disabled = true;
      el.chatText.disabled = true;
      el.chatSend.disabled = true;
      el.chatStatus.textContent = "Could not load rooms: " + err.message;
    });
}

function openChatRoom(room) {
  stopChatPoll();
  el.chatLog.textContent = "";
  chatLastTs = 0;
  chatSeen = {};
  chatSeenOrder = [];
  chatBackoff = chat_poll_base_ms;
  el.chatText.disabled = false;
  el.chatSend.disabled = false;
  el.chatText.placeholder = isDm(room) ? "Message " + dmPartner(room) + "…" : "Message " + room + "…";
  // Opening a room fills the log with its history, and a live region would
  // read every one of those out as if it had just arrived. Announcements
  // start once the backlog is in place.
  el.chatLog.setAttribute("aria-live", "off");
  return joinIfNeeded(room)
    .then(function () { return pollChat(room); })
    .then(function () {
      el.chatLog.setAttribute("aria-live", "polite");
      startChatPoll(room);
    });
}

/* A peer's message is only logged for rooms this instance has joined, so
   opening a DM has to join it — otherwise the first reply would arrive at a
   room the receiving side is refusing, and the conversation would look
   one-sided from both ends. */
function joinIfNeeded(room) {
  if (subscribedRooms.indexOf(room) !== -1) return Promise.resolve();
  return fetch("/api/chat/subscribe", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ room: room, on: true })
  }).then(function (r) {
    if (r.ok) subscribedRooms.push(room);
  }).catch(function () {
    // Reading still works unsubscribed; only inbound delivery is affected,
    // and the next Refresh retries the join.
  });
}

/* Fetches only what arrived after the newest message already shown. The id
   check is belt and braces: two messages can share a timestamp at
   one-second resolution, and `after` is inclusive of neither side reliably
   once that happens. */
function pollChat(room) {
  return fetch("/api/chat/messages?room=" + encodeURIComponent(room) + "&after=" + chatLastTs)
    .then(readJson)
    .then(function (data) {
      chatBackoff = chat_poll_base_ms;
      // Leaving the failure notice up after recovery would keep promising a
      // retry that already happened.
      if (chatFailing) {
        chatFailing = false;
        el.chatStatus.textContent = "Reconnected.";
      }
      // The log is returned newest-first (it is read backwards to honour the
      // 50-message limit); a conversation reads downwards, so it is flipped
      // before appending.
      var fresh = (data.messages || [])
        .filter(function (m) { return !chatSeen[m.id]; })
        .sort(function (a, b) { return a.ts - b.ts; });
      // Measured before anything is appended: whether to follow the
      // conversation depends on where the reader was, not where they end up.
      var following = el.chatLog.scrollHeight - el.chatLog.scrollTop - el.chatLog.clientHeight < 40;
      fresh.forEach(function (m) {
        rememberChatId(m.id);
        if (m.ts > chatLastTs) chatLastTs = m.ts;
        el.chatLog.appendChild(buildChatMessage(m));
      });
      // Only chase the bottom for someone already at it. Scrolling a reader
      // away from the message they are part-way through is worse than making
      // them scroll down for themselves.
      if (fresh.length && following) el.chatLog.scrollTop = el.chatLog.scrollHeight;
    })
    .catch(function (err) {
      // Backs off rather than giving up. Stopping outright meant one
      // transient 500 — a server restart, say — silently ended live updates
      // for the rest of the session, with only a stale error line to show
      // for it.
      chatFailing = true;
      chatBackoff = Math.min(chatBackoff * 3, chat_poll_max_ms);
      el.chatStatus.textContent = "Could not load messages: " + err.message +
        " — retrying in " + Math.round(chatBackoff / 1000) + "s.";
    });
}

/* Bounded so a room left open all day does not accumulate an id per message
   forever. Only the recent window matters: `after` already keeps the server
   from resending anything older, so the set exists to catch the overlap at
   the boundary, not to remember the whole room. */
function rememberChatId(id) {
  chatSeen[id] = true;
  chatSeenOrder.push(id);
  while (chatSeenOrder.length > chat_seen_cap) {
    delete chatSeen[chatSeenOrder.shift()];
  }
}

/* A stable emoji per instance, so a busy room is scannable by shape before
   you read a single name. Derived from the name rather than assigned, so
   every clanker independently agrees on who is who with no shared state and
   no registry — the same reasoning as the DM room name. Collisions are
   possible with enough peers; the name is still right there next to it. */
var CLANKER_MARKS = [
  "🐙", "🦊", "🦉", "🐢", "🦋", "🐝", "🦔", "🦦",
  "🦭", "🐬", "🦅", "🦩", "🐸", "🦎", "🐿️", "🦡",
  "🪼", "🦑", "🐳", "🦌", "🐺", "🦂", "🕷️", "🦜"
];

function clankerMark(name) {
  var h = 5381;
  for (var i = 0; i < name.length; i++) {
    // djb2, kept in 32-bit range so the result does not drift with length.
    h = ((h * 33) ^ name.charCodeAt(i)) >>> 0;
  }
  return CLANKER_MARKS[h % CLANKER_MARKS.length];
}

function buildChatMessage(m) {
  var wrap = document.createElement("div");
  wrap.className = "chat-msg" + (m.from === instanceName ? " mine" : "");

  var meta = document.createElement("div");
  meta.className = "chat-meta";
  var mark = document.createElement("span");
  mark.className = "chat-mark";
  mark.textContent = clankerMark(m.from || "");
  // Decorative: the name follows it and says the same thing.
  mark.setAttribute("aria-hidden", "true");
  meta.appendChild(mark);
  var from = document.createElement("span");
  from.className = "chat-from";
  from.textContent = m.from;
  meta.appendChild(from);
  var time = document.createElement("span");
  time.className = "chat-time";
  time.textContent = formatChatTime(m.ts);
  meta.appendChild(time);
  wrap.appendChild(meta);

  var text = document.createElement("div");
  text.className = "chat-text";
  var said = boardActionLine(m.text);
  if (said) {
    text.classList.add("chat-action");
    text.textContent = said;
  } else {
    text.textContent = m.text;
  }
  wrap.appendChild(text);
  return wrap;
}

/* A card action is a chat message, which is what lets a board replicate with
   the room it belongs to. Printed as it is stored it is a line of JSON in the
   middle of a human conversation, so the room shows the sentence the action
   stands for and keeps the payload out of the way. Returns null for an
   ordinary message, which is then shown verbatim. */
var BOARD_COLUMNS = { backlog: "Backlog", ready: "Ready", doing: "Doing", review: "Review", done: "Done" };

function boardActionLine(raw) {
  if (typeof raw !== "string" || raw.slice(0, 6) !== "@todo ") return null;
  var a;
  try { a = JSON.parse(raw.slice(6)); } catch (e) { return null; }
  if (!a || typeof a !== "object") return null;
  var quoted = function (s) { return "\u201c" + String(s) + "\u201d"; };
  var col = function (c) { return BOARD_COLUMNS[c] || c; };
  switch (a.action) {
    case "add": return "added " + quoted(a.title) + (a.column ? " to " + col(a.column) : "");
    case "update": {
      var parts = [];
      if (a.title) parts.push("title to " + quoted(a.title));
      if (a.priority) parts.push("priority to " + a.priority);
      if (a.column) parts.push("column to " + col(a.column));
      if (a.who !== undefined) parts.push(a.who ? "owner to " + a.who : "nobody as owner");
      if (a.deadline !== undefined) parts.push("the deadline");
      if (a.body !== undefined && !parts.length) parts.push("the notes");
      return "changed " + (parts.length ? parts.join(", ") : "a card");
    }
    case "move": return "moved a card to " + col(a.column);
    case "close": return "moved a card to Done";
    case "claim": return "claimed a card";
    case "assign": return a.who ? "assigned a card to " + a.who : "left a card unassigned";
    case "delete": return "deleted a card";
    case "subtask_add": return "added the subtask " + quoted(a.text);
    case "subtask_toggle": return (a.done === false ? "unticked" : "ticked") + " a subtask";
    case "subtask_remove": return "removed a subtask";
    case "depend": return a.off ? "cleared a dependency" : "made a card wait on another";
    case "log": return "noted: " + a.what;
    case "usage": {
      var bits = [];
      var tok = (a.prompt_tokens || 0) + (a.completion_tokens || 0);
      if (tok) bits.push(tok.toLocaleString() + " tokens");
      if (a.cost) bits.push("$" + Number(a.cost).toFixed(4));
      return "recorded " + (bits.length ? bits.join(" and ") : "usage") + " against a card";
    }
    default: return null;
  }
}

function formatChatTime(ts) {
  if (!ts) return "";
  var d = new Date(ts * 1000);
  return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

/* Polling rather than a socket: the server closes every connection after one
   response (see Connection: close in cli.zig), so there is nothing to hold
   open. Stopped whenever the tab is hidden so a backgrounded page is not
   waking the agent's HTTP server every few seconds for nothing. */
/* A self-rescheduling timeout rather than a fixed interval: the delay has to
   be read fresh after each attempt, because a failure widens it and the next
   success narrows it straight back. An interval would keep firing at the
   rate it was created with. */
function startChatPoll(room) {
  stopChatPoll();
  if (document.hidden) return;
  chatPoll = window.setTimeout(function () {
    pollChat(room).finally(function () {
      // Only reschedule if this poll is still the current one — switching
      // rooms mid-flight clears it, and reviving it here would leave two
      // chains running against different rooms.
      if (chatPoll !== null) startChatPoll(room);
    });
  }, chatBackoff);
}

function stopChatPoll() {
  if (chatPoll) { window.clearTimeout(chatPoll); chatPoll = null; }
}

document.addEventListener("visibilitychange", function () {
  if (document.hidden) stopChatPoll();
  else if (el.chatRoom.value) startChatPoll(el.chatRoom.value);
});

el.chatRoom.addEventListener("change", function () {
  openChatRoom(el.chatRoom.value);
});

el.chatRefresh.addEventListener("click", function () {
  el.chatRefresh.disabled = true;
  loadChatRooms().finally(function () { el.chatRefresh.disabled = false; });
});

el.chatForm.addEventListener("submit", function (e) {
  e.preventDefault();
  var text = el.chatText.value.trim();
  var room = el.chatRoom.value;
  if (!text || !room) return;
  // maxlength on the input counts UTF-16 units while the server counts
  // bytes, so multi-byte text passes the browser's check and comes back as a
  // bare HTTP 400. Checked here in the same units the server uses.
  var bytes = new TextEncoder().encode(text).length;
  if (bytes > chat_max_bytes) {
    el.chatStatus.textContent = "Message is " + bytes + " bytes; the limit is " + chat_max_bytes + ".";
    return;
  }
  el.chatSend.disabled = true;
  // /api/chat/send, not /api/chat/message: the latter is the inbound
  // endpoint peers post to, which only logs rooms this instance has already
  // joined. Sending appends locally and fans out to every peer, and joins
  // the room first when it is one this instance has not been in before.
  fetch("/api/chat/send", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ room: room, text: text })
  }).then(readJson).then(function () {
    el.chatText.value = "";
    return pollChat(room);
  }).catch(function (err) {
    el.chatStatus.textContent = "Could not send: " + err.message;
  }).finally(function () {
    el.chatSend.disabled = false;
    el.chatText.focus();
  });
});

// ---- usage: what the model calls have cost -----------------------------

function fmtInt(n) {
  return (typeof n === "number" ? n : 0).toLocaleString();
}

/* Cost is the reading people actually come here for, so it gets four
   decimals rather than a rounded currency format: a single run is often
   worth less than a cent, and rounding it to $0.00 would say nothing. */
/* 183245ms is a number; three minutes is a duration. */
function fmtMs(ms) {
  if (typeof ms !== "number" || !isFinite(ms)) return "";
  if (ms < 1000) return ms + "ms";
  if (ms < 60000) return (ms / 1000).toFixed(1) + "s";
  var mins = Math.floor(ms / 60000);
  return mins + "m " + Math.round((ms % 60000) / 1000) + "s";
}

function fmtCost(n) {
  return "$" + (typeof n === "number" ? n : 0).toFixed(4);
}

var allUsage = [];

/* What a model is called here, which is not always what is sent on the wire:
   kimi-k3 goes out bare because that is what api.moonshot.ai accepts, and is
   read as moonshotai/kimi-k3, the way an OpenRouter-routed model is written.
   Renaming the wire id to match would have broken every call to the default
   provider. */
function modelLabel(provider, model) {
  for (var i = 0; i < providerCache.length; i++) {
    if (providerCache[i].name !== provider) continue;
    var models = providerCache[i].models || [];
    for (var k = 0; k < models.length; k++) {
      if (models[k].name === model) return models[k].display || model;
    }
  }
  return model;
}

var usageState = van.state([]);

function renderUsage(rows) {
  allUsage = rows || allUsage;
  usageState.val = allUsage.slice();
}

var USAGE_COLUMNS = [
  ["Provider / model", ""], ["Calls", "num"], ["Prompt", "num"],
  ["Completion", "num"], ["Cache hit", "num"], ["Tok/s", "num"], ["Cost", "num"]
];

/* Provider and model are often the same string, and showing it twice is
   noise — unless the model has a name of its own to be shown by. */
function usageName(r) {
  var shown = modelLabel(r.provider, r.model);
  if (shown === r.provider) return T.td(r.provider);
  return T.td(r.provider + " / ", T.span({ class: "model" }, shown));
}

function usageRow(r) {
  return T.tr(usageName(r), [
    fmtInt(r.calls), fmtInt(r.prompt_tokens), fmtInt(r.completion_tokens),
    (r.cache_hit_rate || 0).toFixed(1) + "%", (r.tokens_per_sec || 0).toFixed(0), fmtCost(r.cost)
  ].map(function (v) { return T.td({ class: "num" }, v); }));
}

bind(el.usage, usageState, function (rows) {
  if (!rows.length) {
    return UI.empty("No completions recorded yet. Run a task and the totals appear here.");
  }
  var totals = rows.reduce(function (a, r) {
    a.calls += r.calls || 0;
    a.prompt += r.prompt_tokens || 0;
    a.completion += r.completion_tokens || 0;
    a.cost += r.cost || 0;
    return a;
  }, { calls: 0, prompt: 0, completion: 0, cost: 0 });

  return T.div({ class: "usage-wrap" },
    T.table({ class: "usage" },
      T.thead(T.tr(USAGE_COLUMNS.map(function (col) {
        var th = T.th({ class: col[1] || null }, col[0]);
        // Set directly: van did not carry `scope` through as an attribute, and
        // a header cell without it is not associated with its column.
        th.setAttribute("scope", "col");
        return th;
      }))),
      T.tbody(rows.map(usageRow)),
      T.tfoot(T.tr(
        T.td(rows.length + (rows.length === 1 ? " model" : " models")),
        [fmtInt(totals.calls), fmtInt(totals.prompt), fmtInt(totals.completion), "", "", fmtCost(totals.cost)]
          .map(function (v) { return T.td({ class: "num" }, v); })))));
});

function loadUsage() {
  return fetch("/api/stats")
    .then(readJson)
    .then(function (data) { renderUsage(data.stats || []); })
    .catch(function (err) {
      el.usage.textContent = "";
      var p = document.createElement("p");
      p.className = "usage-empty";
      p.textContent = "Could not load usage: " + err.message;
      el.usage.appendChild(p);
    });
}

// ---- goals: what runs are being steered toward -------------------------

var goalState = van.state([]);

/* Newest first: the goal most recently set is the one steering runs now. */
function renderGoals(goals) {
  goalState.val = (goals || []).slice().sort(function (a, b) {
    return (b.updated || 0) - (a.updated || 0);
  });
}

function goalCard(g) {
  var fields = [["Done when", g.completion_criterion], ["Proof", g.proof],
    ["Boundaries", g.boundaries], ["Stop rule", g.stop_rule]]
    .filter(function (pair) { return !!pair[1]; });

  var actions = [];
  if (g.id) {
    [["Mark done", "done", "Goal marked done."],
     ["Abandon", "abandoned", "Goal abandoned."],
     ["Reactivate", "active", "Goal reactivated."]].forEach(function (pair) {
      if ((g.status || "active") === pair[1]) return;
      actions.push(UI.button(pair[0], function () { postGoal({ id: g.id, status: pair[1] }, pair[2]); }));
    });
    actions.push(UI.button("Delete", function () {
      if (!window.confirm("Delete this goal? Runs that carried it are kept.")) return;
      postGoal({ id: g.id, remove: true }, "Goal deleted.");
    }, { kind: "danger", label: "Delete goal: " + (g.objective || g.id) }));
  }

  return T.div({ class: "goal", "data-status": g.status || "" },
    T.div({ class: "goal-objective" }, g.objective || "(no objective recorded)"),
    T.div({ class: "goal-meta" },
      T.span({ class: "goal-status" }, g.status || "unknown"),
      g.id ? T.span("id " + String(g.id).slice(0, 10)) : null),
    /* A well-specified goal runs to several paragraphs and there are usually
       several of them; expanded by default they push the rest of the page off
       screen, so the objective and status stay visible and the specification
       is one click away. */
    fields.length ? T.details({ class: "goal-detail" },
      T.summary("Specification"),
      T.dl(fields.map(function (pair) {
        return [T.dt(pair[0]), T.dd(pair[1])];
      }))) : null,
    actions.length ? T.div({ class: "goal-actions" }, actions) : null);
}

bind(el.goals, goalState, function (goals) {
  if (!goals.length) {
    return UI.empty("No goals set. Add one above, or run `clanker goal \"<intent>\"`.");
  }
  return goals.map(goalCard);
});

function loadGoals() {
  return fetch("/api/goals")
    .then(readJson)
    .then(function (data) { renderGoals(data.goals || []); })
    .catch(function (err) {
      el.goals.textContent = "";
      var p = document.createElement("p");
      p.className = "usage-empty";
      p.textContent = "Could not load goals: " + err.message;
      el.goals.appendChild(p);
    });
}

// ---- tools: every WASM plugin, and a switch for the optional ones ------

var allTools = [];

/* The tool list is a derivation of what is registered and what is typed in
   the filter, so the two can never disagree about what is on screen. */
var toolState = van.state({ tools: [], filter: "" });

function renderTools(filterText) {
  toolState.val = {
    tools: allTools,
    filter: (filterText == null ? el.toolFilter.value : filterText).trim().toLowerCase()
  };
}

bind(el.tools, toolState, function (s) {
  var shown = !s.filter ? s.tools : s.tools.filter(function (t) {
    return t.name.toLowerCase().indexOf(s.filter) !== -1 ||
      (t.description || "").toLowerCase().indexOf(s.filter) !== -1;
  });
  el.toolsStatus.textContent = s.filter
    ? shown.length + (shown.length === 1 ? " tool matches." : " tools match.")
    : "";
  if (!shown.length) {
    return UI.empty(s.filter
      ? "No tool matches " + s.filter + "."
      : "No tools registered. `zig build tools` compiles them.");
  }
  return shown.map(buildToolRow);
});

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

  // Core tools back the REPL and the HTTP routes, so the harness refuses to
  // switch them off. Showing a dead button would invite the click anyway.
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

  if (t.config_editable && t.config_editable.length) row.appendChild(buildToolConfig(t));

  var desc = document.createElement("span");
  desc.className = "tool-desc";
  // Descriptions are written for the model and run long; the first sentence
  // is what a person scanning the list needs.
  var text = (t.description || "").trim();
  var stop = text.indexOf(". ");
  // A description is trimmed to its first sentence, or failing that to the
  // last word that fits. Slicing at a fixed byte cut a word in half and said
  // nothing about the rest ("guessing would waste w"), so a shortened line now
  // ends on a word and admits it was shortened.
  desc.textContent = stop > 0 && stop < 160 ? text.slice(0, stop + 1) : clip(text, 160);
  desc.title = text;
  row.appendChild(desc);

  return row;
}

/* The settings a plugin's descriptor opted in to runtime editing. Only those
   keys appear: the rest of a config object is the tool's own structure (the
   chat_* tools select their behaviour with a `op` key), and the server
   refuses a write to anything unlisted anyway. Collapsed by default so 45
   rows do not become 45 open forms. */
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
    // A number stays a number on the way back: the manifest declares the
    // type by what it holds, and sending "3" where 3 was expected would
    // quietly change it.
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
    el.toolsStatus.textContent = t.name + ": " + bad + " must be a number.";
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
    el.toolsStatus.textContent = "Saved settings for " + t.name + ".";
  }).catch(function (err) {
    el.toolsStatus.textContent = "Could not save " + t.name + ": " + err.message;
  }).finally(function () {
    btn.disabled = false;
  });
}

/* What a tool accepts and what it is allowed to reach. The sandbox policy is
   the headline: a descriptor's network, filesystem and exec allowances are
   the real answer to "what can this thing do", and they were previously only
   readable by opening the manifest. */
function showToolDetail(t) {
  el.toolDetail.textContent = "";
  el.toolDetail.hidden = false;

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
  tags.push(t.enabled ? "enabled" : "disabled");
  meta.textContent = "  " + tags.join("  ·  ");
  titleWrap.appendChild(meta);
  head.appendChild(titleWrap);

  var closeBtn = document.createElement("button");
  closeBtn.type = "button";
  closeBtn.className = "secondary run-detail-close";
  closeBtn.textContent = "Close";
  closeBtn.addEventListener("click", function () {
    el.toolDetail.hidden = true;
    el.toolDetail.textContent = "";
  });
  head.appendChild(closeBtn);
  el.toolDetail.appendChild(head);

  // Full text, not the first sentence the row shows.
  var desc = document.createElement("p");
  desc.className = "tool-detail-desc";
  desc.textContent = t.description || "(no description)";
  el.toolDetail.appendChild(desc);

  // Actions: every parameter the tool accepts, with the required ones named.
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
      dd.textContent = (spec.type || "any") + (spec.description ? " — " + spec.description : "");
      list.appendChild(dd);
    });
    el.toolDetail.appendChild(sectionTitle("Accepts"));
    el.toolDetail.appendChild(list);
  }

  // Sandbox policy. An empty allowance is a real answer, so it is stated
  // rather than omitted: "no network" is the thing worth knowing.
  el.toolDetail.appendChild(sectionTitle("Sandbox"));
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
  el.toolDetail.appendChild(policy);

  scrollTo(el.toolDetail, "nearest");
  closeBtn.focus();
}

function sectionTitle(text) {
  var h = document.createElement("h3");
  h.className = "tool-detail-h";
  h.textContent = text;
  return h;
}

function toggleTool(t, btn) {
  var want = !t.enabled;
  btn.disabled = true;
  fetch("/api/plugins", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: t.name, on: want })
  }).then(function (r) {
    return r.text().then(function (text) {
      if (!r.ok) throw new Error(String(text).trim() || "HTTP " + r.status);
      return text;
    });
  }).then(function (reply) {
    t.enabled = want;
    btn.dataset.on = String(want);
    btn.textContent = want ? "on" : "off";
    btn.setAttribute("aria-pressed", String(want));
    btn.setAttribute("aria-label", (want ? "Disable " : "Enable ") + t.name);
    // The harness answers in words ("enabled: git", "core tool, cannot be
    // switched off: …"); it is the authority on what happened, so it is
    // what gets announced.
    el.toolsStatus.textContent = String(reply).trim();
  }).catch(function (err) {
    el.toolsStatus.textContent = "Could not switch " + t.name + ": " + err.message;
  }).finally(function () {
    btn.disabled = false;
  });
}

function loadTools() {
  return fetch("/api/plugins")
    .then(readJson)
    .then(function (data) {
      allTools = data.plugins || [];
      renderTools(el.toolFilter.value);
    })
    .catch(function (err) {
      el.tools.textContent = "";
      var p = document.createElement("p");
      p.className = "usage-empty";
      p.textContent = "Could not load tools: " + err.message;
      el.tools.appendChild(p);
      el.toolsStatus.textContent = p.textContent;
    });
}

var toolFilterTimer = null;
el.toolFilter.addEventListener("input", function () {
  if (toolFilterTimer) window.clearTimeout(toolFilterTimer);
  toolFilterTimer = window.setTimeout(function () { renderTools(el.toolFilter.value); }, 120);
});

el.goalsRefresh.addEventListener("click", function () {
  el.goalsRefresh.disabled = true;
  loadGoals().finally(function () { el.goalsRefresh.disabled = false; });
});
el.usageRefresh.addEventListener("click", function () {
  el.usageRefresh.disabled = true;
  loadUsage().finally(function () { el.usageRefresh.disabled = false; });
});
el.toolsRefresh.addEventListener("click", function () {
  el.toolsRefresh.disabled = true;
  loadTools().finally(function () { el.toolsRefresh.disabled = false; });
});

// ---- views: one section visible at a time -----------------------------

var VIEWS = ["chat", "board", "goals", "runs", "rooms", "tools", "system"];
/* Each view's data is fetched the first time it is opened rather than all of
   it at load. The page used to fire seven requests before showing anything,
   several of which execute a WASM tool. */
var viewLoaded = {};
var viewLoaders = {
  runs: loadRuns,
  rooms: function () { return loadStatus().then(loadChatRooms); },
  goals: loadGoals,
  board: function () { return loadBoardRooms(); },
  tools: loadTools,
  system: function () { return Promise.all([loadUsage(), loadStatus(), loadLogList(), loadWebuiPlugins()]); }
};

/* An in-flight panel, an empty panel and a hung panel were pixel-identical.
   Each renderer overwrites this on success and each catch replaces it with the
   failure, so one line is enough. */
var VIEW_CONTAINERS = {
  runs: "run-graph",
  rooms: "chat-log",
  goals: "goals",
  board: "board",
  tools: "tools",
  system: "usage"
};

function markLoading(name) {
  var id = VIEW_CONTAINERS[name];
  if (!id) return;
  var node = document.getElementById(id);
  if (!node || node.childNodes.length) return;
  node.setAttribute("aria-busy", "true");
  var p = document.createElement("p");
  p.className = "meta";
  p.textContent = "Loading…";
  node.appendChild(p);
}

function clearLoading(name) {
  var id = VIEW_CONTAINERS[name];
  if (!id) return;
  var node = document.getElementById(id);
  if (node) node.removeAttribute("aria-busy");
}

var viewSettled = false;
var currentView = null;

function showView(name, focusPanel) {
  if (VIEWS.indexOf(name) === -1) name = "chat";
  // The rooms poll has no idea the view switched away from under it — only
  // document.hidden stopped it before, so leaving Rooms for Chat or Board
  // left it polling a chat log nobody could see. Stop it here, and pick back
  // up where it left off if Rooms is reopened.
  if (currentView === "rooms" && name !== "rooms") stopChatPoll();
  currentView = name;
  VIEWS.forEach(function (v) {
    var tab = document.getElementById("tab-" + v);
    var panel = document.getElementById("view-" + v);
    var on = v === name;
    panel.hidden = !on;
    tab.setAttribute("aria-selected", String(on));
    // Roving tabindex: the tablist is one stop, arrows move within it.
    tab.tabIndex = on ? 0 : -1;
  });
  if (window.location.hash !== "#" + name) {
    // Pushed for a switch someone made, replaced for the initial normalisation
    // of whatever the URL arrived with. Writing a fragment into the address bar
    // is a promise that Back returns to where you were, and it did not.
    try {
      if (viewSettled) window.history.pushState(null, "", "#" + name);
      else window.history.replaceState(null, "", "#" + name);
    } catch (e) {}
  }
  viewSettled = true;
  el.railContext.hidden = name !== "chat";
  if (focusPanel) document.getElementById("view-" + name).focus();
  if (!viewLoaded[name] && viewLoaders[name]) {
    // Marked loaded only once it has loaded: a view whose first fetch failed
    // used to stay broken for the life of the page, however many times you
    // came back to it.
    markLoading(name);
    var loading = viewLoaders[name]();
    if (loading && typeof loading.then === "function") {
      loading.then(function () {
        viewLoaded[name] = true;
        clearLoading(name);
      }, function () { clearLoading(name); });
    } else {
      viewLoaded[name] = true;
    }
  } else if (name === "rooms" && el.chatRoom.value) {
    startChatPoll(el.chatRoom.value);
  }
}

function wireTab(tab, i) {
  var v = tab.getAttribute("data-view");
  tab.addEventListener("click", function () { showView(v, false); });
  tab.addEventListener("keydown", function (e) {
    // The tablist is a column now, so it answers to Up and Down. Left and
    // Right keep working: a tablist that ignored them would be a regression
    // for anyone who learned them here.
    var step = (e.key === "ArrowDown" || e.key === "ArrowRight") ? 1 :
      (e.key === "ArrowUp" || e.key === "ArrowLeft") ? -1 : 0;
    if (step) {
      e.preventDefault();
      var next = VIEWS[(i + step + VIEWS.length) % VIEWS.length];
      showView(next, false);
      document.getElementById("tab-" + next).focus();
      return;
    }
    if (e.key === "Home" || e.key === "End") {
      e.preventDefault();
      var edge = e.key === "Home" ? VIEWS[0] : VIEWS[VIEWS.length - 1];
      showView(edge, false);
      document.getElementById("tab-" + edge).focus();
    }
  });
}

VIEWS.forEach(function (v, i) {
  wireTab(document.getElementById("tab-" + v), i);
});

window.addEventListener("hashchange", function () {
  showView(window.location.hash.replace("#", ""), false);
});

/* A digit jumps straight to a view, but never while someone is typing into
   the composer or a filter. */
document.addEventListener("keydown", function (e) {
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  var t = e.target;
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
  var n = parseInt(e.key, 10);
  if (n >= 1 && n <= VIEWS.length) {
    showView(VIEWS[n - 1], false);
    document.getElementById("tab-" + VIEWS[n - 1]).focus();
  }
});

function setTabCount(view, n) {
  var tab = document.getElementById("tab-" + view);
  if (!tab) return;
  var el0 = tab.querySelector(".tab-count");
  if (!el0) {
    el0 = document.createElement("span");
    el0.className = "tab-count";
    tab.appendChild(el0);
  }
  el0.textContent = n ? String(n) : "";
}



/* ---------- model picker and sampling ---------- */

/* The CLI has --provider and config.json has temperature and top_p; the
   composer had neither, so every run through the page used the default. */
var providerCache = [];

function loadProviders() {
  return fetch("/api/providers")
    .then(readJson)
    .then(function (d) {
      providerCache = d.providers || [];
      // Usage may have rendered before this arrived; its labels come from here.
      if (allUsage.length) renderUsage(null);
      el.modelSelect.textContent = "";
      (d.providers || []).forEach(function (prov) {
        var group = document.createElement("optgroup");
        group.label = prov.name;
        (prov.models || []).forEach(function (m) {
          var opt = document.createElement("option");
          opt.value = prov.name + " " + m.name;
          opt.textContent = (m.display || m.name) + (m.context_window ? "  .  " + fmtInt(m.context_window) + " ctx" : "");
          if (prov.name === d.default && m.name === prov.default_model) opt.selected = true;
          group.appendChild(opt);
        });
        el.modelSelect.appendChild(group);
      });
      var saved = null;
      try { saved = window.localStorage.getItem("clanker.model"); } catch (e) {}
      if (saved && el.modelSelect.querySelector('option[value="' + saved.replace(/"/g, "") + '"]')) {
        el.modelSelect.value = saved;
      }
    })
    .catch(function () {
      // Providers are informational: a failure here must not stop a run,
      // which then simply uses whatever the config says.
      var opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "config default";
      el.modelSelect.appendChild(opt);
    });
}

el.modelSelect.addEventListener("change", function () {
  try { window.localStorage.setItem("clanker.model", el.modelSelect.value); } catch (e) {}
  renderContextMeter();
});

/* Everything the composer adds to a run, in one place, so the submit handler
   and any future caller cannot disagree about it. */
function runOptions() {
  var out = {};
  var pair = (el.modelSelect.value || "").split(" ");
  if (pair[0]) out.provider = pair[0];
  if (pair[1]) out.model = pair[1];
  var t = parseFloat(el.paramTemp.value);
  if (!isNaN(t)) out.temperature = t;
  var tp = parseFloat(el.paramTopP.value);
  if (!isNaN(tp)) out.top_p = tp;
  return out;
}

/* Enter-to-send is the habit every other chat UI trains, but it also throws
   away a half-written multi-line task, so it is opt-in and remembered. */
try { el.enterSends.checked = window.localStorage.getItem("clanker.entersends") === "1"; } catch (e) {}
el.enterSends.addEventListener("change", function () {
  try { window.localStorage.setItem("clanker.entersends", el.enterSends.checked ? "1" : "0"); } catch (e) {}
  syncSubmitLabel();
});

function syncSubmitLabel() {
  el.submit.textContent = el.enterSends.checked ? "Run (Enter)" : "Run (Ctrl+Enter)";
}

el.task.addEventListener("keydown", function (e) {
  if (e.key !== "Enter" || e.shiftKey || e.ctrlKey || e.metaKey || e.altKey) return;
  if (!el.enterSends.checked) return;
  e.preventDefault();
  if (!busy && el.task.value.trim()) el.form.requestSubmit();
});

/* ---------- search inside the conversation ---------- */

function clearMarks(root) {
  var marks = root.querySelectorAll("mark");
  Array.prototype.forEach.call(marks, function (m) {
    var text = document.createTextNode(m.textContent);
    m.parentNode.replaceChild(text, m);
  });
  // Splitting a text node to highlight leaves neighbours behind; rejoining
  // them keeps repeated searches from fragmenting the answer into hundreds
  // of nodes.
  if (root.normalize) root.normalize();
}

function markMatches(root, needle) {
  var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  var targets = [];
  var node;
  while ((node = walker.nextNode())) {
    if (node.nodeValue.toLowerCase().indexOf(needle) !== -1) targets.push(node);
  }
  var hits = 0;
  targets.forEach(function (text) {
    var value = text.nodeValue;
    var frag = document.createDocumentFragment();
    var at = 0;
    var idx = value.toLowerCase().indexOf(needle, at);
    while (idx !== -1) {
      if (idx > at) frag.appendChild(document.createTextNode(value.slice(at, idx)));
      var mark = document.createElement("mark");
      mark.textContent = value.substr(idx, needle.length);
      frag.appendChild(mark);
      hits += 1;
      at = idx + needle.length;
      idx = value.toLowerCase().indexOf(needle, at);
    }
    if (at < value.length) frag.appendChild(document.createTextNode(value.slice(at)));
    text.parentNode.replaceChild(frag, text);
  });
  return hits;
}

function applyTurnFilter() {
  var q = el.turnFilter.value.trim().toLowerCase();
  var turns = el.transcript.querySelectorAll(".turn");
  clearMarks(el.transcript);
  if (!q) {
    Array.prototype.forEach.call(turns, function (t) { t.hidden = false; });
    el.turnFilterCount.textContent = "";
    return;
  }
  var shown = 0, hits = 0;
  Array.prototype.forEach.call(turns, function (t) {
    var match = t.textContent.toLowerCase().indexOf(q) !== -1;
    t.hidden = !match;
    if (match) {
      shown += 1;
      hits += markMatches(t, q);
    }
  });
  el.turnFilterCount.textContent = shown
    ? hits + (hits === 1 ? " match in " : " matches in ") + shown + (shown === 1 ? " turn" : " turns")
    : "No turns match.";
}

el.turnFilter.addEventListener("input", applyTurnFilter);

/* ---------- keeping up with a streaming answer ---------- */

function nearBottom() {
  return window.innerHeight + window.scrollY >= document.body.scrollHeight - 120;
}

function prefersReducedMotion() {
  return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

function syncScrollButton() {
  var show = !nearBottom() && el.transcript.querySelector(".turn") !== null;
  el.scrollBottom.hidden = !show;
}

van.add(el.scrollBottom, icon("deposit", 14));
el.scrollBottom.addEventListener("click", function () {
  window.scrollTo({ top: document.body.scrollHeight, behavior: prefersReducedMotion() ? "auto" : "smooth" });
  el.task.focus();
});

window.addEventListener("scroll", syncScrollButton, { passive: true });
window.addEventListener("resize", syncScrollButton);

/* ---------- export ---------- */

el.sessionExportJson.addEventListener("click", function () {
  fetch("/api/sessions/" + encodeURIComponent(sessionId))
    .then(readJson)
    .then(function (data) {
      downloadText("clanker-" + sessionId.slice(0, 8) + ".json", JSON.stringify(data, null, 2), "application/json");
      el.sessionStatus.textContent = "Exported as JSON.";
    })
    .catch(function (err) { el.sessionStatus.textContent = "Export failed: " + err.message; });
});

/* ---------- first-run suggestions ---------- */

var SUGGESTIONS = [
  "Summarise what this repository does, in five sentences.",
  "List the tools you have and what each one is for.",
  "Read src/agent/loop.zig and explain the agent loop.",
  "What did the last recorded run do?"
];

SUGGESTIONS.forEach(function (text) {
  var b = document.createElement("button");
  b.type = "button";
  b.className = "suggestion";
  b.textContent = text;
  b.addEventListener("click", function () {
    el.task.value = text;
    el.task.focus();
    syncControls();
  });
  el.suggestions.appendChild(b);
});




/* ---------- status, said out loud and shown ---------- */

/* Every view writes progress and failures into its own sr-only live region.
   Fifty call sites did that and none of them were visible: clicking Compact
   or Export or Save prompt produced no sign anything had happened unless you
   were using a screen reader. Rather than change fifty call sites and leave
   the two able to drift, the regions are observed and mirrored here. */
var toasts = document.getElementById("toasts");

function showToast(text) {
  if (!text) return;
  var node = document.createElement("p");
  node.className = "toast";
  node.tabIndex = 0;
  // The word "failed" is the one distinction worth colour: everything else
  // is progress, and progress does not need to shout.
  if (/fail|error|could not|refus|denied|no such/i.test(text)) node.setAttribute("data-kind", "bad");
  node.textContent = text;
  node.addEventListener("click", function () { node.remove(); });
  // A 5s timer is too short to read a long message, so hovering or focusing
  // it (mouse or keyboard) holds it on screen; it resumes counting down once
  // you look away, rather than vanishing mid-read.
  var timer;
  function schedule() { timer = window.setTimeout(function () { node.remove(); }, 5000); }
  node.addEventListener("mouseenter", function () { window.clearTimeout(timer); });
  node.addEventListener("mouseleave", schedule);
  node.addEventListener("focusin", function () { window.clearTimeout(timer); });
  node.addEventListener("focusout", schedule);
  toasts.appendChild(node);
  while (toasts.children.length > 3) toasts.removeChild(toasts.firstChild);
  schedule();
}

if (window.MutationObserver) {
  var statusObserver = new MutationObserver(function (records) {
    var seen = {};
    records.forEach(function (r) {
      var el0 = r.target.nodeType === 3 ? r.target.parentNode : r.target;
      if (!el0 || !el0.textContent) return;
      var text = el0.textContent.trim();
      // The same message written twice in one tick is one event.
      if (!text || seen[text]) return;
      seen[text] = true;
      showToast(text);
    });
  });
  ["session-status", "run-status", "chat-status", "board-status", "webui-plugins-status", "tools-status", "logs-status", "goals-status"].forEach(function (id) {
    var node = document.getElementById(id);
    if (node) statusObserver.observe(node, { childList: true, characterData: true, subtree: true });
  });
}

/* ---------- goals ---------- */

/* The view could only read. Every goal in the file was put there by the
   `goal` tool or the CLI, so setting one from the page meant leaving it. */
function postGoal(payload, status) {
  return fetch("/api/goals", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  })
    .then(readJson)
    .then(function (d) {
      renderGoals(d.goals || []);
      el.goalsStatus.textContent = status;
    })
    .then(function () { return true; })
    .catch(function (err) {
      el.goalsStatus.textContent = "Goal failed: " + err.message;
      return false;
    });
}

el.goalForm.addEventListener("submit", function (e) {
  e.preventDefault();
  var objective = el.goalObjective.value.trim();
  var criterion = el.goalCriterion.value.trim();
  if (!objective || !criterion) return;
  postGoal({ objective: objective, completion_criterion: criterion }, "Goal added.").then(function (ok) {
    // A refused goal keeps what was typed: the criterion is the field most
    // likely to be refused, and retyping the objective to fix it is a tax.
    if (!ok) return;
    el.goalObjective.value = "";
    el.goalCriterion.value = "";
  });
});

/* ---------- saved prompts ---------- */

/* Every one of these UIs has a prompt library, and the reason is the same:
   the tasks worth repeating are long, and retyping them is where the habit
   of using the tool dies. */
function loadPrompts() {
  try { return JSON.parse(window.localStorage.getItem("clanker.prompts") || "[]"); } catch (e) { return []; }
}
var prompts = loadPrompts();

function savePrompts() {
  try { window.localStorage.setItem("clanker.prompts", JSON.stringify(prompts)); } catch (e) {}
}

el.promptSave.addEventListener("click", function () {
  var text = el.task.value.trim();
  if (!text) {
    el.sessionStatus.textContent = "Write the prompt in the composer first.";
    return;
  }
  if (prompts.indexOf(text) !== -1) {
    el.sessionStatus.textContent = "That prompt is already saved.";
    return;
  }
  prompts.push(text);
  savePrompts();
  el.sessionStatus.textContent = "Prompt saved. Type / in the composer to use it.";
});

var promptIndex = 0;

function promptQuery() {
  var v = el.task.value;
  return v.charAt(0) === "/" ? v.slice(1).toLowerCase() : null;
}

function renderPromptList() {
  var q = promptQuery();
  if (q === null || !prompts.length) {
    hidePromptList();
    return;
  }
  var matches = prompts.filter(function (t) { return fuzzyMatch(q, t); });
  el.promptList.textContent = "";
  if (!matches.length) {
    hidePromptList();
    return;
  }
  if (promptIndex >= matches.length) promptIndex = 0;
  matches.forEach(function (text, i) {
    var li = document.createElement("li");
    li.className = "palette-item";
    li.id = "prompt-item-" + i;
    li.setAttribute("role", "option");
    li.setAttribute("aria-selected", String(i === promptIndex));
    var label = document.createElement("span");
    label.className = "palette-label";
    label.textContent = text;
    li.appendChild(label);
    li.addEventListener("mousedown", function (e) {
      e.preventDefault();
      usePrompt(text);
    });
    el.promptList.appendChild(li);
  });
  el.promptList.hidden = false;
  el.task.setAttribute("aria-expanded", "true");
  el.task.setAttribute("aria-activedescendant", "prompt-item-" + promptIndex);
  el.promptList.setAttribute("data-count", String(matches.length));
}

function hidePromptList() {
  el.promptList.hidden = true;
  el.promptList.textContent = "";
  el.task.setAttribute("aria-expanded", "false");
  el.task.removeAttribute("aria-activedescendant");
}

function usePrompt(text) {
  el.task.value = text;
  hidePromptList();
  el.task.focus();
  syncControls();
}

el.task.addEventListener("input", renderPromptList);
el.task.addEventListener("blur", function () { window.setTimeout(hidePromptList, 120); });
el.task.addEventListener("keydown", function (e) {
  if (el.promptList.hidden) return;
  var items = el.promptList.querySelectorAll(".palette-item");
  if (!items.length) return;
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    promptIndex = (promptIndex + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
    renderPromptList();
    return;
  }
  if (e.key === "Escape") {
    e.preventDefault();
    hidePromptList();
    return;
  }
  // Delete removes the highlighted prompt, which was otherwise only possible
  // with a pointer on a 32px glyph inside an option.
  if (e.key === "Delete") {
    e.preventDefault();
    var doomed = items[promptIndex].querySelector(".palette-label").textContent;
    prompts.splice(prompts.indexOf(doomed), 1);
    savePrompts();
    el.sessionStatus.textContent = "Forgot that prompt.";
    renderPromptList();
    return;
  }
  // Shift+Tab belongs to the page, not to this list.
  if (e.key === "Enter" || (e.key === "Tab" && !e.shiftKey)) {
    e.preventDefault();
    usePrompt(items[promptIndex].querySelector(".palette-label").textContent);
  }
});

/* ---------- composer height and context weight ---------- */

/* Grows with what is being written, up to a third of the viewport, then
   scrolls: a five-line task in a two-line box is a scroll bar you have to
   fight while composing. */
function autoGrow() {
  el.task.style.height = "auto";
  var cap = Math.round(window.innerHeight / 3);
  el.task.style.height = Math.min(el.task.scrollHeight, cap) + "px";
}
el.task.addEventListener("input", autoGrow);
window.addEventListener("resize", autoGrow);

/* Compaction is driven by transcript bytes against the model's context, and
   both numbers already exist; nothing was showing the ratio. */
function renderContextMeter() {
  var meta = currentSessionMeta();
  if (!meta || typeof meta.bytes !== "number" || !meta.bytes) {
    el.contextMeter.textContent = "";
    return;
  }
  var pair = (el.modelSelect.value || "").split(" ");
  var window_ = 0;
  (providerCache || []).forEach(function (prov) {
    if (prov.name !== pair[0]) return;
    (prov.models || []).forEach(function (m) { if (m.name === pair[1]) window_ = m.context_window || 0; });
  });
  if (!window_) {
    el.contextMeter.textContent = fmtBytes(meta.bytes) + " of history";
    return;
  }
  // Four bytes to the token is the same rough conversion the improve loop
  // budgets with; it is a gauge, not an accountant.
  var pct = Math.round((meta.bytes / 4) / window_ * 100);
  el.contextMeter.textContent = fmtBytes(meta.bytes) + " · about " + pct + "% of context";
}

/* ---------- conversation utilities ---------- */

el.sessionFilter.addEventListener("input", function () { renderSessionOptions(null); });

/* Compaction is otherwise a thing that happens to you: it fires on its own
   once a transcript passes agent.compact_threshold_bytes. This runs the same
   trim on demand, and reports the size it left behind. */
el.sessionCompact.addEventListener("click", function () {
  if (!currentSessionMeta()) {
    el.sessionStatus.textContent = "This conversation has no saved turns yet.";
    return;
  }
  if (busy) {
    el.sessionStatus.textContent = "Finish or stop the current run before compacting.";
    return;
  }
  // Irreversible: the dropped exchanges are gone from what the model can see.
  // Fork, Export and Copy all sit beside it and are not, so the difference
  // should not be left to the label.
  if (!window.confirm("Compact this conversation? The oldest exchanges are dropped permanently.")) return;
  el.sessionCompact.disabled = true;
  fetch("/api/sessions/" + encodeURIComponent(sessionId) + "/compact", { method: "POST" })
    .then(readJson)
    .then(function (d) {
      el.sessionStatus.textContent = "Compacted to " + fmtBytes(d.bytes) + ".";
      return loadSessions().then(function () {
        el.transcript.textContent = "";
        return fetch("/api/sessions/" + encodeURIComponent(sessionId))
          .then(function (r) { return r.json(); })
          .then(function (data) { renderSessionHistory(data.messages || []); });
      });
    })
    .catch(function (err) { el.sessionStatus.textContent = "Compact failed: " + err.message; })
    .then(function () { el.sessionCompact.disabled = false; });
});

/* One conversation as Markdown. Built from the transcript on screen rather
   than refetched, so what downloads is what you are looking at. */
function transcriptMarkdown() {
  var meta = currentSessionMeta();
  var lines = ["# " + ((meta && meta.title) || "clanker conversation"), "", "`" + sessionId + "`", ""];
  var turns = el.transcript.querySelectorAll(".turn");
  Array.prototype.forEach.call(turns, function (turn) {
    var task = turn.querySelector(".turn-you");
    var answer = turn.querySelector(".turn-answer");
    if (task) {
      var author = task.querySelector(".turn-author");
      var said = author ? task.textContent.slice(author.textContent.length) : task.textContent;
      lines.push("## " + said.trim(), "");
    }
    // turn.raw is the markdown as it arrived; textContent is what is left of
    // it after rendering, which is the fallback for a turn that never had a
    // buffer (a session replayed before this existed).
    var body = turn.markdownSource || (answer ? answer.textContent : "");
    if (body) lines.push(body.replace(/\s+$/, ""), "");
  });
  return lines.join("\n");
}

function downloadText(name, text, mime) {
  var blob = new Blob([text], { type: mime });
  var url = URL.createObjectURL(blob);
  var a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Revoked on the next tick: revoking synchronously races the download in
  // some browsers and produces an empty file.
  window.setTimeout(function () { URL.revokeObjectURL(url); }, 0);
}

el.sessionExport.addEventListener("click", function () {
  var md = transcriptMarkdown();
  if (!md.trim()) {
    el.sessionStatus.textContent = "Nothing to export yet.";
    return;
  }
  downloadText("clanker-" + sessionId.slice(0, 8) + ".md", md, "text/markdown");
  el.sessionStatus.textContent = "Exported as Markdown.";
});

el.sessionCopy.addEventListener("click", function () {
  copyText(transcriptMarkdown(), el.sessionCopy, "Copy all", el.transcript);
});

el.runCopy.addEventListener("click", function () {
  if (!lastBuilt) {
    el.runStatus.textContent = "No run is open.";
    return;
  }
  copyText(graphSummaryText(lastBuilt), el.runCopy, "Copy summary", el.runGraph);
});

/* ---------- board ---------- */

var board = { columns: [], cards: [] };
var openCardId = null;

/* A board belongs to a chatroom, because a card *is* a message in that room's
   log. The picker is the room list, so joining a room is what gives you its
   board; there is no separate "create a board" step and no board that exists
   without anyone subscribed to see it. */
function loadBoardRooms() {
  return fetch("/api/chat/rooms")
    .then(readJson)
    .then(function (d) {
      // The listing calls the field "room", not "name".
      var rooms = (d.rooms || []).map(function (r) { return typeof r === "string" ? r : r.room; });
      if (rooms.indexOf("board") === -1) rooms.unshift("board");
      var keep = el.boardRoom.value;
      el.boardRoom.textContent = "";
      van.add(el.boardRoom, rooms.map(function (name) { return T.option({ value: name }, name); }));
      if (keep && rooms.indexOf(keep) !== -1) el.boardRoom.value = keep;
      return loadBoard();
    })
    .catch(function () { return loadBoard(); });
}

function boardRoom() {
  return (el.boardRoom && el.boardRoom.value) || "board";
}

function loadBoard() {
  return fetch("/api/board?room=" + encodeURIComponent(boardRoom()))
    .then(readJson)
    .then(function (d) { renderBoard(d.board || { columns: [], cards: [] }); })
    .catch(function (err) { el.boardStatus.textContent = "Could not load the board: " + err.message; });
}

function postBoard(payload, status) {
  payload.room = boardRoom();
  return fetch("/api/board", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  })
    .then(readJson)
    .then(function (d) {
      renderBoard(d.board || board);
      if (status) el.boardStatus.textContent = status;
      return d;
    })
    .then(function () { return true; })
    .catch(function (err) {
      el.boardStatus.textContent = "Board: " + err.message;
      return false;
    });
}

function cardById(id) {
  for (var i = 0; i < board.cards.length; i++) {
    if (board.cards[i].id === id) return board.cards[i];
  }
  return null;
}

/* A card is blocked while anything it depends on has not reached the last
   column. Said on the card, because "why can I not start this" is the
   question a board exists to answer. */
function doneColumn() {
  return board.columns.length ? board.columns[board.columns.length - 1].id : "done";
}

function blockers(card) {
  return (card.depends_on || []).filter(function (id) {
    var dep = cardById(id);
    return dep && dep.column !== doneColumn();
  });
}

function dueState(card) {
  if (!card.deadline) return "";
  var left = card.deadline - Math.floor(Date.now() / 1000);
  if (left < 0) return "late";
  if (left < 2 * 24 * 60 * 60) return "soon";
  return "ok";
}

function fmtDeadline(ts) {
  if (!ts) return "";
  var d = new Date(ts * 1000);
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/* The board derives from the card set, the column set and the "only mine"
   filter. It used to clear #board and rebuild it, which is what forced the
   focus snapshot and the per-card edit drafts: a sub-action anywhere rebuilt
   everything. */
var boardState = van.state({ columns: [], cards: [], mine: false, me: "", open: null });

function renderBoard(next) {
  board = next || board;
  boardState.val = {
    columns: board.columns || [],
    cards: board.cards || [],
    mine: el.boardMine.checked,
    me: (el.instanceChip.textContent || "").trim(),
    open: openCardId
  };

  // The "new card" column choice follows the board rather than a fixed list.
  var keepCol = el.cardColumn.value;
  el.cardColumn.textContent = "";
  van.add(el.cardColumn, (board.columns || []).map(function (c) {
    return T.option({ value: c.id }, c.title);
  }));
  if (keepCol) el.cardColumn.value = keepCol;
}

function boardColumn(col, s) {
  var shown = s.cards
    .filter(function (c) { return c.column === col.id; })
    .filter(function (c) { return !s.mine || c.assignee === s.me; })
    .sort(function (a, b) { return (a.order || 0) - (b.order || 0); });

  var over = col.wip && shown.length > col.wip;
  var count = T.span({
    class: "board-col-count",
    "data-over": over ? "true" : null,
    // Over the limit is said in words as well as colour, because colour is the
    // one thing forced-colors and colour blindness both take away.
    title: over ? shown.length + " of " + col.wip + ", over the limit" : null
  }, shown.length + (col.wip ? " / " + col.wip : ""));

  var list = T.ul({
    class: "board-cards",
    "aria-label": col.title + ", " + shown.length + (shown.length === 1 ? " card" : " cards")
  }, shown.map(function (c) { return T.li(cardNode(c)); }));

  var colEl = T.section({
    class: "board-col",
    "data-column": col.id,
    "aria-labelledby": "board-col-" + col.id,
    ondragover: function (e) { e.preventDefault(); colEl.setAttribute("data-drop", "true"); },
    ondragleave: function () { colEl.removeAttribute("data-drop"); },
    ondrop: function (e) {
      e.preventDefault();
      colEl.removeAttribute("data-drop");
      var id = e.dataTransfer.getData("text/plain");
      if (id) postBoard({ op: "move", id: id, column: col.id }, "Moved to " + col.title + ".");
    }
  },
    T.div({ class: "board-col-head" },
      T.h3({ class: "board-col-title", id: "board-col-" + col.id }, col.title),
      count),
    list);
  return colEl;
}

bind(el.board, boardState, function (s) {
  var open = 0;
  var done = s.columns.length ? s.columns[s.columns.length - 1].id : "done";
  s.cards.forEach(function (c) {
    if (c.column !== done && (!s.mine || c.assignee === s.me)) open += 1;
  });
  setTabCount("board", open);
  el.boardEmpty.hidden = s.cards.length > 0;

  // The detail panel is rebuilt with the board because it shows one of these
  // cards; the edit draft and the focus snapshot carry across it.
  var focusSnap = captureFocus();
  if (s.open && cardById(s.open)) {
    showCardDetail(s.open);
    restoreFocus(focusSnap);
  } else {
    closeCardDetail();
  }

  return s.columns.map(function (col) { return boardColumn(col, s); });
});


function cardNode(c) {
  var b = document.createElement("button");
  b.type = "button";
  b.className = "card";
  b.draggable = true;
  b.setAttribute("data-card", c.id);
  if (c.id === openCardId) b.setAttribute("aria-current", "true");
  // The only way to move a card without a pointer, so it says so rather than
  // living in a source comment.
  b.setAttribute("aria-keyshortcuts", "Control+ArrowLeft Control+ArrowRight");
  b.title = "Ctrl or Cmd with the arrow keys moves this card between columns";

  var title = document.createElement("span");
  title.className = "card-title";
  title.textContent = c.title;
  b.appendChild(title);

  var meta = document.createElement("span");
  meta.className = "card-meta";

  if (c.priority && c.priority !== "normal") {
    var pr = document.createElement("span");
    pr.className = "card-flag";
    pr.setAttribute("data-priority", c.priority);
    pr.textContent = c.priority;
    meta.appendChild(pr);
  }
  if (c.deadline) {
    var due = document.createElement("span");
    due.className = "card-flag";
    due.setAttribute("data-due", dueState(c));
    // The state is in the words as well as the colour, which is the part
    // colour blindness and forced-colors both take away.
    var state = dueState(c);
    due.textContent = (state === "late" ? "late · " : state === "soon" ? "due soon · " : "due ") + fmtDeadline(c.deadline);
    meta.appendChild(due);
  }
  var blocked = blockers(c);
  if (blocked.length) {
    var bl = document.createElement("span");
    bl.className = "card-flag";
    bl.setAttribute("data-blocked", "true");
    bl.textContent = "blocked ×" + blocked.length;
    meta.appendChild(bl);
  }
  if ((c.subtasks || []).length) {
    var doneN = c.subtasks.filter(function (s) { return s.done; }).length;
    var prog = document.createElement("span");
    prog.className = "card-progress";
    prog.textContent = doneN + "/" + c.subtasks.length;
    meta.appendChild(prog);
  }
  if (c.assignee) {
    var who = document.createElement("span");
    who.textContent = c.assignee;
    meta.appendChild(who);
  }
  if (c.usage && c.usage.cost) {
    var cost = document.createElement("span");
    cost.textContent = fmtCost(c.usage.cost);
    meta.appendChild(cost);
  }
  if (meta.childNodes.length) b.appendChild(meta);

  b.addEventListener("click", function () {
    openCardId = openCardId === c.id ? null : c.id;
    renderBoard(board);
  });
  b.addEventListener("dragstart", function (e) {
    e.dataTransfer.setData("text/plain", c.id);
    e.dataTransfer.effectAllowed = "move";
    b.setAttribute("data-dragging", "true");
  });
  b.addEventListener("dragend", function () { b.removeAttribute("data-dragging"); });
  /* Dragging is not available to a keyboard, so the same move is on the
     arrow keys with a modifier, which is the only way this board is usable
     without a mouse. */
  b.addEventListener("keydown", function (e) {
    if (!e.ctrlKey && !e.metaKey) return;
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
    e.preventDefault();
    var ids = board.columns.map(function (col) { return col.id; });
    var at = ids.indexOf(c.column);
    var next = at + (e.key === "ArrowRight" ? 1 : -1);
    if (next < 0 || next >= ids.length) return;
    postBoard({ op: "move", id: c.id, column: ids[next] }, "Moved to " + board.columns[next].title + ".");
  });
  return b;
}

function closeCardDetail() {
  el.cardDetail.hidden = true;
  el.cardDetail.textContent = "";
}

/* Unsaved edits to a card's fields, keyed by card id.

   Every sub-action in the panel (ticking a subtask, adding a dependency,
   recording a log line) posts, which re-renders the board, which rebuilds this
   panel from the server's copy. Half-typed title and notes were thrown away
   each time, and focus went with them. The draft outlives the rebuild; saving
   or closing clears it. */
var cardDrafts = {};

function draftFor(id) {
  if (!cardDrafts[id]) cardDrafts[id] = {};
  return cardDrafts[id];
}

/* Which control had focus and where the caret was, so a rebuild triggered by
   an unrelated sub-action does not silently move it. */
function captureFocus() {
  var a = document.activeElement;
  if (!a || !a.id || !el.cardDetail.contains(a)) return null;
  var at = null;
  try { at = { start: a.selectionStart, end: a.selectionEnd }; } catch (e) {}
  return { id: a.id, at: at };
}

function restoreFocus(snap) {
  if (!snap) return;
  var node = document.getElementById(snap.id);
  if (!node) return;
  node.focus();
  if (!snap.at) return;
  try { node.setSelectionRange(snap.at.start, snap.at.end); } catch (e) {}
}

/* Binds a field to the card's draft: what you typed survives a rebuild, and
   the saved value is what the server last confirmed. */
function bindDraft(control, id, key, saved) {
  var draft = draftFor(id);
  control.value = draft[key] !== undefined ? draft[key] : (saved == null ? "" : saved);
  control.addEventListener("input", function () {
    if (control.value === (saved == null ? "" : String(saved))) delete draft[key];
    else draft[key] = control.value;
  });
  return control;
}

function detailSection(parent, title) {
  var head = document.createElement("p");
  head.className = "detail-head";
  head.textContent = title;
  parent.appendChild(head);
  var box = document.createElement("div");
  box.className = "detail-body";
  parent.appendChild(box);
  return box;
}

function fieldRow(parent, label, control) {
  var row = document.createElement("div");
  row.className = "detail-row";
  var l = document.createElement("label");
  l.textContent = label;
  l.htmlFor = control.id;
  row.appendChild(l);
  row.appendChild(control);
  parent.appendChild(row);
  return row;
}

function input(id, type, value, placeholder) {
  var i = document.createElement("input");
  i.type = type;
  i.id = id;
  i.value = value == null ? "" : value;
  if (placeholder) i.placeholder = placeholder;
  return i;
}

/* Everything about one card, in the order you ask about it: what it is, who
   has it and when it is due, what it is waiting on, what is left to do,
   what it has cost, and what has happened to it. */
function showCardDetail(id) {
  var c = cardById(id);
  if (!c) return closeCardDetail();
  el.cardDetail.textContent = "";
  el.cardDetail.hidden = false;

  var head = document.createElement("div");
  head.className = "run-detail-head";
  var title = document.createElement("span");
  title.className = "run-detail-title";
  title.textContent = c.title;
  var close = document.createElement("button");
  close.type = "button";
  close.className = "secondary";
  close.textContent = "Close";
  close.addEventListener("click", function () {
    delete cardDrafts[c.id];
    openCardId = null;
    renderBoard(board);
  });
  head.appendChild(title);
  head.appendChild(close);
  el.cardDetail.appendChild(head);

  // ---- fields ----
  var fields = detailSection(el.cardDetail, "Card");
  var titleIn = input("card-f-title", "text", "");
  titleIn.maxLength = 500;
  bindDraft(titleIn, c.id, "title", c.title);
  fieldRow(fields, "Title", titleIn);

  var bodyIn = document.createElement("textarea");
  bodyIn.id = "card-f-body";
  bodyIn.rows = 3;
  bindDraft(bodyIn, c.id, "body", c.body);
  fieldRow(fields, "Notes", bodyIn);

  var assignIn = input("card-f-assignee", "text", "", "unassigned");
  bindDraft(assignIn, c.id, "assignee", c.assignee);
  fieldRow(fields, "Assignee", assignIn);

  var prioIn = document.createElement("select");
  prioIn.id = "card-f-priority";
  ["low", "normal", "high"].forEach(function (v) {
    var o = document.createElement("option");
    o.value = v;
    o.textContent = v;
    prioIn.appendChild(o);
  });
  var prioDraft = draftFor(c.id);
  prioIn.value = prioDraft.priority !== undefined ? prioDraft.priority : (c.priority || "normal");
  prioIn.addEventListener("change", function () {
    if (prioIn.value === (c.priority || "normal")) delete prioDraft.priority;
    else prioDraft.priority = prioIn.value;
  });
  fieldRow(fields, "Priority", prioIn);

  // A date input, because a deadline typed as a unix timestamp is not a
  // deadline anyone will set twice.
  var dueIn = input("card-f-deadline", "date", "");
  bindDraft(dueIn, c.id, "deadline", c.deadline ? new Date(c.deadline * 1000).toISOString().slice(0, 10) : "");
  fieldRow(fields, "Deadline", dueIn);

  var save = document.createElement("button");
  save.type = "button";
  save.className = "secondary";
  save.textContent = "Save card";
  save.addEventListener("click", function () {
    var deadline = 0;
    if (dueIn.value) {
      var parsed = Date.parse(dueIn.value + "T23:59:59");
      if (!isNaN(parsed)) deadline = Math.floor(parsed / 1000);
    }
    delete cardDrafts[c.id];
    postBoard({
      op: "update", id: c.id,
      title: titleIn.value, body: bodyIn.value,
      assignee: assignIn.value, priority: prioIn.value, deadline: deadline
    }, "Card saved.");
  });
  fields.appendChild(save);

  var takeIt = document.createElement("button");
  takeIt.type = "button";
  takeIt.className = "secondary";
  takeIt.textContent = "Assign to me";
  takeIt.addEventListener("click", function () {
    postBoard({ op: "update", id: c.id, assignee: (el.instanceChip.textContent || "").trim() }, "Assigned.");
  });
  fields.appendChild(takeIt);

  var del = document.createElement("button");
  del.type = "button";
  del.className = "secondary danger";
  del.textContent = "Delete card";
  del.addEventListener("click", function () {
    if (!window.confirm("Delete \"" + c.title + "\"? Its log and usage go with it.")) return;
    delete cardDrafts[c.id];
    openCardId = null;
    postBoard({ op: "delete", id: c.id }, "Card deleted.");
  });
  fields.appendChild(del);

  // ---- subtasks ----
  var subs = detailSection(el.cardDetail, "Subtasks");
  (c.subtasks || []).forEach(function (s) {
    var row = document.createElement("div");
    row.className = "detail-row";
    var box = document.createElement("input");
    box.type = "checkbox";
    box.checked = !!s.done;
    box.id = "sub-" + s.id;
    box.addEventListener("change", function () {
      var wanted = box.checked;
      postBoard({ op: "subtask_toggle", id: c.id, subtask_id: s.id, done: wanted }, null)
        .then(function (ok) {
          // The click already moved the box; put it back rather than leave a
          // state the server refused on screen.
          if (!ok) box.checked = !wanted;
        });
    });
    var lab = document.createElement("label");
    lab.htmlFor = box.id;
    lab.textContent = s.text;
    lab.className = "subtask";
    lab.setAttribute("data-done", String(!!s.done));
    var drop = document.createElement("button");
    drop.type = "button";
    drop.className = "rail-pin";
    drop.appendChild(icon("strike", 14));
    drop.setAttribute("aria-label", "Remove subtask: " + s.text);
    drop.addEventListener("click", function () {
      postBoard({ op: "subtask_remove", id: c.id, subtask_id: s.id }, "Removed subtask: " + s.text);
    });
    row.appendChild(box);
    row.appendChild(lab);
    row.appendChild(drop);
    subs.appendChild(row);
  });
  var subIn = input("card-f-subtask", "text", "", "Add a subtask…");
  subIn.maxLength = 500;
  subIn.addEventListener("keydown", function (e) {
    if (e.key !== "Enter" || !subIn.value.trim()) return;
    e.preventDefault();
    postBoard({ op: "subtask_add", id: c.id, text: subIn.value.trim() }, null);
  });
  subs.appendChild(subIn);

  // ---- dependencies ----
  var deps = detailSection(el.cardDetail, "Waiting on");
  (c.depends_on || []).forEach(function (depId) {
    var dep = cardById(depId);
    var row = document.createElement("div");
    row.className = "detail-row";
    var name = document.createElement("span");
    name.textContent = dep ? dep.title + "  ·  " + dep.column : depId + " (missing)";
    if (dep && dep.column !== doneColumn()) name.className = "dep-open";
    var drop = document.createElement("button");
    drop.type = "button";
    drop.className = "rail-pin";
    drop.appendChild(icon("strike", 14));
    drop.setAttribute("aria-label", "Stop waiting on " + (dep ? dep.title : depId));
    drop.addEventListener("click", function () {
      postBoard({ op: "depend_remove", id: c.id, depends_on: depId }, null);
    });
    row.appendChild(name);
    row.appendChild(drop);
    deps.appendChild(row);
  });
  var depPick = document.createElement("select");
  depPick.id = "card-f-dep";
  var blank = document.createElement("option");
  blank.value = "";
  blank.textContent = "Add a dependency…";
  depPick.appendChild(blank);
  board.cards.forEach(function (other) {
    if (other.id === c.id || (c.depends_on || []).indexOf(other.id) !== -1) return;
    var o = document.createElement("option");
    o.value = other.id;
    o.textContent = other.title;
    depPick.appendChild(o);
  });
  depPick.addEventListener("change", function () {
    if (!depPick.value) return;
    postBoard({ op: "depend_add", id: c.id, depends_on: depPick.value }, null);
  });
  deps.appendChild(depPick);

  // ---- usage ----
  var usage = c.usage || {};
  if (usage.prompt_tokens || usage.completion_tokens || usage.cost) {
    var u = detailSection(el.cardDetail, "Cost so far");
    var line = document.createElement("p");
    line.className = "meta";
    line.textContent = fmtInt(usage.prompt_tokens || 0) + " prompt + " + fmtInt(usage.completion_tokens || 0) +
      " completion  ·  " + fmtCost(usage.cost || 0) +
      ((usage.runs || []).length ? "  ·  " + usage.runs.length + (usage.runs.length === 1 ? " run" : " runs") : "");
    u.appendChild(line);
    (usage.runs || []).forEach(function (rid) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "secondary";
      b.textContent = rid;
      b.title = "Open this run's graph";
      b.addEventListener("click", function () { openRun(rid); });
      u.appendChild(b);
    });
  }

  // ---- log ----
  var logBox = detailSection(el.cardDetail, "Activity");
  var entries = (c.log || []).slice().reverse();
  if (!entries.length) {
    var empty = document.createElement("p");
    empty.className = "meta";
    empty.textContent = "Nothing recorded yet.";
    logBox.appendChild(empty);
  }
  entries.forEach(function (e) {
    var row = document.createElement("p");
    row.className = "log-entry";
    var when = document.createElement("span");
    when.className = "log-when";
    when.textContent = e.ts ? formatChatTime(e.ts) : "";
    var who = document.createElement("span");
    who.className = "log-who";
    who.textContent = e.who || "someone";
    var what = document.createElement("span");
    what.textContent = e.what || "";
    row.appendChild(when);
    row.appendChild(who);
    row.appendChild(what);
    logBox.appendChild(row);
  });
  var noteIn = input("card-f-log", "text", "", "Record what you did…");
  noteIn.maxLength = 2000;
  noteIn.addEventListener("keydown", function (e) {
    if (e.key !== "Enter" || !noteIn.value.trim()) return;
    e.preventDefault();
    postBoard({ op: "log", id: c.id, what: noteIn.value.trim() }, "Recorded.");
  });
  logBox.appendChild(noteIn);
}

el.cardForm.addEventListener("submit", function (e) {
  e.preventDefault();
  var title = el.cardTitle.value.trim();
  if (!title) return;
  postBoard({ op: "create", title: title, column: el.cardColumn.value }, "Card added.").then(function (ok) {
    if (ok) el.cardTitle.value = "";
  });
});

/* Refresh buttons that do not disable can be fired twice and say nothing while
   they work; five of the seven already did this. */
function wireRefresh(button, load) {
  button.addEventListener("click", function () {
    button.disabled = true;
    var done = load();
    if (done && typeof done.then === "function") {
      done.then(function () { button.disabled = false; }, function () { button.disabled = false; });
    } else {
      button.disabled = false;
    }
  });
}

wireRefresh(el.boardRefresh, loadBoard);
el.boardRoom.addEventListener("change", function () { loadBoard(); });


/* ---------- web UI plugins ----------

   The page is itself served by a WASM tool, so it is already a plugin; this
   lets it host plugins of its own. A plugin is a directory under
   tools/webui-plugins/ with a manifest and an app.js, served same-origin so
   the strict CSP covers it without widening: no eval, no other origin, and a
   disabled plugin's assets are never served at all.

   A view a plugin registers is an ordinary view: same rail button, same panel,
   same digit shortcut, same URL fragment. */

var pluginViews = {};

function pluginApi() {
  return {
    getJSON: function (path) {
      return fetch(path).then(function (r) {
        return r.json().then(function (d) {
          if (!r.ok) throw new Error(d.error || "HTTP " + r.status);
          return d;
        });
      });
    },
    el: function (tag, className, text) {
      var node = document.createElement(tag);
      if (className) node.className = className;
      if (text != null) node.textContent = text;
      return node;
    },
    status: function (message) { el.webuiPluginsStatus.textContent = message; },
    // The page's own formatters, so a plugin's numbers read like the rest.
    fmt: { bytes: fmtBytes, int: fmtInt, cost: fmtCost, time: formatChatTime },
    /* VanJS and VanUI, so a plugin can build reactive DOM declaratively rather
       than hand-rolling appendChild chains, and can reach for a Modal or Tabs
       without shipping its own. Both are vendored and same-origin, so a plugin
       using them adds no request and no policy exception. */
    van: window.van,
    ui: {
      Modal: window.Modal, Tabs: window.Tabs, Banner: window.Banner,
      Tooltip: window.Tooltip, Toggle: window.Toggle, Await: window.Await,
      MessageBoard: window.MessageBoard, OptionGroup: window.OptionGroup,
      choose: window.choose
    },
    showView: function (id) { showView(id, false); }
  };
}

/* The whole surface a plugin sees. Deliberately small: everything here is
   something the page is promising to keep working. */
window.clanker = {
  registerView: function (spec) {
    if (!spec || !spec.id || typeof spec.mount !== "function") return;
    if (VIEWS.indexOf(spec.id) !== -1) return;
    var group = spec.group || "Watch";

    var panel = document.createElement("div");
    panel.className = "view";
    panel.id = "view-" + spec.id;
    panel.setAttribute("role", "tabpanel");
    panel.setAttribute("aria-labelledby", "tab-" + spec.id);
    panel.tabIndex = -1;
    panel.hidden = true;
    var section = document.createElement("section");
    panel.appendChild(section);
    document.getElementById("main").appendChild(panel);

    var tab = document.createElement("button");
    tab.type = "button";
    tab.className = "rail-tab";
    tab.setAttribute("role", "tab");
    tab.id = "tab-" + spec.id;
    tab.setAttribute("aria-controls", "view-" + spec.id);
    tab.setAttribute("aria-selected", "false");
    tab.tabIndex = -1;
    tab.setAttribute("data-view", spec.id);
    tab.textContent = spec.title || spec.id;

    // Placed under its group's heading rather than appended, so a plugin's
    // view sits where its kind of thing already lives.
    var nav = document.querySelector(".rail-nav");
    var headings = nav.querySelectorAll(".rail-group");
    var placed = false;
    for (var i = 0; i < headings.length; i++) {
      if (headings[i].textContent !== group) continue;
      var at = headings[i].nextElementSibling;
      while (at && at.nextElementSibling && !at.nextElementSibling.classList.contains("rail-group")) {
        at = at.nextElementSibling;
      }
      nav.insertBefore(tab, at ? at.nextElementSibling : null);
      placed = true;
      break;
    }
    if (!placed) nav.appendChild(tab);

    VIEWS.push(spec.id);
    pluginViews[spec.id] = { spec: spec, section: section };
    var mounted = false;
    viewLoaders[spec.id] = function () {
      if (!mounted) {
        mounted = true;
        return spec.mount.call(spec, section, pluginApi());
      }
      if (typeof spec.refresh === "function") return spec.refresh.call(spec, section, pluginApi());
      return null;
    };
    wireTab(tab, VIEWS.length - 1);
  }
};

function loadPluginAssets(list) {
  var pending = [];
  list.forEach(function (p) {
    if (!p.enabled) return;
    if (p.has_css && !document.querySelector('link[data-plugin="' + p.name + '"]')) {
      var link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = "/webui/plugins/" + encodeURIComponent(p.name) + "/app.css";
      link.setAttribute("data-plugin", p.name);
      document.head.appendChild(link);
    }
    if (document.querySelector('script[data-plugin="' + p.name + '"]')) return;
    pending.push(new Promise(function (resolve) {
      var s = document.createElement("script");
      s.src = "/webui/plugins/" + encodeURIComponent(p.name) + "/app.js";
      s.setAttribute("data-plugin", p.name);
      // A plugin that fails to load must not take the page down with it.
      s.onload = function () { resolve(true); };
      s.onerror = function () {
        el.webuiPluginsStatus.textContent = "Plugin " + p.name + " failed to load.";
        resolve(false);
      };
      document.head.appendChild(s);
    }));
  });
  return Promise.all(pending);
}

function loadWebuiPlugins() {
  return fetch("/api/webui/plugins")
    .then(readJson)
    .then(function (d) {
      renderWebuiPlugins(d.plugins || []);
      return loadPluginAssets(d.plugins || []);
    })
    .catch(function (err) { el.webuiPluginsStatus.textContent = "Could not load plugins: " + err.message; });
}

function renderWebuiPlugins(list) {
  el.webuiPlugins.textContent = "";
  if (!list.length) {
    var none = document.createElement("p");
    none.className = "run-empty";
    none.textContent = "No plugins installed. A plugin is a directory under tools/webui-plugins/ — see its README.";
    el.webuiPlugins.appendChild(none);
    return;
  }
  list.forEach(function (p) {
    var row = document.createElement("div");
    row.className = "webui-plugin";

    var box = document.createElement("input");
    box.type = "checkbox";
    box.id = "plugin-" + p.name;
    box.checked = !!p.enabled;
    box.addEventListener("change", function () {
      box.disabled = true;
      fetch("/api/webui/plugins", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: p.name, enabled: box.checked })
      })
        .then(readJson)
        .then(function (d) {
          var nowOn = box.checked;
          renderWebuiPlugins(d.plugins || []);
          if (nowOn) {
            return loadPluginAssets(d.plugins || []).then(function () {
              el.webuiPluginsStatus.textContent = (p.title || p.name) + " enabled.";
            });
          }
          // Script already run cannot be recalled, and saying otherwise would
          // misdescribe what is running.
          el.webuiPluginsStatus.textContent = (p.title || p.name) + " disabled. Reload to remove it from this page.";
        })
        .catch(function (err) {
          // Same reason as the subtask box: the click moved it, the server did
          // not agree, so it goes back.
          box.checked = !box.checked;
          el.webuiPluginsStatus.textContent = "Plugin: " + err.message;
        })
        .then(function () { box.disabled = false; });
    });

    var name = document.createElement("label");
    name.className = "webui-plugin-name";
    name.htmlFor = box.id;
    name.textContent = p.title || p.name;

    var desc = document.createElement("span");
    desc.className = "webui-plugin-desc";
    desc.textContent = p.description || "";

    var group = document.createElement("span");
    group.className = "webui-plugin-group";
    group.textContent = p.group || "";

    row.appendChild(box);
    row.appendChild(name);
    row.appendChild(desc);
    row.appendChild(group);
    el.webuiPlugins.appendChild(row);
  });
}

el.webuiPluginsRefresh.addEventListener("click", function () { loadWebuiPlugins(); });

/* ---------- logs ---------- */

function loadLogList() {
  return fetch("/api/logs")
    .then(readJson)
    .then(function (d) {
      var logs = (d.logs || []).slice().sort(function (a, b) { return a.name < b.name ? 1 : -1; });
      var keep = el.logSelect.value;
      el.logSelect.textContent = "";
      logs.forEach(function (l) {
        var opt = document.createElement("option");
        opt.value = l.name;
        opt.textContent = l.name + "  ·  " + fmtBytes(l.bytes);
        el.logSelect.appendChild(opt);
      });
      if (!logs.length) {
        el.logView.textContent = "No logs yet. clanker writes them under state/logs/.";
        return;
      }
      el.logSelect.value = keep && el.logSelect.querySelector('option[value="' + keep.replace(/"/g, '\\"') + '"]') ? keep : logs[0].name;
      return loadLog(el.logSelect.value);
    })
    .catch(function (err) { el.logsStatus.textContent = "Could not list logs: " + err.message; });
}

function loadLog(name) {
  if (!name) return Promise.resolve();
  return fetch("/api/logs/" + encodeURIComponent(name))
    .then(readJson)
    .then(function (d) {
      el.logView.textContent = d.text || "(empty)";
      // Newest lines are at the bottom, which is where a tail is read from.
      el.logView.scrollTop = el.logView.scrollHeight;
      el.logsStatus.textContent = "Showing the tail of " + d.name + " (" + fmtBytes(d.bytes) + " total).";
    })
    .catch(function (err) { el.logsStatus.textContent = "Could not read log: " + err.message; });
}

el.logSelect.addEventListener("change", function () { loadLog(el.logSelect.value); });
el.logsRefresh.addEventListener("click", function () { loadLogList(); });

/* ---------- overlays: command palette and shortcut sheet ---------- */

var lastFocus = null;

function openOverlay(node, toFocus) {
  lastFocus = document.activeElement;
  node.hidden = false;
  if (toFocus) toFocus.focus();
}

function closeOverlay(node) {
  node.hidden = true;
  if (lastFocus && lastFocus.focus) lastFocus.focus();
  lastFocus = null;
}

/* aria-modal="true" claims the rest of the page is unreachable while a dialog
   is open, but nothing enforced that: Tab could walk off the last button in
   the box and land on rail/header controls sitting under the scrim. This
   wraps Tab back to the other end of the dialog instead. */
function focusableIn(node) {
  return Array.prototype.slice
    .call(node.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'))
    .filter(function (n) { return n.getClientRects().length > 0; });
}
function trapOverlayTab(e, node) {
  var items = focusableIn(node);
  if (!items.length) { e.preventDefault(); return; }
  var first = items[0], last = items[items.length - 1];
  var atEdge = e.shiftKey ? (document.activeElement === first || !node.contains(document.activeElement))
    : (document.activeElement === last || !node.contains(document.activeElement));
  if (atEdge) {
    e.preventDefault();
    (e.shiftKey ? last : first).focus();
  }
}

/* A styled replacement for window.prompt(): resolves to the entered text, or
   null if cancelled or dismissed. opts.suggestions backs the input with a
   datalist so a value that already exists (a workspace name, say) can be
   picked rather than retyped, which is the part window.prompt could not do. */
var textPromptResolve = null;
function textPrompt(opts) {
  opts = opts || {};
  el.textPromptTitle.textContent = opts.title || "Enter a value";
  el.textPromptLabel.textContent = opts.label || "Value";
  el.textPromptInput.value = opts.value || "";
  el.textPromptHint.textContent = opts.hint || "";
  el.textPromptOptions.textContent = "";
  (opts.suggestions || []).forEach(function (s) {
    var o = document.createElement("option");
    o.value = s;
    el.textPromptOptions.appendChild(o);
  });
  openOverlay(el.textPrompt, el.textPromptInput);
  el.textPromptInput.select();
  return new Promise(function (resolve) { textPromptResolve = resolve; });
}
function finishTextPrompt(value) {
  if (el.textPrompt.hidden) return;
  closeOverlay(el.textPrompt);
  var resolve = textPromptResolve;
  textPromptResolve = null;
  if (resolve) resolve(value);
}
el.textPromptForm.addEventListener("submit", function (e) {
  e.preventDefault();
  finishTextPrompt(el.textPromptInput.value);
});
el.textPromptCancel.addEventListener("click", function () { finishTextPrompt(null); });
el.textPrompt.addEventListener("mousedown", function (e) {
  if (e.target === el.textPrompt) finishTextPrompt(null);
});

var SHORTCUTS = [
  ["Ctrl/⌘ + K", "Jump to a view, conversation, run, tool or action"],
  ["?", "This list"],
  ["1 – 7", "Go to a view by number"],
  ["← →", "Move between tabs when one is focused"],
  ["Ctrl/⌘ + Enter", "Run the task in the composer"],
  ["Ctrl/⌘ + ← →", "Move the focused board card between columns"],
  ["Esc", "Close an overlay, or stop a running task"]
];

SHORTCUTS.forEach(function (pair) {
  var dt = document.createElement("dt");
  dt.textContent = pair[0];
  var dd = document.createElement("dd");
  dd.textContent = pair[1];
  el.shortcuts.appendChild(dt);
  el.shortcuts.appendChild(dd);
});

van.add(el.helpOpen, icon("help", 15));
el.helpOpen.addEventListener("click", function () { openOverlay(el.help, el.helpClose); });
el.helpClose.addEventListener("click", function () { closeOverlay(el.help); });

/* Everything reachable, in one list. Built fresh on open so it reflects the
   conversations, runs and tools actually loaded rather than a stale copy. */
function paletteEntries() {
  var out = [];
  VIEWS.forEach(function (v, i) {
    out.push({ kind: "view", label: v.charAt(0).toUpperCase() + v.slice(1) + "  (" + (i + 1) + ")", run: function () { showView(v, true); } });
  });
  out.push({ kind: "action", label: "New chat", run: function () { el.newChat.click(); } });
  out.push({ kind: "action", label: "Fork this conversation", run: function () { el.sessionFork.click(); } });
  out.push({ kind: "action", label: "Compact this conversation", run: function () { el.sessionCompact.click(); } });
  out.push({ kind: "action", label: "Export this conversation as Markdown", run: function () { el.sessionExport.click(); } });
  out.push({ kind: "action", label: "Cycle theme", run: function () { el.themeToggle.click(); } });
  out.push({ kind: "action", label: "Keyboard shortcuts", run: function () { openOverlay(el.help, el.helpClose); } });
  knownSessions.forEach(function (s) {
    out.push({ kind: "chat", label: sessionLabel(s), run: function () { showView("chat", false); switchSession(s.id); } });
  });
  allRuns.forEach(function (r) {
    out.push({ kind: "run", label: runLabel(r), run: function () { openRun(r.run_id); } });
  });
  board.cards.forEach(function (c) {
    out.push({ kind: "card", label: c.title + "  ·  " + c.column, run: function () {
      openCardId = c.id;
      showView("board", true);
      renderBoard(board);
    } });
  });
  return out;
}

var paletteItems = [];
var paletteIndex = 0;

/* Subsequence matching, the same thing an editor's file finder does: "grp"
   finds "run graph". Cheap, and it forgives the order you remember. */
function fuzzyMatch(query, text) {
  if (!query) return true;
  var t = text.toLowerCase();
  var qi = 0;
  for (var i = 0; i < t.length && qi < query.length; i++) {
    if (t.charAt(i) === query.charAt(qi)) qi += 1;
  }
  return qi === query.length;
}

function renderPalette() {
  var q = el.paletteInput.value.trim().toLowerCase();
  var all = paletteEntries();
  paletteItems = [];
  el.paletteList.textContent = "";
  for (var i = 0; i < all.length && paletteItems.length < 40; i++) {
    if (!fuzzyMatch(q, all[i].kind + " " + all[i].label)) continue;
    paletteItems.push(all[i]);
  }
  if (paletteIndex >= paletteItems.length) paletteIndex = 0;
  paletteItems.forEach(function (entry, i) {
    var li = document.createElement("li");
    li.className = "palette-item";
    li.id = "palette-item-" + i;
    li.setAttribute("role", "option");
    li.setAttribute("aria-selected", String(i === paletteIndex));
    var kind = document.createElement("span");
    kind.className = "palette-kind";
    kind.textContent = entry.kind;
    var label = document.createElement("span");
    label.className = "palette-label";
    label.textContent = entry.label;
    li.appendChild(kind);
    li.appendChild(label);
    li.addEventListener("click", function () { runPalette(i); });
    el.paletteList.appendChild(li);
  });
  if (!paletteItems.length) {
    var empty = document.createElement("li");
    empty.className = "palette-item";
    empty.textContent = "Nothing matches.";
    el.paletteList.appendChild(empty);
  }
  el.paletteInput.setAttribute("aria-activedescendant", paletteItems.length ? "palette-item-" + paletteIndex : "");
}

function runPalette(i) {
  var entry = paletteItems[i];
  closeOverlay(el.palette);
  if (entry) entry.run();
}

function openPalette() {
  el.paletteInput.value = "";
  paletteIndex = 0;
  openOverlay(el.palette, el.paletteInput);
  renderPalette();
}

el.paletteOpen.addEventListener("click", openPalette);
el.paletteInput.addEventListener("input", function () { paletteIndex = 0; renderPalette(); });
el.paletteInput.addEventListener("keydown", function (e) {
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    if (!paletteItems.length) return;
    var step = e.key === "ArrowDown" ? 1 : -1;
    paletteIndex = (paletteIndex + step + paletteItems.length) % paletteItems.length;
    renderPalette();
    var sel = document.getElementById("palette-item-" + paletteIndex);
    if (sel && sel.scrollIntoView) sel.scrollIntoView({ block: "nearest" });
    return;
  }
  if (e.key === "Enter") {
    e.preventDefault();
    runPalette(paletteIndex);
  }
});

/* Clicking the scrim closes; clicking the box does not. */
[el.palette, el.help].forEach(function (node) {
  node.addEventListener("mousedown", function (e) {
    if (e.target === node) closeOverlay(node);
  });
});

document.addEventListener("keydown", function (e) {
  if (e.key === "Tab") {
    if (!el.textPrompt.hidden) { trapOverlayTab(e, el.textPrompt); return; }
    if (!el.palette.hidden) { trapOverlayTab(e, el.palette); return; }
    if (!el.help.hidden) { trapOverlayTab(e, el.help); return; }
    return;
  }
  if (e.key === "Escape") {
    if (!el.textPrompt.hidden) { finishTextPrompt(null); e.preventDefault(); return; }
    if (!el.palette.hidden) { closeOverlay(el.palette); e.preventDefault(); return; }
    if (el.rail.getAttribute("data-open") === "true") { setRailOpen(false); el.railToggle.focus(); e.preventDefault(); return; }
    if (!el.help.hidden) { closeOverlay(el.help); e.preventDefault(); return; }
    return;
  }
  if ((e.ctrlKey || e.metaKey) && (e.key === "k" || e.key === "K")) {
    e.preventDefault();
    if (el.palette.hidden) openPalette(); else closeOverlay(el.palette);
    return;
  }
  // "?" is a plain key, so it must never fire while something is being typed.
  if (e.key === "?" && !e.ctrlKey && !e.metaKey && !e.altKey) {
    var t = e.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
    e.preventDefault();
    openOverlay(el.help, el.helpClose);
  }
});

renderSessionChip();
renderSessionOptions([]);
setBusy(false);
// Status is cheap and gives the header its identity chips, so it loads
// regardless of which view opened. Rooms wait for it because they need the
// instance name to tell this clanker's messages from a peer's.
/* Boot order is chosen for the first draw.

   The opening view and the conversation list are what the page has to show;
   everything else can arrive afterwards without the user waiting for it. The
   model picker in particular reads every provider's model list, which nothing
   on screen needs until the composer is used.

   Plugins are the exception, and only sometimes: a plugin registers a view, so
   a deep link to one cannot resolve until they have loaded. When the hash names
   a view that already exists, plugins wait with everything else. */
var openingHash = window.location.hash.replace("#", "");
var needsPluginsNow = !!openingHash && VIEWS.indexOf(openingHash) === -1;

function afterFirstDraw(work) {
  if (window.requestIdleCallback) window.requestIdleCallback(work, { timeout: 2000 });
  else window.setTimeout(work, 0);
}

if (needsPluginsNow) {
  loadWebuiPlugins().then(function () {
    if (VIEWS.indexOf(openingHash) !== -1) showView(openingHash, false);
  });
}

afterFirstDraw(function () {
  loadStatus();
  loadProviders();
  if (!needsPluginsNow) loadWebuiPlugins();
});
syncSubmitLabel();
// Only the opening view's data is fetched now; the rest load when opened.
showView(window.location.hash.replace("#", ""), false);
/* Reopening the page used to show an empty transcript even when the picker
   said the conversation had nine messages: nothing ever fetched them. The
   conversation you were last in is replayed, so a reload resumes rather
   than restarts. */
loadSessions().then(function () {
  if (!currentSessionMeta()) {
    syncTranscriptEmpty();
    return;
  }
  return fetch("/api/sessions/" + encodeURIComponent(sessionId))
    .then(readJson)
    .then(function (data) {
      renderSessionHistory(data.messages || []);
      syncTranscriptEmpty();
      applyTurnFilter();
      syncScrollButton();
    })
    .catch(function () { syncTranscriptEmpty(); });
});
});
