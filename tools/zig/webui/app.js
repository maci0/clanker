import { readJson as utilReadJson, newSessionId as utilNewSessionId, fmtBytes as utilFmtBytes, clip as utilClip, sessionLabel as utilSessionLabel, recencyGroup as utilRecencyGroup, isSafeLinkUrl as utilIsSafeLinkUrl, splitRow as utilSplitRow, prettyJsonIfPossible as utilPrettyJsonIfPossible, fmtInt as utilFmtInt, fmtMs as utilFmtMs, fmtCost as utilFmtCost, formatChatTime as utilFormatChatTime, fmtDeadline as utilFmtDeadline, fuzzyMatch as utilFuzzyMatch } from "./core/utils.js";
import { T as vanT, bind as vanBind, toast as uiToast, skeletonRows as vanSkeletonRows, setTurnPhase as vanSetTurnPhase, UI as vanUI } from "./core/ui.js";
import { ICON_PATHS as iconPaths, icon as iconFn } from "./core/icons.js";
import { vendorLoads as vendorLoadsMod, loadVendor as loadVendorMod, loadD3 as loadD3Mod, loadHljs as loadHljsMod, registerToml as registerTomlMod, reducedMotion as reducedMotionMod, copyText as copyTextMod } from "./core/vendor.js";
import { THEMES as THEMESMod, loadTheme as loadThemeMod, applyTheme as applyThemeMod } from "./core/theme.js";
import { dmRoom as dmRoomMod, dmSafeName as dmSafeNameMod, dmPartner as dmPartnerMod, isDm as isDmMod, clankerMark as clankerMarkMod, CLANKER_MARKS as CLANKER_MARKSMod } from "./core/chat.js";
import { runLabel as runLabelMod, modelLabel as modelLabelMod, chatRoomLabel as chatRoomLabelMod } from "./core/labels.js";
import { goalSortKey as goalSortKeyMod, goalFields as goalFieldsMod } from "./core/goals.js";
import { makeLineSplitter as makeLineSplitterMod } from "./core/stream.js";
import { INLINE_RE as mdINLINE_RE, inlineInto as mdInlineInto, paragraphInto as mdParagraphInto, tableRow as mdTableRow, renderMarkdown as mdRenderMarkdown, highlightInto as mdHighlightInto, buildCodeBlock as mdBuildCodeBlock, finalizeAnswer as mdFinalizeAnswer } from "./lib/markdown.js";
import { metricsFor as graphMetricsFor, buildStages as graphBuildStages, graphSummaryText as graphSummaryTextMod, toDagInput as graphToDagInput, buildIncompleteNode as graphBuildIncompleteNode, buildNodeBox as graphBuildNodeBox, layoutGraph as graphLayoutGraph } from "./lib/graph.js";
import { BOARD_COLUMNS as BOARD_COLUMNSMod, boardActionLine as boardActionLineMod, doneColumn as doneColumnMod, blockers as blockersMod, dueState as dueStateMod } from "./lib/board.js";
import { openOverlay as overlayOpen, closeOverlay as overlayClose, focusableIn as overlayFocusableIn, trapOverlayTab as overlayTrapTab } from "./core/overlay.js";
import { clearMarks as searchClear, markMatches as searchMark } from "./core/search.js";
import { loadPrompts as compLoadPrompts, savePrompts as compSavePrompts, promptQuery as compPromptQuery, autoGrow as compAutoGrow, contextLabel as compContextLabel, transcriptMarkdown as compTranscriptMarkdown, downloadText as compDownloadText } from "./core/composer.js";
import { nearBottom as scrollNearBottom, prefersReducedMotion as scrollPrefersReducedMotion, syncScrollButton as scrollSyncButton } from "./core/scroll.js";
import { textPrompt as dialogTextPrompt, finishTextPrompt as dialogFinishTextPrompt, bindDialog as dialogBindDialog } from "./core/dialog.js";
import { renderUsageTable as usageRenderTable } from "./core/usage.js";
import { renderStatusInto as statusRenderInto } from "./core/status.js";
import { pendingImages as attachImages, max_image_bytes as attachMaxBytes, renderAttachments as attachRender, addImageFile as attachAddFile } from "./core/attachments.js";
import { loadLog as logsLoadLog, loadLogList as logsLoadLogList } from "./core/logs.js";
import { pluginViews as pluginsViews, bindPlugins as pluginsBind, loadWebuiPlugins as pluginsLoadWebuiPlugins, loadPluginAssets as pluginsLoadPluginAssets, renderWebuiPlugins as pluginsRenderWebuiPlugins } from "./core/plugins.js";
import { bindPalette as paletteBind, paletteKeyHandler as paletteKeyHandle } from "./core/palette.js";
import { getProviderCache as mpProviderCache, getModelIndex as mpModelIndex, loadProviders as mpLoadProviders, syncModelSearchLabel as mpSyncLabel, renderModelList as mpRenderList, hideModelList as mpHideList, selectModel as mpSelectModel, runOptions as mpRunOptions, syncSubmitLabel as mpSyncSubmit, bindModelPicker as mpBind } from "./core/modelpicker.js";
import { renderTools as toolsRenderTools, showToolDetail as toolsShowDetail, toggleTool as toolsToggle, loadTools as toolsLoadTools, bindTools as toolsBind } from "./core/tools.js";

document.addEventListener("DOMContentLoaded", function () {
"use strict";

var readJson = utilReadJson;
var newSessionId = utilNewSessionId;
var fmtBytes = utilFmtBytes;
var clip = utilClip;
var sessionLabel = utilSessionLabel;
var recencyGroup = utilRecencyGroup;
var isSafeLinkUrl = utilIsSafeLinkUrl;
var splitRow = utilSplitRow;
var prettyJsonIfPossible = utilPrettyJsonIfPossible;
var fmtInt = utilFmtInt;
var fmtMs = utilFmtMs;
var fmtCost = utilFmtCost;
var providerCache = [];
var runLabel = function (r) { return runLabelMod(r, clip); };
var modelLabel = function (provider, model) { return modelLabelMod(provider, model, providerCache); };
var chatRoomLabel = function (r) { return chatRoomLabelMod(r, isDm, function(rr){ return dmPartner(rr); }, clankerMark); };
var goalSortKey = goalSortKeyMod;
var goalFields = goalFieldsMod;

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
  headerModel: document.getElementById("header-model"),
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
  goalMaxIterations: document.getElementById("goal-max-iterations"),
  goalsStatus: document.getElementById("goals-status"),
  goalAdd: document.getElementById("goal-add"),
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
  cardAdd: document.getElementById("card-add"),
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
  modelSearch: document.getElementById("model-search"),
  modelList: document.getElementById("model-list"),
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

var T = vanT;
var bind = vanBind;
var skeletonRows = vanSkeletonRows;
var setTurnPhase = vanSetTurnPhase;

var ICON_PATHS = iconPaths;
var icon = iconFn;

var UI = vanUI;

var vendorLoads = vendorLoadsMod;
var loadVendor = loadVendorMod;
var loadD3 = loadD3Mod;
var loadHljs = loadHljsMod;
var registerToml = registerTomlMod;
var reducedMotion = reducedMotionMod;
var copyText = copyTextMod;

var busy = false;
var controller = null;
var elapsedTimer = null;
var sessionId = loadSession();

function loadSession() {
  var id = null;
  try { id = window.localStorage.getItem("clanker.session"); } catch (e) {}
  if (!id) id = newSessionId();
  try { window.localStorage.setItem("clanker.session", id); } catch (e) {}
  return id;
}

function renderSessionChip() {
  if (el.sessionChip) el.sessionChip.textContent = "session " + sessionId.slice(0, 8);
  if (el.headerModel) {
    var sel = el.modelSelect ? el.modelSelect.value : "";
    var label = "";
    if (sel && sel.indexOf(" ") !== -1) label = sel.slice(sel.indexOf(" ") + 1).trim();
    else if (sel) label = sel;
    el.headerModel.textContent = label || "default model";
    el.headerModel.title = sel ? ("Model: " + sel + " — click to change") : "Model: default (from config) — click to change";
  }
}
if (typeof window !== "undefined") {
  document.addEventListener("DOMContentLoaded", function(){
    var hm = document.getElementById("header-model");
    if (hm) hm.addEventListener("click", function(){
      var dest = document.getElementById("task");
      if (dest) { dest.focus(); dest.scrollIntoView({ behavior: "smooth", block: "center" }); }
      var ms = document.getElementById("model-search");
      if (ms) { try { ms.focus(); ms.select(); } catch(_){} }
    });
  });
}

var THEMES = THEMESMod;
var loadTheme = loadThemeMod;
var applyTheme = applyThemeMod;

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

var knownSessionsHolder = { list: [] };
var knownSessions = knownSessionsHolder.list;

/* fmtBytes, clip, sessionLabel live in core/utils.js. */

/* The live session is always selectable even when the server has never seen
   it — a brand new chat has no saved file until its first turn completes,
   and dropping it from the list would make the picker disagree with what the
   composer is actually continuing. */
/* recencyGroup lives in core/utils.js. */


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
  if (sessions) { knownSessionsHolder.list.length = 0; Array.prototype.push.apply(knownSessionsHolder.list, sessions); knownSessions = knownSessionsHolder.list; }
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
    title: title,
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
  var label = meta ? sessionLabel(meta) : "New conversation  ·  unsaved";
  el.sessionTitle.textContent = label;
  el.sessionTitle.title = label;
  renderContextMeter();
}

function setRailOpen(open) {
  el.rail.setAttribute("data-open", String(open));
  el.railScrim.setAttribute("data-open", String(open));
  el.railToggle.setAttribute("aria-expanded", String(open));
  if (open) el.sessionFilter.focus();
}

function applyRailCollapsed(collapsed) {
  el.rail.setAttribute("data-collapsed", String(collapsed));
  var btn = document.getElementById("rail-collapse");
  if (btn) { btn.textContent = collapsed ? "◨" : "◧"; btn.setAttribute("aria-label", collapsed ? "Expand sidebar" : "Collapse sidebar"); btn.title = collapsed ? "Expand sidebar" : "Collapse sidebar"; }
  try { window.localStorage.setItem("clanker.railCollapsed", collapsed ? "1" : "0"); } catch (e) {}
}

(function initRail() {
  try {
    if (window.localStorage.getItem("clanker.railCollapsed") === "1") applyRailCollapsed(true);
  } catch (e) {}
  var cbtn = document.getElementById("rail-collapse");
  if (cbtn) cbtn.addEventListener("click", function () {
    var cur = el.rail.getAttribute("data-collapsed") === "true";
    applyRailCollapsed(!cur);
  });
  // populate data-short for collapsed rail labels from existing tab text
  document.querySelectorAll(".rail-tab").forEach(function (t) {
    var txt = (t.textContent || "").trim();
    if (!t.getAttribute("data-short") && txt) t.setAttribute("data-short", txt.slice(0, 2));
  });
})();

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

var INLINE_RE = mdINLINE_RE;
var inlineInto = mdInlineInto;
var paragraphInto = mdParagraphInto;
var tableRow = mdTableRow;
var renderMarkdown = mdRenderMarkdown;
var highlightInto = mdHighlightInto;
var buildCodeBlock = mdBuildCodeBlock;
var finalizeAnswer = mdFinalizeAnswer;

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

/* Shared by addAskEvent and addConfirmEvent: one button per option, grouped
   and labelled so focusing a button announces both, appended to the waiting
   row. Focus moves to the first option because the run is blocked — there is
   nothing else on the page the user can usefully do first. */
function addAskOptionsGroup(turn, row, evt, ariaLabel) {
  var group = document.createElement("div");
  group.className = "ask-options";
  group.setAttribute("role", "group");
  group.setAttribute("aria-label", ariaLabel);
  evt.options.forEach(function (opt) {
    if (typeof opt !== "string") return;
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "secondary";
    btn.textContent = opt;
    btn.addEventListener("click", function () { answerAsk(row, evt.id, opt); });
    group.appendChild(btn);
  });
  // Keyboard: trap focus within row, Esc denies
  group.addEventListener("keydown", function (e) {
    if (e.key === "Tab") {
      var items = Array.prototype.slice.call(group.querySelectorAll("button:not([disabled])"));
      if (!items.length) return;
      var first = items[0], last = items[items.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
      return;
    }
    if (e.key === "Escape") {
      e.preventDefault(); e.stopPropagation();
      var deny = null;
      for (var di = 0; di < evt.options.length; di++) {
        if (typeof evt.options[di] === "string" && evt.options[di].toLowerCase() === "deny") { deny = evt.options[di]; break; }
      }
      answerAsk(row, evt.id, deny || evt.options[evt.options.length - 1] || "deny");
    }
  });
  row.appendChild(group);
  turn.events.appendChild(row);
  // Announce question via per-turn live region and fleet-status fallback
  var fleetSt = document.getElementById("fleet-status");
  if (fleetSt) fleetSt.textContent = ariaLabel;
  var first = group.querySelector("button");
  if (first) first.focus();
}

/* A streaming run called ask_user: the server sent an `ask` control event
   and is now holding the run until POST /api/ask answers it or the server's
   ask timeout fires. */
function addAskEvent(turn, evt) {
  if (typeof evt.id !== "number" || !Array.isArray(evt.options)) return;
  var row = document.createElement("div");
  row.className = "event-ask";
  row.setAttribute("role", "alertdialog");
  row.setAttribute("aria-live", "assertive");
  row.setAttribute("aria-label", evt.question || "Choose an option");
  var q = document.createElement("div");
  q.className = "ask-question";
  q.textContent = evt.question || "";
  row.appendChild(q);
  addAskOptionsGroup(turn, row, evt, evt.question || "Choose an option");
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
  row.setAttribute("role", "alertdialog");
  row.setAttribute("aria-live", "assertive");
  var label = "Allow this " + (evt.tool || "tool") + " call?";
  row.setAttribute("aria-label", label);
  var q = document.createElement("div");
  q.className = "ask-question";
  q.textContent = label;
  row.appendChild(q);
  if (evt.args_preview) {
    var pre = document.createElement("pre");
    pre.className = "confirm-preview";
    pre.textContent = evt.args_preview;
    row.appendChild(pre);
  }
  addAskOptionsGroup(turn, row, evt, label);
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
  // The focused choice was inside the group that was just removed. Keep the
  // keyboard and screen-reader position at the resolved prompt instead of
  // letting focus fall back to <body>, and stop exposing a completed prompt
  // as an active alert dialog.
  row.removeAttribute("role");
  row.removeAttribute("aria-live");
  row.removeAttribute("aria-label");
  var done = document.createElement("div");
  done.className = "ask-answered";
  done.tabIndex = -1;
  if (iconName) done.appendChild(icon(iconName, 12));
  done.appendChild(document.createTextNode(text));
  row.appendChild(done);
  done.focus();
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

  var actions = document.createElement("span");
  actions.className = "turn-foot-actions";
  actions.style.display = "inline-flex";
  actions.style.gap = "0.4rem";
  actions.style.flexWrap = "wrap";
  var copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "secondary";
  copyBtn.textContent = "Copy answer";
  copyBtn.addEventListener("click", function () {
    copyText(turn.root.markdownSource || turn.answer.textContent, copyBtn, "Copy answer", turn.answer);
  });
  actions.appendChild(copyBtn);

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
    actions.appendChild(applyBtn);
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
    actions.appendChild(regenBtn);

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
    actions.appendChild(editBtn);
  }
  turn.foot.appendChild(actions);
}

var makeLineSplitter = makeLineSplitterMod;

function renderStatus(status) {
  var out = statusRenderInto(status, el);
  instanceName = out.instanceName;
  knownPeers = out.knownPeers;
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
var pendingImages = attachImages;
var max_image_bytes = attachMaxBytes;
function renderAttachments() { attachRender(el, icon, fmtBytes); }
function addImageFile(file) { attachAddFile(file, el, icon, fmtBytes); }

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
  setTurnPhase(turn, "llm");

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
      if (evt.type === "tool_call") { addToolEvent(turn, evt.names); setTurnPhase(turn, "tool"); }
      else if (evt.type === "tool_result") { settleLastToolEvent(turn, evt.ms); setTurnPhase(turn, "tool"); }
      else if (evt.type === "ask") { addAskEvent(turn, evt); setTurnPhase(turn, "ask"); }
      else if (evt.type === "confirm") { addConfirmEvent(turn, evt); setTurnPhase(turn, "ask"); }
      else if (evt.type === "error") { appendText(turn, "\n[" + evt.message + "]\n", true); setTurnPhase(turn, ""); }
      else if (evt.type === "done") {
        renderStats(turn, evt, task);
        statsRendered = true;
        setTurnPhase(turn, "");
      }
      return;
    }
    var stick = nearBottom();
    appendText(turn, line + "\n", false);
    // live markdown: throttled incremental render while streaming
    if (!turn._mdThrottle) { turn._mdThrottle = 0; turn._lastMD = ""; }
    var now2 = Date.now();
    if (now2 - turn._mdThrottle > 160) {
      turn._mdThrottle = now2;
      var pend = turn.root.markdownSource || "";
      if (pend !== turn._lastMD && pend.length > 80) {
        turn._lastMD = pend;
        var hadCaret2 = !!turn.answer.querySelector(".caret");
        try {
          var fragMd2 = renderMarkdown(pend);
          turn.answer.textContent = "";
          turn.answer.className = "turn-answer md";
          turn.answer.appendChild(fragMd2);
          if (hadCaret2) showCaret(turn, true);
        } catch(_e2) {}
      }
    }
    setTurnPhase(turn, "llm");
    if (stick) window.scrollTo(0, document.body.scrollHeight);
    else syncScrollButton();
  });

  fetch("/api/run", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      task: task,
      goal: "",
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
    if (!resp.ok) {
      return resp.text().then(function (t) {
        var msg = t;
        try { var j = JSON.parse(t); msg = j.error || j.message || t; } catch (e2) {}
        throw new Error((msg && String(msg).trim()) ? String(msg).trim() : "server responded HTTP " + resp.status);
      });
    }
    if (!resp.body) throw new Error("server responded HTTP " + resp.status);
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
    pendingImages.length = 0;
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
    setTurnPhase(turn, "");
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

var allRunsHolder = { list: [] };
var allRuns = allRunsHolder.list;
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
  el.runGraph.setAttribute("aria-busy", "true");
  el.runStatus.textContent = "Loading runs…";
  if (!el.runGraph.childNodes.length) skeletonRows(el.runGraph, 3);
  return fetch("/api/runs")
    .then(readJson)
    .then(function (runs) {
      el.runGraph.removeAttribute("aria-busy");
      allRunsHolder.list.length = 0; Array.prototype.push.apply(allRunsHolder.list, runs); allRuns = allRunsHolder.list;
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
      el.runStatus.textContent = "";
    })
    .catch(function (err) {
      el.runGraph.removeAttribute("aria-busy");
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
  el.runGraph.textContent = "";
  skeletonRows(el.runGraph, 2);
  // skeletonRows already set aria-busy; keep specific id in status line for screen readers
  el.runStatus.textContent = "Loading run " + id + "…";
  return fetch("/api/runs/" + encodeURIComponent(id))
    .then(readJson)
    .then(function (g) {
      el.runGraph.textContent = "";
      el.runGraph.removeAttribute("aria-busy");
      drawRun(g);
    })
    .catch(function (err) {
      // Ensure no stale skeleton remains; showRunsError clears graph
      showRunsError("Could not load that run: " + err.message);
    });
}

var metricsFor = graphMetricsFor;
var buildStages = graphBuildStages;

var lastGraph = null;
var lastBuilt = null;
var resizeTimer = null;
var resizeHandler = function () {
  if (resizeTimer) window.clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(function () {
    if (lastGraph) drawRun(lastGraph);
  }, 150);
};
window.addEventListener("resize", resizeHandler);
// Cleaned up on pagehide to avoid handler leak after bfcache restore
window.addEventListener("pagehide", function () {
  window.removeEventListener("resize", resizeHandler);
  if (resizeTimer) window.clearTimeout(resizeTimer);
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

  var head = document.createElement("div");
  head.className = "run-head";
  head.style.display = "flex"; head.style.flexWrap = "wrap"; head.style.gap = "0.4rem"; head.style.alignItems = "center";
  var headId = document.createElement("span"); headId.textContent = g.run_id; headId.style.fontWeight = "600"; head.appendChild(headId);
  if (g.provider) { var hp = document.createElement("span"); hp.className = "tool-tag"; hp.textContent = g.provider; head.appendChild(hp); }
  var hm = document.createElement("span"); hm.className = "meta"; hm.textContent = g.duration_ms + "ms · " + g.total_prompt_tokens + " prompt + " + g.total_completion_tokens + " completion"; head.appendChild(hm);
  if (g.task) { var ht = document.createElement("span"); ht.className = "meta"; ht.style.flexBasis = "100%"; ht.textContent = g.task; head.appendChild(ht); }
  var copyHead = document.createElement("button"); copyHead.type = "button"; copyHead.className = "secondary"; copyHead.textContent = "Copy id";
  copyHead.addEventListener("click", function(){ try{ navigator.clipboard.writeText(g.run_id); copyHead.textContent="Copied"; setTimeout(function(){ copyHead.textContent="Copy id"; }, 1200);}catch(_){} });
  head.appendChild(copyHead);
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

  var graphSearch = document.createElement("div");
  graphSearch.className = "run-graph-search";
  graphSearch.style.display = "flex"; graphSearch.style.gap = "0.5rem"; graphSearch.style.marginBottom = "0.5rem"; graphSearch.style.flexWrap = "wrap";
  var graphSearchInput = document.createElement("input");
  graphSearchInput.type = "search"; graphSearchInput.placeholder = "Filter nodes (e.g. read_file, grep)…";
  graphSearchInput.setAttribute("aria-label", "Filter graph nodes");
  graphSearchInput.style.flex = "1"; graphSearchInput.style.minWidth = "12rem";
  var graphNextBtn = document.createElement("button"); graphNextBtn.type = "button"; graphNextBtn.className = "secondary"; graphNextBtn.textContent = "Next";
  var graphClearBtn = document.createElement("button"); graphClearBtn.type = "button"; graphClearBtn.className = "secondary"; graphClearBtn.textContent = "Clear";
  var graphFitBtn = document.createElement("button"); graphFitBtn.type = "button"; graphFitBtn.className = "secondary"; graphFitBtn.textContent = "Fit";
  graphFitBtn.title = "Fit graph to view";
  graphSearch.appendChild(graphSearchInput); graphSearch.appendChild(graphNextBtn); graphSearch.appendChild(graphClearBtn); graphSearch.appendChild(graphFitBtn);
  el.runGraph.appendChild(graphSearch);
  // Trello/Slack-style focus filters — dim non-matches so dense graphs stay scannable
  var _kindFilter = "";
  var graphKindBar = document.createElement("div");
  graphKindBar.className = "run-kind-filter"; graphKindBar.style.display = "flex"; graphKindBar.style.gap = "0.35rem"; graphKindBar.style.flexWrap = "wrap"; graphKindBar.style.marginBottom = "0.5rem";
  graphKindBar.setAttribute("role", "group"); graphKindBar.setAttribute("aria-label", "Filter by node kind");
  [{k:"",label:"All"},{k:"llm",label:"LLM"},{k:"tool",label:"Tools"},{k:"final",label:"Answer"},{k:"failed",label:"Failed"}].forEach(function(opt){
    var b = document.createElement("button"); b.type = "button"; b.className = "secondary"; b.textContent = opt.label;
    b.dataset.kind = opt.k; b.setAttribute("aria-pressed", opt.k === "" ? "true" : "false");
    if (opt.k === "failed") b.title = "Only failed nodes";
    b.addEventListener("click", function(){
      _kindFilter = opt.k;
      graphKindBar.querySelectorAll("button").forEach(function(x){ x.setAttribute("aria-pressed", x.dataset.kind === _kindFilter ? "true" : "false"); });
      _matchIdx = -1; doLayout(_searchQ);
    });
    graphKindBar.appendChild(b);
  });
  el.runGraph.appendChild(graphKindBar);
  // Codex-style breadcrumb: iteration / step chips + keyboard tour
  var crumb = document.createElement("div");
  crumb.className = "run-crumbs"; crumb.style.display = "flex"; crumb.style.gap = "0.35rem"; crumb.style.flexWrap = "wrap"; crumb.style.marginBottom = "0.5rem";
  crumb.setAttribute("role", "navigation"); crumb.setAttribute("aria-label", "Iterations");
  built.stages.forEach(function(st, idx){
    var chip = document.createElement("button");
    chip.type = "button"; chip.className = "secondary"; chip.textContent = "iter " + st.iteration;
    chip.title = st.iteration + " · " + (st.llm.label || "llm") + (st.tools.length ? " · " + st.tools.map(function(t){ return t.label; }).join(", ") : "");
    chip.addEventListener("click", function(){
      // focus first node of this stage (llm)
      var target = canvas.querySelector('.run-node[data-kind="llm"]');
      // find by iteration tag neighbour
      var tags = canvas.querySelectorAll(".run-iter-tag");
      for (var ti=0; ti<tags.length; ti++) if (tags[ti].textContent.trim() === String(st.iteration)) {
        var sib = tags[ti].nextElementSibling;
        // walk to next llm node near tag
        var x = parseFloat(tags[ti].style.left) + 20;
        var y = parseFloat(tags[ti].style.top) + 11;
        // fallback: focus canvas center near tag
        canvas.scrollLeft = Math.max(0, x - canvas.clientWidth/2);
        canvas.scrollTop = Math.max(0, y - canvas.clientHeight/2);
        break;
      }
    });
    crumb.appendChild(chip);
  });
  if (built.stages.length) el.runGraph.appendChild(crumb);

  var canvas = document.createElement("div");
  canvas.className = "run-canvas";
  canvas.tabIndex = 0;
  canvas.setAttribute("aria-label", "Scrollable execution graph — drag to pan, Ctrl+wheel to zoom, +/- keys, search to highlight");
  (function(){
    var isPanning = false, startX = 0, startY = 0, startScrollLeft = 0, startScrollTop = 0;
    canvas.addEventListener("mousedown", function(e){
      if (e.target.closest && e.target.closest(".run-node")) return;
      isPanning = true; startX = e.clientX; startY = e.clientY; startScrollLeft = canvas.scrollLeft; startScrollTop = canvas.scrollTop;
      canvas.style.cursor = "grabbing";
      e.preventDefault();
    });
    window.addEventListener("mouseup", function(){ if(isPanning){ isPanning = false; canvas.style.cursor = ""; } });
    window.addEventListener("mousemove", function(e){
      if (!isPanning) return;
      canvas.scrollLeft = startScrollLeft - (e.clientX - startX);
      canvas.scrollTop = startScrollTop - (e.clientY - startY);
    });
    canvas.addEventListener("wheel", function(e){
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        if (e.deltaY < 0) zoomInBtn.click(); else if (e.deltaY > 0) zoomOutBtn.click();
      }
    }, { passive: false });
  })();
  var zoomWrap = document.createElement("div");
  zoomWrap.style.display = "flex"; zoomWrap.style.gap = "0.4rem"; zoomWrap.style.marginTop = "0.4rem";
  var zoomInBtn = document.createElement("button"); zoomInBtn.type = "button"; zoomInBtn.className = "secondary"; zoomInBtn.textContent = "+ Zoom";
  var zoomOutBtn = document.createElement("button"); zoomOutBtn.type = "button"; zoomOutBtn.className = "secondary"; zoomOutBtn.textContent = "− Zoom";
  var zoomResetBtn = document.createElement("button"); zoomResetBtn.type = "button"; zoomResetBtn.className = "secondary"; zoomResetBtn.textContent = "Reset";
  var zoomLevel = 1;
  function applyZoom(){ canvas.style.transform = zoomLevel === 1 ? "" : "scale(" + zoomLevel + ")"; canvas.style.transformOrigin = "top left"; }
  zoomInBtn.addEventListener("click", function(){ zoomLevel = Math.min(1.8, zoomLevel + 0.15); applyZoom(); });
  zoomOutBtn.addEventListener("click", function(){ zoomLevel = Math.max(0.5, zoomLevel - 0.15); applyZoom(); });
  zoomResetBtn.addEventListener("click", function(){ zoomLevel = 1; applyZoom(); });
  zoomWrap.appendChild(zoomInBtn); zoomWrap.appendChild(zoomOutBtn); zoomWrap.appendChild(zoomResetBtn);
  el.runGraph.appendChild(canvas);
  el.runGraph.appendChild(zoomWrap);

  var minimap = document.createElement("div");
  minimap.className = "run-minimap"; minimap.hidden = true;
  minimap.setAttribute("role", "navigation"); minimap.setAttribute("aria-label", "Minimap — click to jump, drag viewport to pan");
  minimap.title = "Click to jump · drag viewport to pan";
  var mmLabel = document.createElement("span"); mmLabel.className = "run-minimap-label"; mmLabel.textContent = "map"; minimap.appendChild(mmLabel);
  var mmViewport = document.createElement("div"); mmViewport.className = "run-minimap-viewport";
  minimap.appendChild(mmViewport);
  canvas.appendChild(minimap);
  function updateMinimap(){
    var needsMap = canvas.scrollWidth > canvas.clientWidth + 8 || canvas.scrollHeight > canvas.clientHeight + 8;
    minimap.hidden = !needsMap;
    if (minimap.hidden) return;
    var sx = canvas.scrollLeft / Math.max(1, canvas.scrollWidth - canvas.clientWidth);
    var sy = canvas.scrollTop / Math.max(1, canvas.scrollHeight - canvas.clientHeight);
    var vw = canvas.clientWidth / Math.max(1, canvas.scrollWidth) * 100;
    var vh = canvas.clientHeight / Math.max(1, canvas.scrollHeight) * 100;
    mmViewport.style.left = (sx * (100 - vw)) + "%";
    mmViewport.style.top = (sy * (100 - vh)) + "%";
    mmViewport.style.width = Math.max(12, vw) + "%";
    mmViewport.style.height = Math.max(12, vh) + "%";
  }
  canvas.addEventListener("scroll", updateMinimap);
  // click-to-jump on the map background
  minimap.addEventListener("click", function(e){
    if (e.target === mmViewport) return;
    var rect = minimap.getBoundingClientRect();
    var px = (e.clientX - rect.left) / rect.width;
    var py = (e.clientY - rect.top) / rect.height;
    canvas.scrollLeft = px * (canvas.scrollWidth - canvas.clientWidth);
    canvas.scrollTop = py * (canvas.scrollHeight - canvas.clientHeight);
  });
  // drag viewport to pan
  (function(){
    var dragging = false, startX = 0, startY = 0, startSL = 0, startST = 0;
    mmViewport.addEventListener("mousedown", function(e){
      dragging = true; startX = e.clientX; startY = e.clientY; startSL = canvas.scrollLeft; startST = canvas.scrollTop;
      e.preventDefault(); e.stopPropagation();
    });
    window.addEventListener("mousemove", function(e){
      if (!dragging) return;
      var rect = minimap.getBoundingClientRect();
      var dxRatio = (e.clientX - startX) / rect.width;
      var dyRatio = (e.clientY - startY) / rect.height;
      canvas.scrollLeft = startSL + dxRatio * canvas.scrollWidth;
      canvas.scrollTop = startST + dyRatio * canvas.scrollHeight;
    });
    window.addEventListener("mouseup", function(){ dragging = false; });
  })();
  // keep in sync after layout / resize
  window.addEventListener("resize", updateMinimap);
  // Fit button
  graphFitBtn.addEventListener("click", function(){
    canvas.scrollLeft = 0; canvas.scrollTop = 0;
    // also reset zoom if api exposed
    try{ var ev = new KeyboardEvent("keydown", { key: "0" }); canvas.dispatchEvent(ev); }catch(_){}
    updateMinimap();
  });

  function doLayout(q){
    loadD3().then(function () {
      if (canvas.isConnected) layoutGraph(canvas, built, slowest, { searchQuery: q || "", kindFilter: _kindFilter, statusEl: el.runStatus, minimap: minimap, onSelect: function(k,n){ showNodeDetail(k,n); } });
      try{ updateMinimap(); }catch(_){}
    }).catch(function (err) {
      var errEl = document.createElement("p");
      errEl.className = "run-empty";
      errEl.textContent = "Could not load the graph layout library: " + err.message;
      canvas.appendChild(errEl);
      el.runStatus.textContent = errEl.textContent;
    });
  }
  var _searchQ = "";
  var _matchIdx = -1;
  function focusNextMatch(){
    var matches = canvas.querySelectorAll('.run-node[data-match="true"]');
    if (!matches.length) return;
    _matchIdx = (_matchIdx + 1) % matches.length;
    matches[_matchIdx].focus();
    matches[_matchIdx].scrollIntoView({ block: "nearest", inline: "center" });
  }
  // Qwen-like: link to OpenWebUI's error lens — one button jumps to failed nodes
  var graphFailedBtn = document.createElement("button"); graphFailedBtn.type = "button"; graphFailedBtn.className = "secondary"; graphFailedBtn.textContent = "⚠ Failed";
  graphFailedBtn.title = "Next failed node";
  graphSearch.appendChild(graphFailedBtn);
  function focusNextFailed(){
    var fails = canvas.querySelectorAll('.run-node[data-ok="false"]');
    if (!fails.length) return;
    _matchIdx = (_matchIdx + 1) % fails.length;
    fails[_matchIdx].focus(); fails[_matchIdx].scrollIntoView({ block: "nearest", inline: "center" });
    fails[_matchIdx].click();
  }
  graphFailedBtn.addEventListener("click", focusNextFailed);
  graphSearchInput.addEventListener("input", function(){
    _searchQ = graphSearchInput.value.trim();
    _matchIdx = -1;
    doLayout(_searchQ);
  });
  graphNextBtn.addEventListener("click", focusNextMatch);
  graphClearBtn.addEventListener("click", function(){ graphSearchInput.value = ""; _searchQ = ""; _matchIdx = -1; doLayout(""); graphSearchInput.focus(); });
  // Codex-like j/k step tour between iterations
  var _iterIdx = 0;
  function focusIter(dir){
    var chips = crumb.querySelectorAll("button");
    if (!chips.length) return;
    _iterIdx = (_iterIdx + dir + chips.length) % chips.length;
    chips[_iterIdx].focus();
    chips[_iterIdx].click();
  }
  canvas.addEventListener("keydown", function(e){
    if (e.key === "+" || e.key === "=") { e.preventDefault(); zoomInBtn.click(); }
    else if (e.key === "-" || e.key === "_") { e.preventDefault(); zoomOutBtn.click(); }
    else if (e.key === "0") { e.preventDefault(); zoomResetBtn.click(); }
    else if (e.key === "n" || e.key === "N") { if (_searchQ) { e.preventDefault(); focusNextMatch(); } else if (e.shiftKey || e.key === "N") { e.preventDefault(); focusNextFailed(); } }
    else if (e.key === "F" || e.key === "f") { if (e.shiftKey) { e.preventDefault(); focusNextFailed(); } }
    else if (e.key === "j") { e.preventDefault(); focusIter(1); }
    else if (e.key === "k") { e.preventDefault(); focusIter(-1); }
    else if (e.key === "Escape") { graphSearchInput.blur(); canvas.focus(); }
  });
  doLayout("");
}

var graphSummaryText = graphSummaryTextMod;
var toDagInput = graphToDagInput;
var layoutGraph = graphLayoutGraph;

var buildIncompleteNode = graphBuildIncompleteNode;
var buildNodeBox = graphBuildNodeBox;

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

  var copyBtn = document.createElement("button");
  copyBtn.type = "button"; copyBtn.className = "secondary"; copyBtn.textContent = "Copy";
  copyBtn.title = "Copy this node's output";
  copyBtn.addEventListener("click", function(){
    var t = node.output || "";
    try{ navigator.clipboard.writeText(t); copyBtn.textContent = "Copied"; setTimeout(function(){ copyBtn.textContent="Copy"; }, 1200); }catch(_){ copyText(t, copyBtn, "Copy", out); }
  });
  head.appendChild(copyBtn);
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
  // Qwen / Codex idea: clickable trace refs inside the detail (file:line, run ids) jump to source / graph
  var traceBar = document.createElement("div");
  traceBar.style.display = "flex"; traceBar.style.gap = "0.4rem"; traceBar.style.flexWrap = "wrap"; traceBar.style.marginBottom = "0.5rem";
  var rawOut = node.output || "";
  var traceRe = /(?:^|\s)([a-zA-Z0-9_\-\.\/]+\.(?:zig|ts|js|py|rs|go|md):\d+(?::\d+)?)/g;
  var m, seen = {}, cnt = 0;
  while ((m = traceRe.exec(rawOut)) && cnt < 6) {
    var ref = m[1];
    if (seen[ref]) continue; seen[ref] = true; cnt++;
    (function(r){
      var b = document.createElement("button"); b.type = "button"; b.className = "secondary"; b.textContent = r; b.title = "Search for " + r;
      b.addEventListener("click", function(){
        // cross-link to graph search and file search where available
        var s = document.querySelector("#run-filter"); if (s) { s.value = r.split(":")[0]; s.dispatchEvent(new Event("input",{bubbles:true})); }
        var gf = document.querySelector(".run-graph-search input");
        if (gf) { gf.value = r.split(":")[0].split("/").pop().split(".")[0]; gf.dispatchEvent(new Event("input",{bubbles:true})); }
      });
      traceBar.appendChild(b);
    })(ref);
  }
  if (traceBar.childNodes.length) el.runDetail.appendChild(traceBar);
  var subRe = /\[subagent run:\s*(sub-\d+)\]/g, sm;
  while ((sm = subRe.exec(rawOut)) !== null) {
    var sid = sm[1];
    var sb = document.createElement("button"); sb.type = "button"; sb.className = "secondary"; sb.textContent = "↗ " + sid;
    sb.title = "Open sub-run " + sid;
    (function(id){ sb.addEventListener("click", function(){ if(typeof openRun==="function") openRun(id); }); })(sid);
    traceBar.appendChild(sb);
    if (!traceBar.parentNode) el.runDetail.appendChild(traceBar);
  }

  var out = document.createElement("div");
  out.className = "run-detail-output";
  if (node.output) {
    var parsed;
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

  // Keep detail from covering the graph on tall runs (Kimi/Qwen split-pane feel)
  el.runDetail.style.maxHeight = "42vh";
  el.runDetail.style.overflow = "auto";
  scrollTo(el.runDetail, "nearest");
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

var dmRoom = dmRoomMod;
var dmSafeName = dmSafeNameMod;
var isDm = isDmMod;
var clankerMark = clankerMarkMod;
var CLANKER_MARKS = CLANKER_MARKSMod;
// dmPartner in this file is called as dmPartner(room) closing over instanceName.
var dmPartner = function(room){ return dmPartnerMod(room, instanceName); };

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

/* chatRoomLabel lives in core/labels.js (bridged above). */

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
        var label = chatRoomLabel(r);
        if (r.messages) label += "  ·  " + r.messages;
        // count only peers that are "up" — green dot like Slack presence
        var peerUp = knownPeers.some(function(p){ return p.name === r.room || p.name === dmPartner(r.room); });
        if (r.unread) label += " · " + r.unread + " new";
        else if (peerUp && r.room.indexOf("dm:") === 0) label += " · online";
        return T.option({ value: r.room }, label);
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
      // reset grouping when loading fresh batch (rooms switch already clears, but keep day key fresh)
      if (fresh.length) { _lastChatFrom = null; _lastChatTs = 0; _lastChatDay = ""; }
      fresh.forEach(function (m) {
        rememberChatId(m.id);
        if (m.ts > chatLastTs) chatLastTs = m.ts;
        var node = buildChatMessage(m);
        if (node._daySep) el.chatLog.appendChild(node._daySep);
        el.chatLog.appendChild(node);
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



var _lastChatFrom = null;
var _lastChatTs = 0;
function _chatDayKey(ts){ try{ var d=new Date(ts*1000); return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0"); }catch(_){ return ""; } }
var _lastChatDay = "";
function buildChatMessage(m) {
  var grouped = (m.from === _lastChatFrom) && (m.ts - _lastChatTs < 300) && (_chatDayKey(m.ts) === _lastChatDay);
  var wrap = document.createElement("div");
  wrap.className = "chat-msg" + (m.from === instanceName ? " mine" : "");
  if (grouped) wrap.setAttribute("data-grouped", "true");

  // day separator (Slack-style)
  var dayKey = _chatDayKey(m.ts);
  if (dayKey && dayKey !== _lastChatDay) {
    _lastChatDay = dayKey;
    var sep = document.createElement("div");
    sep.className = "chat-day";
    sep.textContent = dayKey;
    // attach as sibling marker stored on wrap for the caller to insert
    wrap._daySep = sep;
  } else if (!grouped) {
    // keep _lastChatDay current even when grouped
  }

  var meta = document.createElement("div");
  meta.className = "chat-meta";
  var mark = document.createElement("span");
  mark.className = "chat-mark";
  mark.textContent = clankerMark(m.from || "");
  mark.setAttribute("aria-hidden", "true");
  meta.appendChild(mark);
  var from = document.createElement("span");
  from.className = "chat-from";
  from.textContent = m.from;
  from.setAttribute("data-color", String((function(h){ var v=0; for(var i=0;i<m.from.length;i++) v=(v*31 + m.from.charCodeAt(i))>>>0; return v%8; })(m.from)));
  // hue per name so different clankers read as different people at a glance (Slack-like)
  var hues = ["#0b57d0","#7c3aed","#059669","#d97706","#dc2626","#0891b2","#9333ea","#65a30d"];
  var hue = hues[parseInt(from.getAttribute("data-color"),10)%hues.length];
  from.style.color = hue;
  from.style.borderBottom = "2px solid " + hue;
  meta.appendChild(from);
  var time = document.createElement("span");
  time.className = "chat-time";
  time.textContent = formatChatTime(m.ts);
  meta.appendChild(time);
  wrap.appendChild(meta);
  // Slack-like hover timestamp gutter for grouped messages
  if (grouped) {
    var gutter = document.createElement("span");
    gutter.className = "chat-gutter-time";
    gutter.textContent = formatChatTime(m.ts);
    gutter.setAttribute("aria-hidden", "true");
    wrap.appendChild(gutter);
  }

  var text = document.createElement("div");
  text.className = "chat-text";
  var said = boardActionLine(m.text);
  if (said) {
    text.classList.add("chat-action");
    text.textContent = said;
  } else {
    // Slack-style unfurl: bare URL preview affordance (no fetch, just link styling already does it,
    // but we add a subtle link card when the message is exactly a URL)
    var trimmed = m.text.trim();
    var isBareUrl = /^https?:\/\/\S+$/.test(trimmed);
    text.textContent = m.text;
    if (isBareUrl) {
      var linkCard = document.createElement("a");
      linkCard.href = trimmed;
      linkCard.target = "_blank";
      linkCard.rel = "noopener noreferrer";
      linkCard.className = "chat-unfurl";
      linkCard.textContent = trimmed;
      // keep original text too for copy, but add card beneath
      var unfurl = document.createElement("div");
      unfurl.style.marginTop = "0.3rem";
      unfurl.appendChild(linkCard);
      wrap._unfurl = unfurl;
    }
  }
  wrap.appendChild(text);
  if (wrap._unfurl) wrap.appendChild(wrap._unfurl);
  // Slack-like hover quick actions (copy / emoji) — decorative for now, no wire yet
  var actions = document.createElement("div");
  actions.className = "chat-actions";
  actions.setAttribute("aria-hidden", "true");
  var copyBtn = document.createElement("button");
  copyBtn.type = "button"; copyBtn.className = "secondary"; copyBtn.textContent = "Copy";
  copyBtn.addEventListener("click", function(e){ e.stopPropagation(); try{ navigator.clipboard.writeText(m.text); }catch(_){} });
  actions.appendChild(copyBtn);
  var reactBtn = document.createElement("button");
  reactBtn.type = "button"; reactBtn.className = "secondary"; reactBtn.textContent = "♡";
  reactBtn.title = "React";
  actions.appendChild(reactBtn);
  wrap.appendChild(actions);
  // update grouping state for next message
  _lastChatFrom = m.from;
  _lastChatTs = m.ts;
  return wrap;
}

var BOARD_COLUMNS = BOARD_COLUMNSMod;
var boardActionLine = boardActionLineMod;
var doneColumn = function () { return doneColumnMod(board); };
var blockers = function (card) { return blockersMod(card, board, cardById); };
var dueState = dueStateMod;

var formatChatTime = utilFormatChatTime;
var fmtDeadline = utilFmtDeadline;

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

el.chatText.addEventListener("keydown", function(e){
  if (e.key === "@" || (e.key.length === 1 && el.chatText.value.slice(-1) === "@")) {
    // Slack-style @ mention hint — lightweight: show available peers/instance in status
    var peers = (knownPeers || []).map(function(p){ return p.name || p; }).join(", ");
    if (peers) el.chatStatus.textContent = "Mention: @" + (peers.split(",")[0].trim()) + (peers.indexOf(",") !== -1 ? " — also: " + peers.split(",").slice(1,2).join("") + "…" : "");
  }
});
el.chatForm.addEventListener("submit", function (e) {
  e.preventDefault();
  var text = el.chatText.value.trim();
  var room = el.chatRoom.value;
  if (!text || !room) return;
  // Slack-like /slash command affordance (client-side hint); server handles plain text
  if (text.charAt(0) === "/") {
    var cmd = text.slice(1).split(/\s+/)[0].toLowerCase();
    if (cmd === "me" || cmd === "shrug") {
      text = text.slice(cmd.length + 2);
      if (!text) { el.chatStatus.textContent = "Usage: /" + cmd + " <message>"; return; }
      if (cmd === "shrug") text = text + " ¯\\_(ツ)_/¯";
      text = "_" + text + "_";
    }
  }
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

var allUsage = [];

var usageState = van.state([]);

function renderUsage(rows) {
  allUsage = rows || allUsage;
  usageState.val = allUsage.slice();
}

bind(el.usage, usageState, function (rows) {
  return usageRenderTable(rows, modelLabel, fmtInt, fmtCost, UI, T);
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

/* Goals whose board mirror has already been requested, so a goal created
   from within a run (the agent's `goal` tool appends it to state/goals.json,
   which the next loadGoals picks up) gets a board card once rather than on
   every refresh. Form-created goals and board->goal cards set goalCardLinks
   themselves, so this only ever adds the ones that arrived without a card. */
var goalBoardMirrored = {};

/* Newest first: the goal most recently set is the one steering runs now. */
function renderGoals(goals) {
  goalState.val = (goals || []).slice().sort(goalSortKey);
}

/* Goals that reach the web UI from state/goals.json are mirrored onto the
   board in the section matching their state (backlog for a fresh active goal),
   so a goal created from within a goal run is not invisible on the board.
   ensureGoalBoardCard is idempotent (it finds an existing card by title or
   creates one) and the goalBoardMirrored guard keeps a goal from being
   re-created across refreshes. */
function mirrorGoalsToBoard(goals) {
  (goals || []).forEach(function (g) {
    if (!g || !g.id || !g.objective || goalBoardMirrored[g.id]) return;
    goalBoardMirrored[g.id] = true;
    ensureGoalBoardCard(g.objective, g.completion_criterion);
  });
}

function goalCard(g) {
  var fields = goalFields(g);

  var actions = [];
  if (g.id) {
    /* Active goals are meant to be worked: without this, adding a goal only
       wrote state/goals.json and never started a run. The per-run budget box
       sets this run's max iterations; left blank it falls back to the goal's
       stored default, then to the global agent.max_iterations. */
    if ((g.status || "active") === "active") {
      actions.push(T.div({ class: "goal-run-controls" },
        T.input({
          type: "number", min: "1", max: "1000", step: "1",
          "data-goal-budget": g.id,
          placeholder: g.max_iterations ? ("≤ " + g.max_iterations + " iters (default)") : "max iters (default)",
          title: "Optional per-run max iterations. Blank uses the goal's stored default, then the global agent.max_iterations."
        }),
        UI.button("Work on this", function () { workOnGoal(g); },
          { label: "Work on goal: " + (g.objective || g.id) }),
        UI.button("Re-evaluate", function () { reEvaluateGoal(g); },
          { label: "Re-evaluate whether goal is done: " + (g.objective || g.id) })));
    }
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
      g.max_iterations ? T.span("budget ≤ " + g.max_iterations + " iters") : null,
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
    g.id ? renderGoalRunPanel(g.id) : null,
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
    .then(function (data) {
      renderGoals(data.goals || []);
      mirrorGoalsToBoard(data.goals || []);
    })
    .catch(function (err) {
      el.goals.textContent = "";
      var p = document.createElement("p");
      p.className = "usage-empty";
      p.textContent = "Could not load goals: " + err.message;
      el.goals.appendChild(p);
    });
}

// ---- tools: every WASM plugin, and a switch for the optional ones ------

var allToolsHolder = { list: [] };
var allTools = allToolsHolder.list;

var toolState = van.state({ tools: [], filter: "" });

var renderTools = toolsRenderTools;
var showToolDetail = toolsShowDetail;
var toggleTool = toolsToggle;
var loadTools = toolsLoadTools;

toolsBind({
  el: el,
  allToolsHolder: allToolsHolder,
  toolState: toolState,
  clip: clip,
  readJson: readJson,
  scrollTo: scrollTo,
  bind: bind,
  T: T,
  UI: UI
});

// ---- views: one section visible at a time -----------------------------

var VIEWS = ["chat", "board", "goals", "runs", "fleet", "rooms", "tools", "system"];
var fleetModulePromise = null;
function loadFleetModule() {
  if (!fleetModulePromise) {
    fleetModulePromise = import("./features/fleet.js").then(function (fleet) {
      fleet.setNavShowView(showView);
      fleet.setOpenRun(openRun);
      return fleet;
    });
  }
  return fleetModulePromise;
}
/* Each view's data is fetched the first time it is opened rather than all of
   it at load. The page used to fire seven requests before showing anything,
   several of which execute a WASM tool. */
var viewLoaded = {};
var viewLoaders = {
  runs: loadRuns,
  fleet: function () {
    return loadFleetModule().then(function (fleet) { return fleet.refreshFleet(); });
  },
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
  fleet: "fleet-runs",
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
  skeletonRows(node, 2);
}

function clearLoading(name) {
  var id = VIEW_CONTAINERS[name];
  if (!id) return;
  var node = document.getElementById(id);
  if (node) node.removeAttribute("aria-busy");
}

var viewSettled = false;
var currentView = null;

/* The last view the page was on, persisted so a refresh that arrives without a
   URL fragment — a fresh tab on /webui, a proxy that drops the hash, or the
   browser itself after certain hard reloads — still opens the same screen
   instead of defaulting to chat. The URL hash is the primary source of truth
   when it names a real view; this is the fallback for when it does not. */
function saveView(name) {
  try { window.localStorage.setItem("clanker.view", name); } catch (e) {}
}

function showView(name, focusPanel) {
  if (VIEWS.indexOf(name) === -1) name = "chat";
  // The rooms poll has no idea the view switched away from under it — only
  // document.hidden stopped it before, so leaving Rooms for Chat or Board
  // left it polling a chat log nobody could see. Stop it here, and pick back
  // up where it left off if Rooms is reopened.
  if (currentView === "rooms" && name !== "rooms") stopChatPoll();
  currentView = name;
  saveView(name);
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



/* ---------- model picker and sampling — delegated ---------- */
var loadProviders = mpLoadProviders;
var syncModelSearchLabel = mpSyncLabel;
var renderModelList = mpRenderList;
var hideModelList = mpHideList;
var selectModel = mpSelectModel;
var runOptions = mpRunOptions;
var syncSubmitLabel = mpSyncSubmit;

el.task.addEventListener("keydown", function (e) {
  if (e.key !== "Enter" || e.shiftKey || e.ctrlKey || e.metaKey || e.altKey) return;
  if (!el.enterSends.checked) return;
  e.preventDefault();
  if (!busy && el.task.value.trim()) el.form.requestSubmit();
});

/* ---------- search inside the conversation ---------- */

var clearMarks = searchClear;
var markMatches = searchMark;

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

var nearBottom = scrollNearBottom;
var prefersReducedMotion = scrollPrefersReducedMotion;
function syncScrollButton() { scrollSyncButton(el.transcript, el.scrollBottom); }

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
function showToast(text) { uiToast(text); }

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

/* A goal run streams into its own panel on the goal card, independently of
   the chat composer and of every other goal run. The server serves each
   /api/run connection on its own thread, so concurrency is purely a
   front-end shape: each run keeps its own AbortController, its own streamed
   text and its own status. Starting a second goal while the first streams is
   therefore accepted; only a second run of the *same* goal is refused. */
var goalRuns = {};  // goal id -> { controller, status, text }
/* Board cards started as goals: goal id -> card id. Set when "Work as goal"
   turns a card into a goal, so the goal card can move its board card through
   the board columns as the goal progresses (done when marked done). */
var goalCardLinks = {};

function goalRunStatusLabel(status) {
  if (status === "running") return "running…";
  if (status === "stopped") return "stopped";
  if (status === "failed") return "failed";
  return "finished";
}

/* Appends a streamed line to a run's stored text and, if its panel is on
   screen, to that panel's output node directly — streaming must not rebuild
   the whole goals list on every chunk. */
function appendGoalText(gid, text) {
  var run = goalRuns[gid];
  if (!run) return;
  run.text += text;
  var node = el.goals.querySelector('.goal-run-output[data-goal-output="' + gid + '"]');
  if (node) node.textContent = run.text;
}

/* A run's status changed (finished / stopped / failed): update the stored
   status and rebuild so the panel swaps its Stop button for the verdict. The
   stored text survives, so the rebuild shows everything streamed so far. */
function setGoalStatus(gid, status) {
  var run = goalRuns[gid];
  if (!run) return;
  run.status = status;
  renderGoals(goalState.val);
}

function abortGoalRun(gid) {
  var run = goalRuns[gid];
  if (run && run.controller) run.controller.abort();
}

/* The run panel drawn inside a goal card. Rebuilt from stored state whenever
   the goal list re-renders, so a live run survives a reload or a status
   refresh. */
function renderGoalRunPanel(gid) {
  var run = goalRuns[gid];
  if (!run) return null;
  return T.div({ class: "goal-run", "data-status": run.status, "data-goal-run": gid },
    T.div({ class: "goal-run-head" },
      T.span({ class: "goal-run-status" }, goalRunStatusLabel(run.status)),
      run.status === "running"
        ? UI.button("Stop", function () { abortGoalRun(gid); },
            { kind: "danger", icon: "strike", label: "Stop this goal run" })
        : null),
    T.pre({ class: "goal-run-output", "data-goal-output": gid }, run.text || ""));
}

/* Starts a run that executes an active goal: switches to Goals and streams
   the run into that goal's own panel. Runs are independent — the chat
   composer's single busy guard does not apply, so several goals can be
   worked at once. */
function runGoal(g, opts) {
  if (!g || !g.id) return;
  opts = opts || {};
  var existing = goalRuns[g.id];
  if (existing && existing.status === "running") {
    el.goalsStatus.textContent = "A run for this goal is already in progress; wait for it to finish.";
    return;
  }
  var task = opts.task || ("Work on this goal until the completion criterion is met. When the work is done, land it in the repository so the goal is genuinely complete: create a branch, commit your changes to it, push the branch, open a pull request, and merge it. Do not leave the finished work uncommitted.\n\nObjective: " +
    (g.objective || "") + "\nDone when: " + (g.completion_criterion || ""));
  var controller = new AbortController();
  goalRuns[g.id] = { controller: controller, status: "running", text: "" };
  showView("goals", true);
  renderGoals(goalState.val);
  el.goalsStatus.textContent = opts.task ? "Re-evaluating goal…" : "Starting work on goal…";
  // A goal mirrored onto the board follows the run's lifecycle: its card moves
  // to doing when the run starts, review when it finishes, and back to ready if
  // it is stopped or fails. workCardAsGoal also moves its card explicitly, so
  // this only applies where a goal->card link exists (form-created goals).
  if (goalCardLinks[g.id]) {
    moveGoalCardToColumn(g.id, "doing");
    logGoalRunState(g.id, "running");
  }
  if (opts.onStart) opts.onStart();

  var splitter = makeLineSplitter(function (line) {
    if (line.charCodeAt(0) === 1) {
      var evt;
      try { evt = JSON.parse(line.slice(1)); } catch (e) { return; }
      if (evt.type === "error") appendGoalText(g.id, "\n[" + evt.message + "]\n");
      // A status event is a run lifecycle note (contacting the provider,
      // processing) rather than answer text: show it as a bracketed log line
      // so a run that has just started is not an empty panel labelled
      // "running…" while it waits for its first streamed output.
      else if (evt.type === "status") appendGoalText(g.id, "[ " + evt.message + " ]\n");
      return;
    }
    appendGoalText(g.id, line + "\n");
  });

  fetch("/api/run", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      task: task,
      goal: g.id,
      stream: true,
      session: sessionId,
      max_iterations: opts.maxIterations || null
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
    if (goalRuns[g.id] && goalRuns[g.id].status === "running") {
      setGoalStatus(g.id, "finished");
      el.goalsStatus.textContent = "Goal run finished.";
      if (goalCardLinks[g.id]) {
        moveGoalCardToColumn(g.id, "review");
        logGoalRunState(g.id, "finished");
      }
      if (opts.onDone) opts.onDone("finished");
    }
  }).catch(function (err) {
    splitter.flush();
    if (!goalRuns[g.id]) return;
    if (err && err.name === "AbortError") {
      setGoalStatus(g.id, "stopped");
      el.goalsStatus.textContent = "Goal run stopped.";
      if (goalCardLinks[g.id]) {
        moveGoalCardToColumn(g.id, "ready");
        logGoalRunState(g.id, "stopped");
      }
      if (opts.onDone) opts.onDone("stopped");
    } else {
      appendGoalText(g.id, "\n[goal run failed: " + err.message + "]\n");
      setGoalStatus(g.id, "failed");
      el.goalsStatus.textContent = "Goal run failed: " + err.message;
      if (goalCardLinks[g.id]) {
        moveGoalCardToColumn(g.id, "ready");
        logGoalRunState(g.id, "failed");
      }
      if (opts.onDone) opts.onDone("failed");
    }
  });
}

function workOnGoal(g) {
  // Read the per-run budget box on this goal card (if any). A positive number
  // is a per-run override; anything else sends null so the server falls back
  // to the goal's stored default, then to the global agent.max_iterations.
  var box = el.goals.querySelector('input[data-goal-budget="' + g.id + '"]');
  var n = box ? parseInt(box.value, 10) : NaN;
  runGoal(g, { maxIterations: Number.isFinite(n) && n > 0 ? n : null });
}

/* Re-evaluates whether the goal is already done: runs the agent against the
   completion criterion and asks it to inspect the current state and give a
   verdict, rather than doing the work. Streams into the goal's own panel like
   any other run, and if the agent concludes it is met the user can mark it
   done from the same card. */
function reEvaluateGoal(g) {
  if (!g || !g.id) return;
  runGoal(g, {
    task: "Re-evaluate whether this goal is already done. Do NOT do the work " +
      "or make changes unless strictly needed to verify. Inspect the current " +
      "state (files, board, recorded runs) and report clearly whether the " +
      "completion criterion is met, and why.\n\nObjective: " +
      (g.objective || "") + "\nDone when: " + (g.completion_criterion || "")
  });
}

/* Turns a board card into a goal and starts a run on it, moving the card
   through the board with the run's lifecycle: into Doing when the run starts,
   into Review when it finishes, and back to Ready if it is stopped or fails
   (so it never sits in Doing half-finished). The card id lives in the browser
   and the run streams back its own end, so the movement is a front-end
   concern here. */
function workCardAsGoal(c) {
  if (!c || !c.id) return;
  var objective = (c.title || "").trim();
  if (!objective) {
    el.boardStatus.textContent = "That card has no title to turn into a goal.";
    return;
  }
  var criterion = (c.body || "").trim() ||
    "Complete the work described on the board card \"" + objective + "\".";
  postGoal({ objective: objective, completion_criterion: criterion }, "Goal added from the board.")
    .then(function (d) {
      if (!d) return;
      // The card's objective is the newest goal carrying that text: matching
      // by it and taking the largest `updated` picks the one just created even
      // when an older goal already used the same wording.
      var created = null, createdUp = -1;
      var goals = d.goals || [];
      for (var i = 0; i < goals.length; i++) {
        if (goals[i].objective === objective && (goals[i].updated || 0) > createdUp) {
          created = goals[i];
          createdUp = goals[i].updated || 0;
        }
      }
      if (!created) return;
      goalCardLinks[created.id] = c.id;
      postBoard({ op: "move", id: c.id, column: "doing" }, null);
      runGoal(created, {
        onDone: function (status) {
          var col = status === "finished" ? "review" : "ready";
          postBoard({ op: "move", id: c.id, column: col }, null);
        }
      });
    });
}

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
      // A goal marked done (and only that) carries its board card over to the
      // board's done column: the card was moved to doing when the goal started
      // and review when it finished, so closing the goal closes the loop. This
      // is a front-end concern — the goal id -> card id link lives in this
      // browser (see goalCardLinks), not in state/goals.json.
      if (payload && payload.status === "done" && payload.id) {
        moveGoalCardToColumn(payload.id, "done");
        logGoalRunState(payload.id, "done");
      }
      // A goal created from the Goals view (objective present, no id) is also
      // mirrored onto the board: it gets a card in the column that matches the
      // goal's state (backlog for a fresh active goal). The card is the board's
      // equivalent of the goal, so working on / finishing / closing the goal
      // later moves it through doing -> review -> done (see runGoal and the
      // mark-done branch above). Goals created from an existing board card are
      // skipped here — workCardAsGoal already owns that card and links it.
      if (payload && payload.objective && payload.id === undefined && payload.column === undefined) {
        ensureGoalBoardCard(payload.objective, payload.completion_criterion);
      }
      return d;
    })
    .catch(function (err) {
      el.goalsStatus.textContent = "Goal failed: " + err.message;
      return null;
    });
}

/* Mirrors a freshly-created goal onto the board: finds the card whose title is
   the goal's objective (the board mirror created by workCardAsGoal, or an
   earlier auto-add), or creates one in the backlog column if none exists, then
   records the goal -> card link so the card follows the goal's lifecycle.
   Idempotent: a goal whose objective already matches a card is only linked;
   a goal with no matching card creates one. */
function ensureGoalBoardCard(objective, criterion) {
  if (!objective) return;
  var existing = null;
  for (var i = 0; i < board.cards.length; i++) {
    if (board.cards[i].title === objective) { existing = board.cards[i]; break; }
  }
  var goalId = bestGoalIdFor(objective);
  if (existing) {
    if (goalId) goalCardLinks[goalId] = existing.id;
    return;
  }
  var done = function (d) {
    if (!d || !d.board) return;
    var created = null;
    for (var j = 0; j < d.board.cards.length; j++) {
      if (d.board.cards[j].title === objective) { created = d.board.cards[j]; break; }
    }
    if (created && goalId) goalCardLinks[goalId] = created.id;
  };
  postBoard({ op: "create", title: objective, body: criterion, column: "backlog" }, null).then(done);
}

/* The id of the newest goal carrying `objective`, or null. */
function bestGoalIdFor(objective) {
  var goalId = null, best = -1;
  var goals = goalState.val || [];
  for (var i = 0; i < goals.length; i++) {
    if (goals[i].objective === objective && (goals[i].created || 0) > best) {
      goalId = goals[i].id;
      best = goals[i].created || 0;
    }
  }
  return goalId;
}

/* Moves the board card linked to a goal (if any) into `column`. The link is
   recorded when the card is started as a goal; without one this is a no-op, so
   marking a hand-typed goal done never disturbs the board. */
function moveGoalCardToColumn(goalId, column) {
  var cardId = goalCardLinks[goalId];
  if (!cardId) return;
  postBoard({ op: "move", id: cardId, column: column }, null);
}

/* Records a goal run's state on its board card so the card's activity log
   reflects the run lifecycle, not just which column it sits in. The column
   move already encodes where the work stands (doing / review / ready); the
   log entry says what the run actually did, so a board reader can tell a run
   that finished from one that was stopped or failed without opening the goal
   panel. No-op when the goal has no linked card. */
function logGoalRunState(goalId, state) {
  var cardId = goalCardLinks[goalId];
  if (!cardId) return;
  postBoard({ op: "log", id: cardId, what: "goal run " + state }, null);
}

/* The goal a board card is the mirror of, or null. Reverse of goalCardLinks:
   iterate the goal->card map and return the goal that points at this card. */
function goalIdForCard(cardId) {
  for (var gid in goalCardLinks) {
    if (goalCardLinks[gid] === cardId) return gid;
  }
  return null;
}

el.goalForm.addEventListener("submit", function (e) {
  e.preventDefault();
  var objective = el.goalObjective.value.trim();
  var criterion = el.goalCriterion.value.trim();
  if (!objective || !criterion) return;
  var budgetRaw = el.goalMaxIterations.value.trim();
  var budget = budgetRaw ? parseInt(budgetRaw, 10) : 0;
  var payload = { objective: objective, completion_criterion: criterion };
  if (Number.isFinite(budget) && budget > 0) payload.max_iterations = budget;
  el.goalAdd.disabled = true;
  postGoal(payload, "Goal added.").then(function (d) {
    el.goalAdd.disabled = false;
    // A refused goal keeps what was typed: the criterion is the field most
    // likely to be refused, and retyping the objective to fix it is a tax.
    if (!d) return;
    el.goalObjective.value = "";
    el.goalCriterion.value = "";
    el.goalMaxIterations.value = "";
    // Newest first after renderGoals — start work so defining a goal is not
    // just writing state/goals.json.
    var goals = goalState.val || [];
    var created = null;
    for (var i = 0; i < goals.length; i++) {
      if ((goals[i].status || "active") === "active" && goals[i].objective === objective) {
        created = goals[i];
        break;
      }
    }
    if (created) workOnGoal(created);
  });
});

/* ---------- saved prompts ---------- */

/* Every one of these UIs has a prompt library, and the reason is the same:
   the tasks worth repeating are long, and retyping them is where the habit
   of using the tool dies. */
var loadPrompts = compLoadPrompts;
var savePrompts = function () { compSavePrompts(prompts); };
var prompts = loadPrompts();

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

function promptQuery() { return compPromptQuery(el.task.value); }

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
    label.title = text;
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
function autoGrow() { compAutoGrow(el.task); }
el.task.addEventListener("input", autoGrow);
window.addEventListener("resize", autoGrow);

/* Compaction is driven by transcript bytes against the model's context, and
   both numbers already exist; nothing was showing the ratio. */
function renderContextMeter() {
  el.contextMeter.textContent = compContextLabel(currentSessionMeta(), providerCache, el.modelSelect.value, fmtBytes);
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

function transcriptMarkdown() { return compTranscriptMarkdown(el.transcript, currentSessionMeta, sessionId); }
var downloadText = compDownloadText;

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
      // A card moved into the board's done column is the board saying the
      // work is finished. When that card is the mirror of a goal, close the
      // goal too so the two stay in step: the user dragged the card to done,
      // and the Goals panel should agree rather than still show it active.
      if (payload.op === "move" && payload.column === doneColumn()) {
        var gid = goalIdForCard(payload.id);
        if (gid) {
          var goal = null;
          var gl = goalState.val || [];
          for (var gi = 0; gi < gl.length; gi++) {
            if (gl[gi].id === gid) { goal = gl[gi]; break; }
          }
          // Skip when the goal is already done (or gone): avoids re-posting
          // when a goal->done card move bounces back through here.
          if (goal && (goal.status || "active") !== "done") {
            postGoal({ id: gid, status: "done" }, "Goal marked done from the board.");
          }
        }
      }
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

/* The board derives from the card set, the column set and the "only mine"
   filter. It used to clear #board and rebuild it, which is what forced the
   focus snapshot and the per-card edit drafts: a sub-action anywhere rebuilt
   everything. */
var boardState = van.state({ columns: [], cards: [], mine: false, me: "", open: null, text: "", blockedOnly: false, priority: "", assignee: "" });

function boardFilterState() {
  return {
    text: (document.getElementById("board-filter-input") || {}).value || "",
    blockedOnly: !!(document.getElementById("board-filter-blocked") || {}).checked,
    priority: (document.getElementById("board-filter-priority") || {}).value || "",
    assignee: (document.getElementById("board-filter-assignee") || {}).value || ""
  };
}

function renderBoard(next) {
  if (next) { board.columns = next.columns || []; board.cards = next.cards || []; }
  var bf = boardFilterState();
  boardState.val = {
    columns: board.columns || [],
    cards: board.cards || [],
    mine: el.boardMine.checked,
    me: (el.instanceChip.textContent || "").trim(),
    open: openCardId,
    text: bf.text.trim().toLowerCase(),
    blockedOnly: bf.blockedOnly,
    priority: bf.priority,
    assignee: bf.assignee
  };
  // Trello-like assignee filter options: derive from cards present
  (function(){
    var sel = document.getElementById("board-filter-assignee");
    if (!sel) return;
    var keep = sel.value;
    var seen = {};
    var opts = [""];
    board.cards.forEach(function(c){ if(c.assignee && !seen[c.assignee]){ seen[c.assignee]=true; opts.push(c.assignee); } });
    // keep "unassigned" sentinel as well
    if (board.cards.some(function(c){ return !c.assignee; })) opts.push("(unassigned)");
    sel.textContent = "";
    opts.forEach(function(n){
      var o=document.createElement("option");
      o.value=n; o.textContent=n==="" ? "All" : n;
      sel.appendChild(o);
    });
    if (opts.indexOf(keep) !== -1) sel.value = keep;
  })();

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
    .filter(function (c) { if (s.assignee) { if (s.assignee === "(unassigned)") { if (c.assignee) return false; } else if (c.assignee !== s.assignee) return false; } if (s.blockedOnly && blockers(c).length === 0) return false; if (s.priority && (c.priority || "normal") !== s.priority) return false; if (s.text && (c.title + " " + (c.body || "") + " " + (c.assignee || "")).toLowerCase().indexOf(s.text) === -1) return false; return true; })
    .sort(function (a, b) { return (a.order || 0) - (b.order || 0); });

  var over = col.wip && shown.length > col.wip;
  var count = T.span({
    class: "board-col-count",
    "data-over": over ? "true" : null,
    // Over the limit is said in words as well as colour, because colour is the
    // one thing forced-colors and colour blindness both take away.
    title: over ? shown.length + " of " + col.wip + ", over the limit" : null
  }, shown.length + (col.wip ? " / " + col.wip : ""));

  // Trello-style empty lane placeholder — with quick-add affordance
  var items = shown.map(function (c) { return T.li(cardNode(c)); });
  if (!shown.length) {
    var emptySlot = document.createElement("li");
    emptySlot.className = "board-empty-slot";
    emptySlot.setAttribute("aria-hidden", "true");
    emptySlot.textContent = "Drop here — or ";
    var addLink = document.createElement("button");
    addLink.type = "button"; addLink.className = "secondary";
    addLink.textContent = "Add card";
    addLink.addEventListener("click", function(e){ e.stopPropagation(); openQuickAdd(); });
    emptySlot.appendChild(addLink);
    items.push(emptySlot);
  }
  var list = T.ul({
    class: "board-cards",
    "aria-label": col.title + ", " + shown.length + (shown.length === 1 ? " card" : " cards")
  }, items);

  var quickAdd = T.div({ class: "board-quick-add", hidden: true });
  var qaInput = document.createElement("input");
  qaInput.type = "text"; qaInput.placeholder = "Card title…"; qaInput.maxLength = 500;
  var qaSave = document.createElement("button"); qaSave.type = "button"; qaSave.className = "secondary"; qaSave.textContent = "Add";
  var qaCancel = document.createElement("button"); qaCancel.type = "button"; qaCancel.className = "secondary"; qaCancel.textContent = "✕";
  quickAdd.appendChild(qaInput); quickAdd.appendChild(qaSave); quickAdd.appendChild(qaCancel);
  function openQuickAdd(){ quickAdd.hidden = false; qaInput.focus(); }
  function closeQuickAdd(){ quickAdd.hidden = true; qaInput.value = ""; }
  qaCancel.addEventListener("click", function(e){ e.stopPropagation(); closeQuickAdd(); });
  qaInput.addEventListener("keydown", function(e){
    if (e.key === "Enter" && qaInput.value.trim()) { e.preventDefault(); doCreate(); }
    else if (e.key === "Escape") { e.preventDefault(); closeQuickAdd(); }
    else if (e.key === "Tab" && !e.shiftKey && qaInput.value.trim() === "") { /* Slack-like: Tab out closes empty quick-add */ }
  });
  // Slack-like: typing @ in quick-add shows available assignees as placeholder hint
  qaInput.addEventListener("input", function(){
    var v = qaInput.value;
    var atIdx = v.lastIndexOf("@");
    if (atIdx !== -1) {
      var q = v.slice(atIdx + 1).toLowerCase();
      var peers = (knownPeers || []).map(function(p){ return p.name || p; });
      var hit = peers.find(function(n){ return n.toLowerCase().indexOf(q) === 0; });
      if (hit) qaInput.title = "Assign to @" + hit + " — press Tab to accept";
      else qaInput.title = "";
    } else qaInput.title = "";
  });
  function doCreate(){
    var t = qaInput.value.trim(); if (!t) return;
    qaSave.disabled = true;
    postBoard({ op: "create", title: t, column: col.id }, "Card added to " + col.title + ".").finally(function(){ qaSave.disabled = false; closeQuickAdd(); });
  }
  qaSave.addEventListener("click", function(e){ e.stopPropagation(); doCreate(); });
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
      (function(){
        var collapse = document.createElement("button");
        collapse.type = "button"; collapse.className = "secondary"; collapse.textContent = "‹";
        collapse.title = "Collapse lane";
        collapse.style.minHeight = "22px"; collapse.style.padding = "0 0.35rem"; collapse.style.fontSize = "12px"; collapse.style.borderRadius = "999px";
        collapse.addEventListener("click", function(e){
          e.stopPropagation();
          var isCol = colEl.getAttribute("data-collapsed") === "true";
          colEl.setAttribute("data-collapsed", String(!isCol));
          collapse.textContent = isCol ? "‹" : "›";
          collapse.title = isCol ? "Collapse lane" : "Expand lane";
        });
        return collapse;
      })(),
      T.h3({ class: "board-col-title", id: "board-col-" + col.id }, col.title),
      T.span({ style: "display:flex; gap:0.25rem; align-items:center;" },
        (function(){
          var add = document.createElement("button");
          add.type = "button"; add.className = "secondary"; add.textContent = "+";
          add.title = "Add card to " + col.title;
          add.style.minHeight = "24px"; add.style.padding = "0 0.45rem"; add.style.fontSize = "12px"; add.style.borderRadius = "999px";
          add.addEventListener("click", function(e){
            e.stopPropagation();
            // Trello now does inline quick-add, not prompt — open the row input
            if (quickAdd.hidden) openQuickAdd(); else closeQuickAdd();
          });
          var wrap = document.createElement("span");
          wrap.appendChild(add);
          var isDone = (col.id === "done" || col.title.toLowerCase() === "done");
          var isArchived = false;
          try{ isArchived = window.localStorage.getItem("clanker.boardArchive") === "1"; }catch(_){}
          if (isDone) {
            var arch = document.createElement("button");
            var archived = isArchived && document.querySelector('[data-column="done"]') && document.querySelector('[data-column="done"]').hidden;
            // reflect actual hidden state if already applied
            try{ if (window.clankerBoardArchive) archived = true; }catch(_){}
            arch.type = "button"; arch.className = "secondary"; arch.textContent = archived ? "Unarchive" : "Archive";
            arch.title = archived ? "Show done cards again" : "Archive done cards (hide from this view)";
            arch.style.minHeight = "24px"; arch.style.padding = "0 0.45rem"; arch.style.fontSize = "11px"; arch.style.borderRadius = "999px";
            arch.addEventListener("click", function(e){
              e.stopPropagation();
              var currentlyArchived = false;
              try{ currentlyArchived = window.localStorage.getItem("clanker.boardArchive") === "1"; }catch(_){}
              try{ if (window.clankerBoardArchive) currentlyArchived = true; }catch(_){}
              var nextArchived = !currentlyArchived;
              try{
                if (nextArchived) window.localStorage.setItem("clanker.boardArchive", "1");
                else window.localStorage.removeItem("clanker.boardArchive");
                window.clankerBoardArchive = nextArchived;
              }catch(_){}
              var doneCol2 = document.querySelector('[data-column="done"]');
              if (doneCol2) doneCol2.hidden = nextArchived;
              try{ renderBoard(null); }catch(_){}
              arch.textContent = nextArchived ? "Unarchive" : "Archive";
              arch.title = nextArchived ? "Show done cards again" : "Archive done cards (hide from this view)";
            });
            wrap.appendChild(arch);
          }
          return wrap;
        })()
      ),
      count),
    list,
    quickAdd);
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
  if (c.priority && c.priority !== "normal") b.setAttribute("data-priority", c.priority);
  b.draggable = true;
  b.setAttribute("data-card", c.id);
  if (c.id === openCardId) b.setAttribute("aria-current", "true");
  // Trello cover strip — priority tint at top edge
  if (c.priority && c.priority !== "normal") {
    var cover = document.createElement("div");
    cover.className = "card-cover";
    cover.setAttribute("data-priority", c.priority);
    b.appendChild(cover);
  }
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
    var totalN = c.subtasks.length;
    var pct = totalN ? Math.round(doneN / totalN * 100) : 0;
    var prog = document.createElement("span");
    prog.className = "card-progress";
    prog.textContent = doneN + "/" + totalN + " · " + pct + "%";
    meta.appendChild(prog);
    var bar = document.createElement("div");
    bar.className = "card-progress-bar";
    bar.setAttribute("data-done", String(doneN === totalN && totalN > 0));
    bar.setAttribute("role", "progressbar");
    bar.setAttribute("aria-valuenow", String(pct));
    bar.setAttribute("aria-valuemin", "0");
    bar.setAttribute("aria-valuemax", "100");
    var fill = document.createElement("span");
    fill.style.width = pct + "%";
    bar.appendChild(fill);
    // attach bar outside meta so it spans card width
    b._progressBar = bar;
  }
  // Trello-style member avatar (initials) when assigned, Slack-style mention
  var membersWrap = null;
  if (c.assignee) {
    membersWrap = document.createElement("span");
    membersWrap.className = "card-members";
    var av = document.createElement("span");
    av.className = "card-member";
    av.textContent = (c.assignee.trim().charAt(0) || "?").toUpperCase();
    av.title = c.assignee + " — click to reassign";
    av.setAttribute("role", "button");
    av.setAttribute("tabindex", "0");
    av.addEventListener("click", function(e){
      e.stopPropagation();
      var next2 = prompt("Assign to (empty to unassign):", c.assignee || "");
      if (next2 === null) return;
      postBoard({ op: "update", id: c.id, assignee: next2.trim() }, next2.trim() ? "Assigned to " + next2.trim() + "." : "Unassigned.");
    });
    av.addEventListener("keydown", function(e){ if(e.key==="Enter"||e.key===" "){ e.preventDefault(); av.click(); } });
    membersWrap.appendChild(av);
  } else {
    var who = document.createElement("span");
    who.textContent = "unassigned";
    who.title = "Unassigned — click to assign";
    who.style.cursor = "pointer";
    who.setAttribute("role", "button");
    who.setAttribute("tabindex", "0");
    who.addEventListener("click", function(e){
      e.stopPropagation();
      var next = prompt("Assign to (empty to unassign):", c.assignee || "");
      if (next === null) return;
      postBoard({ op: "update", id: c.id, assignee: next.trim() }, next.trim() ? "Assigned to " + next.trim() + "." : "Unassigned.");
    });
    who.addEventListener("keydown", function(e){ if(e.key==="Enter"||e.key===" "){ e.preventDefault(); who.click(); } });
    meta.appendChild(who);
  }
  if (c.usage && c.usage.cost) {
    var cost = document.createElement("span");
    cost.textContent = fmtCost(c.usage.cost);
    meta.appendChild(cost);
  }
  if (membersWrap) meta.appendChild(membersWrap);
  if (meta.childNodes.length) b.appendChild(meta);
  if (b._progressBar) b.appendChild(b._progressBar);

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

  var asGoal = document.createElement("button");
  asGoal.type = "button";
  asGoal.className = "secondary";
  asGoal.textContent = "Work as goal";
  asGoal.title = "Create a goal from this card and run it. The card moves to Doing, then to Review when the goal finishes.";
  asGoal.addEventListener("click", function () {
    delete cardDrafts[c.id];
    workCardAsGoal(c);
  });
  fields.appendChild(asGoal);

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
  // Trello-style checklist progress bar (also on card face)
  if ((c.subtasks || []).length) {
    var dN = c.subtasks.filter(function(ss){ return ss.done; }).length;
    var tN = c.subtasks.length;
    var pct2 = tN ? Math.round(dN / tN * 100) : 0;
    var track = document.createElement("div");
    track.className = "card-progress-bar";
    track.setAttribute("data-done", String(dN === tN && tN>0));
    track.setAttribute("role", "progressbar");
    track.setAttribute("aria-valuenow", String(pct2));
    track.setAttribute("aria-valuemin", "0");
    track.setAttribute("aria-valuemax", "100");
    track.setAttribute("aria-label", "Checklist " + dN + " of " + tN);
    var fill2 = document.createElement("span");
    fill2.style.width = pct2 + "%";
    track.appendChild(fill2);
    var pctLabel = document.createElement("span");
    pctLabel.className = "card-progress"; pctLabel.textContent = dN + "/" + tN + " · " + pct2 + "%";
    pctLabel.style.marginLeft = "0.5rem";
    var progRow = document.createElement("div");
    progRow.className = "detail-row";
    progRow.style.alignItems = "center";
    progRow.appendChild(track); track.style.flex = "1";
    progRow.appendChild(pctLabel);
    subs.appendChild(progRow);
  }
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
  el.cardAdd.disabled = true;
  postBoard({ op: "create", title: title, column: el.cardColumn.value }, "Card added.").then(function (ok) {
    el.cardAdd.disabled = false;
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
["board-filter-input","board-filter-mine","board-filter-blocked","board-filter-priority","board-filter-assignee"].forEach(function(id){
  var n=document.getElementById(id);
  if(!n) return;
  n.addEventListener(id==="board-filter-input" ? "input" : "change", function(){ renderBoard(null); });
});
var boardMine=document.getElementById("board-filter-mine");
if(boardMine) boardMine.addEventListener("change", function(){ var top=document.getElementById("board-mine"); if(top) top.checked=boardMine.checked; renderBoard(null); });
var topMine=document.getElementById("board-mine");
if(topMine) topMine.addEventListener("change", function(){ var b=document.getElementById("board-filter-mine"); if(b) b.checked=topMine.checked; renderBoard(null); });
// board list view (full-fledged todo list)
(function(){
  var listView=document.getElementById("board-list-view");
  var sortSel=document.getElementById("board-sort");
  if(!listView) return;
  function fmtBoardDate(ts){
    if(!ts) return "";
    var d=new Date(ts*1000);
    var y=d.getFullYear(), m=String(d.getMonth()+1).padStart(2,"0"), da=String(d.getDate()).padStart(2,"0");
    return y+"-"+m+"-"+da;
  }
  function boardListRows(){
    var s=boardState.val;
    var rows=[].concat(s.cards||[]);
    // reuse same filters as columns
    rows=rows.filter(function(c){
      if(s.assignee) { if(s.assignee==="(unassigned)"){ if(c.assignee) return false; } else if(c.assignee!==s.assignee) return false; }
      if(s.mine && c.assignee!==s.me) return false;
      if(s.blockedOnly && blockers(c).length===0) return false;
      if(s.priority && (c.priority||"normal")!==s.priority) return false;
      if(s.text && (c.title+" "+(c.body||"")+" "+(c.assignee||"")).toLowerCase().indexOf(s.text)===-1) return false;
      return true;
    });
    var how=(sortSel && sortSel.value) || "updated";
    rows.sort(function(a,b){
      if(how==="priority"){
        var rank={high:0, normal:1, low:2};
        var ra=rank[a.priority||"normal"]||1, rb=rank[b.priority||"normal"]||1;
        if(ra!==rb) return ra-rb;
      } else if(how==="due"){
        var da=a.deadline||Infinity, db=b.deadline||Infinity;
        if(da!==db) return da-db;
      } else if(how==="cost"){
        var ca=(a.usage&&a.usage.cost)||0, cb=(b.usage&&b.usage.cost)||0;
        if(ca!==cb) return cb-ca;
      }
      return (b.created||0)-(a.created||0);
    });
    return rows;
  }
  function renderList(){
    var rows=boardListRows();
    listView.textContent="";
    if(!rows.length){
      var empty=document.createElement("p");
      empty.className="run-empty";
      empty.textContent="No cards match the current filters.";
      listView.appendChild(empty);
      return;
    }
    var table=document.createElement("table");
    table.className="usage board-list-table";
    var thead=document.createElement("thead");
    var hr=document.createElement("tr");
    ["Title","Column","Assignee","Due","Priority","Cost",""].forEach(function(h){
      var th=document.createElement("th"); th.textContent=h; hr.appendChild(th);
    });
    thead.appendChild(hr); table.appendChild(thead);
    var tbody=document.createElement("tbody");
    rows.forEach(function(c){
      var tr=document.createElement("tr");
      var titleTd=document.createElement("td"); titleTd.textContent=c.title; titleTd.style.maxWidth="18rem"; titleTd.style.overflow="hidden"; titleTd.style.textOverflow="ellipsis"; titleTd.style.whiteSpace="nowrap"; tr.appendChild(titleTd);
      var colTd=document.createElement("td"); colTd.textContent=c.column; tr.appendChild(colTd);
      var whoTd=document.createElement("td"); whoTd.textContent=c.assignee||"—"; tr.appendChild(whoTd);
      var dueTd=document.createElement("td"); dueTd.textContent=c.deadline?fmtBoardDate(c.deadline):"—"; if(c.deadline){ var ds=dueState(c); if(ds==="late") dueTd.style.color="var(--danger)"; else if(ds==="soon") dueTd.style.color="var(--warn-text)"; } tr.appendChild(dueTd);
      var prTd=document.createElement("td"); prTd.textContent=c.priority||"normal"; tr.appendChild(prTd);
      var costTd=document.createElement("td"); costTd.className="num"; costTd.textContent=(c.usage&&c.usage.cost)?fmtCost(c.usage.cost):"—"; tr.appendChild(costTd);
      var actTd=document.createElement("td");
      var openBtn=document.createElement("button"); openBtn.type="button"; openBtn.className="secondary"; openBtn.textContent="Open"; openBtn.addEventListener("click", function(){ openCardId=c.id; renderBoard(board); document.getElementById("card-detail").scrollIntoView({behavior:"smooth", block:"start"}); }); actTd.appendChild(openBtn);
      if(c.assignee!==((document.getElementById("instance-chip")||{}).textContent||"").trim()){
        var claimBtn=document.createElement("button"); claimBtn.type="button"; claimBtn.className="secondary"; claimBtn.textContent="Claim"; claimBtn.style.marginLeft="0.4rem"; claimBtn.addEventListener("click", function(){ postBoard({op:"update", id:c.id, assignee: ((document.getElementById("instance-chip")||{}).textContent||"").trim()}, "Claimed."); }); actTd.appendChild(claimBtn);
      }
      tr.appendChild(actTd);
      tbody.appendChild(tr);
    });
    table.appendChild(tbody); listView.appendChild(table);
  }
  // bind on boardState changes
  var _origRenderBoard = renderBoard;
  // wrap to also refresh list
  window.renderBoard = function(next){ var r=_origRenderBoard(next); try{ renderList(); }catch(_){} return r; };
  // also directly bind to state
  try{
    // VanJS bind doesn't expose subscribe; poll via mutation: boardState.val setter triggers list
    var _lastCards="";
    setInterval(function(){
      try{
        var cur=JSON.stringify(boardState.val.cards||[])+boardState.val.text+boardState.val.mine+boardState.val.blockedOnly+boardState.val.priority+boardState.val.assignee;
        if(cur!==_lastCards){ _lastCards=cur; renderList(); }
      }catch(_){}
    }, 600);
  }catch(_){}
  if(sortSel) sortSel.addEventListener("change", renderList);
  // initial
  try{ renderList(); }catch(_){}
})();


/* ---------- web UI plugins ----------

   The page is itself served by a WASM tool, so it is already a plugin; this
   lets it host plugins of its own. A plugin is a directory under
   tools/webui-plugins/ with a manifest and an app.js, served same-origin so
   the strict CSP covers it without widening: no eval, no other origin, and a
   disabled plugin's assets are never served at all.

   A view a plugin registers is an ordinary view: same rail button, same panel,
   same digit shortcut, same URL fragment. */

var pluginViews = pluginsViews;
var loadPluginAssets = pluginsLoadPluginAssets;
var loadWebuiPlugins = pluginsLoadWebuiPlugins;
var renderWebuiPlugins = pluginsRenderWebuiPlugins;
pluginsBind({ VIEWS: VIEWS, viewLoaders: viewLoaders, wireTab: wireTab, showView: showView, el: el, readJson: readJson, fmtBytes: fmtBytes, fmtInt: fmtInt, fmtCost: fmtCost, formatChatTime: formatChatTime });

function loadLogList() { return logsLoadLogList(el, readJson, fmtBytes); }
function loadLog(name) { return logsLoadLog(name, el, readJson, fmtBytes); }

el.logSelect.addEventListener("change", function () { loadLog(el.logSelect.value); });
el.logsRefresh.addEventListener("click", function () { loadLogList(); });

// Phase 5 progress streaming — reuses /api/run event channel shape via fetch + reader.
// History + revert are read from state/history and improve loop artifacts where available.
(function(){
  var progCtrl=null, progEl=document.getElementById("progress-log"), progStatus=document.getElementById("progress-status"), progHist=document.getElementById("progress-history");
  var stopBtn=document.getElementById("progress-stop");
  function append(t){ if(!progEl) return; progEl.textContent += t; progEl.scrollTop=progEl.scrollHeight; }
  function renderHistory(){
    if(!progHist) return;
    Promise.all([
      fetch("/api/runs").then(function(r){ return r.json().then(function(d){ var txt=d.text||""; try{ return txt?JSON.parse(txt): (Array.isArray(d)?d:(d.runs||[])); }catch(_){ return []; } }); }).catch(function(){ return []; }),
      fetch("/api/providers").then(function(r){ return r.json(); }).catch(function(){ return null; })
    ]).then(function(vals){
      var runs=vals[0]||[]; progHist.textContent="";
      if(!runs.length){ var p=document.createElement("p"); p.className="run-empty"; p.textContent="No runs yet — start a task in Chat and it appears here and in the gate history."; progHist.appendChild(p); return; }
      var recent=runs.slice(0, 8);
      var ul=document.createElement("ul"); ul.className="fleet-roster-list";
      recent.forEach(function(r){
        var li=document.createElement("li"); li.className="fleet-meta";
        var a=document.createElement("a"); a.href="#"; a.textContent=(r.run_id||"run")+" · "+(r.provider||"?")+" · "+((r.duration_ms||0)+"ms");
        a.addEventListener("click", function(e){ e.preventDefault(); if(typeof openRun==="function") openRun(r.run_id); });
        li.appendChild(a);
        var rev=document.createElement("button"); rev.type="button"; rev.className="secondary"; rev.textContent="Revert"; rev.style.marginLeft="0.5rem";
        rev.addEventListener("click", function(){
          if(!confirm("Revert to "+r.run_id+"? This restores the worktree from that run where available.")) return;
          append("Revert requested for "+r.run_id+" — use CLI `clanker revert "+r.run_id+"` if server-side revert is not enabled.\n");
        });
        li.appendChild(rev);
        ul.appendChild(li);
      });
      progHist.appendChild(ul);
    }).catch(function(){});
  }
  function wire(id, body){
    var b=document.getElementById(id); if(!b) return;
    b.addEventListener("click", function(){
      if(progCtrl) try{progCtrl.abort();}catch(_){}
      if(progEl) progEl.textContent="";
      if(progStatus) progStatus.textContent="Running…";
      if(stopBtn) stopBtn.hidden=false;
      progCtrl=new AbortController();
      fetch("/api/run", { method:"POST", headers:{ "Content-Type":"application/json" }, body: JSON.stringify(body), signal: progCtrl.signal })
        .then(function(r){
          if(!r.ok) return r.text().then(function(t){ throw new Error(t || ("HTTP "+r.status)); });
          if(!r.body) throw new Error("No stream");
          var reader=r.body.getReader(), dec=new TextDecoder(), buf="", lastSummary="";
          function pump(){ return reader.read().then(function(ch){
            if(ch.done){
              if(buf) append(buf+"\n");
              // try to parse trailing summary line as structured gate/eval output
              try{
                var maybe=JSON.parse(lastSummary);
                if(maybe && typeof maybe==="object") append("\n[structured]\n"+JSON.stringify(maybe, null, 2)+"\n");
              }catch(_){}
              if(progStatus) progStatus.textContent="Done.";
              if(stopBtn) stopBtn.hidden=true;
              progCtrl=null; renderHistory(); return;
            }
            buf += dec.decode(ch.value, {stream:true});
            var lines=buf.split("\n"); buf=lines.pop();
            lines.forEach(function(line){
              if(!line) return;
              if(line.charCodeAt(0)===1){ try{ var e=JSON.parse(line.slice(1)); if(e.type==="tool_call") append("… "+(e.names||"")+"\n"); else if(e.type==="tool_result") { var out=""; try{ out=JSON.parse(e.output||""); }catch(_){ out=e.output||""; } if(out && typeof out==="object") append(JSON.stringify(out, null, 2)+"\n"); else if(out) append(String(out).slice(0, 1200)+"\n"); else append("  done "+(e.ms||0)+"ms\n"); if(e.type==="done" && e.output) lastSummary=e.output; } else if(e.type==="done"){ lastSummary=e.output||""; if(lastSummary) append(lastSummary.slice(0, 2000)+"\n"); else append("done\n"); } else if(e.type==="error") append("[error] "+(e.message||"")+"\n"); }catch(_){ append(line.slice(1)+"\n"); } }
              else { lastSummary=line; append(line+"\n"); }
            });
            return pump();
          }); }
          return pump();
        }).catch(function(e){
          if(e && e.name==="AbortError") { if(progStatus) progStatus.textContent="[stopped]"; }
          else { append("[failed] "+(e.message||e)+"\n"); if(progStatus) progStatus.textContent=e.message||"Failed"; }
          if(stopBtn) stopBtn.hidden=true; progCtrl=null; renderHistory();
        });
    });
  }
  wire("progress-gate", { task:"run the gate: zig build, zig build test, zig fmt check, and summarize pass/fail per check", stream:true, session: (typeof sessionId!=="undefined"?sessionId:"progress") });
  wire("progress-eval", { task:"run evals: list tasks with criteria, run each, and summarize scores", stream:true, session: (typeof sessionId!=="undefined"?sessionId:"progress") });
  wire("progress-providers", { task:"check providers: for each configured provider/model report reachable/missing auth/rate-limited", stream:true, session: (typeof sessionId!=="undefined"?sessionId:"progress") });
  if(stopBtn) stopBtn.addEventListener("click", function(){ if(progCtrl) try{progCtrl.abort();}catch(_){} });
  var histBtn=document.getElementById("progress-history-refresh");
  if(histBtn) histBtn.addEventListener("click", renderHistory);
  renderHistory();
})();

/* ---------- overlays: command palette and shortcut sheet ---------- */

var openOverlay = overlayOpen;
var closeOverlay = overlayClose;
var focusableIn = overlayFocusableIn;
var trapOverlayTab = overlayTrapTab;

var textPrompt = dialogTextPrompt;
var finishTextPrompt = dialogFinishTextPrompt;
dialogBindDialog(el, overlayOpen, overlayClose);

van.add(el.helpOpen, icon("help", 15));
el.helpOpen.addEventListener("click", function () { openOverlay(el.help, el.helpClose); });
el.helpClose.addEventListener("click", function () { closeOverlay(el.help); });

var providerCacheHolder = { list: providerCache };
mpBind({ el: el, readJson: readJson, fmtInt: fmtInt, allUsage: allUsage, renderUsage: renderUsage, renderContextMeter: renderContextMeter, fuzzyMatch: fuzzyMatch, providerCacheHolder: providerCacheHolder });

paletteBind({
  VIEWS: VIEWS, showView: showView, el: el,
  refs: { knownSessionsHolder: knownSessionsHolder, allRunsHolder: allRunsHolder, board: board, goalState: goalState, allToolsHolder: allToolsHolder, sessionLabel: sessionLabel, runLabel: runLabel },
  setRailOpen: setRailOpen, switchSession: switchSession, openRun: openRun, renderBoard: renderBoard, showToolDetail: showToolDetail,
  setOpenCardId: function (id) { openCardId = id; }
});
document.addEventListener("keydown", function (e) {
  if (paletteKeyHandle(e, { el: el, finishTextPrompt: finishTextPrompt, setRailOpen: setRailOpen })) return;
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

/* The view to open on load: a URL fragment naming a real view wins; otherwise
   the last view this browser was on (persisted by showView) is reopened so a
   hard refresh keeps you on the same page instead of dropping to chat. */
function lastView() {
  try {
    var v = window.localStorage.getItem("clanker.view");
    if (v && VIEWS.indexOf(v) !== -1) return v;
  } catch (e) {}
  return "";
}
var openingView = openingHash && VIEWS.indexOf(openingHash) !== -1 ? openingHash : lastView() || "chat";

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
showView(openingView, false);
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
