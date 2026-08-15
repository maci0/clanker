import { readJson as utilReadJson, newSessionId as utilNewSessionId, fmtBytes as utilFmtBytes, clip as utilClip, sessionLabel as utilSessionLabel, summarizeTitle as utilSummarizeTitle, recencyGroup as utilRecencyGroup, fmtInt as utilFmtInt, fmtMs as utilFmtMs, fmtCost as utilFmtCost, formatChatTime as utilFormatChatTime, fuzzyMatch as utilFuzzyMatch, escapeHtml as utilEscapeHtml, searchFold as utilSearchFold, view_digit_max } from "./core/utils.js";
import { T as vanT, bind as vanBind, toast as uiToast, skeletonRows as vanSkeletonRows, setTurnPhase as vanSetTurnPhase, UI as vanUI, state as uiState, add as uiAdd, uiConfirm, uiPrompt, upgradePfButton, upgradePfButtons, upgradePfChip, upgradePfUi } from "./core/ui.js";
import { icon as iconFn } from "./core/icons.js";
import { vendorLoads as vendorLoadsMod, loadVendor as loadVendorMod, loadD3 as loadD3Mod, loadHljs as loadHljsMod, registerToml as registerTomlMod, copyText as copyTextMod, scrollTo as vendorScrollTo } from "./core/vendor.js";
import { loadTheme as loadThemeMod, applyTheme as applyThemeMod, bindThemeToggle as bindThemeToggleMod } from "./core/theme.js";
import { dmRoom as dmRoomMod, dmSafeName as dmSafeNameMod, dmPartner as dmPartnerMod, isDm as isDmMod, clankerMark as clankerMarkMod, CLANKER_MARKS as CLANKER_MARKSMod, messageKey as chatMessageKey, hasServerId as chatHasServerId } from "./core/chat.js";
import { runLabel as runLabelMod, modelLabel as modelLabelMod, chatRoomLabel as chatRoomLabelMod } from "./core/labels.js";
import { makeLineSplitter as makeLineSplitterMod, onLive as liveOn, liveOk as liveIsUp } from "./core/stream.js";
import { INLINE_RE as mdINLINE_RE, inlineInto as mdInlineInto, paragraphInto as mdParagraphInto, tableRow as mdTableRow, renderMarkdown as mdRenderMarkdown, highlightInto as mdHighlightInto, buildCodeBlock as mdBuildCodeBlock, finalizeAnswer as mdFinalizeAnswer } from "./lib/markdown.js";
import { metricsFor as graphMetricsFor, buildStages as graphBuildStages, graphSummaryText as graphSummaryTextMod, toDagInput as graphToDagInput, buildIncompleteNode as graphBuildIncompleteNode, buildNodeBox as graphBuildNodeBox, layoutGraph as graphLayoutGraph } from "./lib/graph.js";
import { boardActionLine as boardActionLineMod } from "./lib/board.js";
import { openOverlay as overlayOpen, closeOverlay as overlayClose, focusableIn as overlayFocusableIn, trapOverlayTab as overlayTrapTab } from "./core/overlay.js";
import { clearMarks as searchClear, markMatches as searchMark, turnForMessage } from "./core/search.js";
import { loadPrompts as compLoadPrompts, savePrompts as compSavePrompts, promptQuery as compPromptQuery, autoGrow as compAutoGrow, contextLabel as compContextLabel, transcriptMarkdown as compTranscriptMarkdown, downloadText as compDownloadText, forgetPrompt as compForgetPrompt, setActiveItem as compSetActiveItem, loadDrafts as compLoadDrafts, saveDrafts as compSaveDrafts, draftFor as compDraftFor, setDraft as compSetDraft } from "./core/composer.js";
import { nearBottom as scrollNearBottom, prefersReducedMotion as scrollPrefersReducedMotion, syncScrollButton as scrollSyncButton, scrollChatToLatest as scrollChatLatest, conversationScroller as scrollChatBox } from "./core/scroll.js";
import { textPrompt as dialogTextPrompt, finishTextPrompt as dialogFinishTextPrompt, bindDialog as dialogBindDialog } from "./core/dialog.js";
import { renderUsageTable as usageRenderTable } from "./core/usage.js";
import { renderStatusInto as statusRenderInto } from "./core/status.js";
import { pendingImages as attachImages, max_image_bytes as attachMaxBytes, renderAttachments as attachRender, addMediaFile as attachAddMedia } from "./core/attachments.js";
import { loadLog as logsLoadLog, loadLogList as logsLoadLogList } from "./core/logs.js";
import { pluginViews as pluginsViews, bindPlugins as pluginsBind, loadWebuiPlugins as pluginsLoadWebuiPlugins, loadPluginAssets as pluginsLoadPluginAssets, renderWebuiPlugins as pluginsRenderWebuiPlugins } from "./core/plugins.js";
import { bindPalette as paletteBind, paletteKeyHandler as paletteKeyHandle } from "./core/palette.js";
import { getProviderCache as mpProviderCache, getModelIndex as mpModelIndex, loadProviders as mpLoadProviders, runOptions as mpRunOptions, syncSubmitLabel as mpSyncSubmit, bindModelPicker as mpBind, openModelPicker as mpOpen, toggleModelPicker as mpToggle, setModelChipLabel as mpSetChip } from "./core/modelpicker.js";
import { renderTools as toolsRenderTools, showToolDetail as toolsShowDetail, toggleTool as toolsToggle, loadTools as toolsLoadTools, loadWorkflows as toolsLoadWorkflows, loadSkills as toolsLoadSkills, bindTools as toolsBind } from "./core/tools.js";
import { board, loadBoardRooms, renderBoard, setOpenCardId, cardById, cardModalKeyHandler, bindBoard } from "./features/board.js";
import { goalState, loadGoals, bindGoals } from "./features/goals.js";
import { goalStatusLabel } from "./core/goals.js";
import { selectedKnowledge as kbSelected, loadKnowledge as kbLoad, bindKnowledge as kbBind } from "./features/knowledge.js";
import { loadPromptsView as promptsLoadView, bindPrompts as promptsBind } from "./features/prompts.js";
import { loadModelsView as modelsLoadView, bindModels as modelsBind } from "./features/models.js";
import { loadScheduleView as scheduleLoadView, bindSchedule as scheduleBind } from "./features/schedule.js";
import { loadSearchView as searchLoadView, bindSearch as searchBind, bindSearchDeps as searchDeps, runSearch as searchRun } from "./features/search.js";
import { createAnswerHead, ANSWER_LABEL } from "./core/ai-disclosure.js";
import { applyDoneStats, applyLiveUsage, beginLiveTurn, emptyRunMetrics, formatRunMetricsParts, liveElapsedMs, noteFirstToken, noteLiveChars } from "./core/run-metrics.js";

/* CSP blocks inline onload handlers, so PatternFly stays media=print until
   this module runs. Flip to all as soon as the sheet is ready so first paint
   skipped the 1.8MB decode but structure styles still arrive. */
(function activatePatternFly() {
  var link = document.querySelector('link[data-pf]');
  if (!link) return;
  function arm() { link.media = "all"; }
  if (link.sheet) arm();
  else link.addEventListener("load", arm);
})();

document.addEventListener("DOMContentLoaded", function () {
"use strict";

var readJson = utilReadJson;
var newSessionId = utilNewSessionId;
var fmtBytes = utilFmtBytes;
var clip = utilClip;
var sessionLabel = utilSessionLabel;
var summarizeTitle = utilSummarizeTitle;
var recencyGroup = utilRecencyGroup;
var fmtInt = utilFmtInt;
var fmtMs = utilFmtMs;
var fmtCost = utilFmtCost;
var escapeHtml = utilEscapeHtml;
var providerCache = [];
var runLabel = function (r) { return runLabelMod(r, clip); };
var modelLabel = function (provider, model) { return modelLabelMod(provider, model, providerCache); };
var chatRoomLabel = function (r) { return chatRoomLabelMod(r, isDm, function(rr){ return dmPartner(rr); }, clankerMark); };
var el = {
  form: document.getElementById("task-form"),
  task: document.getElementById("task"),
  attachments: document.getElementById("attachments"),
  submit: document.getElementById("submit"),
  cancel: document.getElementById("cancel"),
  steerRow: document.getElementById("steer-row"),
  steerInput: document.getElementById("steer-input"),
  steerBtn: document.getElementById("steer-btn"),
  steerHint: document.getElementById("steer-hint"),
  refresh: document.getElementById("refresh"),
  hint: document.getElementById("hint"),
  transcript: document.getElementById("transcript"),
  instance: document.getElementById("instance"),
  instanceChip: document.getElementById("instance-chip"),
  peers: document.getElementById("peers"),
  peersChip: document.getElementById("peers-chip"),
  sessionChip: document.getElementById("session-chip"),
  headerModel: document.getElementById("header-model"),
  composerModel: document.getElementById("composer-model"),
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
  sessionStatusBar: document.getElementById("session-status-bar"),
  runMetrics: document.getElementById("run-metrics"),
  statusGoal: document.getElementById("status-goal"),
  statusTools: document.getElementById("status-tools"),
  statusSubagent: document.getElementById("status-subagent"),
  statusTodos: document.getElementById("status-todos"),
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
  chatSidebar: document.getElementById("chat-sidebar"),
  chatSidebarToggle: document.getElementById("chat-sidebar-toggle"),
  chatRoomFilter: document.getElementById("chat-room-filter"),
  chatRoomsItems: document.getElementById("chat-rooms-items"),
  chatDmsItems: document.getElementById("chat-dms-items"),
  chatChannelTitle: document.getElementById("chat-channel-title"),
  chatChannelTopic: document.getElementById("chat-channel-topic"),
  chatCreateRoomBtn: document.getElementById("chat-create-room"),
  chatCreateDialog: document.getElementById("chat-create-dialog"),
  chatNewRoomName: document.getElementById("chat-new-room-name"),
  chatCreateCancel: document.getElementById("chat-create-cancel"),
  chatSearchToggle: document.getElementById("chat-search-toggle"),
  chatSearchBar: document.getElementById("chat-search-bar"),
  chatSearchInput: document.getElementById("chat-search-input"),
  chatSearchResults: document.getElementById("chat-search-results"),
  chatSearchClose: document.getElementById("chat-search-close"),
  chatPinToggle: document.getElementById("chat-pin-toggle"),
  chatPinsPanel: document.getElementById("chat-pins-panel"),
  chatPinsList: document.getElementById("chat-pins-list"),
  chatPinsClose: document.getElementById("chat-pins-close"),
  chatEmojiBtn: document.getElementById("chat-emoji-btn"),
  chatEmojiPicker: document.getElementById("chat-emoji-picker"),
  goals: document.getElementById("goals"),
  goalsRefresh: document.getElementById("goals-refresh"),
  goalForm: document.getElementById("goal-form"),
  goalObjective: document.getElementById("goal-objective"),
  goalCriterion: document.getElementById("goal-criterion"),
  goalMaxIterations: document.getElementById("goal-max-iterations"),
  goalWorktree: document.getElementById("goal-worktree"),
  worktreeMode: document.getElementById("worktree-mode"),
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
  workspacePick: document.getElementById("workspace-pick"),
  workspaceNew: document.getElementById("workspace-new"),
  workspaceRemove: document.getElementById("workspace-remove"),
  workspaceNewDialog: document.getElementById("workspace-new-dialog"),
  workspaceNewForm: document.getElementById("workspace-new-form"),
  workspaceNewName: document.getElementById("workspace-new-name"),
  workspaceNewPath: document.getElementById("workspace-new-path"),
  workspaceNewCancel: document.getElementById("workspace-new-cancel"),
  sessionCompact: document.getElementById("session-compact"),
  sessionExport: document.getElementById("session-export"),
  sessionCopy: document.getElementById("session-copy"),
  runCopy: document.getElementById("run-copy"),
  board: document.getElementById("board-grid"),
  boardEmpty: document.getElementById("board-empty"),
  cardForm: document.getElementById("card-form"),
  cardTitle: document.getElementById("card-title"),
  cardColumn: document.getElementById("card-column"),
  cardAdd: document.getElementById("card-add"),
  cardDetail: document.getElementById("card-detail"),
  cardDetailBox: document.querySelector("#card-detail .overlay-box"),
  boardMine: document.getElementById("board-mine"),
  boardResyncGoals: document.getElementById("board-resync-goals"),
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
  fallbackProvider: document.getElementById("fallback-provider"),
  enterSends: document.getElementById("enter-sends"),
  planMode: document.getElementById("plan-mode"),
  researchMode: document.getElementById("research-mode"),
  unlimitedIterations: document.getElementById("unlimited-iterations"),
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

   T builds real DOM nodes and sets text as text, so nothing here can
   introduce markup from data. */

var T = vanT;
var bind = vanBind;
var skeletonRows = vanSkeletonRows;
var setTurnPhase = vanSetTurnPhase;

var icon = iconFn;

var UI = vanUI;

var vendorLoads = vendorLoadsMod;
var loadVendor = loadVendorMod;
var loadD3 = loadD3Mod;
var loadHljs = loadHljsMod;
var registerToml = registerTomlMod;
var copyText = copyTextMod;
/* Without this alias, bare scrollTo(node, block) calls resolved to
   window.scrollTo(x, y) and jumped the page to the top left. */
var scrollTo = vendorScrollTo;

var busy = false;
var controller = null;
var elapsedTimer = null;
var runWaitLabel = "thinking";
var sessionId = loadSession();
function loadCurrentWorkspace() {
  try { return window.localStorage.getItem("clanker.workspace") || ""; } catch (e) { return ""; }
}
var currentWorkspace = loadCurrentWorkspace();
window.clankerWorkspace = currentWorkspace;
var knownWorkspaces = [];

function loadSession() {
  var id = null;
  try { id = window.localStorage.getItem("clanker.session"); } catch (e) {}
  if (!id) id = newSessionId();
  try { window.localStorage.setItem("clanker.session", id); } catch (e) {}
  return id;
}

/* ---------- unsent drafts ----------

   What is in the composer belongs to the conversation it was written for. It
   is saved under that id as you type, put back when the conversation is
   reopened or the page reloads, and dropped once a run using it finishes.
   `drafts` is the whole store; `core/composer.js` owns its shape and bounds
   its size. */
var drafts = compLoadDrafts();
var draftTimer = null;

/* Debounced: this runs on every keystroke, and localStorage is synchronous. */
function rememberDraft() {
  if (draftTimer) window.clearTimeout(draftTimer);
  draftTimer = window.setTimeout(flushDraft, 400);
}

function flushDraft() {
  if (draftTimer) { window.clearTimeout(draftTimer); draftTimer = null; }
  compSetDraft(drafts, sessionId, el.task.value);
  compSaveDrafts(drafts);
}

function dropDraft(id) {
  compSetDraft(drafts, id || sessionId, "");
  compSaveDrafts(drafts);
}

/* Only ever fills an empty composer. Restoring over text the reader is in the
   middle of writing would be the same loss this exists to prevent, in the
   other direction. */
function restoreDraft() {
  var saved = compDraftFor(drafts, sessionId);
  if (!saved || el.task.value) return false;
  el.task.value = saved;
  syncControls();
  autoGrow();
  // Appended rather than assigned: the caller has usually just said what it
  // loaded, and that line is still true.
  var said = el.sessionStatus.textContent;
  el.sessionStatus.textContent = (said ? said + " " : "") + "Restored the unsent task.";
  return true;
}

function renderSessionChip() {
  if (el.sessionChip) {
    el.sessionChip.textContent = "session " + sessionId.slice(0, 8);
    el.sessionChip.hidden = false;
    el.sessionChip.removeAttribute("aria-hidden");
    upgradePfChip(el.sessionChip);
  }
  var sel = el.modelSelect ? el.modelSelect.value : "";
  var label = "";
  if (sel && sel.indexOf(" ") !== -1) label = sel.slice(sel.indexOf(" ") + 1).trim();
  else if (sel) label = sel;
  var title = sel ? ("Model: " + sel + " (click to change)") : "Model: default (from config) (click to change)";
  var shown = label || "default model";
  mpSetChip(el.headerModel, shown, title);
  mpSetChip(el.composerModel, shown, title);
}
/* Wired directly: this whole file already runs inside DOMContentLoaded, and a
   listener for the same event added during its dispatch never fires. */
(function(){
  var hm = document.getElementById("header-model");
  var cm = document.getElementById("composer-model");
  function openFrom(btn) {
    return function (e) {
      e.preventDefault();
      mpToggle(btn);
    };
  }
  if (hm) hm.addEventListener("click", openFrom(hm));
  if (cm) cm.addEventListener("click", openFrom(cm));
})();

var loadTheme = loadThemeMod;
var applyTheme = applyThemeMod;

var theme = loadTheme();
applyTheme(theme);
bindThemeToggleMod(el.themeToggle, function (next) { theme = next; });

el.newChat.addEventListener("click", function () {
  if (busy) return;
  if (currentView !== "chat") showView("chat", false);
  // The half-written task belongs to the conversation being left, so it is
  // saved there and the new one opens with an empty composer.
  flushDraft();
  sessionId = newSessionId();
  el.task.value = "";
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
  resetSessionMetrics();
  syncControls();
  autoGrow();
  el.task.focus();
});

// ---- conversations: switch between saved sessions ----------------------

var knownSessionsHolder = { list: [] };
var knownSessions = knownSessionsHolder.list;

/* The live session is always selectable even when the server has never seen
   it — a brand new chat has no saved file until its first turn completes,
   and dropping it from the list would make the picker disagree with what the
   composer is actually continuing. */

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

/* Which day-groups the rail folds away. Like pins this lives in the browser:
   which "Yesterday" you have stopped looking at is a property of how you are
   browsing right now, not of the conversation. Keyed by the group label
   ("Pinned", "Today", "Yesterday", …) so one choice covers the same day in
   every workspace. */
function loadCollapsedGroups() {
  try { return JSON.parse(window.localStorage.getItem("clanker.collapsedGroups") || "[]"); } catch (e) { return []; }
}
var collapsedGroups = loadCollapsedGroups();

function isCollapsedGroup(g) { return collapsedGroups.indexOf(g) !== -1; }

function toggleCollapsedGroup(g) {
  var at = collapsedGroups.indexOf(g);
  if (at === -1) collapsedGroups.push(g); else collapsedGroups.splice(at, 1);
  try { window.localStorage.setItem("clanker.collapsedGroups", JSON.stringify(collapsedGroups)); } catch (e) {}
  renderSessionOptions(null);
}

/* The conversation list derives from three things: what the server knows,
   what is pinned here, and what is typed in the filter. Nothing else can put
   a row on screen, which is what stops the rail and the transcript
   disagreeing about which conversation is open. */
var railState = uiState({ sessions: [], filter: "", pins: [], current: "", collapsed: collapsedGroups.slice() });

function isArchived(s){ return !!s.archived; }
function showArchived(){ var cb=document.getElementById("archived-toggle"); return !!(cb && cb.checked); }
function renderSessionOptions(sessions) {
  if (sessions) { knownSessionsHolder.list.length = 0; Array.prototype.push.apply(knownSessionsHolder.list, sessions); knownSessions = knownSessionsHolder.list; }
  railState.val = {
    sessions: knownSessions,
    filter: el.sessionFilter ? el.sessionFilter.value.trim().toLowerCase() : "",
    pins: pins.slice(),
    current: sessionId,
    collapsed: collapsedGroups.slice(),
    workspace: currentWorkspace
  };
  renderSessionTitle();
}

function railRowFor(s, current) {
  var title = summarizeTitle(s.title || "");
  var archivedMark = s.archived ? " · archived" : "";
  var meta = s.messages + (s.messages === 1 ? " msg" : " msgs") + archivedMark +
    (typeof s.bytes === "number" && s.bytes > 0 ? "  ·  " + fmtBytes(s.bytes) : "");
  var open = s.id === current;

  var row = T.button({
    type: "button",
    class: "rail-item",
    title: title,
    onclick: function () {
      if (currentView !== "chat") showView("chat", false);
      switchSession(s.id);
      closeRailOnNarrow();
    }
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
  uiAdd(pin, icon("pin", 15));

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
  var filtered = s.sessions.filter(function(it){ return showArchived() || !isArchived(it); });
  var ordered = filtered.slice().sort(function (a, b) {
    var pa = isPinned(a.id) ? 1 : 0, pb = isPinned(b.id) ? 1 : 0;
    return pa === pb ? 0 : pb - pa;
  });
  var scoped = ordered.filter(function (item) {
    return (item.workspace || "") === (s.workspace || "");
  });
  var seen = scoped.some(function (item) { return item.id === s.current; });
  var matched = 0;
  var inWorkspace = scoped.filter(function (item) {
    return !s.filter || sessionLabel(item).toLowerCase().indexOf(s.filter) !== -1;
  });

  var groups = [];
  var lastGroup = "";
  inWorkspace.forEach(function (item) {
    var group = isPinned(item.id) ? "Pinned" : recencyGroup(item.updated);
    if (group !== lastGroup) { groups.push({ name: group, items: [] }); lastGroup = group; }
    groups[groups.length - 1].items.push(item);
  });
  groups.forEach(function (g) {
    var collapsed = isCollapsedGroup(g.name);
    var head = T.button({
      type: "button",
      class: "rail-group",
      "aria-expanded": String(!collapsed),
      "aria-label": (collapsed ? "Expand " : "Collapse ") + g.name,
      title: (collapsed ? "Show " : "Hide ") + g.items.length + (g.items.length === 1 ? " conversation" : " conversations") + " in " + g.name,
      onclick: function () { toggleCollapsedGroup(g.name); }
    }, T.span({ class: "rail-group-caret" }, collapsed ? "▸" : "▾"),
      T.span({ class: "rail-group-name" }, g.name),
      T.span({ class: "rail-group-count" }, String(g.items.length)));
    out.push(T.li({ class: "rail-group-row", role: "presentation" }, head));
    if (collapsed) { matched += g.items.length; return; }
    g.items.forEach(function (item) {
      out.push(railRowFor(item, s.current));
    });
    matched += g.items.length;
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
  if (!matched && s.filter) {
    out.push(T.li({ class: "rail-empty" },
      "No title matches. ",
      T.button({
        type: "button",
        class: "rail-empty-action",
        onclick: function () {
          var q = s.filter;
          var input = document.getElementById("search-q");
          if (input) input.value = q;
          showView("search", true);
          searchRun(q);
        }
      }, "Search messages")));
  }
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
  if (open) {
    // Focus would otherwise scroll the drawer so Work (Chat/Board) sits
    // above the fold and the first visible tab is Files.
    el.rail.scrollTop = 0;
    var body = el.rail.querySelector(".pf-v6-c-page__sidebar-body");
    if (body) body.scrollTop = 0;
    if (el.sessionFilter && el.sessionFilter.focus) el.sessionFilter.focus({ preventScroll: true });
  }
}

function applyRailCollapsed(collapsed) {
  el.rail.setAttribute("data-collapsed", String(collapsed));
  /* PatternFly's pf-m-collapsed means "gone" (max-width: 0), not icon rail.
     Keep pf-m-expanded so the page grid still reserves the sidebar; our own
     data-collapsed styles shrink it to the icon strip. */
  el.rail.classList.remove("pf-m-collapsed");
  el.rail.classList.add("pf-m-expanded");
  var btn = document.getElementById("rail-collapse");
  if (btn) {
    btn.textContent = "";
    btn.appendChild(icon("panel", 15));
    btn.setAttribute("aria-expanded", String(!collapsed));
    btn.setAttribute("aria-label", collapsed ? "Expand sidebar" : "Collapse sidebar");
    btn.title = collapsed ? "Expand sidebar" : "Collapse sidebar";
  }
}

(function initRail() {
  /* Always clear PatternFly's "gone" modifier; icon-rail uses data-collapsed. */
  el.rail.classList.remove("pf-m-collapsed");
  el.rail.classList.add("pf-m-expanded");
  /* Do not restore clanker.railCollapsed on load. HTML paints the full rail,
     then app.js used to shrink it to the icon strip a moment later — that
     read as "sidebar visible, then gone". Collapse stays a same-session
     gesture via the masthead button. */
  try { window.localStorage.removeItem("clanker.railCollapsed"); } catch (e) {}
  el.rail.removeAttribute("data-collapsed");
  var cbtn = document.getElementById("rail-collapse");
  if (cbtn) {
    applyRailCollapsed(false);
    cbtn.addEventListener("click", function () {
      var cur = el.rail.getAttribute("data-collapsed") === "true";
      applyRailCollapsed(!cur);
    });
  }
  // populate data-short for collapsed rail labels from existing tab text
  document.querySelectorAll(".rail-tab").forEach(function (t) {
    var txt = (t.textContent || "").trim();
    if (!t.getAttribute("data-short") && txt) t.setAttribute("data-short", txt.slice(0, 2));
  });
})();

/* Phone More hosts the same Fork/Rename/Delete nodes and the transcript
   find field so they stay in the tree when the header is compact. */
function placeSessionChrome() {
  var phone = window.matchMedia && window.matchMedia("(max-width: 40rem)").matches;
  var acts = document.getElementById("session-acts-body");
  var tools = document.getElementById("transcript-tools");
  var more = document.getElementById("session-more-actions");
  var row = document.querySelector("#session-picker .session-actions");
  var moreFold = document.getElementById("session-more");
  var header = document.querySelector("#view-chat .conversation-header");
  if (!acts || !more || !row) return;
  if (phone) {
    if (acts.parentNode !== more) more.insertBefore(acts, more.firstChild);
    if (tools && tools.parentNode !== more) more.appendChild(tools);
  } else {
    if (moreFold && acts.parentNode !== row) row.insertBefore(acts, moreFold);
    else if (acts.parentNode !== row) row.insertBefore(acts, row.firstChild);
    if (tools && header && tools.parentNode !== header) header.appendChild(tools);
  }
}
placeSessionChrome();
if (window.matchMedia) {
  var mqPhone = window.matchMedia("(max-width: 40rem)");
  if (mqPhone.addEventListener) mqPhone.addEventListener("change", placeSessionChrome);
  else if (mqPhone.addListener) mqPhone.addListener(placeSessionChrome);
}

function closeRailOnNarrow() {
  if (window.matchMedia && window.matchMedia("(max-width: 40rem)").matches) setRailOpen(false);
}

el.railToggle.addEventListener("click", function () {
  setRailOpen(el.rail.getAttribute("data-open") !== "true");
});
el.railScrim.addEventListener("click", function () { setRailOpen(false); });

/* Drag-to-scroll for the chat-history list inside the pinned rail. The list is
   the one scrollable region in the sidebar; hovering and using the wheel works
   because it is an overflow container, and this adds the click-and-drag
   gesture. A small threshold keeps a plain click (which switches a
   conversation) from being treated as the start of a drag. */
function enableDragScroll(node) {
  if (!node) return;
  var dragging = false, moved = false, startX = 0, startY = 0, startTop = 0;
  node.addEventListener("mousedown", function (e) {
    if (e.button !== 0) return;
    dragging = true; moved = false;
    startX = e.clientX; startY = e.clientY; startTop = node.scrollTop;
  });
  window.addEventListener("mousemove", function (e) {
    if (!dragging) return;
    var dx = e.clientX - startX, dy = e.clientY - startY;
    if (!moved && Math.abs(dx) < 4 && Math.abs(dy) < 4) return;
    moved = true;
    node.scrollTop = startTop - dy;
    e.preventDefault();
  });
  function end() { dragging = false; }
  window.addEventListener("mouseup", end);
  /* A drag that ends over a conversation row would otherwise fire the row's
     click (which switches conversation) on release. Suppress that click when a
     real drag happened. */
  node.addEventListener("click", function (e) {
    if (moved) { e.preventDefault(); e.stopPropagation(); moved = false; }
  }, true);
}
enableDragScroll(el.railList);

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
  var empty = el.transcript.querySelector(".turn") === null;
  el.transcriptEmpty.hidden = !empty;
  // Empty conversations keep the idle plate, composer and jobs stacked from
  // the top; the first turn docks the composer to the bottom.
  document.getElementById("view-chat").classList.toggle("chat-empty", empty);
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

function workspaceLabel(w) {
  if (!w) return "This folder";
  var name = w.name || w.id || "This folder";
  if (w.builtin) return name + " (this folder)";
  if (w.orphan) return name + " (no folder)";
  return name;
}

function renderWorkspacePick() {
  if (!el.workspacePick) return;
  var pick = el.workspacePick;
  var keep = currentWorkspace;
  pick.textContent = "";
  if (!knownWorkspaces.length) {
    var fallback = document.createElement("option");
    fallback.value = "";
    fallback.textContent = "This folder";
    pick.appendChild(fallback);
  } else {
    knownWorkspaces.forEach(function (w) {
      var opt = document.createElement("option");
      opt.value = w.id || "";
      opt.textContent = workspaceLabel(w);
      pick.appendChild(opt);
    });
  }
  pick.value = keep;
  if (pick.value !== keep) {
    var missing = document.createElement("option");
    missing.value = keep;
    missing.textContent = keep || "This folder";
    pick.appendChild(missing);
    pick.value = keep;
  }
  if (el.workspaceRemove) {
    var cur = knownWorkspaces.filter(function (w) { return (w.id || "") === keep; })[0];
    el.workspaceRemove.hidden = !cur || !!cur.builtin;
  }
}

function loadWorkspaces() {
  return fetch("/api/workspaces")
    .then(readJson)
    .then(function (data) {
      knownWorkspaces = data.workspaces || [];
      renderWorkspacePick();
    })
    .catch(function () {
      knownWorkspaces = [];
      renderWorkspacePick();
    });
}

function setCurrentWorkspace(id, opts) {
  opts = opts || {};
  currentWorkspace = id || "";
  window.clankerWorkspace = currentWorkspace;
  try { window.localStorage.setItem("clanker.workspace", currentWorkspace); } catch (e) {}
  try { window.dispatchEvent(new CustomEvent("clanker-workspace", { detail: currentWorkspace })); } catch (e) {}
  renderWorkspacePick();
  if (opts.silent) {
    renderSessionOptions(null);
    return;
  }
  var meta = currentSessionMeta();
  if (meta && (meta.workspace || "") !== currentWorkspace) {
    var next = null;
    for (var i = 0; i < knownSessions.length; i++) {
      var s = knownSessions[i];
      if ((s.workspace || "") === currentWorkspace && (showArchived() || !s.archived)) {
        next = s;
        break;
      }
    }
    if (next) switchSession(next.id);
    else if (el.newChat) el.newChat.click();
    else renderSessionOptions(null);
  } else {
    renderSessionOptions(null);
  }
}

/* Which message indices each rendered turn covers, in render order. Written
   by renderSessionHistory, read by jumpToMessage: a search hit names a message
   and the transcript is drawn in turns, so this is the only place that knows
   how the one maps onto the other. Cleared with the transcript. */
var replayedSpans = [];

/* Replays a saved conversation into the transcript. Reuses the same turn
   card the live stream builds, so history and a just-finished turn are the
   same object rather than two renderings of the same thing that drift. */
function renderSessionHistory(messages) {
  el.transcript.textContent = "";
  replayedSpans = [];
  var pendingTurn = null;
  var lastTask = null;
  var span = null;
  messages.forEach(function (m, idx) {
    if (m.role === "user") {
      // A question with no reply before the next one: close it off rather
      // than letting the next answer attach to the wrong question.
      if (pendingTurn) markTurnUnanswered(pendingTurn);
      lastTask = m.content;
      pendingTurn = createTurn(m.content);
      span = { from: idx, to: idx };
      replayedSpans.push(span);
      return;
    }
    if (!pendingTurn) {
      lastTask = null;
      pendingTurn = createTurn("(question not in this transcript)");
      span = { from: idx, to: idx };
      replayedSpans.push(span);
      var head = pendingTurn.root.querySelector(".turn-you");
      head.setAttribute("data-orphan", "true");
      head.querySelector(".turn-author").textContent = "unknown  ·  ";
    }
    if (span) span.to = idx;
    appendText(pendingTurn, m.content, false);
    finalizeAnswer(pendingTurn);
    // The task is passed back so Run again and Edit & resend survive a reload;
    // the numbers cannot, because they were never saved with the session.
    renderStats(pendingTurn, {}, lastTask);
    pendingTurn = null;
  });
  if (pendingTurn) markTurnUnanswered(pendingTurn);
}

/* Scrolls the transcript to the turn holding message `index` and says which
   one it is: the card is flagged for a moment, and the text that was searched
   for is marked inside it. Used by the Search view, which until now could only
   open the conversation and leave you at the top of it — on a long transcript
   that is the same as not going there.

   The mark reuses the transcript's own find-in-page highlighter, so a hit
   found from Search looks exactly like one found with `/`, and the next `/`
   clears it the same way. */
function jumpToMessage(index, query) {
  var turns = el.transcript.querySelectorAll(".turn");
  var at = turnForMessage(replayedSpans, index);
  if (at === -1 || !turns.length) return null;
  var turn = turns[Math.min(at, turns.length - 1)];
  clearMarks(el.transcript);
  if (query) markMatches(turn, String(query));
  scrollTo(turn, "center");
  // Removed on its own so a later jump to the same turn flags it again, and
  // so the card does not stay singled out for the rest of the conversation.
  turn.setAttribute("data-found", "true");
  window.setTimeout(function () { turn.removeAttribute("data-found"); }, 2000);
  return turn;
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

/* `jump`, when given, is `{ index, query }` from a Search hit: the message to
   land on once the transcript is on screen. Passed in rather than read back
   later because the scroll can only happen after the fetch resolves, and the
   caller is gone by then. */
function switchSession(id, jump) {
  if (id === sessionId) {
    // Already open. Still a jump — a hit in the conversation you are reading
    // is the case where scrolling to it helps most, and refusing to move
    // because nothing had to load reads as a dead link.
    if (jump) jumpToMessage(jump.index, jump.query);
    return;
  }
  if (busy) {
    // Refused mid-run, so put the control back on the conversation that is
    // actually still running rather than leaving it pointing at one the
    // composer is not using.
    renderSessionOptions(null);
    el.sessionStatus.textContent = "Finish or stop the current run before switching conversation.";
    return;
  }
  // Written down before the id moves, or it would be saved against the
  // conversation being opened rather than the one being left.
  flushDraft();
  sessionId = id;
  resetSessionMetrics();
  el.task.value = "";
  try { window.localStorage.setItem("clanker.session", sessionId); } catch (e) {}
  var opened = currentSessionMeta();
  if (opened && (opened.workspace || "") !== currentWorkspace) {
    setCurrentWorkspace(opened.workspace || "", { silent: true });
  }
  renderSessionChip();
  renderSessionOptions(null);
  el.transcript.textContent = "";
  el.sessionStatus.textContent = "Loading conversation…";
  // Belongs to the turn just left behind, not the conversation being opened.
  if (el.sessionStatusBar) el.sessionStatusBar.hidden = true;
  fetch("/api/sessions/" + encodeURIComponent(id))
    .then(readJson)
    .then(function (data) {
      renderSessionHistory(data.messages || []);
      syncTranscriptEmpty();
      var n = (data.messages || []).length;
      el.sessionStatus.textContent = "Loaded " + n + (n === 1 ? " message." : " messages.");
      restoreDraft();
      if (jump) jumpToMessage(jump.index, jump.query);
    })
    .catch(function (err) {
      var p = document.createElement("p");
      p.className = "run-empty";
      p.textContent = "Could not load that conversation: " + err.message;
      el.transcript.appendChild(p);
      el.sessionStatus.textContent = p.textContent;
      // The transcript did not load, but the composer is this conversation's
      // either way — leaving it empty would look like the draft was lost.
      restoreDraft();
    });
}



/* Workspaces are created by naming one: there is no separate "new folder"
   step, because a folder with nothing in it is not yet a folder. */
if (el.workspacePick) {
  el.workspacePick.addEventListener("change", function () {
    setCurrentWorkspace(el.workspacePick.value || "");
  });
}
if (el.workspaceNew) {
  el.workspaceNew.addEventListener("click", function () {
    if (!el.workspaceNewDialog) return;
    if (el.workspaceNewName) el.workspaceNewName.value = "";
    if (el.workspaceNewPath) el.workspaceNewPath.value = "";
    overlayOpen(el.workspaceNewDialog, el.workspaceNewName);
  });
}
if (el.workspaceNewCancel) {
  el.workspaceNewCancel.addEventListener("click", function () {
    if (el.workspaceNewDialog) overlayClose(el.workspaceNewDialog);
  });
}
if (el.workspaceNewDialog) {
  el.workspaceNewDialog.addEventListener("mousedown", function (e) {
    if (e.target === el.workspaceNewDialog) overlayClose(el.workspaceNewDialog);
  });
}
if (el.workspaceNewForm) {
  el.workspaceNewForm.addEventListener("submit", function (e) {
    e.preventDefault();
    var name = el.workspaceNewName ? el.workspaceNewName.value.trim() : "";
    var path = el.workspaceNewPath ? el.workspaceNewPath.value.trim() : "";
    if (!name || !path) return;
    fetch("/api/workspaces", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: name, path: path })
    })
      .then(readJson)
      .then(function (data) {
        if (el.workspaceNewDialog) overlayClose(el.workspaceNewDialog);
        return loadWorkspaces().then(function () {
          setCurrentWorkspace(data.id || name);
          el.sessionStatus.textContent = "Workspace " + (data.name || name) + " ready.";
        });
      })
      .catch(function (err) {
        el.sessionStatus.textContent = "Could not create workspace: " + err.message;
      });
  });
}
if (el.workspaceRemove) {
  el.workspaceRemove.addEventListener("click", function () {
    var id = currentWorkspace;
    if (!id) return;
    var cur = knownWorkspaces.filter(function (w) { return (w.id || "") === id; })[0];
    var label = cur ? (cur.name || id) : id;
    uiConfirm("Remove workspace \"" + label + "\"? Its chats move back to this folder. The directory on disk is not deleted.", { confirmLabel: "Remove" }).then(function (yes) {
      if (!yes) return;
      fetch("/api/workspaces/" + encodeURIComponent(id), { method: "DELETE" })
        .then(readJson)
        .then(function () {
          return Promise.all([loadWorkspaces(), loadSessions()]).then(function () {
            setCurrentWorkspace("");
            el.sessionStatus.textContent = "Removed " + label + ".";
          });
        })
        .catch(function (err) {
          el.sessionStatus.textContent = "Could not remove workspace: " + err.message;
        });
    });
  });
}

el.sessionMove.addEventListener("click", function () {
  var meta = currentSessionMeta();
  if (!meta) {
    el.sessionStatus.textContent = "This conversation has no saved turns yet.";
    return;
  }
  var existing = knownWorkspaces.map(function (w) { return w.id || ""; }).filter(function (w) { return w !== ""; });
  workspacesOf(knownSessions).forEach(function (w) {
    if (w && existing.indexOf(w) === -1) existing.push(w);
  });
  var hint = existing.length
    ? "Pick a workspace or type a new name. Leave empty for this folder."
    : "Leave empty for this folder, or type a name. Use + to attach a directory.";
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
          : "Moved to this folder.";
        return Promise.all([loadSessions(), loadWorkspaces()]).then(function () {
          if (next.trim()) setCurrentWorkspace(next.trim(), { silent: true });
        });
      })
      .catch(function (err) { el.sessionStatus.textContent = "Move failed: " + err.message; })
      .then(function () { el.sessionMove.disabled = false; });
  });
});

/* Auto titles are a couple of content words from the opening task. Both
   actions refuse to touch a conversation that has never been saved, since
   there is nothing on disk to act on yet. */
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
  uiConfirm("Delete \"" + (meta.title || sessionId) + "\"? Its recorded runs are kept.", { danger: true, confirmLabel: "Delete" }).then(function (yes) {
    if (!yes) return;
    el.sessionDelete.disabled = true;
    fetch("/api/sessions/" + encodeURIComponent(sessionId), { method: "DELETE" })
      .then(readJson)
      .then(function () {
        el.sessionStatus.textContent = "Deleted. Started a new conversation.";
        // Nothing left for the draft to belong to.
        dropDraft(sessionId);
        sessionId = newSessionId();
        try { window.localStorage.setItem("clanker.session", sessionId); } catch (e) {}
        el.transcript.textContent = "";
        renderSessionChip();
        return loadSessions();
      }).catch(function (err) {
        el.sessionStatus.textContent = "Could not delete: " + err.message;
      }).finally(function () { el.sessionDelete.disabled = false; });
  });
});

function syncControls() {
  el.submit.disabled = busy || el.task.value.trim() === "";
  el.refresh.disabled = busy;
  el.newChat.disabled = busy;
  el.task.readOnly = busy;
  el.cancel.hidden = !busy;
  // Mid-run steering: only meaningful while a turn is in flight. Hidden and
  // cleared the moment the run ends, so a stale course-correction is never
  // queued against the next turn.
  el.steerRow.hidden = !busy;
  if (!busy) {
    el.steerInput.value = "";
    el.steerHint.textContent = "";
    updateComposerModeHint();
  }
  // The send circle yields its spot to the stop circle while a turn runs
  // (the focus handoff below keeps keyboard users on the live control).
  el.submit.hidden = busy;
  if (!busy) syncSubmitLabel();
  document.title = busy ? "Running… · clanker" : "clanker";
}

/** Idle composer hint for plan/research toggles (matches TUI status bar labels). */
function updateComposerModeHint() {
  if (busy) return;
  var parts = [];
  if (el.planMode && el.planMode.checked) parts.push("Plan mode · write tools refused");
  if (el.researchMode && el.researchMode.checked) parts.push("Research mode · web search preferred");
  el.hint.textContent = parts.join(" · ");
}

function setBusy(next) {
  busy = next;
  syncControls();
}

function startElapsed(startedAt) {
  stopElapsed();
  function tick() {
    elapsedTimer = window.requestAnimationFrame(tick);
    el.hint.textContent = runWaitLabel + " · " + ((Date.now() - startedAt) / 1000).toFixed(1) + "s";
    paintRunMetrics();
  }
  tick();
}

function stopElapsed() {
  if (elapsedTimer) { window.cancelAnimationFrame(elapsedTimer); elapsedTimer = null; }
}

/* Mid-run steering for the chat composer (same POST /api/steer the goals
   view uses, keyed by the run's session id instead of a goal id). While a
   turn runs, a dedicated input appears beside the locked composer; sending
   queues a course correction the agent loop drains between iterations. */
function sendSteerChat() {
  var msg = (el.steerInput.value || "").trim();
  if (!msg) { el.steerHint.textContent = "Type a message to steer the running turn."; return; }
  el.steerHint.textContent = "sending…";
  el.steerBtn.disabled = true;
  fetch("/api/steer", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ session: sessionId, message: msg })
  }).then(function (resp) {
    if (resp.ok) {
      el.steerInput.value = "";
      el.steerHint.textContent = "steering message sent — it lands on the next model step.";
    } else {
      return resp.json().then(function (j) {
        el.steerHint.textContent = "steer failed: " + (j.error || ("HTTP " + resp.status));
      }).catch(function () {
        el.steerHint.textContent = "steer failed: HTTP " + resp.status;
      });
    }
  }).catch(function (err) {
    el.steerHint.textContent = "steer failed: " + (err && err.message ? err.message : "network error");
  }).finally(function () {
    el.steerBtn.disabled = false;
  });
}
el.steerBtn.addEventListener("click", sendSteerChat);
el.steerInput.addEventListener("keydown", function (e) {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); sendSteerChat(); }
});

/* Each submitted task gets its own turn card, appended below the last —
   a real conversation history instead of one box that forgets the past
   answer as soon as you ask another question. */
function createTurn(task) {
  if (el.transcriptEmpty) el.transcriptEmpty.hidden = true;
  document.getElementById("view-chat").classList.remove("chat-empty");
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

  var assistantHead = createAnswerHead();

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

  body.appendChild(assistantHead);
  body.appendChild(events);
  body.appendChild(answer);
  body.appendChild(foot);
  turn.appendChild(you);
  turn.appendChild(body);
  el.transcript.appendChild(turn);

  return { root: turn, events: events, answer: answer, foot: foot };
}

function errorRecoveryHint(msg) {
  if (!msg) return "";
  var m = msg.toLowerCase();
  if (m.indexOf("401") !== -1 || m.indexOf("unauthorized") !== -1 || m.indexOf("authentication") !== -1)
    return " (check API key; run clanker doctor)";
  if (m.indexOf("429") !== -1 || m.indexOf("rate limit") !== -1 || m.indexOf("rate_limit") !== -1)
    return " (rate limited; wait or switch model)";
  if (m.indexOf("not found") !== -1 || m.indexOf("model_not_found") !== -1)
    return " (model not found; pick another in the model pill)";
  if (m.indexOf("timeout") !== -1 || m.indexOf("timed out") !== -1)
    return " (request timed out)";
  if (m.indexOf("onnection refused") !== -1 || m.indexOf("onnection reset") !== -1)
    return " (cannot reach provider; check network)";
  if (m.indexOf("max_iterations") !== -1 || m.indexOf("iteration limit") !== -1)
    return " (hit iteration limit; try a simpler task or raise agent.max_iterations)";
  if (m.indexOf("token_budget") !== -1 || m.indexOf("token budget") !== -1)
    return " (ran out of token budget)";
  return "";
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
/* fuzzyMatch came over in the ES-module split as utilFuzzyMatch; the palette
   and the prompt list call it bare, so it needs its alias like the markdown
   bindings above. Without it, the `/` prompt list throws at render time. */
var fuzzyMatch = utilFuzzyMatch;
window.clankerOpenRun = function (id) {
  try { openRun(id); } catch (e) {}
};
window.clankerOpenCitation = function(ref){
  try{
    var stem = ref.split(":")[0].split("/").pop().split(".")[0];
    var runsTab = document.getElementById("tab-runs");
    if (runsTab) runsTab.click();
    setTimeout(function(){
      var inp = document.querySelector(".run-graph-search input");
      if (inp) { inp.value = stem; inp.dispatchEvent(new Event("input", {bubbles:true})); inp.focus(); }
      var rf = document.getElementById("run-filter");
      if (rf) { rf.value = ref.split(":")[0]; rf.dispatchEvent(new Event("input", {bubbles:true})); }
    }, 80);
  }catch(_){}
};

function addToolEvent(turn, names, calls) {
  // A <details> per call batch: the summary is the same one-line "what ran"
  // as before, the body shows the arguments each call was made with. Closed
  // by default so a chatty run stays scannable.
  var row = document.createElement("details");
  row.className = "event-tool";
  var head = document.createElement("summary");
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
  head.appendChild(spin);
  head.appendChild(label);
  head.appendChild(state);
  row.appendChild(head);
  var has_body = false;
  if (Array.isArray(calls)) {
    calls.forEach(function (c) {
      if (!c || typeof c.name !== "string") return;
      var line = document.createElement("pre");
      line.className = "tool-args";
      var args = typeof c.args === "string" ? c.args.trim() : "";
      line.textContent = c.name + (args && args !== "{}" ? " " + args : " (no arguments)");
      row.appendChild(line);
      has_body = true;
    });
  }
  // Nothing to unfold (an old server that only sends names): stay a plain
  // row rather than a <details> that opens onto nothing.
  if (!has_body) row.classList.add("no-detail");
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
    upgradePfButton(btn);
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
  // Desktop notification when tab is hidden — otherwise ask/confirm dies silently
  try{
    if (document.hidden && "Notification" in window) {
      if (Notification.permission === "granted") {
        var n = new Notification(ariaLabel, { body: (evt.question || ariaLabel).slice(0,120), tag: "clanker-ask-" + evt.id });
        n.onclick = function(){ try{ window.focus(); first && first.focus(); }catch(_){} n.close(); };
        // tiny beep via Web Audio if available
        try{ var ac = new (window.AudioContext||window.webkitAudioContext)(); var o=ac.createOscillator(); o.frequency.value=880; o.connect(ac.destination); o.start(); setTimeout(function(){ try{o.stop(); ac.close();}catch(_){} }, 180); }catch(_){}
      } else if (Notification.permission !== "denied") {
        Notification.requestPermission().catch(function(){});
      }
    }
  }catch(_){}
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
  // The duration belongs on the always-visible summary line, not in the
  // fold-out body under it.
  (row.querySelector("summary") || row).appendChild(dur);
}

function renderStats(turn, stats, task) {
  turn.foot.textContent = "";

  /* Did this layer hold? A turn that produced an answer held; one that was
     stopped, errored or ended early did not. */
  var stopped = turn.answer.textContent.indexOf("[stopped]") !== -1;
  var failed = turn.answer.querySelector(".failed") !== null ||
    stopped ||
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
  upgradePfButton(copyBtn);
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
      updateComposerModeHint();
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
    upgradePfButton(regenBtn);
    regenBtn.title = "Resubmit this task as a new turn";
    regenBtn.addEventListener("click", function () {
      if (busy) return;
      el.task.value = task;
      el.form.requestSubmit();
    });
    actions.appendChild(regenBtn);

    var branchBtn = document.createElement("button");
    branchBtn.type = "button";
    branchBtn.className = "secondary";
    branchBtn.textContent = "Branch";
    upgradePfButton(branchBtn);
    branchBtn.title = "Continue from this turn in a new conversation";
    branchBtn.addEventListener("click", function () {
      if (!currentSessionMeta()) {
        el.sessionStatus.textContent = "This conversation has no saved turns yet.";
        return;
      }
      // The turn's own stratum index, which is the same 1-based number the
      // server's branch endpoint cuts the transcript at.
      var n = parseInt((turn.root.querySelector(".turn-depth") || {}).textContent, 10) || 1;
      branchBtn.disabled = true;
      fetch("/api/sessions/" + encodeURIComponent(sessionId) + "/branch/" + n, { method: "POST" })
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
          el.sessionStatus.textContent = "Branched at turn " + n + ". You are now in the copy.";
          return loadSessions();
        })
        .catch(function (err) {
          el.sessionStatus.textContent = "Could not branch: " + err.message;
        })
        .finally(function () { branchBtn.disabled = false; });
    });
    actions.appendChild(branchBtn);

    // Branch timeline: which forks came from here
    (function(){
      if (!knownSessions || !knownSessions.length) return;
      var title = ((turn.root.querySelector(".turn-you") || {}).textContent || "").trim();
      var forks = knownSessions.filter(function(s){
        return s.title && (s.title.indexOf("fork of") !== -1 || s.title.indexOf("branch of") !== -1) && s.id !== sessionId;
      });
      // Heuristic: server titles forks as "fork of <original title>" — show any fork when on its parent
      var meta = currentSessionMeta();
      var parentTitle = meta ? (meta.title || "") : "";
      var relevant = forks.filter(function(s){ return parentTitle && s.title.indexOf(parentTitle.slice(0, 24)) !== -1; });
      if (!relevant.length) relevant = forks.slice(0, 3);
      if (!relevant.length) return;
      var bar = document.createElement("div");
      bar.className = "turn-branches";
      bar.setAttribute("role", "navigation");
      bar.setAttribute("aria-label", "Branches from this turn");
      relevant.forEach(function(s){
        var chip = document.createElement("button");
        chip.type = "button"; chip.className = "branch-chip";
        chip.textContent = (s.title || s.id.slice(0,8)) + " · " + (s.messages || 0) + " msgs";
        chip.title = "Switch to " + (s.title || s.id);
        if (s.id === sessionId) chip.setAttribute("data-current", "true");
        chip.addEventListener("click", function(){ switchSession(s.id); });
        bar.appendChild(chip);
      });
      turn.root.appendChild(bar);
    })();

    var editBtn = document.createElement("button");
    editBtn.type = "button";
    editBtn.className = "secondary";
    editBtn.textContent = "Edit & resend";
    upgradePfButton(editBtn);
    editBtn.title = "Put this task back in the composer to change it";
    editBtn.addEventListener("click", function () {
      el.task.value = task;
      el.task.focus();
      el.task.setSelectionRange(task.length, task.length);
      syncControls();
      scrollTo(el.task, "center");
    });
    actions.appendChild(editBtn);
    // History hygiene affordances (no invented state):
    // - Copy turn copies the transcript slice for that turn via the same
    //   helper Copy answer uses (still the per-turn source, not invented).
    var copyTurnBtn = document.createElement("button");
    copyTurnBtn.type = "button";
    copyTurnBtn.className = "secondary";
    copyTurnBtn.textContent = "Copy turn";
    upgradePfButton(copyTurnBtn);
    copyTurnBtn.title = "Copy this turn as markdown";
    copyTurnBtn.addEventListener("click", function(){
      var you = turn.root.querySelector(".turn-you");
      var promptText = you ? you.textContent : task || "";
      var answerText = turn.root.markdownSource || (turn.answer ? turn.answer.textContent : "");
      var md = (promptText ? ("## " + String(promptText).trim() + "\n\n") : "") +
        "### " + ANSWER_LABEL + "\n\n" +
        String(answerText || "").replace(/\s+$/, "");
      copyText(md || String(promptText||""), copyTurnBtn, "Copy turn", turn.root);
    });
    actions.appendChild(copyTurnBtn);
    if (stopped) {
      var contBtn = document.createElement("button");
      contBtn.type = "button"; contBtn.className = "secondary"; contBtn.textContent = "Continue"; upgradePfButton(contBtn);
      contBtn.title = "Continue this run from where it stopped";
      contBtn.addEventListener("click", function(){ if(busy) return; el.task.value = "Continue where you left off."; el.form.requestSubmit(); });
      actions.appendChild(contBtn);
      var regenEditBtn = document.createElement("button");
      regenEditBtn.type = "button"; regenEditBtn.className = "secondary"; regenEditBtn.textContent = "Regenerate"; upgradePfButton(regenEditBtn);
      regenEditBtn.title = "Run this task again from scratch";
      regenEditBtn.addEventListener("click", function(){ if(busy) return; el.task.value = task; el.form.requestSubmit(); });
      actions.appendChild(regenEditBtn);
      // Edit is already there as Edit & resend — covers the edit leg of the trio
    }
  }
  turn.foot.appendChild(actions);
}

var makeLineSplitter = makeLineSplitterMod;

function renderStatus(status) {
  var out = statusRenderInto(status, el);
  instanceName = out.instanceName;
  knownPeers = out.knownPeers;
  var defaults = status && status.run_defaults;
  if (defaults) {
    window.clankerWorktreeDefault = !!defaults.webui_worktree;
    if (el.worktreeMode) el.worktreeMode.checked = !!defaults.webui_worktree;
    if (el.goalWorktree) el.goalWorktree.checked = !!defaults.goal_worktree;
  }
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
/* A dropped or pasted file may be an image or a video (Kimi Code parity:
   drop a screen recording and the agent watches it). Videos are sampled to
   JPEG frames by the attachments module and ride the same image path. */
function addImageFile(file) { attachAddMedia(file, el, icon, fmtBytes); }

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
el.task.addEventListener("input", rememberDraft);
if (el.planMode) el.planMode.addEventListener("change", updateComposerModeHint);
if (el.researchMode) el.researchMode.addEventListener("change", updateComposerModeHint);
// A tab closed or reloaded mid-sentence has no other chance to write.
window.addEventListener("beforeunload", flushDraft);

// Voice input — Web Speech API
(function(){
  var btn = document.getElementById("voice-btn");
  if (!btn) return;
  var SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SR) { btn.hidden = true; return; }
  var rec = null, listening = false;
  function setListening(on){
    listening = on;
    btn.textContent = "";
    btn.appendChild(icon(on ? "minus" : "mic", 16));
    btn.setAttribute("aria-pressed", String(on));
    btn.title = on ? "Listening (click to stop)" : "Voice input (click to start)";
    el.task.placeholder = on ? "Listening…" : "Describe the task, / for prompts";
  }
  btn.addEventListener("click", function(){
    if (listening && rec) { try{ rec.stop(); }catch(_){ } return; }
    rec = new SR();
    rec.lang = (navigator.language || "en-US");
    rec.interimResults = true;
    rec.continuous = false;
    var base = el.task.value;
    rec.onstart = function(){ setListening(true); };
    rec.onend = function(){ setListening(false); };
    rec.onerror = function(){ setListening(false); el.sessionStatus.textContent = "Voice input failed: check microphone permission."; };
    rec.onresult = function(e){
      var transcript = "";
      for(var i=e.resultIndex;i<e.results.length;i++) transcript += e.results[i][0].transcript;
      el.task.value = base ? (base + " " + transcript) : transcript;
      syncControls(); autoGrow();
      if (e.results[e.results.length-1].isFinal) {
        el.task.focus();
      }
    };
    try{ rec.start(); }catch(_){ setListening(false); }
  });
})();

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

function handleSlashDocFile(task){
  var m = task.match(/^\/(?:doc|file)\s+(.+)$/);
  if (!m) return null;
  var path = m[1].trim();
  if (!path) return null;
  // Create a Knowledge collection on-the-fly if needed and add the file as a doc via a hint
  // We can't read the file client-side (sandbox), so we inject a task header that tells
  // the agent to read that path via read_file/file_ops and treat it as RAG.
  // #file / @doc convention — here it's /doc <path> as an alias for #knowledge.
  return "[File: " + path + "]\n\n" + task;
}

// ---- session status bar: goal / tool-call / sub-agent / todos receipt ----
// Reflects the turn currently streaming, or the last one that did, not the
// whole session's history. Resets on every new submit; nothing here is
// persisted, so a reload clears it the same way the live caret does.
// sessionMetrics is the opposite: it accumulates across turns in this
// tab until New chat, a session switch, or reload.
var statusToolCalls = 0;
var statusSubagentCalls = 0;
var sessionMetrics = emptyRunMetrics();

function resetSessionStatusBar() {
  statusToolCalls = 0;
  statusSubagentCalls = 0;
  if (!el.sessionStatusBar) return;
  el.sessionStatusBar.hidden = false;
  [el.statusGoal, el.statusTools, el.statusSubagent, el.statusTodos].forEach(function (chip) {
    if (chip) chip.hidden = true;
  });
}

function resetSessionMetrics() {
  sessionMetrics = emptyRunMetrics();
  paintRunMetrics();
}

function paintRunMetrics() {
  if (!el.runMetrics) return;
  var parts = formatRunMetricsParts(sessionMetrics, Date.now());
  el.runMetrics.hidden = !parts.length;
  el.runMetrics.setAttribute("aria-live", sessionMetrics.live ? "off" : "polite");
  if (!parts.length) {
    el.runMetrics.textContent = "";
    return;
  }
  var kids = el.runMetrics.children;
  if (kids.length !== parts.length) {
    el.runMetrics.textContent = "";
    parts.forEach(function (p) {
      var s = document.createElement("span");
      s.className = "run-metrics-cell";
      s.setAttribute("data-m", p.key);
      s.textContent = p.text;
      el.runMetrics.appendChild(s);
    });
    return;
  }
  for (var i = 0; i < parts.length; i++) {
    if (kids[i].textContent !== parts[i].text) kids[i].textContent = parts[i].text;
  }
}

function setStatusGoal(goalId) {
  if (!el.statusGoal) return;
  var g = (goalState.val || []).filter(function (x) { return x.id === goalId; })[0];
  el.statusGoal.hidden = false;
  el.statusGoal.textContent = "Goal " + (g ? goalStatusLabel(g, true) : "active");
  el.statusGoal.title = g ? g.objective : goalId;
}

function bumpStatusTools(calls) {
  if (!el.statusTools) return;
  var n = (calls || []).length;
  if (n === 0) return;
  statusToolCalls += n;
  el.statusTools.hidden = false;
  el.statusTools.textContent = "Tools (" + statusToolCalls + ")";
  var subN = (calls || []).filter(function (c) { return c.name === "subagent" || c.name === "swarm"; }).length;
  if (subN > 0 && el.statusSubagent) {
    statusSubagentCalls += subN;
    el.statusSubagent.hidden = false;
    el.statusSubagent.textContent = "Sub Agent (" + statusSubagentCalls + ")";
  }
}

function setStatusTodos(todos) {
  if (!el.statusTodos) return;
  var list = todos || [];
  if (!list.length) { el.statusTodos.hidden = true; return; }
  var done = list.filter(function (t) { return t.status === "closed"; }).length;
  el.statusTodos.hidden = false;
  el.statusTodos.textContent = "Todos (" + done + "/" + list.length + ")";
}

el.form.addEventListener("submit", function (e) {
  e.preventDefault();
  var task = el.task.value.trim();
  if (busy || task === "") return;
  var promoted = handleSlashDocFile(task);
  if (promoted) task = promoted;

  var isPlan = el.planMode && el.planMode.checked;
  var isResearch = el.researchMode && el.researchMode.checked;
  // 1000 is the server's own clamp ceiling (clampIterationBudget in
  // cli.zig) — there is no true "unlimited", so this asks for the highest
  // budget the harness will actually honor rather than a number it clamps
  // down anyway.
  var noLimit = el.unlimitedIterations && el.unlimitedIterations.checked;
  resetSessionStatusBar();
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
  beginLiveTurn(sessionMetrics, startedAt);
  paintRunMetrics();
  runWaitLabel = "thinking";
  startElapsed(startedAt);
  controller = new AbortController();

  var liveGraph = { nodes: [], _byIter: {} };
  function pushLiveNode(kind, detail, label, ms){
    var iter = liveGraph.nodes.filter(function(n){ return n.kind==="llm"; }).length + 1;
    var node = { kind: kind, detail: detail||label||kind, label: label||detail||kind, duration_ms: ms||0, prompt_tokens:0, completion_tokens:0, result_bytes:0, ok: true, iteration: iter };
    liveGraph.nodes.push(node);
    // fire a lightweight live-runs refresh so Runs shows progress even before done
    try{
      if (!liveGraph._timer) liveGraph._timer = setTimeout(function(){
        liveGraph._timer=null;
        // stash as a synthetic run for the picker — not persisted, just for live view
        var synth = { run_id:"live", task: task, provider: (opts.provider||""), duration_ms: Date.now()-startedAt, total_prompt_tokens:0, total_completion_tokens:0, nodes: liveGraph.nodes.slice() };
        // render into Runs if that view is open, otherwise just keep for final compare
        if (document.getElementById("view-runs") && !document.getElementById("view-runs").hidden) {
          try{ drawRun(synth); }catch(_){}
        }
        window._liveGraph = synth;
      }, 250);
    }catch(_){}
  }
  var opts = runOptions();
  var statsRendered = false;
  var splitter = makeLineSplitter(function (line) {
    if (line.charCodeAt(0) === 1) {
      var evt;
      try { evt = JSON.parse(line.slice(1)); } catch (e) { return; }
      if (evt.type === "tool_call") { addToolEvent(turn, evt.names, evt.calls); setTurnPhase(turn, "tool"); if (evt.names) { runWaitLabel = "running " + evt.names; pushLiveNode("tool", evt.names, evt.names, 0); } bumpStatusTools(evt.calls); sessionMetrics.liveSteps += 1; paintRunMetrics(); }
      else if (evt.type === "tool_result") { settleLastToolEvent(turn, evt.ms); setTurnPhase(turn, "tool"); runWaitLabel = "thinking"; if (typeof evt.ms === "number") { sessionMetrics.liveToolMs += evt.ms; paintRunMetrics(); } if(evt.ms){
        var last = liveGraph.nodes[liveGraph.nodes.length-1]; if(last && last.kind==="tool") last.duration_ms = evt.ms;
      }}
      // The run's own private checklist (features/todos.js): pushed whenever a
      // todo_* call moved it, never fetched — the list is in-memory server-side
      // and dies with the run, so the turn card is the only place it can live.
      else if (evt.type === "todos") { try { todosRenderTurn(turn, evt.todos); } catch (_t) {} setStatusTodos(evt.todos); }
      else if (evt.type === "goal") { setStatusGoal(evt.id); }
      // A status event is a run lifecycle note (contacting the provider, a
      // steering message being applied) rather than answer text: show it as a
      // bracketed log line, the same way the goals view renders it.
      else if (evt.type === "status") { appendText(turn, "\n[ " + evt.message + " ]\n", true); }
      else if (evt.type === "ask") { addAskEvent(turn, evt); setTurnPhase(turn, "ask"); }
      else if (evt.type === "confirm") { addConfirmEvent(turn, evt); setTurnPhase(turn, "ask"); }
      else if (evt.type === "error") { appendText(turn, "\n[" + evt.message + errorRecoveryHint(evt.message) + "]\n", true); setTurnPhase(turn, ""); pushLiveNode("tool", evt.message, "error", 0); }
      else if (evt.type === "usage") {
        applyLiveUsage(sessionMetrics, evt);
        paintRunMetrics();
      }
      else if (evt.type === "done") {
        renderStats(turn, evt, task);
        applyDoneStats(sessionMetrics, evt);
        paintRunMetrics();
        statsRendered = true;
        setTurnPhase(turn, "");
        pushLiveNode("final", "done", "done", evt.ms||0);
      } else if (evt.type === "llm_start" || evt.type === "llm") { pushLiveNode("llm", evt.model||"llm", evt.model||"llm", 0); }
      return;
    }
    var stick = nearBottom();
    if (sessionMetrics.live && sessionMetrics.liveTtftMs == null) {
      noteFirstToken(sessionMetrics, Date.now());
    }
    if (sessionMetrics.live) noteLiveChars(sessionMetrics, line.length + 1);
    paintRunMetrics();
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
    if (stick) scrollChatLatest("auto");
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
      fallback_provider: opts.fallbackProvider || "",
      temperature: typeof opts.temperature === "number" ? opts.temperature : null,
      top_p: typeof opts.top_p === "number" ? opts.top_p : null,
      plan: isPlan,
      research: isResearch,
      max_iterations: noLimit ? 1000 : null,
      worktree: !!(el.worktreeMode && el.worktreeMode.checked),
      knowledge: (typeof kbSelected !== "undefined" ? kbSelected.slice() : []),
      workspace: currentWorkspace || ""
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
    // The draft was this task; it has been asked and answered. Cleared only on
    // this path — the branch above deliberately leaves an unfinished run's task
    // in the composer, and that is exactly a draft worth keeping.
    dropDraft(sessionId);
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
      var msg = err.message || "unknown error";
      var hint = errorRecoveryHint(msg);
      if (!hint && /fetch|network|ECONNREFUSED/i.test(msg))
        hint = " (is the server still running?)";
      appendText(turn, "\n[run failed: " + msg + hint + "]\n", true);
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
    if (sessionMetrics.live) {
      applyDoneStats(sessionMetrics, { ms: liveElapsedMs(sessionMetrics, Date.now()) });
    }
    stopElapsed();
    paintRunMetrics();
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
function runFailed(r){ return r && (r.failed === true || r.ok === false || (r.nodes||[]).some(function(n){ return n.ok===false; })); }
function renderRunOptions(filterText) {
  var q = (filterText || "").trim().toLowerCase();
  var failedOnly = q === "failed" || q === ":failed" || q === "⚠ failed";
  var matches;
  if (failedOnly) matches = allRuns.filter(function(r){ return runFailed(r); });
  else matches = !q ? allRuns : allRuns.filter(function (r) { return (r.task || "").toLowerCase().indexOf(q) !== -1 || r.run_id.toLowerCase().indexOf(q) !== -1; });
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
        var p = loadRun(want);
        var pn = window._pendingRunNode; window._pendingRunNode = null;
        if (pn) p.then(function(){ setTimeout(function(){ try{ var n = el.runGraph.querySelector('.run-node[data-label="' + CSS.escape(pn) + '"]'); if(n){ n.focus(); n.click(); n.scrollIntoView({block:"center", inline:"center"}); } }catch(_){}} , 300); });
        return p;
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
  try { history.replaceState(null, "", "#runs/" + encodeURIComponent(id)); } catch (_) {}
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
  el.runStatus.textContent = "Loading run " + id + "…";
  return fetch("/api/runs/" + encodeURIComponent(id))
    .then(readJson)
    .then(function (g) {
      el.runGraph.textContent = "";
      el.runGraph.removeAttribute("aria-busy");
      populateCompareSelects();
      drawRun(g);
      // The graph itself makes completion visible, but this live region is
      // also the small floating status shown while a run loads. Leaving the
      // loading copy behind makes a finished graph still look in flight.
      el.runStatus.textContent = "";
    })
    .catch(function (err) {
      var msg = err && err.message ? err.message : "unknown error";
      showRunsError(msg === "graph read failed"
        ? "Could not load that run. It may have been removed; open Runs to pick another."
        : "Could not load that run: " + msg);
    });
}
function populateCompareSelects(){
  var a=document.getElementById("run-compare-a"), b=document.getElementById("run-compare-b");
  if(!a||!b) return;
  var opts = allRuns.map(function(r){ var o=document.createElement("option"); o.value=r.run_id; o.textContent=runLabel(r); return o; });
  // keep selections if already set
  var keepA=a.value, keepB=b.value;
  a.textContent=""; b.textContent="";
  opts.forEach(function(o){ a.appendChild(o.cloneNode(true)); b.appendChild(o.cloneNode(true)); });
  if(keepA) a.value=keepA; else if(allRuns[0]) a.value=allRuns[0].run_id;
  if(keepB) b.value=keepB; else if(allRuns[1]) b.value=allRuns[1].run_id;
  document.getElementById("run-compare").hidden = allRuns.length < 2;
}
function diffRuns(aId, bId){
  var status=document.getElementById("run-compare-status"), clearBtn=document.getElementById("run-compare-clear");
  if(!aId||!bId){ if(status) status.textContent="Pick two runs"; return; }
  if(aId===bId){ if(status) status.textContent="Pick two different runs"; return; }
  if(status) status.textContent="Comparing…";
  Promise.all([fetch("/api/runs/"+encodeURIComponent(aId)).then(readJson), fetch("/api/runs/"+encodeURIComponent(bId)).then(readJson)]).then(function(pair){
    var ga=pair[0], gb=pair[1];
    var aNodes={}, bNodes={};
    (ga.nodes||[]).forEach(function(n){ var k=n.label||n.detail||n.kind; aNodes[k]=(aNodes[k]||0)+1; });
    (gb.nodes||[]).forEach(function(n){ var k=n.label||n.detail||n.kind; bNodes[k]=(bNodes[k]||0)+1; });
    var added=[], removed=[], changed=[];
    Object.keys(bNodes).forEach(function(k){ if(!aNodes[k]) added.push(k); });
    Object.keys(aNodes).forEach(function(k){ if(!bNodes[k]) removed.push(k); });
    (ga.nodes||[]).forEach(function(n){
      var k=n.label||n.detail||n.kind;
      var m=(gb.nodes||[]).find(function(x){ return (x.label||x.detail||x.kind)===k; });
      if(m && (m.ok!==n.ok || Math.abs((m.duration_ms||0)-(n.duration_ms||0))> Math.max(80, (n.duration_ms||0)*0.25))) changed.push(k + ": " + (m.ok===false?"failed":"") + " " + (n.duration_ms||0)+"ms → "+(m.duration_ms||0)+"ms");
    });
    // Re-render current graph with highlights
    drawRun(ga);
    setTimeout(function(){
      added.forEach(function(k){ el.runGraph.querySelectorAll(".run-node").forEach(function(el2){ if((el2.getAttribute("data-label")||"").indexOf(k.slice(0,16))!==-1) el2.style.outline="2px solid var(--ok)"; }); });
      removed.forEach(function(k){ el.runGraph.querySelectorAll(".run-node").forEach(function(el2){ if((el2.getAttribute("data-label")||"").indexOf(k.slice(0,16))!==-1) el2.setAttribute("data-ok","false"); }); });
      changed.forEach(function(k){ var lab=k.split(": ")[0]; el.runGraph.querySelectorAll(".run-node").forEach(function(el2){ if((el2.getAttribute("data-label")||"").indexOf(lab.slice(0,16))!==-1) el2.style.boxShadow="0 0 0 2px var(--warn)"; }); });
    }, 260);
    if(status) status.textContent = added.length+" added · "+removed.length+" removed · "+changed.length+" changed";
    if(clearBtn) clearBtn.hidden=false;
    el.runDetail.hidden=false; el.runDetail.textContent="";
    var pre=document.createElement("pre"); pre.style.whiteSpace="pre-wrap"; pre.style.fontSize="12px";
    pre.textContent = "A: "+aId+"\nB: "+bId+"\n\n+ added ("+added.length+"):\n"+added.join("\n")+"\n\n- removed ("+removed.length+"):\n"+removed.join("\n")+"\n\n~ changed ("+changed.length+"):\n"+changed.join("\n");
    el.runDetail.appendChild(pre);
  }).catch(function(e){ if(status) status.textContent="Diff failed: "+e.message; });
}

var metricsFor = graphMetricsFor;
var buildStages = graphBuildStages;

var lastGraph = null;
var lastBuilt = null;
/* drawRun hangs pan/minimap handlers off window; each redraw builds a fresh
   canvas, so the previous set is aborted here or every redraw would leak five
   listeners plus the detached subtree their closures retain. */
var drawRunListeners = null;
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
  if (drawRunListeners) drawRunListeners.abort();
  drawRunListeners = new AbortController();
  var winSignal = drawRunListeners.signal;
  el.runGraph.textContent = "";
  var nodes = g.nodes || [];

  var head = document.createElement("div");
  head.className = "run-head";
  head.style.display = "flex"; head.style.flexWrap = "wrap"; head.style.gap = "0.4rem"; head.style.alignItems = "center";
  var headId = document.createElement("span"); headId.textContent = g.run_id; headId.style.fontWeight = "600"; head.appendChild(headId);
  if (g.provider) { var hp = document.createElement("span"); hp.className = "tool-tag"; hp.textContent = g.provider; head.appendChild(hp); }
  var hm = document.createElement("span"); hm.className = "meta"; hm.textContent = g.duration_ms + "ms · " + g.total_prompt_tokens + " prompt + " + g.total_completion_tokens + " completion"; head.appendChild(hm);
  if (g.task) { var ht = document.createElement("span"); ht.className = "meta"; ht.style.flexBasis = "100%"; ht.textContent = g.task; head.appendChild(ht); }
  var copyHead = document.createElement("button"); copyHead.type = "button"; copyHead.className = "secondary"; copyHead.textContent = "Copy id"; upgradePfButton(copyHead);
  copyHead.addEventListener("click", function(){ try{ navigator.clipboard.writeText(g.run_id); copyHead.textContent="Copied"; setTimeout(function(){ copyHead.textContent="Copy id"; }, 1200);}catch(_){} });
  head.appendChild(copyHead);
  var copyLink = document.createElement("button"); copyLink.type = "button"; copyLink.className = "secondary"; copyLink.textContent = "Copy link"; upgradePfButton(copyLink);
  copyLink.title = "Copy deep-link to this run — add ?node= to pin this exact graph position";
  copyLink.addEventListener("click", function(){
    var sel = el.runGraph.querySelector(".run-node.selected");
    var nodePart = sel && sel.getAttribute("data-label") ? "?node=" + encodeURIComponent(sel.getAttribute("data-label")) : "";
    var u = location.origin + location.pathname + "#runs/" + encodeURIComponent(g.run_id) + nodePart;
    try{ navigator.clipboard.writeText(u); copyLink.textContent="Copied"; setTimeout(function(){ copyLink.textContent="Copy link"; }, 1200);}catch(_){ copyText(u, copyLink, "Copy link", head); }
  });
  head.appendChild(copyLink);
  var exportBtn = document.createElement("button"); exportBtn.type = "button"; exportBtn.className = "secondary"; exportBtn.textContent = "Export .html"; upgradePfButton(exportBtn);
  exportBtn.title = "Download this run as a self-contained HTML file";
  exportBtn.addEventListener("click", function(){
    try{
      var svg = el.runGraph.querySelector("svg.run-edges");
      var svgHtml = svg ? new XMLSerializer().serializeToString(svg) : "";
      var detailHtml = el.runDetail.hidden ? "" : el.runDetail.innerHTML;
      // Everything interpolated here is run data — the task is whatever the
      // operator or a parent agent typed, the run id is a server-side string
      // — and this is raw string concatenation, not DOM building, so it needs
      // explicit escaping. It did not have it: a task containing markup was
      // written straight into <title>, <h1> and <p> of a file the browser then
      // opens from a blob URL.
      //
      // The JSON dump below looked escaped and was not, which is how the gap
      // in the header stayed invisible: it hand-rolled `.replace(/</g,"&lt;")`,
      // a second escaper covering one of the five characters that matter. `<`
      // alone does keep markup out of a <pre>, but leaving `&` means every
      // entity a run's own text contains is decoded on the way back out, so a
      // tool result holding the literal text "&lt;script&gt;" was shown as
      // "<script>". One escaper, `core/utils.js`'s escapeHtml, at every
      // interpolation site including this one.
      var esc = escapeHtml;
      var html = "<!doctype html><meta charset=utf-8><title>" + esc(g.run_id) + "</title><style>body{font-family:ui-sans-serif,system-ui;padding:1.2rem;max-width:70rem;margin:auto}pre{white-space:pre-wrap;word-break:break-word;background:#f6f6f6;padding:0.8rem;border-radius:8px;overflow:auto}svg{max-width:100%;height:auto}</style><h1>" + esc(g.run_id) + "</h1><p>" + esc(g.task||"") + " · " + esc(g.duration_ms) + "ms · " + esc(g.total_prompt_tokens) + " prompt + " + esc(g.total_completion_tokens) + " completion</p><div>" + svgHtml + "</div><hr><div>" + detailHtml + "</div><pre>" + esc(JSON.stringify(g, null, 2)) + "</pre>";
      var blob = new Blob([html], {type:"text/html"});
      var url = URL.createObjectURL(blob);
      var a = document.createElement("a"); a.href = url; a.download = g.run_id + ".html";
      document.body.appendChild(a); a.click(); a.remove(); setTimeout(function(){ URL.revokeObjectURL(url); }, 1000);
    }catch(_){ el.runStatus.textContent = "Export failed"; }
  });
  head.appendChild(exportBtn);
  if (g.parent_run_id) {
    var par = document.createElement("button"); par.type = "button"; par.className = "secondary"; par.textContent = "↑ Parent " + g.parent_run_id.slice(0,8); upgradePfButton(par);
    par.title = "Open parent run " + g.parent_run_id;
    par.addEventListener("click", function(){ openRun(g.parent_run_id); });
    head.appendChild(par);
  }
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
  graphSearch.style.display = "flex"; graphSearch.style.gap = "0.5rem"; graphSearch.style.marginBottom = "0.5rem"; graphSearch.style.flexWrap = "wrap"; graphSearch.style.alignItems = "center";
  var graphSearchInput = document.createElement("input");
  graphSearchInput.type = "search"; graphSearchInput.placeholder = "Filter nodes (e.g. read_file, grep)…  —  / to focus";
  graphSearchInput.setAttribute("aria-label", "Filter graph nodes — press / to focus, n/N to step matches, F failed, j/k iterations, arrows walk nodes");
  graphSearchInput.title = "Filter nodes — / focuses, n/N next match, F failed, j/k next iteration";
  graphSearchInput.style.flex = "1"; graphSearchInput.style.minWidth = "12rem";
  var graphNextBtn = document.createElement("button"); graphNextBtn.type = "button"; graphNextBtn.className = "secondary"; graphNextBtn.textContent = "Next"; upgradePfButton(graphNextBtn);
  graphNextBtn.title = "Next match (n)";
  var graphClearBtn = document.createElement("button"); graphClearBtn.type = "button"; graphClearBtn.className = "secondary"; graphClearBtn.textContent = "Clear"; upgradePfButton(graphClearBtn);
  graphClearBtn.title = "Clear filter";
  var graphFitBtn = document.createElement("button"); graphFitBtn.type = "button"; graphFitBtn.className = "secondary"; graphFitBtn.textContent = "Fit"; upgradePfButton(graphFitBtn);
  graphFitBtn.title = "Fit graph to view (0)";
  graphSearch.appendChild(graphSearchInput); graphSearch.appendChild(graphNextBtn); graphSearch.appendChild(graphClearBtn); graphSearch.appendChild(graphFitBtn);
  var graphHint = document.createElement("span"); graphHint.className = "meta"; graphHint.textContent = "/ filter · n next · F failed · j/k iter · arrows walk · +/− zoom · click node to pin link";
  graphHint.style.fontSize = "11px"; graphHint.style.opacity = "0.75"; graphHint.style.flexBasis = "100%";
  graphSearch.appendChild(graphHint);
  el.runGraph.appendChild(graphSearch);
  // Trello/Slack-style focus filters — dim non-matches so dense graphs stay scannable
  var _kindFilter = (function(){ try{ return localStorage.getItem("clanker.graphKind") || ""; }catch(_){ return ""; } })();
  var _initSearch = (function(){ try{ return localStorage.getItem("clanker.graphSearch") || ""; }catch(_){ return ""; } })();
  var graphKindBar = document.createElement("div");
  graphKindBar.className = "run-kind-filter"; graphKindBar.style.display = "flex"; graphKindBar.style.gap = "0.35rem"; graphKindBar.style.flexWrap = "wrap"; graphKindBar.style.marginBottom = "0.5rem";
  graphKindBar.setAttribute("role", "group"); graphKindBar.setAttribute("aria-label", "Filter by node kind");
  [{k:"",label:"All"},{k:"llm",label:"LLM"},{k:"tool",label:"Tools"},{k:"final",label:"Answer"},{k:"failed",label:"Failed"}].forEach(function(opt){
    var b = document.createElement("button"); b.type = "button"; b.className = "secondary"; b.textContent = opt.label; upgradePfButton(b);
    b.dataset.kind = opt.k; b.setAttribute("aria-pressed", String(opt.k === _kindFilter));
    if (opt.k === "failed") b.title = "Only failed nodes";
    b.addEventListener("click", function(){
      _kindFilter = opt.k;
      try{ localStorage.setItem("clanker.graphKind", _kindFilter); }catch(_){}
      graphKindBar.querySelectorAll("button").forEach(function(x){ x.setAttribute("aria-pressed", String(x.dataset.kind === _kindFilter)); });
      _matchIdx = -1; doLayout(_searchQ);
    });
    graphKindBar.appendChild(b);
  });
  if (_initSearch) graphSearchInput.value = _initSearch;
  el.runGraph.appendChild(graphKindBar);
  // Codex-style breadcrumb: iteration / step chips + keyboard tour
  var crumb = document.createElement("div");
  crumb.className = "run-crumbs"; crumb.style.display = "flex"; crumb.style.gap = "0.35rem"; crumb.style.flexWrap = "wrap"; crumb.style.marginBottom = "0.5rem";
  crumb.setAttribute("role", "navigation"); crumb.setAttribute("aria-label", "Iterations");
  built.stages.forEach(function(st, idx){
    var chip = document.createElement("button");
    chip.type = "button"; chip.className = "secondary"; chip.textContent = "iter " + st.iteration; upgradePfButton(chip);
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
  // Time scrubber / playback — iteration stepper (Codex/Kimi parity)
  if (built.stages.length > 1) {
    var maxIter = Math.max.apply(null, built.stages.map(function(s){ return s.iteration; }));
    var minIter = Math.min.apply(null, built.stages.map(function(s){ return s.iteration; }));
    var scrubWrap = document.createElement("div");
    scrubWrap.style.display = "flex"; scrubWrap.style.alignItems = "center"; scrubWrap.style.gap = "0.5rem"; scrubWrap.style.marginBottom = "0.5rem";
    var scrubLabel = document.createElement("span"); scrubLabel.className = "meta"; scrubLabel.textContent = "Scrub:"; scrubWrap.appendChild(scrubLabel);
    var scrub = document.createElement("input"); scrub.type = "range"; scrub.min = String(minIter); scrub.max = String(maxIter); scrub.value = String(maxIter); scrub.step = "1";
    scrub.setAttribute("aria-label", "Scrub iterations"); scrub.style.flex = "1";
    var scrubOut = document.createElement("span"); scrubOut.className = "meta"; scrubOut.textContent = "iter " + maxIter + " / " + maxIter;
    scrubWrap.appendChild(scrub); scrubWrap.appendChild(scrubOut);
    scrub.addEventListener("input", function(){
      var v = parseInt(scrub.value, 10);
      scrubOut.textContent = "iter " + v + " / " + maxIter;
      // dim nodes past scrub point so you can see how the run grew
      canvas.querySelectorAll(".run-node").forEach(function(n){
        var iterTag = n.previousElementSibling;
        // find iter via crumb mapping: nearest llm tag — simpler: use data highlight path via iter
        var nodeIter = parseInt(n.getAttribute("data-iter") || "0", 10);
        if (isNaN(nodeIter)) return;
        n.style.opacity = (nodeIter > v) ? "0.2" : "";
      });
      // keep selected detail in sync: if its iter is now hidden, auto-select nearest visible iter
    });
    el.runGraph.appendChild(scrubWrap);
  }

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
    window.addEventListener("mouseup", function(){ if(isPanning){ isPanning = false; canvas.style.cursor = ""; } }, { signal: winSignal });
    window.addEventListener("mousemove", function(e){
      if (!isPanning) return;
      canvas.scrollLeft = startScrollLeft - (e.clientX - startX);
      canvas.scrollTop = startScrollTop - (e.clientY - startY);
    }, { signal: winSignal });
    canvas.addEventListener("wheel", function(e){
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        if (e.deltaY < 0) zoomInBtn.click(); else if (e.deltaY > 0) zoomOutBtn.click();
      }
    }, { passive: false });
  })();
  var zoomWrap = document.createElement("div");
  zoomWrap.style.display = "flex"; zoomWrap.style.gap = "0.4rem"; zoomWrap.style.marginTop = "0.4rem";
  var zoomInBtn = document.createElement("button"); zoomInBtn.type = "button"; zoomInBtn.className = "secondary"; zoomInBtn.textContent = "+ Zoom"; upgradePfButton(zoomInBtn);
  var zoomOutBtn = document.createElement("button"); zoomOutBtn.type = "button"; zoomOutBtn.className = "secondary"; zoomOutBtn.textContent = "− Zoom"; upgradePfButton(zoomOutBtn);
  var zoomResetBtn = document.createElement("button"); zoomResetBtn.type = "button"; zoomResetBtn.className = "secondary"; zoomResetBtn.textContent = "Reset"; upgradePfButton(zoomResetBtn);
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
  var mmCanvas = document.createElement("canvas"); mmCanvas.width = 148; mmCanvas.height = 90; minimap.insertBefore(mmCanvas, mmLabel.nextSibling);
  var mmViewport = document.createElement("div"); mmViewport.className = "run-minimap-viewport";
  minimap.appendChild(mmViewport);
  canvas.appendChild(minimap);
  // Content size and node positions are cached on layout. Scroll only
  // updates the viewport rect, coalesced to one rAF, so it never walks
  // the node list or forces layout.
  var mmSW = 1, mmSH = 1, mmRaf = 0, mmNodes = [], mmEdges = [];
  function mmToken(name, fallback) {
    try { return (getComputedStyle(document.documentElement).getPropertyValue(name) || "").trim() || fallback; }
    catch (_) { return fallback; }
  }
  function measureMinimap(){
    try { mmSW = Math.max(1, canvas.scrollWidth); mmSH = Math.max(1, canvas.scrollHeight); }
    catch(_){ mmSW = 1; mmSH = 1; }
  }
  function rebuildMinimapCache(){
    measureMinimap();
    mmNodes = [];
    canvas.querySelectorAll(".run-node").forEach(function(n){
      var lx = parseFloat(n.style.left), ly = parseFloat(n.style.top);
      mmNodes.push({
        el: n,
        x: isFinite(lx) ? lx : 0,
        y: isFinite(ly) ? ly : 0,
        kind: n.getAttribute("data-kind") || "",
        ok: n.getAttribute("data-ok"),
        selected: n.classList.contains("selected"),
        highlight: n.hasAttribute("data-highlight")
      });
    });
    mmEdges = [];
    try {
      canvas.querySelectorAll("svg.run-edges path[data-edge]").forEach(function(p){
        var d = p.getAttribute("d") || "";
        var m = d.match(/M\s*([0-9.\-]+),([0-9.\-]+)\s*L\s*([0-9.\-]+),([0-9.\-]+)/);
        if (!m) return;
        mmEdges.push({ x1: parseFloat(m[1]), y1: parseFloat(m[2]), x2: parseFloat(m[3]), y2: parseFloat(m[4]) });
      });
    } catch (_) {}
  }
  function paintMinimap(){
    try{
      var ctx = mmCanvas.getContext("2d");
      if (!ctx) return;
      ctx.clearRect(0,0,mmCanvas.width, mmCanvas.height);
      var sw = mmSW, sh = mmSH;
      var accent = mmToken("--accent", "#0b57d0");
      var ok = mmToken("--ok", "#117a3a");
      var danger = mmToken("--danger", "#dc2626");
      var fg = mmToken("--fg", "#111");
      var muted = mmToken("--fg-muted", "#888");
      ctx.strokeStyle = muted;
      ctx.globalAlpha = 0.35;
      ctx.lineWidth = 0.7;
      mmEdges.forEach(function(e){
        ctx.beginPath();
        ctx.moveTo((e.x1 / sw) * mmCanvas.width, (e.y1 / sh) * mmCanvas.height);
        ctx.lineTo((e.x2 / sw) * mmCanvas.width, (e.y2 / sh) * mmCanvas.height);
        ctx.stroke();
      });
      ctx.globalAlpha = 0.75;
      mmNodes.forEach(function(n){
        var x = (n.x / sw) * mmCanvas.width;
        var y = (n.y / sh) * mmCanvas.height;
        var w = 6, h = 4;
        if (n.kind === "llm") ctx.fillStyle = accent;
        else if (n.kind === "tool") ctx.fillStyle = ok;
        else if (n.kind === "final") ctx.fillStyle = fg;
        else ctx.fillStyle = muted;
        if (n.ok === "false") ctx.fillStyle = danger;
        if (n.selected) { ctx.fillStyle = accent; ctx.globalAlpha = 1; w = 7; h = 5; }
        else if (n.highlight) { ctx.fillStyle = accent; ctx.globalAlpha = 0.45; }
        ctx.fillRect(x, y, w, h);
        ctx.globalAlpha = 0.75;
      });
      ctx.globalAlpha = 1;
    }catch(_){}
  }
  function updateMinimapViewport(){
    var cw = canvas.clientWidth, ch = canvas.clientHeight;
    var needsMap = mmSW > cw + 8 || mmSH > ch + 8;
    minimap.hidden = !needsMap;
    if (minimap.hidden) return;
    var sx = canvas.scrollLeft / Math.max(1, mmSW - cw);
    var sy = canvas.scrollTop / Math.max(1, mmSH - ch);
    var vw = cw / mmSW * 100;
    var vh = ch / mmSH * 100;
    mmViewport.style.left = (sx * (100 - vw)) + "%";
    mmViewport.style.top = (sy * (100 - vh)) + "%";
    mmViewport.style.width = Math.max(12, vw) + "%";
    mmViewport.style.height = Math.max(12, vh) + "%";
  }
  function updateMinimap(){
    rebuildMinimapCache();
    if (mmSW > canvas.clientWidth + 8 || mmSH > canvas.clientHeight + 8) paintMinimap();
    updateMinimapViewport();
  }
  function scheduleMinimap(){
    if (mmRaf) return;
    mmRaf = requestAnimationFrame(function(){
      mmRaf = 0;
      updateMinimapViewport();
    });
  }
  canvas.addEventListener("scroll", scheduleMinimap, { passive: true });
  minimap.addEventListener("click", function(e){
    if (e.target === mmViewport) return;
    var rect = minimap.getBoundingClientRect();
    var px = (e.clientX - rect.left) / rect.width;
    var py = (e.clientY - rect.top) / rect.height;
    var cx = px * mmSW, cy = py * mmSH;
    var best = null, bestD = Infinity;
    mmNodes.forEach(function(n){
      var d = Math.hypot(n.x - cx, n.y - cy);
      if (d < bestD) { bestD = d; best = n.el; }
    });
    if (best && bestD < 60) { best.focus(); best.click(); best.scrollIntoView({block:"center", inline:"center"}); return; }
    canvas.scrollLeft = px * (mmSW - canvas.clientWidth);
    canvas.scrollTop = py * (mmSH - canvas.clientHeight);
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
    }, { signal: winSignal });
    window.addEventListener("mouseup", function(){ dragging = false; }, { signal: winSignal });
  })();
  // keep in sync after layout / resize
  window.addEventListener("resize", updateMinimap, { signal: winSignal });
  // Fit button
  graphFitBtn.addEventListener("click", function(){
    canvas.scrollLeft = 0; canvas.scrollTop = 0;
    // also reset zoom if api exposed
    try{ var ev = new KeyboardEvent("keydown", { key: "0" }); canvas.dispatchEvent(ev); }catch(_){}
    updateMinimap();
  });

  function syncGraphUrl(){
    try{
      var rawHash = location.hash || "";
      var parsed = parseRunsHash(rawHash) || { id: (lastGraph ? lastGraph.run_id : ""), search:"", kind:"", node:"" };
      var base = "#runs/" + encodeURIComponent(lastGraph ? lastGraph.run_id : parsed.id);
      if (!lastGraph || !lastGraph.run_id) base = rawHash.split("?")[0] || base;
      var params = [];
      if (_searchQ) params.push("search=" + encodeURIComponent(_searchQ));
      else if (parsed.search && !canvas.querySelector(".run-node")) params.push("search=" + encodeURIComponent(parsed.search));
      if (_kindFilter) params.push("kind=" + encodeURIComponent(_kindFilter));
      else if (parsed.kind && !canvas.querySelector(".run-node")) params.push("kind=" + encodeURIComponent(parsed.kind));
      var sel = canvas.querySelector(".run-node.selected");
      var lbl = sel ? sel.getAttribute("data-label") : (parsed.node || window._pendingRunNode || null);
      if (lbl) params.push("node=" + encodeURIComponent(lbl));
      var hash = base + (params.length ? "?" + params.join("&") : "");
      if (location.hash !== hash) history.replaceState(null, "", hash);
    }catch(_){}
  }
  function doLayout(q){
    loadD3().then(function () {
      if (canvas.isConnected) layoutGraph(canvas, built, slowest, { searchQuery: q || "", kindFilter: _kindFilter, statusEl: el.runStatus, minimap: minimap, onSelect: function(k,n){ showNodeDetail(k,n); syncGraphUrl(); } });
      try{ updateMinimap(); paintMinimap(); }catch(_){}
      syncGraphUrl();
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
  // An error lens — one button jumps to failed nodes
  var graphFailedBtn = document.createElement("button"); graphFailedBtn.type = "button"; graphFailedBtn.className = "secondary"; graphFailedBtn.textContent = "⚠ Failed"; upgradePfButton(graphFailedBtn);
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
  _searchQ = _initSearch || "";
  graphSearchInput.addEventListener("input", function(){
    _searchQ = graphSearchInput.value.trim();
    try{ localStorage.setItem("clanker.graphSearch", graphSearchInput.value); }catch(_){}
    _matchIdx = -1;
    doLayout(_searchQ);
  });
  graphNextBtn.addEventListener("click", focusNextMatch);
  graphClearBtn.addEventListener("click", function(){ graphSearchInput.value = ""; _searchQ = ""; _matchIdx = -1; try{ localStorage.removeItem("clanker.graphSearch"); }catch(_){} doLayout(""); graphSearchInput.focus(); });
  // j/k step tour between iterations
  var _iterIdx = 0;
  function focusIter(dir){
    var chips = crumb.querySelectorAll("button");
    if (!chips.length) return;
    _iterIdx = (_iterIdx + dir + chips.length) % chips.length;
    chips[_iterIdx].focus();
    chips[_iterIdx].click();
  }
  canvas.addEventListener("keydown", function(e){
    if (document.activeElement === graphSearchInput) return;
    if (e.key === "ArrowDown" || e.key === "ArrowRight") {
      e.preventDefault();
      var nodes = Array.prototype.slice.call(canvas.querySelectorAll(".run-node"));
      if (!nodes.length) return;
      var at = nodes.indexOf(document.activeElement);
      var nxt = at === -1 ? 0 : Math.min(nodes.length - 1, at + 1);
      nodes[nxt].focus();
      return;
    }
    if (e.key === "ArrowUp" || e.key === "ArrowLeft") {
      e.preventDefault();
      var nodes2 = Array.prototype.slice.call(canvas.querySelectorAll(".run-node"));
      if (!nodes2.length) return;
      var at2 = nodes2.indexOf(document.activeElement);
      var prv = at2 <= 0 ? 0 : at2 - 1;
      nodes2[prv].focus();
      return;
    }
    if (e.key === "+" || e.key === "=") { e.preventDefault(); zoomInBtn.click(); }
    else if (e.key === "-" || e.key === "_") { e.preventDefault(); zoomOutBtn.click(); }
    else if (e.key === "0") { e.preventDefault(); zoomResetBtn.click(); }
    else if (e.key === "n" || e.key === "N") { if (_searchQ) { e.preventDefault(); focusNextMatch(); } else if (e.shiftKey || e.key === "N") { e.preventDefault(); focusNextFailed(); } }
    else if (e.key === "F" || e.key === "f") { if (e.shiftKey) { e.preventDefault(); focusNextFailed(); } }
    else if (e.key === "j") { e.preventDefault(); focusIter(1); }
    else if (e.key === "k") { e.preventDefault(); focusIter(-1); }
    else if (e.key === "Escape") { graphSearchInput.blur(); canvas.focus(); }
    else if (e.key === "/" && !e.ctrlKey && !e.metaKey) {
      e.preventDefault(); graphSearchInput.focus(); graphSearchInput.select();
    }
  });
  doLayout(_searchQ);
}

var graphSummaryText = graphSummaryTextMod;
var toDagInput = graphToDagInput;
var layoutGraph = graphLayoutGraph;

var buildIncompleteNode = graphBuildIncompleteNode;
var buildNodeBox = graphBuildNodeBox;

/* Rows for the edit-diff card: removed/added lines with a couple of context
   lines around the change, computed from an edit tool's old/new fragments.
   The fragments carry surrounding context by contract, so trimming the
   common prefix and suffix leaves exactly what the edit changed. */
function diffRows(oldText, newText) {
  var oldLines = oldText.replace(/\n$/, "").split("\n");
  var newLines = newText.replace(/\n$/, "").split("\n");
  var pre = 0;
  while (pre < oldLines.length && pre < newLines.length && oldLines[pre] === newLines[pre]) pre += 1;
  var oldEnd = oldLines.length;
  var newEnd = newLines.length;
  while (oldEnd > pre && newEnd > pre && oldLines[oldEnd - 1] === newLines[newEnd - 1]) { oldEnd -= 1; newEnd -= 1; }
  var rows = [];
  for (var i = Math.max(0, pre - 2); i < pre; i += 1) rows.push({ kind: "ctx", text: oldLines[i] });
  for (var i = pre; i < oldEnd; i += 1) rows.push({ kind: "del", text: oldLines[i] });
  for (var i = pre; i < newEnd; i += 1) rows.push({ kind: "add", text: newLines[i] });
  for (var i = oldEnd; i < Math.min(oldLines.length, oldEnd + 2); i += 1) rows.push({ kind: "ctx", text: oldLines[i] });
  return rows;
}

/* A collapsible tree for JSON-shaped node output — most tool results are
   JSON, and a flat highlighted blob makes a large payload (a big file
   listing, a nested API response) a wall of text with no way to collapse
   the part you don't care about. <details>/<summary> gives keyboard
   toggle and correct semantics for free, no custom ARIA needed. */
function buildJsonTree(value, keyLabel, depth) {  if (value === null) return jsonLeaf(keyLabel, "null", "hljs-literal");
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

  // Trello/Slack-style quick-jump: if output mentions another run, surface a Jump button in the header too
  (function(){
    var m = (node.output || "").match(/\[subagent run:\s*(sub-\d+)\]/);
    if (m) {
      var j = document.createElement("button"); j.type = "button"; j.className = "secondary"; j.textContent = "↗ " + m[1]; upgradePfButton(j);
      j.title = "Open sub-run " + m[1];
      j.addEventListener("click", function(){ openRun(m[1]); });
      head.appendChild(j);
    }
  })();
  var copyBtn = document.createElement("button");
  copyBtn.type = "button"; copyBtn.className = "secondary"; copyBtn.textContent = "Copy"; upgradePfButton(copyBtn);
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
  upgradePfButton(closeBtn);
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
  // Clickable trace refs inside the detail (file:line, run ids) jump to source / graph
  var traceBar = document.createElement("div");
  traceBar.style.display = "flex"; traceBar.style.gap = "0.4rem"; traceBar.style.flexWrap = "wrap"; traceBar.style.marginBottom = "0.5rem";
  var rawOut = node.output || "";
  var traceRe = /(?:^|\s)([a-zA-Z0-9_\-\.\/]+\.(?:zig|ts|js|py|rs|go|md):\d+(?::\d+)?)/g;
  var m, seen = {}, cnt = 0;
  while ((m = traceRe.exec(rawOut)) && cnt < 6) {
    var ref = m[1];
    if (seen[ref]) continue; seen[ref] = true; cnt++;
    (function(r){
      var b = document.createElement("button"); b.type = "button"; b.className = "secondary"; b.textContent = r; upgradePfButton(b); b.title = "Search for " + r;
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
    var sb = document.createElement("button"); sb.type = "button"; sb.className = "secondary"; sb.textContent = "↗ " + sid; upgradePfButton(sb);
    sb.title = "Open sub-run " + sid;
    (function(id){ sb.addEventListener("click", function(){ if(typeof openRun==="function") openRun(id); }); })(sid);
    traceBar.appendChild(sb);
    if (!traceBar.parentNode) el.runDetail.appendChild(traceBar);
  }

  var out = document.createElement("div");
  out.className = "run-detail-output";
  /* A file-edit tool records its arguments (path/old/new or create/content)
     on the run node now, so the change itself renders here — the result
     line ("replaced 1 match") says it happened, not what it was. Old runs
     predate the field and fall through to the output below. */
  (function () {
    var argsStr = node.arguments || "";
    if (!argsStr) return;
    var argsParsed = null;
    try { argsParsed = JSON.parse(argsStr); } catch (e) { argsParsed = null; }
    // Truncated previews are invalid JSON on purpose (the cap cuts mid-string)
    // so a broken diff can never render: say so instead.
    if (!argsParsed) {
      if (argsStr.length >= 8000) {
        var truncNote = document.createElement("p");
        truncNote.className = "meta run-diff-truncated";
        truncNote.textContent = "arguments preview truncated — open the run's source to see the full change";
        out.appendChild(truncNote);
      }
      return;
    }
    var file = argsParsed.path;
    if (typeof file !== "string" || !file) return;
    var rows = [];
    var isCreate = argsParsed.create === true;
    if (isCreate && typeof argsParsed.content === "string") {
      var contentLines = argsParsed.content.replace(/\n$/, "").split("\n");
      contentLines.forEach(function (l) { rows.push({ kind: "add", text: l }); });
    } else if (typeof argsParsed.old === "string" && typeof argsParsed.new === "string") {
      rows = diffRows(argsParsed.old, argsParsed.new);
    } else {
      return;
    }
    var adds = rows.filter(function (r) { return r.kind === "add"; }).length;
    var dels = rows.filter(function (r) { return r.kind === "del"; }).length;
    var diffWrap = document.createElement("div");
    diffWrap.className = "diff-view edit-diff";
    var diffHead = document.createElement("div");
    diffHead.className = "diff-header";
    var fileTag = document.createElement("span");
    fileTag.textContent = "\u270e " + file;
    diffHead.appendChild(fileTag);
    var counts = document.createElement("span");
    counts.className = "diff-counts";
    counts.textContent = "+" + adds + " \u2212" + dels;
    diffHead.appendChild(counts);
    diffWrap.appendChild(diffHead);
    rows.forEach(function (r) {
      var row = document.createElement("div");
      row.className = "diff-line";
      row.setAttribute("data-kind", r.kind);
      var sign = document.createElement("span");
      sign.className = "diff-sign";
      sign.textContent = r.kind === "add" ? "+" : (r.kind === "del" ? "\u2212" : " ");
      row.appendChild(sign);
      var txt = document.createElement("span");
      txt.textContent = r.text;
      row.appendChild(txt);
      diffWrap.appendChild(row);
    });
    out.appendChild(diffWrap);
  })();
  if (node.output) {
    var parsed;
    if (!truncated) {
      try { parsed = JSON.parse(node.output); } catch (e) { parsed = undefined; }
    }
    // Unified diff heuristic: has hunk headers + +/- lines — render as Codex-style diff instead of plain text
    var looksDiff = !truncated && typeof node.output === "string" && /^@@ /m.test(node.output) && /(^\+[^+]|\n\+[^+]|^-[^-]|\n-[^-])/m.test(node.output);
    if (looksDiff) {
      var diffWrap = document.createElement("div"); diffWrap.className = "diff-view";
      var diffHead = document.createElement("div"); diffHead.className = "diff-header"; diffHead.textContent = "Patch"; diffWrap.appendChild(diffHead);
      node.output.split("\n").forEach(function(line){
        var row = document.createElement("div"); row.className = "diff-line";
        var sign = document.createElement("span"); sign.className = "diff-sign";
        if (line.indexOf("@@")===0) { row.setAttribute("data-kind","hunk"); sign.textContent = "●"; }
        else if (line.charAt(0)==="+") { row.setAttribute("data-kind","add"); sign.textContent = "+"; }
        else if (line.charAt(0)==="-") { row.setAttribute("data-kind","del"); sign.textContent = "−"; }
        else sign.textContent = " ";
        row.appendChild(sign);
        var txt = document.createElement("span"); txt.textContent = line; txt.style.flex="1"; txt.style.minWidth="0";
        row.appendChild(txt); diffWrap.appendChild(row);
      });
      out.appendChild(diffWrap);
    } else if (parsed !== undefined && typeof parsed === "object" && parsed !== null) {
      var tree = document.createElement("div");
      tree.className = "json-tree";
      tree.appendChild(buildJsonTree(parsed, null, 0));
      var treeBar = document.createElement("div");
      treeBar.style.display = "flex"; treeBar.style.gap = "0.4rem"; treeBar.style.marginBottom = "0.4rem";
      var expandAll = document.createElement("button"); expandAll.type="button"; expandAll.className="secondary"; expandAll.textContent="Expand all"; upgradePfButton(expandAll);
      expandAll.addEventListener("click", function(){ tree.querySelectorAll("details").forEach(function(d){ d.open=true; }); });
      var collapseAll = document.createElement("button"); collapseAll.type="button"; collapseAll.className="secondary"; collapseAll.textContent="Collapse all"; upgradePfButton(collapseAll);
      collapseAll.addEventListener("click", function(){ tree.querySelectorAll("details").forEach(function(d){ d.open=false; }); var first = tree.querySelector("details"); if(first) first.open = true; });
      treeBar.appendChild(expandAll); treeBar.appendChild(collapseAll);
      out.appendChild(treeBar); out.appendChild(tree);
    } else {
      var outCode = document.createElement("code");
      highlightInto(outCode, null, node.output);
      out.appendChild(outCode);
    }
  }
  el.runDetail.appendChild(out);

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
(function(){
  var go=document.getElementById("run-compare-go"), clr=document.getElementById("run-compare-clear");
  if(!go) return;
  go.addEventListener("click", function(){
    var a=document.getElementById("run-compare-a"), b=document.getElementById("run-compare-b");
    if(a&&b) diffRuns(a.value, b.value);
  });
  if(clr) clr.addEventListener("click", function(){
    var s=document.getElementById("run-compare-status"); if(s) s.textContent="";
    clr.hidden=true; el.runDetail.textContent=""; el.runDetail.hidden=true;
    if(lastGraph) drawRun(lastGraph);
  });
})();

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

/* Rooms the server knows about, plus a DM entry per configured peer even
   when that conversation has no messages yet — otherwise the only way to
   start a DM would be to have already started one. */
/* The room picker derives from the rooms the server knows plus the peers this
   instance could open a DM with. It returns the room that ends up selected,
   because the caller polls it — a derivation that silently changed the
   selection would leave the log showing one room and the composer sending to
   another. */
/* ── Unread tracking ──
   Each room's "last read" timestamp is persisted in localStorage. Messages
   with ts > lastRead are unread. Opening a room marks it as read. */
var _chatReadTimestamps = (function(){
  try { return JSON.parse(localStorage.getItem("clanker.chatRead") || "{}"); } catch(_){ return {}; }
})();
function _markRoomRead(room) {
  _chatReadTimestamps[room] = Math.floor(Date.now() / 1000);
  try { localStorage.setItem("clanker.chatRead", JSON.stringify(_chatReadTimestamps)); } catch(_){}
}
function _roomHasUnread(r) {
  var lastRead = _chatReadTimestamps[r.room] || 0;
  return r.last_ts && r.last_ts > lastRead;
}
/* The sidebar (channel list) is a second view over the same room data the
   hidden <select> already holds — built here rather than replacing the
   select, so every existing chat_* call site that reads el.chatRoom.value
   keeps working unchanged. Rows are real buttons (not <option>s) so they can
   carry a Slack-style "#"/"@" prefix and unread/presence text a <select>
   can't style. */
function renderChatSidebarList(container, list, icon) {
  if (!container) return;
  container.textContent = "";
  list.forEach(function (r) {
    var row = document.createElement("button");
    row.type = "button";
    row.className = "slack-room-item";
    row.dataset.room = r.room;
    var iconEl = document.createElement("span");
    iconEl.className = "slack-room-icon";
    iconEl.setAttribute("aria-hidden", "true");
    var isRoomDm = r.room.indexOf("dm:") === 0;
    var peerUp = knownPeers.some(function (p) { return p.name === r.room || p.name === dmPartner(r.room); });
    if (isRoomDm) {
      var dot = document.createElement("span");
      dot.className = "slack-presence-dot" + (peerUp ? " is-online" : "");
      dot.title = peerUp ? "Online" : "Offline";
      dot.setAttribute("role", "img");
      dot.setAttribute("aria-label", peerUp ? "Online" : "Offline");
      iconEl.appendChild(dot);
    } else {
      iconEl.textContent = icon;
    }
    row.appendChild(iconEl);
    var name = document.createElement("span");
    name.className = "slack-room-name";
    name.textContent = chatRoomLabel(r).replace(/^[#@]/, "");
    row.appendChild(name);
    /* Unread indicator: bold name + dot when room has unread messages */
    var hasUnread = _roomHasUnread(r) && el.chatRoom.value !== r.room;
    if (hasUnread) {
      row.classList.add("has-unread");
      var unreadDot = document.createElement("span");
      unreadDot.className = "slack-room-item-count";
      unreadDot.textContent = "•";
      unreadDot.title = "New messages";
      row.appendChild(unreadDot);
    } else if (r.messages) {
      var badge = document.createElement("span");
      badge.className = "slack-room-badge";
      badge.textContent = String(r.messages);
      row.appendChild(badge);
    }
    row.addEventListener("click", function () {
      if (el.chatRoom.value === r.room) return;
      el.chatRoom.value = r.room;
      _markRoomRead(r.room);
      openChatRoom(r.room);
    });
    container.appendChild(row);
  });
}

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
  uiAdd(el.chatRoom, [["Rooms", shared], ["Direct", dms]]
    .filter(function (pair) { return pair[1].length; })
    .map(function (pair) {
      return T.optgroup({ label: pair[0] }, pair[1].map(function (r) {
        var label = chatRoomLabel(r);
        if (r.messages) label += "  ·  " + r.messages;
        var peerUp = knownPeers.some(function(p){ return p.name === r.room || p.name === dmPartner(r.room); });
        if (r.unread) label += " · " + r.unread + " new";
        else if (r.room.indexOf("dm:") === 0) {
          var partner = dmPartner(r.room);
          var seen = (typeof lastSeenAt !== "undefined" && lastSeenAt[partner]) ? lastSeenAt[partner] : 0;
          if (peerUp) label += " · online";
          else if (seen) {
            var mins = Math.floor((Date.now()/1000 - seen)/60);
            label += " · " + (mins < 1 ? "just now" : mins < 60 ? mins + "m ago" : Math.floor(mins/60) + "h ago");
          } else if (r.room.indexOf("dm:") === 0) label += " · offline";
        }
        return T.option({ value: r.room }, label);
      }));
    }));
  renderChatSidebarList(el.chatRoomsItems, shared, "#");
  renderChatSidebarList(el.chatDmsItems, dms, "@");

  var options = el.chatRoom.querySelectorAll("option");
  var empty = options.length === 0;
  el.chatRoom.disabled = empty;
  el.chatText.disabled = empty;
  el.chatSend.disabled = empty;
  if (empty) {
    el.chatStatus.textContent = "No rooms yet. Add [chat.rooms] in config.toml or use --serve-as to peer.";
    showRoomsComposerLocked("No channels yet. Create one to start talking, or add rooms in config.toml.", true);
    return null;
  }
  var wanted = Array.prototype.some.call(options, function (o) { return o.value === previous; })
    ? previous : options[0].value;
  el.chatRoom.value = wanted;
  return wanted;
}

var roomTopics = {};
function loadChatRooms() {
  if (el.chatRoomsItems && !el.chatRoomsItems.querySelector(".slack-room-item")) {
    el.chatRoomsItems.textContent = "";
    var loading = document.createElement("p");
    loading.className = "meta slack-room-loading";
    loading.textContent = "Loading channels…";
    el.chatRoomsItems.appendChild(loading);
  }
  if (el.chatStatus) el.chatStatus.textContent = "Loading channels…";
  return fetch("/api/chat/rooms")
    .then(readJson)
    .then(function (data) {
      subscribedRooms = data.subscribed || [];
      // Store topics
      (data.rooms || []).forEach(function(r){ if(r.topic) roomTopics[r.room]=r.topic; });
      var wanted = renderChatRooms(data.rooms || []);
      if (wanted) return openChatRoom(wanted);
    })
    .catch(function (err) {
      el.chatRoom.disabled = true;
      el.chatText.disabled = true;
      el.chatSend.disabled = true;
      el.chatStatus.textContent = "Could not load rooms: " + err.message;
      showRoomsComposerLocked("Could not load rooms: " + err.message, false);
    });
}

function showRoomsComposerLocked(message, offerCreate) {
  if (el.chatChannelTitle) el.chatChannelTitle.textContent = "No channels";
  if (el.chatChannelTopic) {
    el.chatChannelTopic.textContent = "";
    el.chatChannelTopic.classList.remove("is-placeholder");
    el.chatChannelTopic.onclick = null;
  }
  if (el.chatText) el.chatText.placeholder = "Create a channel to send a message";
  if (!el.chatLog) return;
  el.chatLog.textContent = "";
  var box = document.createElement("div");
  box.className = "run-empty";
  var p = document.createElement("p");
  p.textContent = message;
  box.appendChild(p);
  if (offerCreate && el.chatCreateRoomBtn) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "secondary";
    btn.textContent = "Create a channel";
    btn.addEventListener("click", function () { el.chatCreateRoomBtn.click(); });
    box.appendChild(btn);
  }
  el.chatLog.appendChild(box);
}

var _chatUnreadCutoff = 0;   /* ts before which msgs are "read" (for divider) */
function openChatRoom(room) {
  stopChatPoll();
  _chatUnreadCutoff = _chatReadTimestamps[room] || 0;
  _markRoomRead(room);
  el.chatLog.textContent = "";
  chatLastTs = 0;
  chatSeen = {};
  chatSeenOrder = [];
  // An emptied log starts grouping over, day separator included.
  _lastChatFrom = null; _lastChatTs = 0; _lastChatDay = "";
  chatBackoff = chat_poll_base_ms;
  el.chatText.disabled = false;
  el.chatSend.disabled = false;
  el.chatText.placeholder = isDm(room) ? "Message " + dmPartner(room) + "…" : "Message " + room + "…";
  // Channel header: title + topic (click to set/change). DMs get no topic —
  // it is a per-channel concept, and a DM has nothing to name.
  if (el.chatChannelTitle) el.chatChannelTitle.textContent = isDm(room) ? "@" + dmPartner(room) : "#" + room;
  if (el.chatChannelTopic) {
    // An empty topic still needs something on screen to click, or a topic
    // could never be set the first time.
    el.chatChannelTopic.textContent = roomTopics[room] || (isDm(room) ? "" : "Add a topic");
    el.chatChannelTopic.classList.toggle("is-placeholder", !roomTopics[room] && !isDm(room));
    el.chatChannelTopic.onclick = isDm(room) ? null : function () {
      uiPrompt("Set channel topic for #" + room, roomTopics[room] || "", { maxlength: 1024 }).then(function (newTopic) {
        if (newTopic === null) return;
        fetch("/api/chat/topic", { method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ room: room, topic: newTopic })
        }).then(function (r) { return r.json(); }).then(function (d) {
          if (d.ok) {
            roomTopics[room] = newTopic;
            el.chatChannelTopic.textContent = newTopic || "Add a topic";
            el.chatChannelTopic.classList.toggle("is-placeholder", !newTopic);
          }
        }).catch(function () {});
      });
    };
  }
  // Active-room highlight in the sidebar.
  [el.chatRoomsItems, el.chatDmsItems].forEach(function (list) {
    if (!list) return;
    Array.prototype.forEach.call(list.querySelectorAll(".slack-room-item"), function (row) {
      row.classList.toggle("is-active", row.dataset.room === room);
    });
  });
  // A room switch invalidates whatever the pins/search panels were showing.
  if (el.chatPinsPanel && !el.chatPinsPanel.hidden) loadChatPins(room);
  if (el.chatSearchBar && !el.chatSearchBar.hidden) el.chatSearchResults.textContent = "";
  // History must not dump into a live region. Announce only arrivals after
  // the backlog is on screen, and only through #chat-status.
  _chatAnnounce = false;
  return joinIfNeeded(room)
    .then(function () { return pollChat(room); })
    .then(function () {
      _chatAnnounce = true;
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
var lastSeenAt = {};
var _chatAnnounce = false;
function announceChatArrival(fresh) {
  if (!_chatAnnounce || !fresh || !fresh.length || !el.chatStatus) return;
  var last = fresh[fresh.length - 1];
  var who = last.from || "someone";
  var text = String(last.text || "").replace(/\s+/g, " ").trim();
  el.chatStatus.textContent = who + (text ? ": " + text.slice(0, 80) : " sent a message");
}
function ingestChatMessages(messages) {
  var fresh = (messages || []).filter(function (m) { return m && !chatSeen[chatMessageKey(m)]; }).sort(function (a, b) { return (a.ts || 0) - (b.ts || 0); });
  if (!el.chatLog) return;
  var following = el.chatLog.scrollHeight - el.chatLog.scrollTop - el.chatLog.clientHeight < 40;
  if (fresh.length) { _lastChatFrom = null; _lastChatTs = 0; }
  var placed = false;
  fresh.forEach(function (m) {
    rememberChatId(chatMessageKey(m));
    if (m.ts > chatLastTs) chatLastTs = m.ts;
    lastSeenAt[m.from] = m.ts;
    if (!placed && _chatUnreadCutoff > 0 && m.ts > _chatUnreadCutoff) {
      placed = true;
      var divider = document.createElement("div");
      divider.className = "chat-unread-divider";
      divider.setAttribute("role", "separator");
      divider.setAttribute("aria-label", "New messages");
      divider.innerHTML = "<span>New messages</span>";
      el.chatLog.appendChild(divider);
    }
    var node = buildChatMessage(m);
    if (node._daySep) el.chatLog.appendChild(node._daySep);
    el.chatLog.appendChild(node);
  });
  _chatUnreadCutoff = 0;
  announceChatArrival(fresh);
  if (fresh.length && following) el.chatLog.scrollTop = el.chatLog.scrollHeight;
}
function pollChat(room) {
  return fetch("/api/chat/messages?room=" + encodeURIComponent(room) + "&after=" + chatLastTs)
    .then(readJson)
    .then(function (data) {
      chatBackoff = chat_poll_base_ms;
      if (chatFailing) {
        chatFailing = false;
        el.chatStatus.textContent = "Reconnected.";
      }
      // Keyed on messageKey rather than m.id: an id-less message (a peer too
      // old to send one — chatrooms.zig defaults the field to "" and accepts
      // it) otherwise registered "" as seen, and every later id-less message
      // was discarded as a duplicate of it.
      var fresh = (data.messages || [])
        .filter(function (m) { return !chatSeen[chatMessageKey(m)]; })
        .sort(function (a, b) { return a.ts - b.ts; });
      var following = el.chatLog.scrollHeight - el.chatLog.scrollTop - el.chatLog.clientHeight < 40;
      // Only sender grouping resets across batches; the day key must persist
      // or every poll batch would open with a repeat of the same date banner.
      if (fresh.length) { _lastChatFrom = null; _lastChatTs = 0; }
      var _unreadDividerPlaced = false;
      fresh.forEach(function (m) {
        rememberChatId(chatMessageKey(m));
        if (m.ts > chatLastTs) chatLastTs = m.ts;
        lastSeenAt[m.from] = m.ts;
        /* Slack-style "New messages" divider: shown once, before the first
           message whose ts exceeds the cutoff captured when the room opened. */
        if (!_unreadDividerPlaced && _chatUnreadCutoff > 0 && m.ts > _chatUnreadCutoff) {
          _unreadDividerPlaced = true;
          var divider = document.createElement("div");
          divider.className = "chat-unread-divider";
          divider.setAttribute("role", "separator");
          divider.setAttribute("aria-label", "New messages");
          divider.innerHTML = "<span>New messages</span>";
          el.chatLog.appendChild(divider);
        }
        var node = buildChatMessage(m);
        if (node._daySep) el.chatLog.appendChild(node._daySep);
        el.chatLog.appendChild(node);
      });
      /* Consumed — subsequent poll batches should not re-insert the divider */
      _chatUnreadCutoff = 0;
      // presence dot freshness handled via CSS only — timestamps already in lastSeenAt for future use
      announceChatArrival(fresh);
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



/* ── Slack-style message formatting ──────────────────────────────────
   Converts Slack-style markup to DOM nodes:
   ```code blocks```, `inline code`, *bold*, _italic_, ~strike~,
   > blockquotes, :emoji_shortcodes:, and auto-links.
   All output is XSS-safe (no innerHTML, only textContent + classList). */
var _emojiShortcodes = {
  ":thumbsup:":"👍",":thumbsdown:":"👎",":heart:":"❤️",":fire:":"🔥",
  ":eyes:":"👀",":rocket:":"🚀",":check:":"✅",":white_check_mark:":"✅",
  ":x:":"❌",":warning:":"⚠️",":bug:":"🐛",":tada:":"🎉",":sparkles:":"✨",
  ":star:":"⭐",":wave:":"👋",":thinking:":"🤔",":laugh:":"😂",":cry:":"😢",
  ":angry:":"😡",":sweat:":"😅",":100:":"💯",":clap:":"👏",":pray:":"🙏",
  ":muscle:":"💪",":bulb:":"💡",":wrench:":"🔧",":hammer:":"🔨",
  ":gear:":"⚙️",":lock:":"🔒",":key:":"🔑",":link:":"🔗",":zap:":"⚡",
  ":hourglass:":"⏳",":calendar:":"📅",":memo:":"📝",":package:":"📦",
  ":bell:":"🔔",":mute:":"🔇",":speaker:":"🔊",":mic:":"🎤",
  ":camera:":"📷",":film:":"🎬",":art:":"🎨",":trophy:":"🏆",
  ":medal:":"🏅",":crown:":"👑",":gem:":"💎",":money:":"💰",
  ":chart:":"📈",":chart_down:":"📉",":inbox:":"📥",":outbox:":"📤",
  ":mailbox:":"📬",":paperclip:":"📎",":scissors:":"✂️",":pin:":"📌",
  ":pushpin:":"📌",":bookmark:":"🔖",":label:":"🏷️",":flag:":"🚩",
  ":construction:":"🚧",":recycle:":"♻️",":heavy_plus_sign:":"+",
  ":heavy_minus_sign:":"−",":question:":"❓",":exclamation:":"❗",
  ":ok:":"🆗",":new:":"🆕",":up:":"🆙",":cool:":"🆒",":free:":"🆓",
  ":1:":"1️⃣",":2:":"2️⃣",":3:":"3️⃣",":4:":"4️⃣",":5:":"5️⃣",
  ":arrow_right:":"➡️",":arrow_left:":"⬅️",":arrow_up:":"⬆️",":arrow_down:":"⬇️",
  ":smile:":"😊",":grin:":"😀",":wink:":"😉",":sunglasses:":"😎",
  ":nerd:":"🤓",":robot:":"🤖",":alien:":"👽",":ghost:":"👻",
  ":skull:":"💀",":poop:":"💩",":cat:":"🐱",":dog:":"🐶",
  "+1":"👍","-1":"👎",":ship:":"🚢",":airplane:":"✈️",":car:":"🚗"
};
function formatChatText(raw) {
  var frag = document.createDocumentFragment();
  if (!raw) return frag;

  /* --- Code blocks: ```...``` (must come first, greedy) --- */
  var codeBlockRe = /```([\s\S]*?)```/g;
  var parts = [];
  var lastIdx = 0;
  var cbMatch;
  while ((cbMatch = codeBlockRe.exec(raw)) !== null) {
    if (cbMatch.index > lastIdx) parts.push({ type: "text", val: raw.slice(lastIdx, cbMatch.index) });
    parts.push({ type: "codeblock", val: cbMatch[1] });
    lastIdx = codeBlockRe.lastIndex;
  }
  if (lastIdx < raw.length) parts.push({ type: "text", val: raw.slice(lastIdx) });

  parts.forEach(function(part) {
    if (part.type === "codeblock") {
      var pre = document.createElement("span");
      pre.className = "fmt-codeblock";
      pre.textContent = part.val;
      frag.appendChild(pre);
      return;
    }
    /* --- Blockquotes: lines starting with > --- */
    var lines = part.val.split("\n");
    var i = 0;
    while (i < lines.length) {
      if (/^>\s?/.test(lines[i])) {
        var bq = document.createElement("span");
        bq.className = "fmt-blockquote";
        var bqLines = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) {
          bqLines.push(lines[i].replace(/^>\s?/, ""));
          i++;
        }
        bq.appendChild(_formatInline(bqLines.join("\n")));
        frag.appendChild(bq);
      } else {
        if (i > 0) frag.appendChild(document.createTextNode("\n"));
        frag.appendChild(_formatInline(lines[i]));
        i++;
      }
    }
  });
  return frag;
}
function _formatInline(line) {
  var frag = document.createDocumentFragment();
  /* Inline formatting: `code`, *bold*, _italic_, ~strike~, :emoji:, URLs */
  var re = /(`[^`]+`)|(\*[^\s*][^*]*[^\s*]\*|\*[^\s*]\*)|(_[^\s_][^_]*[^\s_]_|_[^\s_]_)|(~[^\s~][^~]*[^\s~]~|~[^\s~]~)|(:[a-z0-9_+-]+:)|(https?:\/\/[^\s<]+)/g;
  var last = 0;
  var match;
  while ((match = re.exec(line)) !== null) {
    if (match.index > last) {
      frag.appendChild(document.createTextNode(line.slice(last, match.index)));
    }
    if (match[1]) {
      /* inline code */
      var code = document.createElement("span");
      code.className = "fmt-code";
      code.textContent = match[1].slice(1, -1);
      frag.appendChild(code);
    } else if (match[2]) {
      /* bold */
      var b = document.createElement("span");
      b.className = "fmt-bold";
      b.textContent = match[2].slice(1, -1);
      frag.appendChild(b);
    } else if (match[3]) {
      /* italic */
      var em = document.createElement("span");
      em.className = "fmt-italic";
      em.textContent = match[3].slice(1, -1);
      frag.appendChild(em);
    } else if (match[4]) {
      /* strikethrough */
      var s = document.createElement("span");
      s.className = "fmt-strike";
      s.textContent = match[4].slice(1, -1);
      frag.appendChild(s);
    } else if (match[5]) {
      /* emoji shortcode */
      var emoji = _emojiShortcodes[match[5]];
      if (emoji) {
        frag.appendChild(document.createTextNode(emoji));
      } else {
        frag.appendChild(document.createTextNode(match[5]));
      }
    } else if (match[6]) {
      /* URL auto-link */
      var a = document.createElement("a");
      a.href = match[6]; a.target = "_blank"; a.rel = "noopener noreferrer";
      a.textContent = match[6];
      a.style.color = "var(--accent)";
      frag.appendChild(a);
    }
    last = re.lastIndex;
  }
  if (last < line.length) {
    frag.appendChild(document.createTextNode(line.slice(last)));
  }
  return frag;
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
  if (m.id) wrap.dataset.msgId = m.id;
  /* Every action that names a message to the server — react, pin, edit,
     delete — matches on the id, and an id-less message would send "", which
     the server resolves to whichever id-less message it holds first. Acting on
     a message that is not the one clicked is worse than not offering the
     action, so the ones that need an id are left out. Copy is client-side and
     stays. */
  var canAct = chatHasServerId(m);

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
  // Hue per name so different clankers read as different people at a
  // glance. The hue values live in CSS as --chat-hue-N (with dark-theme
  // overrides); data-color only picks which one, so themes stay in charge
  // of legibility.
  from.setAttribute("data-color", String((function(h){ var v=0; for(var i=0;i<m.from.length;i++) v=(v*31 + m.from.charCodeAt(i))>>>0; return v%8; })(m.from)));
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
  // Deleted messages
  if (m.deleted) {
    text.classList.add("chat-deleted");
    text.textContent = "[This message was deleted]";
    wrap.appendChild(text);
    wrap.setAttribute("data-deleted", "true");
    _lastChatFrom = m.from;
    _lastChatTs = m.ts;
    return wrap;
  }
  var said = boardActionLine(m.text);
  if (said) {
    text.classList.add("chat-action");
    text.textContent = said;
  } else {
    // Slack-style unfurl: bare URL preview affordance (no fetch, just link styling already does it,
    // but we add a subtle link card when the message is exactly a URL)
    var trimmed = m.text.trim();
    var isBareUrl = /^https?:\/\/\S+$/.test(trimmed);
    text.appendChild(formatChatText(m.text));
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
  // Edited indicator
  if (m.edited) {
    var edited = document.createElement("span");
    edited.className = "chat-edited";
    edited.textContent = " (edited)";
    edited.title = "Edited";
    text.appendChild(edited);
  }
  wrap.appendChild(text);
  if (wrap._unfurl) wrap.appendChild(wrap._unfurl);
  // ---- server-side reactions (aggregated from m.reactions array) ----
  // m.reactions is [{emoji,from}, ...] — group into {emoji: [from1, ...]}
  var reacts = {};
  if (m.reactions && m.reactions.length) {
    m.reactions.forEach(function(r){ reacts[r.emoji] = reacts[r.emoji] || []; reacts[r.emoji].push(r.from); });
  }
  var reactionsBar = document.createElement("div"); reactionsBar.className = "chat-reactions";
  var EMOJIS = ["👍","❤️","🎉","🔥","👀","✅"];
  function renderReacts(){
    reactionsBar.textContent="";
    Object.keys(reacts).forEach(function(emoji){
      var cnt = reacts[emoji].length;
      if(!cnt) return;
      var pill = document.createElement("button"); pill.type="button"; pill.className="chat-reaction";
      pill.textContent = emoji + " " + cnt; pill.title = reacts[emoji].join(", ");
      var mine = reacts[emoji].indexOf(instanceName)!==-1; pill.setAttribute("data-mine", String(mine));
      pill.addEventListener("click", function(e){ e.stopPropagation(); toggleReact(emoji); });
      reactionsBar.appendChild(pill);
    });
  }
  function toggleReact(emoji){
    // Call the server-side react endpoint
    if (!canAct) return;
    fetch("/api/chat/react", { method: "POST", headers: {"Content-Type":"application/json"},
      body: JSON.stringify({ room: el.chatRoom.value, msg_id: m.id, emoji: emoji })
    }).then(function(r){ return r.json(); }).then(function(d){
      if(d.ok){
        // Optimistic update
        reacts[emoji] = reacts[emoji] || [];
        var at = reacts[emoji].indexOf(instanceName);
        if(d.added) { if(at===-1) reacts[emoji].push(instanceName); }
        else { if(at!==-1) reacts[emoji].splice(at,1); if(!reacts[emoji].length) delete reacts[emoji]; }
        renderReacts();
      }
    }).catch(function(){});
  }
  renderReacts();
  wrap.appendChild(reactionsBar);
  // ---- threads (Slack-style, local grouping by replyTo) ----
  var threadStore = (function(){ try{ return JSON.parse(localStorage.getItem("clanker.threads")||"{}"); }catch(_){ return {}; }})();
  function saveThreads(){ try{ localStorage.setItem("clanker.threads", JSON.stringify(threadStore)); }catch(_){} }
  var threadKey = chatMessageKey(m);
  var replies = threadStore[threadKey] || [];
  var threadBar = document.createElement("div"); threadBar.className = "chat-thread-bar";
  var threadCount = document.createElement("button"); threadCount.type="button"; threadCount.className="secondary"; upgradePfButton(threadCount);
  function renderThreadBar(){
    if(!replies.length){ threadBar.hidden=true; return; }
    threadBar.hidden=false;
    threadCount.textContent = "↳ " + replies.length + (replies.length===1?" reply":" replies");
    upgradePfButton(threadCount);
    threadBar.title = replies.slice(-2).map(function(r){return r.from+": "+r.text;}).join("\n");
  }
  threadBar.appendChild(threadCount);
  var threadList = document.createElement("div"); threadList.className="chat-thread-list"; threadList.hidden=true;
  function renderThreads(){
    threadList.textContent="";
    replies.forEach(function(r){
      var row=document.createElement("div"); row.className="chat-thread-reply";
      row.textContent=r.from+": "+r.text; threadList.appendChild(row);
    });
    renderThreadBar();
  }
  threadCount.addEventListener("click", function(e){ e.stopPropagation(); threadList.hidden=!threadList.hidden; });
  threadBar.appendChild(threadList);
  var replyBtn = document.createElement("button"); replyBtn.type="button"; replyBtn.className="secondary"; replyBtn.textContent="Reply"; upgradePfButton(replyBtn);
  replyBtn.addEventListener("click", function(e){
    e.stopPropagation();
    uiPrompt("Reply in thread", "", { confirmLabel: "Reply", maxlength: 4096 }).then(function (t) {
      if(!t||!t.trim()) return;
      replies.push({from: instanceName, text: t.trim(), ts: Math.floor(Date.now()/1000)});
      threadStore[threadKey]=replies; saveThreads(); renderThreads(); threadList.hidden=false;
    });
  });
  threadBar.appendChild(replyBtn);
  renderThreads();
  wrap.appendChild(threadBar);
  // Slack-like quick actions (copy / emoji), revealed on hover and
  // :focus-within, and exposed to AT, so they are reachable by keyboard too.
  var actions = document.createElement("div");
  actions.className = "chat-actions";
  var copyBtn = document.createElement("button");
  copyBtn.type = "button"; copyBtn.className = "secondary"; copyBtn.textContent = "Copy"; upgradePfButton(copyBtn);
  copyBtn.setAttribute("aria-label", "Copy message");
  copyBtn.addEventListener("click", function(e){ e.stopPropagation(); try{ navigator.clipboard.writeText(m.text); }catch(_){} });
  actions.appendChild(copyBtn);
  if (canAct) EMOJIS.forEach(function(emoji){
    var b=document.createElement("button"); b.type="button"; b.className="secondary"; b.textContent=emoji; upgradePfButton(b); b.title="React "+emoji;
    b.setAttribute("aria-label", "React " + emoji);
    b.addEventListener("click", function(e){ e.stopPropagation(); toggleReact(emoji); });
    actions.appendChild(b);
  });
  // Pin button
  if (canAct) {
    var pinBtn = document.createElement("button");
    pinBtn.type = "button"; pinBtn.className = "secondary"; pinBtn.title = "Pin/Unpin";
    pinBtn.setAttribute("aria-label", "Pin message");
    pinBtn.appendChild(icon("pin", 14));
    upgradePfButton(pinBtn);
    pinBtn.addEventListener("click", function(e){ e.stopPropagation();
      fetch("/api/chat/pin", { method: "POST", headers: {"Content-Type":"application/json"},
        body: JSON.stringify({ room: el.chatRoom.value, msg_id: m.id })
      }).then(function(r){ return r.json(); }).then(function(d){
        if(d.ok) pollChat(el.chatRoom.value);
      }).catch(function(){});
    });
    actions.appendChild(pinBtn);
  }
  // Edit + Delete only for own messages
  if (m.from === instanceName && canAct) {
    var editBtn = document.createElement("button");
    editBtn.type = "button"; editBtn.className = "secondary"; editBtn.textContent = "✏️"; upgradePfButton(editBtn); editBtn.title = "Edit message";
    editBtn.setAttribute("aria-label", "Edit message");
    editBtn.addEventListener("click", function(e){ e.stopPropagation();
      var cur = text.childNodes[0] ? text.childNodes[0].textContent || text.textContent : m.text;
      var inp = document.createElement("input"); inp.type="text"; inp.className="chat-edit-input"; inp.value=cur;
      text.textContent = ""; text.appendChild(inp); inp.focus();
      function finishEdit(){
        var v = inp.value.trim();
        if(v && v !== m.text){
          fetch("/api/chat/edit", { method: "POST", headers: {"Content-Type":"application/json"},
            body: JSON.stringify({ room: el.chatRoom.value, msg_id: m.id, text: v })
          }).then(function(r){ return r.json(); }).then(function(d){
            if(d.ok){ m.text = v; m.edited = true; text.textContent = v;
              var ed = document.createElement("span"); ed.className="chat-edited"; ed.textContent=" (edited)"; text.appendChild(ed);
            } else { text.textContent = m.text; }
          }).catch(function(){ text.textContent = m.text; });
        } else { text.textContent = m.text; if(m.edited){
          var ed2 = document.createElement("span"); ed2.className="chat-edited"; ed2.textContent=" (edited)"; text.appendChild(ed2); }}
      }
      inp.addEventListener("keydown", function(ev){ if(ev.key==="Enter"){ ev.preventDefault(); finishEdit(); } if(ev.key==="Escape"){ text.textContent=m.text; if(m.edited){
        var ed3=document.createElement("span"); ed3.className="chat-edited"; ed3.textContent=" (edited)"; text.appendChild(ed3); }} });
      inp.addEventListener("blur", finishEdit);
    });
    actions.appendChild(editBtn);
    var delBtn = document.createElement("button");
    delBtn.type = "button"; delBtn.className = "secondary"; delBtn.textContent = "🗑️"; upgradePfButton(delBtn); delBtn.title = "Delete message";
    delBtn.setAttribute("aria-label", "Delete message");
    delBtn.addEventListener("click", function(e){ e.stopPropagation();
      uiConfirm("Delete this message?", { danger: true, confirmLabel: "Delete" }).then(function (yes) {
        if(!yes) return;
        fetch("/api/chat/delete", { method: "POST", headers: {"Content-Type":"application/json"},
          body: JSON.stringify({ room: el.chatRoom.value, msg_id: m.id })
        }).then(function(r){ return r.json(); }).then(function(d){
          if(d.ok) { wrap.classList.add("chat-msg-deleted"); text.textContent = "[This message was deleted]"; text.classList.add("chat-deleted"); }
        }).catch(function(){});
      });
    });
    actions.appendChild(delBtn);
  }
  wrap.appendChild(actions);
  // update grouping state for next message
  _lastChatFrom = m.from;
  _lastChatTs = m.ts;
  return wrap;
}

var boardActionLine = boardActionLineMod;

var formatChatTime = utilFormatChatTime;

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
  var delay = liveIsUp() ? chat_poll_max_ms : chatBackoff;
  chatPoll = window.setTimeout(function () {
    pollChat(room).finally(function () {
      if (chatPoll !== null) startChatPoll(room);
    });
  }, delay);
}

function stopChatPoll() {
  if (chatPoll) { window.clearTimeout(chatPoll); chatPoll = null; }
}

/* Hiding the tab stops every standing timer, and showing it starts back only
   what the view on screen actually wants.
 *
 * This handler predates the view-aware stops in showView and never learned
 * about them. It restarted the rooms poll on `el.chatRoom.value` alone, which
 * survives leaving Rooms, so: open Rooms, switch to Board (showView stops the
 * poll), switch browser tabs away and back, and the poll restarts while Board
 * is showing. Nothing then stops it, because showView only stops it on the way
 * *out* of Rooms and Rooms is not where you are. That is a permanent
 * background fetch of a chat log nobody is looking at, which is the same thing
 * the comment in showView calls out as not allowed.
 *
 * The arena had the opposite half missing: its poll and animation loop are
 * stopped when you navigate away, but nothing stopped them when the tab itself
 * went away, so a hidden tab kept polling a running match. */
document.addEventListener("visibilitychange", function () {
  if (document.hidden) {
    stopChatPoll();
    if (arenaModulePromise) arenaModulePromise.then(function (arena) { arena.stopArena(); });
    return;
  }
  if (currentView === "rooms" && el.chatRoom.value) startChatPoll(el.chatRoom.value);
  if (currentView === "arena" && arenaModulePromise) {
    arenaModulePromise.then(function (arena) { arena.loadArenaView(); });
  }
});

liveOn(function (ev) {
  if (!ev || ev.t !== "chat") return;
  if (!el.chatRoom || ev.room !== el.chatRoom.value) return;
  ingestChatMessages([ev]);
});
el.chatRoom.addEventListener("change", function () {
  openChatRoom(el.chatRoom.value);
});

el.chatRefresh.addEventListener("click", function () {
  el.chatRefresh.disabled = true;
  loadChatRooms().finally(function () { el.chatRefresh.disabled = false; });
});

// ---- Slack-layout chrome: sidebar collapse, channel filter, pins, search,
//      emoji picker, create-channel. All thin wrappers over state and
//      endpoints the message-level code above already uses. ----

if (el.chatSidebarToggle) el.chatSidebarToggle.addEventListener("click", function () {
  el.chatSidebar.classList.toggle("is-collapsed");
});

// Group headers (Channels / Direct Messages) fold their own items away —
// .slack-room-group.is-collapsed hides .slack-room-items via CSS.
Array.prototype.forEach.call(document.querySelectorAll(".slack-room-group-head"), function (head) {
  head.addEventListener("click", function () {
    var group = head.closest(".slack-room-group");
    if (group) group.classList.toggle("is-collapsed");
  });
});

if (el.chatRoomFilter) el.chatRoomFilter.addEventListener("input", function () {
  var q = el.chatRoomFilter.value.trim().toLowerCase();
  [el.chatRoomsItems, el.chatDmsItems].forEach(function (list) {
    if (!list) return;
    Array.prototype.forEach.call(list.querySelectorAll(".slack-room-item"), function (row) {
      row.hidden = q.length > 0 && row.textContent.toLowerCase().indexOf(q) === -1;
    });
  });
});

function closeChatPins() { if (el.chatPinsPanel) el.chatPinsPanel.hidden = true; }
function loadChatPins(room) {
  if (!el.chatPinsList) return;
  el.chatPinsList.textContent = "Loading…";
  fetch("/api/chat/pins?room=" + encodeURIComponent(room))
    .then(readJson)
    .then(function (data) {
      var ids = data.pins || [];
      el.chatPinsList.textContent = "";
      if (!ids.length) {
        var empty = document.createElement("p");
        empty.style.color = "var(--fg-muted)";
        empty.textContent = "No pinned messages in this channel.";
        el.chatPinsList.appendChild(empty);
        return;
      }
      // Pins are ids; resolve against the currently loaded log first (cheap,
      // covers the common case), falling back to a history fetch for ids
      // that scrolled out of what is currently rendered.
      var have = {};
      ids.forEach(function (id) {
        var node = el.chatLog.querySelector('[data-msg-id="' + CSS.escape(id) + '"]');
        if (node) have[id] = node;
      });
      var missing = ids.filter(function (id) { return !have[id]; });
      (missing.length ? fetch("/api/chat/messages?room=" + encodeURIComponent(room) + "&after=0").then(readJson) : Promise.resolve({ messages: [] }))
        .then(function (hist) {
          var byId = {};
          (hist.messages || []).forEach(function (m) { byId[m.id] = m; });
          ids.forEach(function (id) {
            var node = have[id];
            var m = byId[id];
            var sender = node ? node.querySelector(".chat-from").textContent : m ? m.from : "";
            var text = node ? node.querySelector(".chat-text").textContent : m ? m.text : id;
            var row = document.createElement("div");
            row.className = "slack-pin-item";
            row.setAttribute("role", "button");
            row.tabIndex = 0;
            var senderEl = document.createElement("span");
            senderEl.className = "slack-pin-sender";
            senderEl.textContent = sender;
            row.appendChild(senderEl);
            var textEl = document.createElement("span");
            textEl.className = "slack-pin-text";
            textEl.textContent = text;
            row.appendChild(textEl);
            function jump() {
              closeChatPins();
              var target = el.chatLog.querySelector('[data-msg-id="' + CSS.escape(id) + '"]');
              if (target) { target.scrollIntoView({ block: "center" }); target.classList.add("chat-highlight"); setTimeout(function () { target.classList.remove("chat-highlight"); }, 1500); }
            }
            row.addEventListener("click", jump);
            row.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); jump(); } });
            el.chatPinsList.appendChild(row);
          });
        });
    })
    .catch(function () { el.chatPinsList.textContent = "Could not load pins."; });
}
if (el.chatPinToggle) el.chatPinToggle.addEventListener("click", function () {
  var open = el.chatPinsPanel.hidden;
  el.chatPinsPanel.hidden = !open;
  if (open && el.chatRoom.value) loadChatPins(el.chatRoom.value);
});
if (el.chatPinsClose) el.chatPinsClose.addEventListener("click", closeChatPins);

function closeChatSearch() { if (el.chatSearchBar) { el.chatSearchBar.hidden = true; el.chatSearchResults.textContent = ""; el.chatSearchInput.value = ""; } }
if (el.chatSearchToggle) el.chatSearchToggle.addEventListener("click", function () {
  var open = el.chatSearchBar.hidden;
  el.chatSearchBar.hidden = !open;
  if (open) el.chatSearchInput.focus();
  else closeChatSearch();
});
if (el.chatSearchClose) el.chatSearchClose.addEventListener("click", closeChatSearch);
var chatSearchTimer = null;
if (el.chatSearchInput) el.chatSearchInput.addEventListener("input", function () {
  if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
  var q = el.chatSearchInput.value.trim();
  var room = el.chatRoom.value;
  if (!q || !room) { el.chatSearchResults.textContent = ""; return; }
  chatSearchTimer = window.setTimeout(function () {
    fetch("/api/chat/messages?room=" + encodeURIComponent(room) + "&after=0")
      .then(readJson)
      .then(function (data) {
        var ql = q.toLowerCase();
        var hits = (data.messages || []).filter(function (m) { return !m.deleted && m.text && m.text.toLowerCase().indexOf(ql) !== -1; }).slice(0, 30);
        el.chatSearchResults.textContent = "";
        if (!hits.length) {
          var empty = document.createElement("p");
          empty.textContent = "No matches.";
          el.chatSearchResults.appendChild(empty);
          return;
        }
        hits.forEach(function (m) {
          var row = document.createElement("button");
          row.type = "button";
          row.className = "slack-search-result";
          row.textContent = m.from + ": " + m.text;
          row.addEventListener("click", function () {
            closeChatSearch();
            var target = el.chatLog.querySelector('[data-msg-id="' + CSS.escape(m.id) + '"]');
            if (target) { target.scrollIntoView({ block: "center" }); target.classList.add("chat-highlight"); setTimeout(function () { target.classList.remove("chat-highlight"); }, 1500); }
          });
          el.chatSearchResults.appendChild(row);
        });
      })
      .catch(function () { el.chatSearchResults.textContent = "Search failed."; });
  }, 200);
});

var CHAT_EMOJI_PICKER_SET = ["👍","❤️","🎉","🔥","👀","✅","😀","😂","😅","😊","🙌","🙏","👏","💯","🚀","⚠️","❌","🤔","😢","👋","🎯","💡","✨","🐛"];
if (el.chatEmojiBtn && el.chatEmojiPicker) {
  if (!el.chatEmojiBtn.querySelector("svg")) uiAdd(el.chatEmojiBtn, icon("smile", 16));
  el.chatEmojiBtn.addEventListener("click", function () {
    if (!el.chatEmojiPicker.hidden) { el.chatEmojiPicker.hidden = true; return; }
    el.chatEmojiPicker.textContent = "";
    CHAT_EMOJI_PICKER_SET.forEach(function (emoji) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "slack-emoji-option";
      b.textContent = emoji;
      b.addEventListener("click", function () {
        var start = el.chatText.selectionStart || el.chatText.value.length;
        var end = el.chatText.selectionEnd || el.chatText.value.length;
        el.chatText.value = el.chatText.value.slice(0, start) + emoji + el.chatText.value.slice(end);
        el.chatText.focus();
        el.chatText.selectionStart = el.chatText.selectionEnd = start + emoji.length;
        el.chatEmojiPicker.hidden = true;
      });
      el.chatEmojiPicker.appendChild(b);
    });
    el.chatEmojiPicker.hidden = false;
  });
  document.addEventListener("click", function (e) {
    if (el.chatEmojiPicker.hidden) return;
    if (e.target === el.chatEmojiBtn || el.chatEmojiPicker.contains(e.target)) return;
    el.chatEmojiPicker.hidden = true;
  });
}

if (el.chatCreateRoomBtn && el.chatCreateDialog) {
  el.chatCreateRoomBtn.addEventListener("click", function () {
    el.chatNewRoomName.value = "";
    el.chatCreateDialog.showModal();
    el.chatNewRoomName.focus();
  });
  if (el.chatCreateCancel) el.chatCreateCancel.addEventListener("click", function () { el.chatCreateDialog.close(); });
  el.chatCreateDialog.addEventListener("close", function () {
    if (el.chatCreateDialog.returnValue !== "ok") return;
    var name = el.chatNewRoomName.value.trim();
    if (!name) return;
    fetch("/api/chat/subscribe", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ room: name, on: true })
    }).then(function (r) { return r.json(); }).then(function (d) {
      if (!d.ok) {
        var fail = "Could not create channel: " + (d.error || "unknown error");
        el.chatStatus.textContent = fail;
        uiToast(fail);
        return;
      }
      loadChatRooms().then(function () {
        el.chatRoom.value = name;
        openChatRoom(name);
      });
    }).catch(function (err) {
      var fail = "Could not create channel: " + err.message;
      el.chatStatus.textContent = fail;
      uiToast(fail);
    });
  });
}

var typingAt = 0, typingTimer = null;
function setTyping(on){
  var ind = document.getElementById("chat-typing");
  if(!ind) return;
  if (on) {
    ind.innerHTML = "";
    var name = (window._clankerInstance || "you");
    ind.appendChild(document.createTextNode(name + " is typing"));
    var dots = document.createElement("span");
    dots.className = "slack-typing-dots";
    for (var i = 0; i < 3; i++) {
      var dot = document.createElement("span");
      dot.className = "slack-typing-dot";
      dots.appendChild(dot);
    }
    ind.appendChild(dots);
  } else {
    ind.textContent = "";
  }
  ind.hidden = !on;
}
el.chatText.addEventListener("input", function(){
  typingAt = Date.now();
  setTyping(true);
  if(typingTimer) clearTimeout(typingTimer);
  typingTimer = setTimeout(function(){ if(Date.now()-typingAt >= 1800) setTyping(false); }, 2000);
});

/* ── Ctrl+K / Cmd+K: Quick channel switcher (Slack-style) ── */
document.addEventListener("keydown", function(e){
  if ((e.ctrlKey || e.metaKey) && e.key === "k") {
    /* Only intercept when the chat view is visible */
    var chatView = document.getElementById("view-rooms");
    if (!chatView || chatView.hidden) return;
    e.preventDefault();
    var existing = document.getElementById("slack-quick-switch");
    if (existing) { existing.remove(); return; }
    var overlay = document.createElement("div");
    overlay.id = "slack-quick-switch";
    overlay.style.cssText = "position:fixed;inset:0;z-index:100;display:flex;align-items:flex-start;justify-content:center;padding-top:20vh;background:rgba(0,0,0,.5);";
    var box = document.createElement("div");
    box.style.cssText = "background:var(--surface);border:1px solid var(--rule);border-radius:8px;box-shadow:0 8px 32px rgba(0,0,0,.3);width:480px;max-width:90vw;overflow:hidden;";
    var input = document.createElement("input");
    input.type = "text"; input.placeholder = "Switch to channel or DM…";
    input.style.cssText = "width:100%;padding:0.75rem 1rem;border:none;background:transparent;color:var(--fg);font-size:15px;outline:none;";
    var results = document.createElement("div");
    results.style.cssText = "max-height:300px;overflow-y:auto;";
    box.appendChild(input);
    box.appendChild(results);
    overlay.appendChild(box);
    document.body.appendChild(overlay);
    input.focus();

    function renderResults(filter) {
      results.textContent = "";
      var opts = Array.from(el.chatRoom.options);
      var filtered = opts.filter(function(o){ return !filter || o.value.toLowerCase().indexOf(filter.toLowerCase()) !== -1; });
      filtered.forEach(function(o){
        var btn = document.createElement("button");
        btn.type = "button";
        btn.style.cssText = "display:block;width:100%;text-align:left;padding:0.5rem 1rem;border:none;background:none;color:var(--fg);font-size:14px;cursor:pointer;";
        var isDM = o.value.indexOf("dm:") === 0;
        btn.textContent = (isDM ? "@ " : "# ") + chatRoomLabel(o.value);
        btn.addEventListener("mouseenter", function(){ btn.style.background = "var(--surface-hover)"; });
        btn.addEventListener("mouseleave", function(){ btn.style.background = "none"; });
        btn.addEventListener("click", function(){
          el.chatRoom.value = o.value;
          openChatRoom(o.value);
          overlay.remove();
        });
        results.appendChild(btn);
      });
    }
    renderResults("");
    input.addEventListener("input", function(){ renderResults(input.value); });
    input.addEventListener("keydown", function(ev){
      if (ev.key === "Escape") { overlay.remove(); ev.stopPropagation(); }
      if (ev.key === "Enter") {
        var first = results.querySelector("button");
        if (first) first.click();
      }
    });
    overlay.addEventListener("click", function(ev){ if (ev.target === overlay) overlay.remove(); });
  }
});
el.chatText.addEventListener("keydown", function(e){
  if (e.key === "@" || (e.key.length === 1 && el.chatText.value.slice(-1) === "@")) {
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

var usageState = uiState([]);

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

/* Extracted to features/goals.js; wired here with the app-level pieces it
   needs: view switching and the conversation the chat composer is on (a
   goal run joins that session). */
bindGoals({ el: el, showView: showView, getSessionId: function () { return sessionId; }, switchSession: switchSession });

// ---- tools: every WASM plugin, and a switch for the optional ones ------

var allToolsHolder = { list: [] };
var allTools = allToolsHolder.list;

var toolState = uiState({ tools: [], filter: "" });

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

var VIEWS = ["chat", "board", "runs", "fleet", "arena", "compare", "rooms", "models", "search", "schedule", "knowledge", "prompts", "tools", "system"];
var arenaModulePromise = null;
function loadArenaModule() {
  if (!arenaModulePromise) arenaModulePromise = import("./features/arena.js");
  return arenaModulePromise;
}
var compareModulePromise = null;
function loadCompareModule() {
  if (!compareModulePromise) compareModulePromise = import("./features/compare.js");
  return compareModulePromise;
}
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

/* A view's loader runs again every time its *first* load failed, because
   `viewLoaded[name]` is only set once a load has actually succeeded (see
   showView, and the comment there on why that retry matters). The loaders
   that also bind listeners were therefore binding them again on every retry:
   two failed opens of Compare left three Refresh handlers on one button, and
   the arena added a `prefers-reduced-motion` listener each time too. Retrying
   the fetch is the point; retrying the wiring is not, so the wiring is
   separated out here and happens once per view for the life of the page.
   `features/models.js` already carried a private `bound` flag against exactly
   this; that flag is now redundant rather than load-bearing, and the next view
   to be added gets the guarantee without having to remember it. */
var viewBound = {};
function bindOnce(name, bind) {
  if (viewBound[name]) return;
  viewBound[name] = true;
  bind();
}

var viewLoaders = {
  runs: loadRuns,
  fleet: function () {
    return loadFleetModule().then(function (fleet) { return fleet.refreshFleet(); });
  },
  arena: function () {
    return loadArenaModule().then(function (arena) { bindOnce("arena", arena.bindArena); return arena.loadArenaView(); });
  },
  compare: function () {
    return loadCompareModule().then(function (compare) { bindOnce("compare", compare.bindCompare); return compare.loadCompareView(); });
  },
  rooms: function () { return loadStatus().then(loadChatRooms); },
  // Goals ride along with the board: the board->goal sync (moving a card
  // marks its goal) needs the goal list, and the goal->board mirror needs to
  // run even when the Goals view was never opened.
  board: function () { return loadBoardRooms().then(function () { return loadGoals(); }); },
  models: function () { bindOnce("models", modelsBind); return modelsLoadView(); },
  schedule: function () { bindOnce("schedule", scheduleBind); return scheduleLoadView(); },
  search: function () {
    bindOnce("search", function () {
      // Opening a hit is a conversation switch, which app.js owns: switchSession
      // refuses mid-run and puts the rail back, and the search view has no
      // business reimplementing that.
      searchDeps({ openSession: function (id, jump) { switchSession(id, jump); showView("chat", true); } });
      searchBind();
    });
    return searchLoadView();
  },
  knowledge: function(){ return kbLoad(); },
  prompts: function () { return Promise.all([promptsLoadView(), toolsLoadWorkflows(), toolsLoadSkills()]); },
  tools: loadTools,
  system: function () { return Promise.all([loadUsage(), loadStatus(), loadLogList(), loadWebuiPlugins()]); }
};

/* An in-flight panel, an empty panel and a hung panel were pixel-identical.
   Each renderer overwrites this on success and each catch replaces it with the
   failure, so one line is enough. */
var VIEW_CONTAINERS = {
  models: "models-configured",
  runs: "run-graph",
  fleet: "fleet-runs",
  arena: "arena-list",
  compare: "compare-list",
  rooms: "chat-log",
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

function parseRunsHash(hash){
  // accepts #runs/<id>?search=foo&kind=tool&node=label — order-agnostic
  if (hash.indexOf("#runs/") !== 0) return null;
  var rest = hash.slice(6);
  var qAt = rest.indexOf("?");
  var idPart = qAt===-1 ? rest : rest.slice(0, qAt);
  var qs = qAt===-1 ? "" : rest.slice(qAt+1);
  var params = {};
  qs.split("&").forEach(function(p){ if(!p) return; var kv=p.split("="); try{ params[decodeURIComponent(kv[0])]=kv[1]?decodeURIComponent(kv[1]):"";}catch(_){ params[kv[0]]=kv[1]||""; } });
  var id=""; try{ id=decodeURIComponent(idPart);}catch(_){ id=idPart; }
  return { id: id, search: params.search||"", kind: params.kind||"", node: params.node||"" };
}
function syncRailFolds(name) {
  var tab = document.getElementById("tab-" + name);
  var fold = tab && tab.closest ? tab.closest("details.rail-fold") : null;
  if (fold) fold.open = true;
}

function showView(name, focusPanel) {
  // Goals and board are one workflow now. Keep old bookmarks working while
  // making Board the only visible navigation destination.
  if (name === "goals") name = "board";
  var parsed = parseRunsHash("#" + name);
  var deepRun = null, deepNode = null, deepSearch=null, deepKind=null;
  if (parsed) { deepRun = parsed.id; deepNode = parsed.node || null; deepSearch = parsed.search; deepKind = parsed.kind; name = "runs"; }
  else if (name.indexOf("runs/") === 0) {
    var rest2 = name.slice(5);
    var qA2 = rest2.indexOf("?node=");
    if (qA2 !== -1) { deepRun = decodeURIComponent(rest2.slice(0, qA2)); deepNode = decodeURIComponent(rest2.slice(qA2 + 6)); }
    else { deepRun = decodeURIComponent(rest2); }
    name = "runs";
  }
  var pendingBoardCard = null;
  var pendingKnowledgeId = null;
  var pendingSessionId = null;
  if (name.indexOf("chat?session=") === 0) { try { pendingSessionId = decodeURIComponent(name.slice(13)); } catch (e) {} name = "chat"; }
  if (name.indexOf("arena/") === 0) { window._pendingArenaId = decodeURIComponent(name.slice(6)); name = "arena"; }
  if (name.indexOf("compare/") === 0) { window._pendingCompareId = decodeURIComponent(name.slice(8)); name = "compare"; }
  if (name.indexOf("board/") === 0) { pendingBoardCard = decodeURIComponent(name.slice(6)); name = "board"; }
  if (name.indexOf("knowledge/") === 0) { pendingKnowledgeId = decodeURIComponent(name.slice(10)); name = "knowledge"; }
  if (pendingBoardCard) window._pendingBoardCard = pendingBoardCard;
  if (pendingKnowledgeId) window._pendingKnowledgeId = pendingKnowledgeId;
  if (VIEWS.indexOf(name) === -1) name = "chat";
  // The rooms poll has no idea the view switched away from under it — only
  // document.hidden stopped it before, so leaving Rooms for Chat or Board
  // left it polling a chat log nobody could see. Stop it here, and pick back
  // up where it left off if Rooms is reopened.
  if (currentView === "rooms" && name !== "rooms") stopChatPoll();
  // Same reason, and the arena has two things to stop: the match poll and the
  // canvas animation loop. Leaving either running on a view nobody can see is
  // exactly the standing background timer the arena view is not allowed to be.
  if (currentView === "arena" && name !== "arena" && arenaModulePromise) {
    arenaModulePromise.then(function (arena) { arena.stopArena(); });
  }
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
  // Preserve callgraph filter state in the URL (shareable/bookmarkable) — search/kind from either deep link or active graph
  var _qs = []; try{ if(deepSearch) _qs.push("search="+encodeURIComponent(deepSearch)); if(deepKind) _qs.push("kind="+encodeURIComponent(deepKind)); }catch(_){}
  var desiredHash = deepRun ? "#runs/" + encodeURIComponent(deepRun) + ((deepNode||_qs.length) ? "?" + (_qs.join("&") + (deepNode ? (_qs.length?"&":"")+"node="+encodeURIComponent(deepNode) : "")) : "") : "#" + name;
  if (window.location.hash !== desiredHash) {
    try {
      if (viewSettled) window.history.pushState(null, "", desiredHash);
      else window.history.replaceState(null, "", desiredHash);
    } catch (e) {}
  }
  if (deepRun) {
    if (deepSearch || deepKind) { try{ localStorage.setItem("clanker.graphSearch", deepSearch||""); localStorage.setItem("clanker.graphKind", deepKind||""); }catch(_){} }
  }
  viewSettled = true;
  if (el.railContext) el.railContext.hidden = false;
  syncRailFolds(name);
  closeRailOnNarrow();
  if (focusPanel) {
    var panel = document.getElementById("view-" + name);
    if (panel && panel.focus) panel.focus({ preventScroll: true });
  }
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
  } else if (name === "arena" && arenaModulePromise) {
    // Leaving the arena stops its poll and animation loop; coming back has to
    // start them again, or the view stays frozen until a manual Refresh.
    arenaModulePromise.then(function (arena) { arena.loadArenaView(); });
  }
  if (pendingSessionId) switchSession(pendingSessionId);
  if (deepRun) {
    window._pendingRunNode = deepNode || null;
    if (viewLoaded.runs) { openRun(deepRun); if (deepNode) setTimeout(function(){ try{ var n = el.runGraph.querySelector('.run-node[data-label="' + CSS.escape(deepNode) + '"]'); if(n){ n.focus(); n.click(); n.scrollIntoView({block:"center", inline:"center"}); } }catch(_){}} , 300); }
    else pendingRunId = deepRun;
  }
  if (pendingKnowledgeId) {
    setTimeout(function(){
      try {
        kbLoad().then(function(){
          try {
            // Reuse the same path as Knowledge Open button: populate detail via API
            fetch("/api/knowledge/"+encodeURIComponent(pendingKnowledgeId)).then(function(r){ return r.json(); }).then(function(d){
              var detail = document.getElementById("knowledge-detail");
              if (!detail) return;
              detail.hidden = false;
              detail.textContent = "";
              var head = document.createElement("div"); head.className = "run-detail-head";
              var tt = document.createElement("span"); tt.className = "run-detail-title"; tt.textContent = d.title || pendingKnowledgeId; head.appendChild(tt);
              var close = document.createElement("button"); close.type="button"; close.className="secondary"; close.textContent="Close"; upgradePfButton(close);
              close.addEventListener("click", function(){ detail.hidden = true; }); head.appendChild(close);
              detail.appendChild(head);
              if (d.description) { var desc=document.createElement("p"); desc.className="meta"; desc.textContent=d.description; detail.appendChild(desc); }
              var docs = d.docs || [];
              if (!docs.length) { var empty=document.createElement("p"); empty.className="meta"; empty.textContent="No documents yet."; detail.appendChild(empty); }
              else docs.forEach(function(doc){
                var row=document.createElement("div"); row.className="knowledge-doc";
                var dn=document.createElement("span"); dn.textContent=doc.name+" ("+doc.bytes+" bytes)"; row.appendChild(dn);
                var pre=document.createElement("pre"); pre.className="knowledge-preview"; pre.textContent=(doc.content||"").slice(0,800); row.appendChild(pre);
                detail.appendChild(row);
              });
              try { detail.scrollIntoView({behavior:"smooth", block:"nearest"}); } catch(_){}
            }).catch(function(){});
          } catch(_){}
        }).catch(function(){});
      } catch(_){}
    }, 450);
  }
  if (pendingBoardCard) {
    // need board loaded first — defer until after viewLoaders[board] would have fired, then poll
    var tries = 0;
    (function tryOpen(){
      tries++;
      if (cardById(pendingBoardCard)) { setOpenCardId(pendingBoardCard); try{ renderBoard(board); }catch(_){} return; }
      if (tries < 20) setTimeout(tryOpen, 250);
      else { setOpenCardId(pendingBoardCard); try{ renderBoard(board); }catch(_){} }
    })();
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
   the composer or a filter. Only the first `view_digit_max` views, because a
   digit is one key: the rest are reached by the palette or the tablist arrows,
   and the two surfaces that describe this shortcut read the same cap from
   core/utils.js so they cannot drift from it again. */
document.addEventListener("keydown", function (e) {
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  var t = e.target;
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
  var n = parseInt(e.key, 10);
  if (n >= 1 && n <= Math.min(view_digit_max, VIEWS.length)) {
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
  var q = el.turnFilter.value.trim();
  var qFold = utilSearchFold(q);
  var turns = el.transcript.querySelectorAll(".turn");
  clearMarks(el.transcript);
  if (!q) {
    Array.prototype.forEach.call(turns, function (t) { t.hidden = false; });
    el.turnFilterCount.textContent = "";
    return;
  }
  var shown = 0, hits = 0;
  Array.prototype.forEach.call(turns, function (t) {
    var match = utilSearchFold(t.textContent).indexOf(qFold) !== -1;
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

function nearBottom() { return scrollNearBottom(scrollChatBox()); }
var prefersReducedMotion = scrollPrefersReducedMotion;
function syncScrollButton() { scrollSyncButton(el.transcript, el.scrollBottom, scrollChatBox()); }

uiAdd(el.scrollBottom, icon("deposit", 14));
el.submit.textContent = "";
uiAdd(el.submit, icon("arrowUp", 16), document.createTextNode("Run"));
uiAdd(el.cancel, icon("stop", 14));
el.scrollBottom.addEventListener("click", function () {
  scrollChatLatest(prefersReducedMotion() ? "auto" : "smooth");
  el.task.focus();
});

var chatScroll = scrollChatBox();
if (chatScroll) chatScroll.addEventListener("scroll", syncScrollButton, { passive: true });
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
function showToast(text) { return uiToast(text); }

if (window.MutationObserver) {
  var statusToasts = new WeakMap();
  var statusObserver = new MutationObserver(function (records) {
    var seen = {};
    records.forEach(function (r) {
      var el0 = r.target.nodeType === 3 ? r.target.parentNode : r.target;
      if (!el0) return;
      var previous = statusToasts.get(el0);
      if (previous) {
        previous.remove();
        statusToasts.delete(el0);
      }
      var text = el0.textContent.trim();
      // The same message written twice in one tick is one event.
      if (!text || seen[text]) return;
      // In-flight progress belongs in the view (or sr-only status), not a
      // toast that vanishes before the work finishes.
      if (/^(Loading|Searching|Refreshing|Pausing|Resuming)\b/.test(text)) return;
      seen[text] = true;
      var shown = showToast(text);
      if (shown) statusToasts.set(el0, shown);
    });
  });
  ["session-status", "run-status", "chat-status", "board-status", "webui-plugins-status", "tools-status", "logs-status", "goals-status",
   "search-status", "schedule-status", "knowledge-status", "prompts-status", "models-status", "fleet-status",
   "progress-status", "settings-status", "skills-status", "workflows-status"].forEach(function (id) {
    var node = document.getElementById(id);
    if (node) statusObserver.observe(node, { childList: true, characterData: true, subtree: true });
  });
}

/* ---------- saved prompts ---------- */

/* Every one of these UIs has a prompt library, and the reason is the same:
   the tasks worth repeating are long, and retyping them is where the habit
   of using the tool dies. */
var loadPrompts = compLoadPrompts;
var _origSavePrompts = compSavePrompts;
var savePrompts = function () {
  _origSavePrompts(prompts);
  try {
    var toSync = prompts.slice();
    fetch("/api/prompts").then(function(r){ return r.json(); }).then(function(data){
      var server = (data && data.prompts) || [];
      var have = {};
      server.forEach(function(p){ have[p.content] = true; have[p.title] = true; });
      toSync.forEach(function(text){
        if (have[text]) return;
        var title = text.slice(0, 60).trim() || "Untitled";
        fetch("/api/prompts", { method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({ title: title, content: text }) }).catch(function(){});
      });
    }).catch(function(){});
  } catch(e) {}
};
var prompts = loadPrompts();
try {
  fetch("/api/prompts").then(function(r){ return r.json(); }).then(function(data){
    var server = (data && data.prompts) || [];
    var changed = false;
    server.forEach(function(p){
      var text = p.content || p.title;
      if (!text) return;
      if (prompts.indexOf(text) === -1) { prompts.push(text); changed = true; }
    });
    if (changed) _origSavePrompts(prompts);
  }).catch(function(){});
} catch(e) {}

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
  // The one place that means "no suggestion list is open", so it is also where
  // the mention list's own state stops being true. Leaving the flag set is what
  // let a key meant for one list be dispatched against another.
  kbMentionActive = false;
  kbMentionIndex = 0;
}

var SLASH_CMDS = [
  { cmd: "/compact", desc: "Drop oldest exchanges to fit context", run: function(){ document.getElementById("session-compact").click(); } },
  { cmd: "/fork", desc: "Fork this conversation", run: function(){ document.getElementById("session-fork").click(); } },
  { cmd: "/branch", desc: "Branch from last turn", run: function(){ var b=document.querySelector(".turn:last-child .turn-foot-actions button"); if(b) b.click(); } },
  { cmd: "/clear", desc: "Start a new conversation", run: function(){ document.getElementById("new-chat").click(); } },
  { cmd: "/model", desc: "Switch model — e.g. /model gpt-4o", run: function(arg){
    var s = document.getElementById("model-select");
    if (!s) return;
    if (arg) {
      var matched = false;
      for (var i = 0; i < s.options.length; i++) {
        if (s.options[i].value === arg || s.options[i].textContent.indexOf(arg) >= 0) {
          s.value = s.options[i].value; matched = true; break;
        }
      }
      if (matched) s.dispatchEvent(new Event("change", { bubbles: true }));
      return;
    }
    mpOpen(document.getElementById("composer-model") || document.getElementById("header-model"));
  } },
  { cmd: "/knowledge", desc: "Open Knowledge collections", run: function(){ showView("knowledge", true); } },
  { cmd: "/prompts", desc: "Open Prompts library", run: function(){ showView("prompts", true); } },
  { cmd: "/compare", desc: "Open blind model comparisons", run: function(){ showView("compare", true); } },
  { cmd: "/new", desc: "New chat (alias for /clear)", run: function(){ document.getElementById("new-chat").click(); } },
  { cmd: "/help", desc: "Show keyboard shortcuts", run: function(){ document.getElementById("help-open").click(); } },
];
function slashQuery(){
  var v = el.task.value;
  if (v.charAt(0) !== "/") return null;
  var sp = v.indexOf(" ");
  var head = sp===-1 ? v : v.slice(0, sp);
  var rest = sp===-1 ? "" : v.slice(sp+1);
  return { head: head.toLowerCase(), rest: rest, raw: v };
}
function renderSlashList(){
  var q = slashQuery();
  if (!q) { hideSlashList(); return; }
  var matches = SLASH_CMDS.filter(function(c){ return c.cmd.indexOf(q.head) === 0; });
  // also match /model sub-query against provider list for hint
  el.promptList.textContent = "";
  if (!matches.length) { hideSlashList(); return; }
  promptIndex = Math.min(promptIndex, matches.length - 1);
  matches.forEach(function(c, i){
    var li = document.createElement("li");
    li.className = "palette-item"; li.id = "prompt-item-" + i;
    li.setAttribute("role","option"); li.setAttribute("aria-selected", String(i===promptIndex));
    var k = document.createElement("span"); k.className="palette-kind"; k.textContent=c.cmd; li.appendChild(k);
    var label = document.createElement("span"); label.className="palette-label"; label.textContent=c.desc; li.appendChild(label);
    li.addEventListener("mousedown", function(e){ e.preventDefault(); useSlash(c, q.rest); });
    el.promptList.appendChild(li);
  });
  el.promptList.hidden = false;
  el.task.setAttribute("aria-expanded","true");
  el.task.setAttribute("aria-activedescendant","prompt-item-"+promptIndex);
}
function hideSlashList(){ hidePromptList(); }
function useSlash(entry, arg){
  hideSlashList();
  // keep the slash text out of the composer for pure-command entries
  if (entry.cmd === "/model" && arg) { entry.run(arg); el.task.value=""; }
  else if (entry.cmd === "/model") { el.task.value=""; entry.run(""); }
  else { el.task.value=""; entry.run(arg); }
  syncControls();
  el.task.focus();
}
function usePrompt(text) {
  el.task.value = text;
  hidePromptList();
  el.task.focus();
  syncControls();
}

function taskInputHandler(){ var q=slashQuery(); if(q) renderSlashList(); else renderPromptList(); }
el.task.addEventListener("input", taskInputHandler);
el.task.addEventListener("blur", function () { window.setTimeout(hidePromptList, 120); });
/* One popup, three lists: saved prompts, `/` commands, and `#` knowledge
   collections. Each keeps its own highlight — `promptIndex` for the first two,
   `kbMentionIndex` for mentions — and the handler has to know which one is on
   screen before it moves anything or acts on a row.

   It did not. Every key was treated as belonging to the prompt list, so with
   the `#` mention list open: an arrow key nudged `promptIndex` and re-rendered
   the *prompt* list, which for a value not starting with `/` hides the popup —
   the first arrow press dismissed the mentions rather than walking them; Enter
   always activated the first row whatever was highlighted; and Delete read the
   row's label ("3 docs") as the name of a saved prompt, found it absent, and
   `splice(-1, 1)` silently forgot your most recently saved prompt instead. The
   index left over from another list can also be past the end of a shorter one,
   which made `items[promptIndex]` undefined and the keypress a TypeError. */
el.task.addEventListener("keydown", function (e) {
  var isSlash = slashQuery() !== null;
  if (el.promptList.hidden) return;
  var items = el.promptList.querySelectorAll(".palette-item");
  if (!items.length) return;
  var list = kbMentionActive ? "kb" : (isSlash ? "slash" : "prompt");
  var at = list === "kb" ? kbMentionIndex : promptIndex;
  if (typeof at !== "number" || at < 0 || at >= items.length) at = 0;
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    at = (at + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
    if (list === "kb") {
      // Moved in place: the mention list is built from a /api/knowledge fetch,
      // and re-rendering would be one request per arrow key.
      kbMentionIndex = at;
      compSetActiveItem(el.promptList, at, el.task);
    } else {
      promptIndex = at;
      if (isSlash) renderSlashList(); else renderPromptList();
    }
    return;
  }
  if (e.key === "Escape") {
    e.preventDefault();
    hidePromptList();
    return;
  }
  if (list === "prompt" && e.key === "Delete") {
    e.preventDefault();
    var doomed = items[at].querySelector(".palette-label").textContent;
    if (!compForgetPrompt(prompts, doomed)) return;
    savePrompts();
    el.sessionStatus.textContent = "Forgot that prompt.";
    renderPromptList();
    return;
  }
  if (e.key === "Enter" || (e.key === "Tab" && !e.shiftKey)) {
    e.preventDefault();
    if (list === "kb") {
      items[at].dispatchEvent(new MouseEvent("mousedown", {bubbles:true, cancelable:true}));
      return;
    }
    if (list === "slash") {
      var q2=slashQuery(); var m=SLASH_CMDS.filter(function(c){ return c.cmd.indexOf(q2.head)===0; })[at];
      if(m) useSlash(m, q2.rest);
    } else {
      usePrompt(items[at].querySelector(".palette-label").textContent);
    }
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
  uiConfirm("Compact this conversation? The oldest exchanges are dropped permanently.", { danger: true, confirmLabel: "Compact" }).then(function (yes) {
    if (!yes) return;
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
});

function transcriptMarkdown() { return compTranscriptMarkdown(el.transcript, currentSessionMeta, sessionId); }
(function(){
  var btn = document.getElementById("session-share");
  if (!btn) return;
  btn.addEventListener("click", function(){
    var id = sessionId || "";
    var url = window.location.origin + window.location.pathname + "#chat";
    // Prefer session deep-link when available
    try {
      if (id) url = window.location.origin + window.location.pathname + "#chat?session=" + encodeURIComponent(id);
      // Also include session title hint for standalone share
      navigator.clipboard.writeText(url).then(function(){
        btn.textContent = "Copied";
        setTimeout(function(){ btn.textContent = "Share"; }, 1200);
      }, function(){ uiPrompt("Share link", url); });
    } catch(_){ try { uiPrompt("Share link", url); } catch(__){} }
  });
})();
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

/* Extracted to features/board.js; wired here with the app-level pieces it
   needs: tab counts, opening a recorded run, and the peer roster for the
   quick-add @ mention hint. */
bindBoard({ el: el, setTabCount: setTabCount, openRun: openRun, getKnownPeers: function () { return knownPeers; } });

// Archive + Import (history parity) — reuses existing session API, no invented state
(function(){
  var archBtn = document.getElementById("session-archive");
  var importBtn = document.getElementById("session-import");
  var tog = document.getElementById("archived-toggle");
  if (archBtn) archBtn.addEventListener("click", function(){
    var meta = currentSessionMeta && currentSessionMeta();
    if (!meta){ el.sessionStatus.textContent = "This conversation has no saved turns yet."; return; }
    var next = !meta.archived;
    archBtn.disabled = true;
    fetch("/api/sessions/" + encodeURIComponent(sessionId), { method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({ archived: next }) })
      .then(readJson).then(function(){
        el.sessionStatus.textContent = next ? "Archived — toggle Show archived to see it." : "Unarchived.";
        archBtn.textContent = next ? "Unarchive" : "Archive";
        return loadSessions();
      }).catch(function(err){ el.sessionStatus.textContent = "Archive failed: " + err.message; })
      .finally(function(){ archBtn.disabled = false; });
  });
  function syncArchiveLabel(){
    try {
      var meta = currentSessionMeta && currentSessionMeta();
      if (archBtn) archBtn.textContent = meta && meta.archived ? "Unarchive" : "Archive";
    } catch(_){}
  }
  // Session metadata changes only when the conversation list is rendered.
  // Observe that state boundary instead of waking the page every 900ms.
  var railList = document.getElementById("rail-list");
  if (railList && typeof MutationObserver !== "undefined") {
    new MutationObserver(syncArchiveLabel).observe(railList, { childList: true, subtree: true });
  }
  syncArchiveLabel();
  if (tog) tog.addEventListener("change", function(){ renderSessionOptions(null); });
  if (importBtn) importBtn.addEventListener("click", function(){
    var inp = document.createElement("input"); inp.type="file"; inp.accept=".json,application/json";
    inp.addEventListener("change", function(){
      var f = inp.files && inp.files[0]; if (!f) return;
      var fr = new FileReader();
      fr.onload = function(){
        var text = String(fr.result || "");
        var parsed = null; try { parsed = JSON.parse(text); } catch(e){ uiToast("Not valid JSON: "+e.message); return; }
        // Accept {messages:[{role,content}]} or {conversations:[...]} or bare array
        var msgs = null; var title = "";
        if (Array.isArray(parsed)) msgs = parsed;
        else if (parsed && Array.isArray(parsed.messages)) { msgs = parsed.messages; title = parsed.title || ""; }
        else if (parsed && Array.isArray(parsed.conversations) && parsed.conversations[0]) { var c = parsed.conversations[0]; msgs = c.messages || c.mapping && Object.values(c.mapping).map(function(v){ var m=v.message; return m?{role:m.author&&m.author.role,content:(m.content&&m.content.parts&&m.content.parts[0])||m.content} : null; }).filter(Boolean) || []; title = c.title || ""; }
        else if (parsed && parsed.id && Array.isArray(parsed.messages)) { msgs = parsed.messages; title = parsed.title || ""; }
        if (!msgs || !msgs.length){ uiToast("No messages found in file. Expected {messages:[{role,content}]} or an array of messages."); return; }
        // Normalize to StoredMessage shape the server expects
        var norm = msgs.map(function(m){
          var role = (m.role==="assistant"||m.role==="assistant") ? "assistant" : (m.role==="user"?"user":String(m.role||"user"));
          var content = m.content!=null ? String(m.content) : (m.text!=null?String(m.text):"");
          if (role!=="user" && role!=="assistant") role="user";
          return { role: role, content: content };
        }).filter(function(m){ return m.content && m.content.trim(); });
        if (!norm.length){ uiToast("No importable messages."); return; }
        fetch("/api/sessions", { method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify({ import_chat: true, title: title || ("imported "+new Date().toLocaleString()), messages: norm }) })
          .then(function(r){ return r.json().then(function(d){ if(!r.ok||!d.ok) throw new Error(d.error||r.status); return d; }); })
          .then(function(d){
            el.sessionStatus.textContent = "Imported.";
            if (d.id){ sessionId = d.id; try{ window.localStorage.setItem("clanker.session", sessionId); }catch(_){} renderSessionChip(); }
            return loadSessions();
          }).catch(function(err){ uiToast("Import failed: "+err.message); });
      };
      fr.readAsText(f);
    });
    inp.click();
  });
})();


/* ---------- web UI plugins ----------

   The page is itself served by a WASM tool, so it is already a plugin; this
   lets it host plugins of its own. A plugin is a directory under
   ui/plugins/ with a manifest and an app.js, served same-origin so
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
        var rev=document.createElement("button"); rev.type="button"; rev.className="secondary"; rev.textContent="Revert"; upgradePfButton(rev); rev.style.marginLeft="0.5rem";
        rev.addEventListener("click", function(){
          uiConfirm("Revert to "+r.run_id+"? This restores the worktree from that run where available.", { danger: true, confirmLabel: "Revert" }).then(function (yes) {
            if(!yes) return;
            append("Revert requested for "+r.run_id+" — use CLI `clanker revert "+r.run_id+"` if server-side revert is not enabled.\n");
          });
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
  // These chores can legitimately run long (gate failures send the agent off
  // to read source and fix them) and there is no checkbox here to raise the
  // budget per-run the way the composer's "No limit" toggle does, so they ask
  // for the same 1000 ceiling outright rather than silently inheriting
  // cfg.agent.max_iterations (usually far lower) and cutting the run short.
  wire("progress-gate", { task:"run the gate: zig build, zig build test, zig fmt check, and summarize pass/fail per check", stream:true, session: (typeof sessionId!=="undefined"?sessionId:"progress"), max_iterations:1000 });
  wire("progress-eval", { task:"run evals: list tasks with criteria, run each, and summarize scores", stream:true, session: (typeof sessionId!=="undefined"?sessionId:"progress"), max_iterations:1000 });
  wire("progress-providers", { task:"check providers: for each configured provider/model report reachable/missing auth/rate-limited", stream:true, session: (typeof sessionId!=="undefined"?sessionId:"progress"), max_iterations:1000 });
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

function mountIcon(node, name, size) {
  if (!node) return;
  upgradePfButton(node);
  node.textContent = "";
  var wrap = document.createElement("span");
  wrap.className = "pf-v6-c-button__icon";
  wrap.appendChild(icon(name, size || 15));
  node.appendChild(wrap);
}
upgradePfUi(document);
mountIcon(el.helpOpen, "help", 15);
mountIcon(document.getElementById("rail-collapse"), "panel", 15);
mountIcon(document.getElementById("voice-btn"), "mic", 16);
mountIcon(document.getElementById("chat-sidebar-toggle"), "list", 16);
mountIcon(document.getElementById("chat-search-toggle"), "find", 16);
mountIcon(document.getElementById("chat-pin-toggle"), "pin", 16);
mountIcon(document.getElementById("chat-refresh"), "refresh", 16);
mountIcon(document.getElementById("chat-search-close"), "close", 16);
mountIcon(document.getElementById("chat-pins-close"), "close", 16);
var pinsTitle = document.getElementById("chat-pins-title");
if (pinsTitle && !pinsTitle.querySelector(".icon")) {
  pinsTitle.insertBefore(icon("pin", 14), pinsTitle.firstChild);
  pinsTitle.insertBefore(document.createTextNode(" "), pinsTitle.lastChild);
}
el.helpOpen.addEventListener("click", function () { openOverlay(el.help, el.helpClose); });
el.helpClose.addEventListener("click", function () { closeOverlay(el.help); });

var providerCacheHolder = { list: providerCache };
mpBind({ el: el, readJson: readJson, fmtInt: fmtInt, allUsage: allUsage, renderUsage: renderUsage, renderContextMeter: renderContextMeter, providerCacheHolder: providerCacheHolder, onModelChange: renderSessionChip });
// Header chip and composer pill mirror the hidden select.
if (el.modelSelect) el.modelSelect.addEventListener("change", renderSessionChip);

paletteBind({
  VIEWS: VIEWS, showView: showView, el: el,
  refs: { knownSessionsHolder: knownSessionsHolder, allRunsHolder: allRunsHolder, board: board, goalState: goalState, allToolsHolder: allToolsHolder, sessionLabel: sessionLabel, runLabel: runLabel },
  setRailOpen: setRailOpen, switchSession: switchSession, openRun: openRun, renderBoard: renderBoard, showToolDetail: showToolDetail,
  setOpenCardId: setOpenCardId
});
document.addEventListener("keydown", function (e) {
  // Trello/Slack-style card modal owns focus while open — Esc closes, Tab
  // traps. Lives in features/board.js with the rest of the modal.
  if (cardModalKeyHandler(e)) return;
  if (paletteKeyHandle(e, { el: el, finishTextPrompt: finishTextPrompt, setRailOpen: setRailOpen })) return;
});

try { kbBind(); } catch(_){}
try { promptsBind(); } catch(_){}

// Settings surface wires the same header affordances (single source of truth)
try {
  (function(){
    var themeCycle = document.getElementById("settings-theme-cycle");
    var themeLabel = document.getElementById("settings-theme-label");
    var headerCycle = document.getElementById("theme-toggle");
    function syncThemeLabel(){
      try { themeLabel.textContent = theme; } catch(_){}
    }
    if (themeCycle) themeCycle.addEventListener("click", function(){ if(headerCycle) headerCycle.click(); setTimeout(syncThemeLabel, 0); });
    syncThemeLabel();
    // session/status mirrors
    function syncSessionMirror(){
      try {
        var m = document.getElementById("settings-session-chip");
        if (m) m.textContent = document.getElementById("session-chip") ? document.getElementById("session-chip").textContent : "";
        var meta = currentSessionMeta && currentSessionMeta();
        if (m && meta && meta.title) m.textContent = meta.title + " · " + m.textContent;
      } catch(_){}
    }
    // The hidden chip is updated by every session switch/new-session path;
    // mirror those writes directly instead of keeping a permanent timer.
    var sourceChip = document.getElementById("session-chip");
    if (sourceChip && typeof MutationObserver !== "undefined") {
      new MutationObserver(syncSessionMirror).observe(sourceChip, { childList: true, characterData: true, subtree: true });
    }
    var sourceSessions = document.getElementById("rail-list");
    if (sourceSessions && typeof MutationObserver !== "undefined") {
      new MutationObserver(syncSessionMirror).observe(sourceSessions, { childList: true, subtree: true });
    }
    syncSessionMirror();
    var sCompact = document.getElementById("settings-compact");
    var sDelete = document.getElementById("settings-delete");
    var sFork = document.getElementById("settings-fork");
    var sRename = document.getElementById("settings-rename");
    var sMove = document.getElementById("settings-move");
    if (sCompact && document.getElementById("session-compact")) sCompact.addEventListener("click", function(){ document.getElementById("session-compact").click(); });
    if (sDelete && document.getElementById("session-delete")) sDelete.addEventListener("click", function(){ document.getElementById("session-delete").click(); });
    if (sFork && document.getElementById("session-fork")) sFork.addEventListener("click", function(){ document.getElementById("session-fork").click(); });
    if (sRename && document.getElementById("session-rename")) sRename.addEventListener("click", function(){ document.getElementById("session-rename").click(); });
    if (sMove && document.getElementById("session-move")) sMove.addEventListener("click", function(){ document.getElementById("session-move").click(); });
  })();
} catch(_){}


// # prompt for knowledge — typing # shows collections to inject context
var kbMentionActive = false;
var kbMentionIndex = 0;
function kbMentionQuery() {
  var v = el.task.value;
  var hashAt = v.lastIndexOf("#");
  if (hashAt === -1) return null;
  if (hashAt > 0 && v.charAt(hashAt - 1) !== " " && v.charAt(hashAt - 1) !== "\n") return null;
  var q = v.slice(hashAt + 1).toLowerCase();
  if (q.indexOf(" ") !== -1 || q.indexOf("\n") !== -1) return null;
  return { at: hashAt, q: q };
}
function renderKbMentionList() {
  var mq = kbMentionQuery();
  if (!mq) { kbMentionActive = false; el.promptList.hidden = true; return; }
  fetch("/api/knowledge").then(function(r){ return r.json(); }).then(function(data){
    var cols = (data && data.collections) || [];
    var matches = cols.filter(function(c){ return c.title.toLowerCase().indexOf(mq.q) !== -1 || c.id.toLowerCase().indexOf(mq.q) !== -1; }).slice(0, 6);
    if (!matches.length) { el.promptList.hidden = true; kbMentionActive = false; return; }
    el.promptList.textContent = "";
    kbMentionActive = true;
    kbMentionIndex = Math.min(kbMentionIndex, matches.length - 1);
    matches.forEach(function(c, i){
      var li = document.createElement("li");
      li.className = "palette-item"; li.id = "prompt-item-" + i;
      li.setAttribute("role","option"); li.setAttribute("aria-selected", String(i===kbMentionIndex));
      var k = document.createElement("span"); k.className="palette-kind"; k.textContent="# " + c.title; li.appendChild(k);
      var label = document.createElement("span"); label.className="palette-label"; label.textContent=c.doc_count + " docs"; li.appendChild(label);
      li.addEventListener("mousedown", function(e){
        e.preventDefault();
        if (typeof kbSelected !== "undefined" && kbSelected.indexOf(c.id) === -1) { kbSelected.push(c.id); try { window.localStorage.setItem("clanker.knowledge", JSON.stringify(kbSelected)); } catch(_){} } 
        var before = el.task.value.slice(0, mq.at);
        var after = el.task.value.slice(mq.at + 1 + mq.q.length);
        el.task.value = before + "#" + c.title + " " + after;
        kbMentionActive = false;
        el.promptList.hidden = true;
        el.task.focus();
        var hint = document.getElementById("knowledge-hint");
        if (hint) hint.textContent = kbSelected.length + " collection(s) will be included in the next prompt.";
      });
      el.promptList.appendChild(li);
    });
    el.promptList.hidden = false;
    el.task.setAttribute("aria-expanded","true");
    el.task.setAttribute("aria-activedescendant","prompt-item-"+kbMentionIndex);
  }).catch(function(){});
}
// Integrated input handler so #knowledge and / prompts + Delete share one promptList cleanly
function integratedTaskInputHandler(){
  var mq = kbMentionQuery();
  if (mq && mq.q.length >= 0) {
    // Only trigger knowledge suggest when the # is the trailing token and not mid-slash
    var beforeHash = el.task.value.slice(0, mq.at);
    var afterHash = el.task.value.slice(mq.at + 1);
    // If the input is exactly a slash command prefix, prefer slash; otherwise allow #
    var slashQ = (function(){ try{ return slashQuery(); }catch(_){ return null; } })();
    if (!slashQ) {
      renderKbMentionList();
      // slight debounce-friendly: grow still handled by separate autoGrow listener
      return;
    }
  }
  kbMentionActive = false;
  taskInputHandler();
}
el.task.removeEventListener("input", taskInputHandler);
el.task.addEventListener("input", integratedTaskInputHandler);

renderSessionChip();
renderSessionOptions([]);
setBusy(false);
// A reload should not cost the sentence you were in the middle of writing.
restoreDraft();
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
/* The full hash is handed to showView, whose prefix parsing resolves deep
   links (#runs/<id>, #board/<id>, #arena/<id>, #knowledge/<id>,
   #chat?session=<id>) that a bare view-name check used to drop on load. */
var openingView = openingHash || lastView() || "chat";

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
updateComposerModeHint();
// Only the opening view's data is fetched now; the rest load when opened.
showView(openingView, false);
/* Reopening the page used to show an empty transcript even when the picker
   said the conversation had nine messages: nothing ever fetched them. The
   conversation you were last in is replayed, so a reload resumes rather
   than restarts. */
Promise.all([loadSessions(), loadWorkspaces()]).then(function () {
  var meta = currentSessionMeta();
  if (meta) setCurrentWorkspace(meta.workspace || "", { silent: true });
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

/* ---- config editor (System view) ----------------------------------------
   Raw TOML editing with validate-before-write: POST /api/config/raw refuses
   a config that does not load, so the server never leaves its last known
   good state; a valid save hot-restarts serve into the new config. The
   highlight is the overlay trick: the textarea owns the text and the caret,
   the <pre> behind it owns the colors. */
(function bindConfigEditor() {
  var fileSel = document.getElementById("config-editor-file");
  var text = document.getElementById("config-editor-text");
  var code = document.getElementById("config-editor-code");
  var note = document.getElementById("config-editor-note");
  var saveBtn = document.getElementById("config-editor-save");
  var reloadBtn = document.getElementById("config-editor-reload");
  if (!fileSel || !text || !code) return;

  function setNote(msg) { if (note) note.textContent = msg; }

  var lastFile = fileSel.value;
  var savedText = "";
  function isDirty() { return text.value !== savedText; }
  function markClean() { savedText = text.value; }

  function paint() {
    loadHljs().then(function () {
      var out = window.hljs.highlight(text.value, { language: "toml", ignoreIllegals: true });
      code.innerHTML = out.value;
      // Trailing newline keeps the pre as tall as the textarea's last line.
      code.appendChild(document.createTextNode("\n"));
    }).catch(function () { code.textContent = text.value; });
  }

  function syncScroll() {
    var pre = code.parentElement;
    pre.scrollTop = text.scrollTop;
    pre.scrollLeft = text.scrollLeft;
  }

  function load() {
    setNote("");
    fetch("/api/config/raw?file=" + encodeURIComponent(fileSel.value))
      .then(readJson)
      .then(function (d) {
        text.value = d.content || "";
        markClean();
        paint();
        syncScroll();
      })
      .catch(function (err) { setNote("Could not read " + fileSel.value + ": " + err.message); });
  }

  function confirmDiscard(next) {
    if (!isDirty()) { next(); return; }
    uiConfirm("Discard unsaved changes to " + lastFile + "?", { danger: true, confirmLabel: "Discard" }).then(function (yes) {
      if (yes) next();
    });
  }

  function save() {
    saveBtn.disabled = true;
    setNote("Validating…");
    fetch("/api/config/raw", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ file: fileSel.value, content: text.value }),
    })
      .then(readJson)
      .then(function (d) {
        markClean();
        setNote("Saved. " + (d.applied || "Hot reload applies it."));
      })
      .catch(function (err) {
        // readJson surfaces the server's {error} message on a 400.
        setNote("Refused: " + err.message + " — the running config is unchanged.");
      })
      .finally(function () { saveBtn.disabled = false; });
  }

  text.addEventListener("input", function () {
    paint();
    if (isDirty()) setNote("Unsaved changes.");
    else setNote("");
  });
  text.addEventListener("scroll", syncScroll);
  fileSel.addEventListener("change", function () {
    var nextFile = fileSel.value;
    if (nextFile === lastFile) return;
    if (!isDirty()) { lastFile = nextFile; load(); return; }
    fileSel.value = lastFile;
    confirmDiscard(function () {
      fileSel.value = nextFile;
      lastFile = nextFile;
      load();
    });
  });
  if (reloadBtn) reloadBtn.addEventListener("click", function () { confirmDiscard(load); });
  if (saveBtn) saveBtn.addEventListener("click", save);
  window.addEventListener("beforeunload", function (e) {
    if (!isDirty()) return;
    e.preventDefault();
    e.returnValue = "";
  });
  // Tab inserts two spaces instead of leaving the editor.
  text.addEventListener("keydown", function (e) {
    if (e.key !== "Tab") return;
    e.preventDefault();
    var s = text.selectionStart;
    text.setRangeText("  ", s, text.selectionEnd, "end");
    paint();
  });
  load();
})();
