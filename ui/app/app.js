import { readJson as utilReadJson, classifyLoadFailure as utilClassifyLoadFailure, newSessionId as utilNewSessionId, fmtBytes as utilFmtBytes, clip as utilClip, sessionLabel as utilSessionLabel, sessionMatchesFilter as utilSessionMatchesFilter, summarizeTitle as utilSummarizeTitle, recencyGroup as utilRecencyGroup, fmtInt as utilFmtInt, fmtMs as utilFmtMs, fmtCost as utilFmtCost, formatChatTime as utilFormatChatTime, fuzzyMatch as utilFuzzyMatch, escapeHtml as utilEscapeHtml, searchFold as utilSearchFold, view_digit_max, wireRefresh } from "./core/utils.js";
import { T as vanT, bind as vanBind, toast as uiToast, skeletonRows as vanSkeletonRows, setTurnPhase as vanSetTurnPhase, UI as vanUI, state as uiState, add as uiAdd, uiConfirm, uiPrompt, upgradePfButton, upgradePfButtons, upgradePfChip, upgradePfUi, showLoadError } from "./core/ui.js";
import { icon as iconFn } from "./core/icons.js";
import { vendorLoads as vendorLoadsMod, loadVendor as loadVendorMod, loadHljs as loadHljsMod, registerToml as registerTomlMod, copyText as copyTextMod, scrollTo as vendorScrollTo } from "./core/vendor.js";
import { loadTheme as loadThemeMod, applyTheme as applyThemeMod, bindThemeToggle as bindThemeToggleMod } from "./core/theme.js";
import { SLASH_CMDS, slashReady, runSlashEntry } from "./core/slash.js";
import { dmRoom as dmRoomMod, dmSafeName as dmSafeNameMod, dmPartner as dmPartnerMod, isDm as isDmMod, clankerMark as clankerMarkMod, CLANKER_MARKS as CLANKER_MARKSMod, messageKey as chatMessageKey, hasServerId as chatHasServerId } from "./core/chat.js";
import { runLabel as runLabelMod, modelLabel as modelLabelMod, chatRoomLabel as chatRoomLabelMod } from "./core/labels.js";
import { makeLineSplitter as makeLineSplitterMod, pumpInto, onLive as liveOn, liveOk as liveIsUp } from "./core/stream.js";
import { makeSteerLedger, steerAdd, steerMark, steerApplyOldest, steerUnapplied, steerClear, steerPreview, steeredText as steeredMessageText, renderSteerList } from "./core/steer.js";
import { INLINE_RE as mdINLINE_RE, inlineInto as mdInlineInto, paragraphInto as mdParagraphInto, tableRow as mdTableRow, renderMarkdown as mdRenderMarkdown, renderMarkdownWithFences as mdRenderMarkdownWithFences, buildCodeBlock as mdBuildCodeBlock, finalizeAnswer as mdFinalizeAnswer } from "./lib/markdown.js";
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
import { getProviderCache as mpProviderCache, getModelIndex as mpModelIndex, loadProviders as mpLoadProviders, runOptions as mpRunOptions, syncSubmitLabel as mpSyncSubmit, bindModelPicker as mpBind, applyChatPrefs as mpApplyChatPrefs, openModelPicker as mpOpen, toggleModelPicker as mpToggle, setModelChipLabel as mpSetChip } from "./core/modelpicker.js";
import { goalStatusLabel } from "./core/goals.js";
import { createAnswerHead, ANSWER_LABEL } from "./core/ai-disclosure.js";
import { loadPrefs as cpLoad, savePrefs as cpSave, prefsFor as cpFor, setPref as cpSet, dropPref as cpDrop, copyPref as cpCopy } from "./core/chatprefs.js";
import { applyDoneStats, applyLiveUsage, beginLiveTurn, emptyRunMetrics, formatRunMetricsParts, liveElapsedMs, noteFirstToken, noteLiveChars } from "./core/run-metrics.js";

/* The deferred stylesheets (PatternFly, views.css) are armed by
   preact-boot.js, not here: this module evaluates only once its whole static
   import graph has arrived, which is the wrong moment to be applying the
   page's layout framework. */

document.addEventListener("DOMContentLoaded", function () {
"use strict";

var readJson = utilReadJson;
var classifyLoadFailure = utilClassifyLoadFailure;
var newSessionId = utilNewSessionId;
var fmtBytes = utilFmtBytes;
var clip = utilClip;
var sessionLabel = utilSessionLabel;
var sessionMatchesFilter = utilSessionMatchesFilter;
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
  // The wrapper that carries role=combobox, which ARIA does not allow on the
  // textarea itself. See setPromptListOpen().
  taskCombobox: document.getElementById("task-combobox"),
  attachments: document.getElementById("attachments"),
  submit: document.getElementById("submit"),
  cancel: document.getElementById("cancel"),
  steerRow: document.getElementById("steer-row"),
  steerInput: document.getElementById("steer-input"),
  steerBtn: document.getElementById("steer-btn"),
  steerHint: document.getElementById("steer-hint"),
  steerSent: document.getElementById("steer-sent"),
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
  runList: document.getElementById("run-list"),
  runListCount: document.getElementById("run-list-count"),
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
  paramEffort: document.getElementById("param-effort"),
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

// Write-only: nothing reads the key back (a visit always starts a new
// conversation), but the first turn and every later switch need a stable id.
// localStorage throws in private mode and over quota, and a session id that
// did not persist is not worth failing the switch over.
function rememberSession(id) {
  try { window.localStorage.setItem("clanker.session", id); } catch (e) {}
}

function loadSession() {
  // A visit starts a new conversation. The last session stays in the
  // sidebar; opening it is a click. `#chat?session=` is the explicit
  // resume path.
  var id = newSessionId();
  rememberSession(id);
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

/* ---------- per-conversation model and reasoning effort ----------

   Same idea as the drafts above, for the composer's two run selects: the
   model and the reasoning effort a conversation runs on belong to it, not to
   the browser. `core/chatprefs.js` owns the store's shape and bounds; the
   hooks below are all the model picker is given, so it never has to know
   which conversation is open. */
var chatPrefs = cpLoad();

function chatPrefsGet() {
  return cpFor(chatPrefs, sessionId);
}

function chatPrefsSet(patch) {
  cpSet(chatPrefs, sessionId, patch);
  cpSave(chatPrefs);
}

function chatPrefsDrop(id) {
  cpDrop(chatPrefs, id || sessionId);
  cpSave(chatPrefs);
}

/* A fork, a branch or an import continues under a new id; the copy keeps
   running on what it was forked from. */
function chatPrefsCarry(fromId, toId) {
  cpCopy(chatPrefs, fromId, toId);
  cpSave(chatPrefs);
}

/* The selects, the Advanced fold summary and the idle hint all describe the
   conversation's current pin, so they move together. Deliberately not a
   dispatched `change` event: that would re-write the browser default, which
   is the cross-chat leak this store exists to close. */
function applyChatPrefs() {
  mpApplyChatPrefs();
  updateComposerModeHint();
}

/* A conversation that never had a select touched is pinned by its first turn,
   to whatever it is about to run on. Without this, a chat with history would
   still follow a model chosen later in another tab. */
function chatPrefsPinFirstTurn() {
  if (chatPrefsGet()) return;
  chatPrefsSet({
    model: (el.modelSelect && el.modelSelect.value) || "",
    effort: (el.paramEffort && el.paramEffort.value) || ""
  });
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
bindThemeToggleMod(el.themeToggle, function (next) {
  theme = next;
  var themeLabel = document.getElementById("settings-theme-label");
  if (themeLabel) themeLabel.textContent = next;
});

el.newChat.addEventListener("click", function () {
  if (busy) return;
  if (currentView !== "chat") showView("chat", false);
  // The half-written task belongs to the conversation being left, so it is
  // saved there and the new one opens with an empty composer.
  flushDraft();
  sessionId = newSessionId();
  el.task.value = "";
  rememberSession(sessionId);
  // The selects are shared DOM: a new chat starts on the browser default, not
  // on whatever the conversation just left was pinned to.
  applyChatPrefs();
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
/* Why the rail has nothing to show, when it has nothing to show. Null is
   "the list loaded and it is what it is"; anything else is the classified
   failure the rail renders instead of an empty state. Only loadSessions
   writes it, so a re-render for a filter or a pin cannot clear a failure the
   page has not retried. */
var railFailure = null;

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
    workspace: currentWorkspace,
    failure: railFailure
  };
  renderSessionTitle();
}

function railRowFor(s, current) {
  var rawTitle = (s.title || "").replace(/\s+/g, " ").trim();
  var title = summarizeTitle(s.title || "");
  var archivedMark = s.archived ? " · archived" : "";
  var meta = s.messages + (s.messages === 1 ? " msg" : " msgs") + archivedMark +
    (typeof s.bytes === "number" && s.bytes > 0 ? "  ·  " + fmtBytes(s.bytes) : "");
  var open = s.id === current;

  var row = T.button({
    type: "button",
    class: "rail-item",
    title: rawTitle || title,
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
    title: isPinned(s.id) ? "Stop pinning this conversation" : "Keep this conversation at the top of the list",
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
    return sessionMatchesFilter(item, s.filter);
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
  /* A failed load is stated where the rows would have been, with the retry
     next to it. It answers before the filter's own empty row, because "no
     title matches" describes a list that loaded — saying that over a list
     that never arrived is the same swallowed failure in a different shape. */
  if (!matched && s.failure) {
    if (s.failure.kind === "disabled") {
      out.push(T.li({ class: "rail-empty" }, "Conversation history is off (" + s.failure.message + ")."));
    } else {
      out.push(T.li({ class: "rail-empty" },
        "Could not load conversations: " + s.failure.message + " ",
        T.button({
          type: "button",
          class: "rail-empty-action",
          onclick: function () { loadSessions(); }
        }, "Try again")));
    }
  } else if (!matched && s.filter) {
    out.push(T.li({ class: "rail-empty" },
      "No title matches. ",
      T.button({
        type: "button",
        class: "rail-empty-action",
        onclick: function () {
          var q = s.filter;
          window._pendingSearchQuery = q;
          showView("search", true);
        }
      }, "Search messages"),
      " or ",
      T.button({
        type: "button",
        class: "rail-empty-action",
        onclick: function () {
          if (el.sessionFilter) {
            el.sessionFilter.value = "";
            el.sessionFilter.focus();
          }
          renderSessionOptions(null);
        }
      }, "clear the filter")));
  }
  return out;
});

function renderSessionTitle() {
  var meta = currentSessionMeta();
  if (!meta) {
    el.sessionTitle.textContent = "New conversation";
    el.sessionTitle.title = "Unsaved conversation";
    renderContextMeter();
    return;
  }
  var full = (meta.title || "").replace(/\s+/g, " ").trim() || "Untitled conversation";
  el.sessionTitle.textContent = full;
  var bits = [full, meta.messages + (meta.messages === 1 ? " msg" : " msgs")];
  if (typeof meta.bytes === "number" && meta.bytes > 0) bits.push(fmtBytes(meta.bytes));
  el.sessionTitle.title = bits.join("  ·  ");
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
      railFailure = null;
      renderSessionOptions(data.sessions || []);
    })
    .catch(function (err) {
      // Sessions may simply be disabled, and the picker still has to describe
      // the conversation the composer is using. Every other failure gets a
      // visible failed state instead: an empty list and a dead server used to
      // look the same.
      railFailure = classifyLoadFailure(err);
      renderSessionOptions([]);
      // The rail row is the visible half; this is the same sentence for a
      // screen reader, and only for the kind worth acting on — a module the
      // operator switched off would announce itself on every load.
      if (railFailure.retry && el.sessionStatus) {
        el.sessionStatus.textContent = "Could not load conversations: " + railFailure.message;
      }
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
   same object rather than two renderings of the same thing that drift.

   The replay is chunked: each turn card costs a markdown parse of the
   question, a fence pass and a card of buttons over the answer, and a long
   session is hundreds of turns. Building them all in one synchronous forEach
   froze the page for the whole load — the status line kept saying "Loading
   conversation…" while every card of a 500-message session was rebuilt in a
   single main-thread task. A time-boxed batch per tick yields to paint and
   input between batches, so the transcript visibly fills in and the page
   stays live. Resolves when the last card is in the DOM; callers that jump
   to a search hit or report "Loaded N messages." must chain on it. */
function renderSessionHistory(messages) {
  el.transcript.textContent = "";
  replayedSpans = [];
  var pendingTurn = null;
  var lastTask = null;
  var span = null;
  var idx = 0;
  return new Promise(function (resolve, reject) {
    function step() {
      var until = performance.now() + replay_chunk_ms;
      try {
        while (idx < messages.length && performance.now() < until) {
          var m = messages[idx];
          // A steering message is persisted as a user turn the server marks
          // `steered` (older transcripts carry the framing sentence in the
          // text instead). Rendered as a plain user message it closed the
          // real question as unanswered and impersonated the user with text
          // they never typed — show it as the mid-run interjection it was,
          // inside the turn it steered.
          var steeredText = m.role === "user" && pendingTurn ? steeredMessageText(m) : null;
          if (steeredText != null) {
            if (span) span.to = idx;
            appendText(pendingTurn, "\n[ steered mid-run: " + steeredText + " ]\n", true);
          } else if (m.role === "user") {
            // A question with no reply before the next one: close it off
            // rather than letting the next answer attach to the wrong one.
            if (pendingTurn) markTurnUnanswered(pendingTurn);
            lastTask = m.content;
            pendingTurn = createTurn(m.content);
            span = { from: idx, to: idx };
            replayedSpans.push(span);
          } else {
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
            // The task is passed back so Run again and Edit & resend survive
            // a reload; the numbers cannot, because they were never saved
            // with the session.
            renderStats(pendingTurn, {}, lastTask);
            pendingTurn = null;
          }
          idx += 1;
        }
      } catch (err) {
        reject(err);
        return;
      }
      if (idx < messages.length) {
        window.setTimeout(step, 0);
      } else {
        if (pendingTurn) markTurnUnanswered(pendingTurn);
        resolve();
      }
    }
    step();
  });
}

/* Cap on synchronous work per tick while a saved conversation is rebuilt
   into the DOM: long enough to make real progress per frame, short enough
   that the longest session never blocks a frame for more than a fraction of
   it. Browsers budget ~50 ms before a task counts as long; 12 ms leaves the
   rest of the frame for paint and input. */
var replay_chunk_ms = 12;

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
  rememberSession(sessionId);
  // Puts this conversation's own model and effort back on the selects.
  applyChatPrefs();
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
      // The tail runs once the last card is in the DOM: the empty-state, the
      // "Loaded N messages." line, the draft and a search jump all assume the
      // replay finished. Chaining here also means a replay failure lands in
      // the same catch below that a synchronous one did.
      return renderSessionHistory(data.messages || []).then(function () {
        syncTranscriptEmpty();
        var n = (data.messages || []).length;
        el.sessionStatus.textContent = "Loaded " + n + (n === 1 ? " message." : " messages.");
        restoreDraft();
        if (jump) jumpToMessage(jump.index, jump.query);
      });
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

/* Session actions report here. #session-status is an sr-only live region, so
   a message that lands only there is invisible to a sighted user — which
   reads as "the button does nothing". Toast it; the live region stays as the
   fallback when the toast host is missing (toasts are themselves aria-live,
   so writing both would announce everything twice). */
function sessionNotice(msg) {
  if (!uiToast(msg)) el.sessionStatus.textContent = msg;
}

/* knownSessions refreshes only when the conversation list reloads, and a run
   that ended early (stopped, dropped connection, no done event) skips that
   reload — the transcript then has turns the picker does not know about, and
   every session action died on the missing meta with no visible feedback.
   Refresh once and retry before giving up. */
function withSessionMeta(then) {
  var meta = currentSessionMeta();
  if (meta) { then(meta); return; }
  loadSessions().then(function () {
    var found = currentSessionMeta();
    if (found) then(found);
    else sessionNotice("This conversation has no saved turns yet.");
  });
}

/* A fork is a branch you can abandon: the same messages under a new id, so
   trying a different direction never costs the conversation it came from.
   Branching is the same move with a cut point, so both go through here: POST,
   adopt the id the server answers with, and continue in the copy. */
function switchToSessionCopy(path, btn, verb, doneMessage) {
  if (!currentSessionMeta()) {
    el.sessionStatus.textContent = "This conversation has no saved turns yet.";
    return;
  }
  btn.disabled = true;
  fetch("/api/sessions/" + encodeURIComponent(sessionId) + path, { method: "POST" })
    .then(function (r) {
      return r.json().then(function (data) {
        if (!r.ok || !data.ok || !data.id) throw new Error(data.error || ("HTTP " + r.status));
        return data.id;
      });
    })
    .then(function (newId) {
      chatPrefsCarry(sessionId, newId);
      sessionId = newId;
      rememberSession(sessionId);
      renderSessionChip();
      el.sessionStatus.textContent = doneMessage;
      return loadSessions();
    })
    .catch(function (err) {
      el.sessionStatus.textContent = "Could not " + verb + ": " + err.message;
    })
    .finally(function () { btn.disabled = false; });
}

el.sessionFork.addEventListener("click", function () {
  switchToSessionCopy("/fork", el.sessionFork, "fork", "Forked. You are now in the copy.");
});

el.sessionRename.addEventListener("click", function () {
  withSessionMeta(function (meta) {
    textPrompt({ title: "Rename conversation", label: "Title", value: meta.title || "" }).then(function (next) {
      if (next === null) return;
      next = next.trim();
      if (!next) {
        sessionNotice("A conversation needs a title.");
        return;
      }
      el.sessionRename.disabled = true;
      fetch("/api/sessions/" + encodeURIComponent(sessionId), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title: next })
      }).then(readJson).then(function () {
        sessionNotice("Renamed to " + next + ".");
        return loadSessions();
      }).catch(function (err) {
        sessionNotice("Could not rename: " + err.message);
      }).finally(function () { el.sessionRename.disabled = false; });
    });
  });
});

el.sessionDelete.addEventListener("click", function () {
  withSessionMeta(function (meta) {
    // Deleting a transcript cannot be undone from here, so it is confirmed.
    // The run graphs survive it: they record runs that really happened and are
    // addressed by run id, not by session.
    uiConfirm("Delete \"" + (meta.title || sessionId) + "\"? This cannot be undone. Its recorded runs are kept.", { danger: true, confirmLabel: "Delete" }).then(function (yes) {
      if (!yes) return;
      el.sessionDelete.disabled = true;
      fetch("/api/sessions/" + encodeURIComponent(sessionId), { method: "DELETE" })
        .then(readJson)
        .then(function () {
          sessionNotice("Deleted. Started a new conversation.");
          // Nothing left for the draft or the model pin to belong to.
          dropDraft(sessionId);
          chatPrefsDrop(sessionId);
          sessionId = newSessionId();
          rememberSession(sessionId);
          applyChatPrefs();
          el.transcript.textContent = "";
          renderSessionChip();
          return loadSessions();
        }).catch(function (err) {
          sessionNotice("Could not delete: " + err.message);
        }).finally(function () { el.sessionDelete.disabled = false; });
    });
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
    el.steerSent.textContent = "";
    el.steerSent.hidden = true;
    updateComposerModeHint();
  }
  // The send circle yields its spot to the stop circle while a turn runs
  // (the focus handoff below keeps keyboard users on the live control).
  el.submit.hidden = busy;
  if (!busy) syncSubmitLabel();
  document.title = busy ? "Running… · clanker" : "clanker";
}

/* The disclosure starts closed, so a checked Plan / Isolated box used to
   vanish behind "Run shape" with no lamp on the summary. Isolated can also
   arrive pre-checked from the server default. The summary is the only
   control still visible, so it has to name what is on. */
function syncRunShape() {
  var shape = document.getElementById("run-shape");
  if (!shape) return;
  var summary = shape.querySelector("summary");
  var bits = [];
  if (el.planMode && el.planMode.checked) bits.push("Plan");
  if (el.researchMode && el.researchMode.checked) bits.push("Research");
  if (el.unlimitedIterations && el.unlimitedIterations.checked) bits.push("Long run");
  if (el.worktreeMode && el.worktreeMode.checked) bits.push("Isolated");
  if (summary) {
    summary.textContent = bits.length ? bits.join(" · ") : "Run shape";
    summary.title = bits.length
      ? "This run: " + bits.join(", ") + ". Click to change."
      : "Plan, research, long run, and isolated worktree";
  }
  if (bits.length) shape.setAttribute("data-active", "true");
  else shape.removeAttribute("data-active");
  syncAdvancedSummary();
}

/* A pinned reasoning effort must stay visible when the Advanced fold is
   closed, same rule as the Run shape toggles. */
function syncAdvancedSummary() {
  var params = document.getElementById("params");
  if (!params) return;
  var summary = params.querySelector("summary");
  if (!summary) return;
  var effort = (el.paramEffort && el.paramEffort.value) || "";
  summary.textContent = effort ? "Advanced: effort " + effort : "Advanced";
  summary.title = effort
    ? "Reasoning effort " + effort + ", pinned for this conversation and sent with each new message. A message already running keeps the effort it started with. Click to change."
    : "Fallback provider, sampling and reasoning-effort overrides";
  if (effort) params.setAttribute("data-active", "true");
  else params.removeAttribute("data-active");
}

/** Idle composer hint for plan/research toggles (matches TUI status bar labels). */
function updateComposerModeHint() {
  syncRunShape();
  if (busy) return;
  var parts = [];
  if (el.planMode && el.planMode.checked) parts.push("Plan mode · write tools refused");
  if (el.researchMode && el.researchMode.checked) parts.push("Research mode · web search preferred");
  if (el.unlimitedIterations && el.unlimitedIterations.checked) parts.push("Long run · 1000-step budget");
  if (el.worktreeMode && el.worktreeMode.checked) parts.push("Isolated worktree · shared checkout untouched");
  if (el.paramEffort && el.paramEffort.value) parts.push("Effort " + el.paramEffort.value + " · pinned for this chat");
  if (attachImages.length) {
    parts.push(attachImages.length + (attachImages.length === 1 ? " image attached" : " images attached"));
  }
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
var steerLedger = makeSteerLedger();
function paintSteerList() {
  renderSteerList(steerLedger, el.steerSent, document);
  el.steerSent.hidden = steerLedger.entries.length === 0;
}
function sendSteerChat() {
  var msg = (el.steerInput.value || "").trim();
  if (!msg) { el.steerHint.textContent = "Type a message to steer the running turn."; return; }
  // Cleared before the POST, so a repeated Ctrl+Enter cannot send the same
  // text twice — the second press hits the blank guard above. The message
  // itself is not lost: the ledger entry below carries it from here on.
  el.steerInput.value = "";
  el.steerHint.textContent = "";
  var entry = steerAdd(steerLedger, msg);
  paintSteerList();
  fetch("/api/steer", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ session: sessionId, message: msg })
  }).then(function (resp) {
    if (resp.ok) {
      // The stream's "applied" event can beat this 200 — don't demote.
      if (entry.state === "sending") steerMark(entry, "queued");
    } else {
      return resp.json().then(function (j) {
        steerMark(entry, "failed", j.error || ("HTTP " + resp.status));
      }).catch(function () {
        steerMark(entry, "failed", "HTTP " + resp.status);
      });
    }
  }).catch(function (err) {
    steerMark(entry, "failed", err && err.message ? err.message : "network error");
  }).finally(paintSteerList);
}
el.steerBtn.addEventListener("click", sendSteerChat);
el.steerInput.addEventListener("keydown", function (e) {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); sendSteerChat(); }
});

/* Each submitted task gets its own turn card, appended below the last —
   a real conversation history instead of one box that forgets the past
   answer as soon as you ask another question. */
function turnPromptSource(turnRoot) {
  var you = turnRoot && turnRoot.querySelector ? turnRoot.querySelector(".turn-you") : null;
  if (!you) return "";
  if (you._taskSource != null) return you._taskSource;
  var author = you.querySelector(".turn-author");
  return author ? you.textContent.slice(author.textContent.length) : (you.textContent || "");
}

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
  you.className = "turn-you md";
  // Kept on the node so Edit / Copy / export still see the source after
  // the bubble is rendered as markdown (textContent would drop the marks).
  you._taskSource = task;
  // Real text, not generated content: a name in ::before is not announced,
  // not selected, not copied and not exported.
  var youHead = document.createElement("div");
  youHead.className = "turn-you-head";
  var author = document.createElement("span");
  author.className = "turn-author";
  author.textContent = "you";
  youHead.appendChild(author);
  you.appendChild(youHead);
  var youBody = document.createElement("div");
  youBody.className = "turn-you-body";
  try { youBody.appendChild(renderMarkdownWithFences(task)); }
  catch (_e) { youBody.textContent = task; }
  you.appendChild(youBody);

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
  // The server already appends recovery guidance to /api/run failures
  // (enrichRunError: "try `clanker providers models`", "run clanker
  // doctor", "switch model", ...). Re-classifying an enriched message
  // stacks a second, overlapping hint inside the first — "…request body
  // is invalid (provider rejected the request; …)" — so defer to the
  // server when it already named a next action. Raw tool errors (the
  // other caller) carry none of these phrases, so their hint still fires.
  var serverGuided = [
    "providers models", "clanker doctor", "switch model",
    "slow or unreachable", "base_url", "vision-capable",
    "is the server still running"
  ];
  for (var i = 0; i < serverGuided.length; i++)
    if (m.indexOf(serverGuided[i]) !== -1) return "";
  if (m.indexOf("401") !== -1 || m.indexOf("unauthorized") !== -1 || m.indexOf("authentication") !== -1)
    return " (check API key; run clanker doctor)";
  if (m.indexOf("429") !== -1 || m.indexOf("rate limit") !== -1 || m.indexOf("rate_limit") !== -1)
    return " (rate limited; wait or switch model)";
  if (m.indexOf("http 400") !== -1 || m.indexOf("bad request") !== -1)
    return " (provider rejected the request; the model may not exist, or the request is invalid; pick another in the model pill)";
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
var renderMarkdownWithFences = mdRenderMarkdownWithFences;
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

function notifyTurnDone(task) {
  try {
    if (!document.hidden || !("Notification" in window)) return;
    if (Notification.permission === "granted") {
      var n = new Notification("clanker finished", {
        body: String(task || "").slice(0, 120),
        tag: "clanker-turn-" + sessionId,
      });
      n.onclick = function () { try { window.focus(); } catch (_) {} n.close(); };
    } else if (Notification.permission !== "denied") {
      Notification.requestPermission().catch(function () {});
    }
  } catch (_) {}
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
  /* Name who answered this turn. A mid-chat model or effort switch is
     otherwise invisible: the run applies it, but nothing on the turn says
     so, and the switch looks like it never happened. */
  if (stats.served_by) {
    parts.push(stats.served_by + (stats.model ? " " + stats.model : ""));
  }
  if (stats.reasoning_effort) parts.push("effort " + stats.reasoning_effort);
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
  actions.style.gap = "var(--space-2)";
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
  var upBtn = document.createElement("button");
  upBtn.type = "button";
  upBtn.className = "secondary";
  upBtn.textContent = "Up";
  upBtn.title = "Record a thumbs-up. Never sent to the model.";
  upgradePfButton(upBtn);
  var downBtn = document.createElement("button");
  downBtn.type = "button";
  downBtn.className = "secondary";
  downBtn.textContent = "Down";
  downBtn.title = "Record a thumbs-down. Never sent to the model.";
  upgradePfButton(downBtn);
  function sendFeedback(rating, btn) {
    var n = parseInt((turn.root.querySelector(".turn-depth") || {}).textContent, 10) || 0;
    fetch("/api/feedback", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ rating: rating, session: sessionId, turn: n }),
    }).then(function (r) { return r.json(); }).then(function (data) {
      btn.textContent = data && data.ok ? "Saved" : "Failed";
    }).catch(function () { btn.textContent = "Failed"; });
  }
  upBtn.addEventListener("click", function () { sendFeedback("up", upBtn); });
  downBtn.addEventListener("click", function () { sendFeedback("down", downBtn); });
  actions.appendChild(upBtn);
  actions.appendChild(downBtn);

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
      // The turn's own stratum index, which is the same 1-based number the
      // server's branch endpoint cuts the transcript at.
      var n = parseInt((turn.root.querySelector(".turn-depth") || {}).textContent, 10) || 1;
      switchToSessionCopy("/branch/" + n, branchBtn, "branch", "Branched at turn " + n + ". You are now in the copy.");
    });
    actions.appendChild(branchBtn);

    // Branch timeline: which forks came from here
    (function(){
      if (!knownSessions || !knownSessions.length) return;
      var title = (turnPromptSource(turn.root) || "").trim();
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
      var promptText = turnPromptSource(turn.root) || task || "";
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
    updateComposerModeHint();
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
el.onAttachmentsChange = updateComposerModeHint;
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
if (el.unlimitedIterations) el.unlimitedIterations.addEventListener("change", updateComposerModeHint);
if (el.worktreeMode) el.worktreeMode.addEventListener("change", updateComposerModeHint);
if (el.paramEffort) el.paramEffort.addEventListener("change", updateComposerModeHint);
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
    btn.setAttribute("aria-label", btn.title);
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

var pendingFiles = [];
function renderFileChips() {
  var hostEl = document.getElementById("file-chips") || el.attachments;
  if (!hostEl) return;
  if (!pendingFiles.length && hostEl.id === "file-chips") { hostEl.hidden = true; hostEl.textContent = ""; return; }
  if (hostEl.id === "file-chips") {
    hostEl.hidden = pendingFiles.length === 0;
    hostEl.textContent = "";
    pendingFiles.forEach(function (path, i) {
      var chip = document.createElement("button");
      chip.type = "button";
      chip.className = "chip";
      chip.textContent = "@" + path + " ×";
      chip.title = "Remove " + path;
      chip.addEventListener("click", function () {
        pendingFiles.splice(i, 1);
        renderFileChips();
      });
      hostEl.appendChild(chip);
    });
  }
}
function prependPendingFiles(task) {
  if (!pendingFiles.length) return task;
  var prefix = pendingFiles.map(function (p) { return "[File: " + p + "]"; }).join("\n");
  pendingFiles = [];
  renderFileChips();
  return prefix + "\n\n" + task;
}
function fileMentionQuery() {
  var v = el.task.value;
  var at = v.lastIndexOf("@");
  if (at === -1) return null;
  if (at > 0 && v.charAt(at - 1) !== " " && v.charAt(at - 1) !== "\n") return null;
  var q = v.slice(at + 1);
  if (q.indexOf(" ") !== -1 || q.indexOf("\n") !== -1) return null;
  return { at: at, q: q };
}
/* Every keystroke after an `@` starts a listing. The replies are not ordered,
   so a slow listing for `@sr` could land after the one for `@src/` and paint
   the older directory over the newer query. Each request takes a ticket and
   only the newest one is allowed to draw. */
var fileMentionSeq = 0;
function renderFileMentionList() {
  var mq = fileMentionQuery();
  if (!mq) return false;
  var dir = "";
  var slash = mq.q.lastIndexOf("/");
  if (slash !== -1) dir = mq.q.slice(0, slash);
  var needle = (slash === -1 ? mq.q : mq.q.slice(slash + 1)).toLowerCase();
  var seq = ++fileMentionSeq;
  fetch("/api/files?path=" + encodeURIComponent(dir || ".")).then(function (r) { return r.json(); }).then(function (data) {
    if (seq !== fileMentionSeq) return;
    var names = (data && (data.entries || data.files || data.names)) || [];
    var matches = [];
    names.forEach(function (n) {
      var name = typeof n === "string" ? n : (n.name || n.path || "");
      if (!name) return;
      if (needle && name.toLowerCase().indexOf(needle) === -1) return;
      var full = dir ? (dir + "/" + name.replace(/\/$/, "")) : name.replace(/\/$/, "");
      matches.push(full);
    });
    matches = matches.slice(0, 8);
    if (!matches.length) { hidePromptList(); return; }
    el.promptList.textContent = "";
    matches.forEach(function (path, i) {
      var li = document.createElement("li");
      li.className = "palette-item";
      li.id = "prompt-item-" + i;
      li.setAttribute("role", "option");
      li.setAttribute("aria-selected", String(i === 0));
      li.textContent = path;
      li.addEventListener("mousedown", function (e) {
        e.preventDefault();
        if (pendingFiles.indexOf(path) === -1) pendingFiles.push(path);
        var before = el.task.value.slice(0, mq.at);
        var after = el.task.value.slice(mq.at + 1 + mq.q.length);
        el.task.value = before + after;
        renderFileChips();
        hidePromptList();
        el.task.focus();
      });
      el.promptList.appendChild(li);
    });
    el.promptList.hidden = false;
    // The list is a listbox the composer owns. Opening it silently left
    // `aria-expanded="false"`, so a screen reader was never told the popup was
    // there at all; every show and hide goes through the same pair of states
    // now, exactly as the / and # lists do.
    setPromptListOpen(true, "prompt-item-0");
    // A failed listing closes the list rather than leaving a stale one open
    // under an `aria-expanded` that no longer describes the page.
  }).catch(function () { if (seq === fileMentionSeq) hidePromptList(); });
  return true;
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
  el.runMetrics.title = "This visit only. Reloading or opening another conversation clears these numbers.";
  if (!parts.length) {
    el.runMetrics.textContent = "";
    return;
  }
  var cells = [{ key: "scope", text: "This visit" }].concat(parts);
  var kids = el.runMetrics.children;
  if (kids.length !== cells.length) {
    el.runMetrics.textContent = "";
    cells.forEach(function (p) {
      var s = document.createElement("span");
      s.className = "run-metrics-cell" + (p.key === "scope" ? " run-metrics-scope" : "");
      s.setAttribute("data-m", p.key);
      s.textContent = p.text;
      el.runMetrics.appendChild(s);
    });
    return;
  }
  for (var i = 0; i < cells.length; i++) {
    if (kids[i].textContent !== cells[i].text) kids[i].textContent = cells[i].text;
  }
}

function setStatusGoal(goalId) {
  if (!el.statusGoal) return;
  var apply = function () {
    // goalState lives in the lazily loaded goals view module; before the
    // Board/Goals view has been opened this session it is not loaded, so the
    // chip falls back to a plain "active" label until the list has arrived.
    var g = ((goalState && goalState.val) || []).filter(function (x) { return x.id === goalId; })[0];
    el.statusGoal.hidden = false;
    el.statusGoal.textContent = "Goal " + (g ? goalStatusLabel(g, true) : "active");
    el.statusGoal.title = g ? g.objective : goalId;
  };
  apply();
  // A goal can be running without the Board/Goals view ever having been
  // opened; fetch its list so the label above can show the real status.
  loadGoalsModule().then(function (m) { return m.loadGoals(); }).then(apply).catch(function () {});
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
  task = prependPendingFiles(task);

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
    var youHead = turn.root.querySelector(".turn-you-head");
    (youHead || turn.root.querySelector(".turn-you")).appendChild(planBadge);
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
  // This conversation now has history, and history keeps what it ran on: a
  // model chosen later in another tab must not retro-fit it.
  chatPrefsPinFirstTurn();
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
      // The module is lazy: the first todos event of the session pulls it in.
      else if (evt.type === "todos") {
        setStatusTodos(evt.todos);
        loadTodosModule().then(function (m) { try { m.renderTurnTodos(turn, evt.todos); } catch (_t) {} }).catch(function () {});
      }
      else if (evt.type === "goal") { setStatusGoal(evt.id); }
      // A status event is a run lifecycle note (contacting the provider, a
      // steering message being applied) rather than answer text: show it as a
      // bracketed log line, the same way the goals view renders it.
      else if (evt.type === "status") {
        // The applied event names no message; the queue drains oldest-first,
        // so the ledger's oldest pending entry is the one that just landed —
        // echo its text so two applied steers are distinguishable.
        if (evt.message === "steering message applied") {
          var appliedSteer = steerApplyOldest(steerLedger);
          paintSteerList();
          appendText(turn, "\n[ steering applied" + (appliedSteer ? ": " + steerPreview(appliedSteer.text) : "") + " ]\n", true);
        } else {
          appendText(turn, "\n[ " + evt.message + " ]\n", true);
        }
      }
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
        notifyTurnDone(task);
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
          var fragMd2 = renderMarkdownWithFences(pend);
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
      backend: opts.backend || "",
      fallback_provider: opts.fallbackProvider || "",
      temperature: typeof opts.temperature === "number" ? opts.temperature : null,
      top_p: typeof opts.top_p === "number" ? opts.top_p : null,
      reasoning_effort: opts.reasoning_effort || "",
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
    return pumpInto(resp.body, splitter);
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
    // The first turn created the session server-side and gave it a title and
    // timestamp; refresh the picker on every outcome, not only the fully
    // finished one — a stopped or half-streamed run still saved the session,
    // and a picker that never learns about it leaves knownSessions without
    // this id, which used to dead-end every session action (archive, delete,
    // rename) on this page.
    loadSessions();
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
    // The server frees still-queued steering messages silently when the run
    // ends; this ledger is the only record left, so say what was dropped
    // before the steer row (and the list in it) is hidden.
    var droppedSteers = steerUnapplied(steerLedger);
    for (var dsi = 0; dsi < droppedSteers.length; dsi++) {
      appendText(turn, "\n[ steering never applied; the run ended first: " + steerPreview(droppedSteers[dsi].text) + " ]\n", true);
    }
    steerClear(steerLedger);
    paintSteerList();
    // Stop is about to be hidden; take focus back to the composer rather
    // than letting it drop to <body>.
    var focusWasOnStop = document.activeElement === el.cancel;
    setBusy(false);
    if (focusWasOnStop) el.task.focus();
  });
});


// ---- runs: pick a recorded run, draw its execution graph ----------------

/* The whole Runs view — picker, execution graph, node detail, A/B diff —
   lives in features/runs.js and loads on first open, like every other feature
   view. It was ~64 KB raw / ~19 KB gz of app.js that a chat-only visit
   downloaded and never ran; taking it out also takes lib/runs-list.js off the
   eager path. The forwarders below are what the rest of the page still needs:
   a run opened from a deep link, the fleet roster or a board card; the live
   run tick's synthetic graph; and Copy summary. */
var runsModule = null;
var runsModulePromise = null;
function loadRunsModule() {
  if (!runsModulePromise) {
    runsModulePromise = import("./features/runs.js").then(function (m) {
      m.initRuns({ el: el, showView: showView, viewLoaded: viewLoaded, parseRunsHash: parseRunsHash });
      runsModule = m;
      paletteRefs.allRunsHolder = m.allRunsHolder;
      return m;
    }, function (err) {
      runsModulePromise = null; // a failed chunk import must be retryable
      throw err;
    });
  }
  return runsModulePromise;
}

function openRun(id) {
  loadRunsModule().then(function (m) { m.openRun(id); }).catch(function () {
    showLoadError(el.runStatus, "Runs view failed to load.", function () { openRun(id); });
  });
}

/* Only ever called while the Runs view is on screen, which means the module
   has already loaded; before that there is no graph to redraw. */
function drawRun(g) {
  if (runsModule) runsModule.drawRun(g);
}

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
    name.title = name.textContent;
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
  syncChatSend();
  if (empty) {
    // The sr-only status and the visible empty state must give the same
    // instruction: the actionable path is creating a channel in the sidebar,
    // with the config route as the secondary option. They used to disagree —
    // the status told a screen-reader user to edit config.toml while the
    // visible state offered a Create button.
    el.chatStatus.textContent = "No channels yet. Create one to start talking, or add rooms in config.toml.";
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
      syncChatSend();
      el.chatStatus.textContent = "Could not load rooms: " + err.message;
      if (el.chatRoomsItems && !el.chatRoomsItems.querySelector(".slack-room-item")) {
        el.chatRoomsItems.textContent = "";
        var fail = document.createElement("p");
        fail.className = "meta";
        fail.appendChild(document.createTextNode("Could not load channels. "));
        var retry = document.createElement("button");
        retry.type = "button";
        retry.className = "secondary";
        retry.textContent = "Try again";
        retry.addEventListener("click", function () { loadChatRooms(); });
        fail.appendChild(retry);
        el.chatRoomsItems.appendChild(fail);
      }
      showRoomsComposerLocked("Could not load rooms: " + err.message, false);
    });
}

function showRoomsComposerLocked(message, offerCreate) {
  if (el.chatChannelTitle) el.chatChannelTitle.textContent = offerCreate ? "No channels" : "Channels unavailable";
  if (el.chatChannelTopic) {
    el.chatChannelTopic.textContent = "";
    el.chatChannelTopic.classList.remove("is-placeholder");
    el.chatChannelTopic.onclick = null;
  }
  if (el.chatText) el.chatText.placeholder = offerCreate
    ? "Create a channel to send a message"
    : "Retry loading channels to send a message";
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
    btn.className = "primary";
    btn.textContent = "Create a channel";
    btn.addEventListener("click", function () { el.chatCreateRoomBtn.click(); });
    box.appendChild(btn);
  } else {
    var retry = document.createElement("button");
    retry.type = "button";
    retry.className = "secondary";
    retry.textContent = "Try again";
    retry.addEventListener("click", function () { loadChatRooms(); });
    box.appendChild(retry);
  }
  el.chatLog.appendChild(box);
}

function syncChatLogEmpty(room) {
  if (!el.chatLog) return;
  var existing = document.getElementById("chat-log-empty");
  if (el.chatLog.querySelector(".chat-msg")) {
    if (existing) existing.remove();
    return;
  }
  if (el.chatRoom && el.chatRoom.disabled) return;
  var who = room || (el.chatRoom && el.chatRoom.value) || "";
  var msg = isDm(who)
    ? "No messages with " + dmPartner(who) + " yet. Write the first one below."
    : (who ? "No messages in #" + who + " yet. Write the first one below."
      : "No messages in this room yet. Write the first one below.");
  if (existing) { existing.textContent = msg; return; }
  var box = document.createElement("div");
  box.id = "chat-log-empty";
  box.className = "run-empty";
  box.textContent = msg;
  el.chatLog.appendChild(box);
}

var _chatUnreadCutoff = 0;   /* ts before which msgs are "read" (for divider) */
function openChatRoom(room) {
  stopChatPoll();
  _chatUnreadCutoff = _chatReadTimestamps[room] || 0;
  _markRoomRead(room);
  el.chatLog.textContent = "";
  var loading = document.createElement("p");
  loading.id = "chat-log-empty";
  loading.className = "run-empty";
  loading.textContent = "Loading messages…";
  el.chatLog.appendChild(loading);
  chatLastTs = 0;
  chatSeen = {};
  chatSeenOrder = [];
  // An emptied log starts grouping over, day separator included.
  _lastChatFrom = null; _lastChatTs = 0; _lastChatDay = "";
  chatBackoff = chat_poll_base_ms;
  el.chatText.disabled = false;
  syncChatSend();
  el.chatText.placeholder = isDm(room) ? "Message " + dmPartner(room) + "…" : "Message " + room + "…";
  // Channel header: title + topic (click to set/change). DMs get no topic —
  // it is a per-channel concept, and a DM has nothing to name.
  if (el.chatChannelTitle) el.chatChannelTitle.textContent = isDm(room) ? "@" + dmPartner(room) : "#" + room;
  if (el.chatChannelTopic) {
    // An empty topic still needs something on screen to click, or a topic
    // could never be set the first time.
    el.chatChannelTopic.textContent = roomTopics[room] || (isDm(room) ? "" : "Add a topic");
    el.chatChannelTopic.title = roomTopics[room] || (isDm(room) ? "" : "Set a topic for this channel");
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
            el.chatChannelTopic.title = newTopic || "Set a topic for this channel";
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
  // Phone: the channel drawer sits over the transcript and covers the
  // header toggle. Picking a room has to put the messages in front.
  setRoomsSidebarOpen(false, true);
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
function ingestChatMessages(messages, room) {
  // Keyed on messageKey rather than m.id: an id-less message (a peer too
  // old to send one — chatrooms.zig defaults the field to "" and accepts
  // it) otherwise registered "" as seen, and every later id-less message
  // was discarded as a duplicate of it.
  var fresh = (messages || []).filter(function (m) { return m && !chatSeen[chatMessageKey(m)]; }).sort(function (a, b) { return (a.ts || 0) - (b.ts || 0); });
  if (!el.chatLog) return;
  var following = el.chatLog.scrollHeight - el.chatLog.scrollTop - el.chatLog.clientHeight < 40;
  // Only sender grouping resets across batches; the day key must persist
  // or every poll batch would open with a repeat of the same date banner.
  if (fresh.length) { _lastChatFrom = null; _lastChatTs = 0; }
  var placed = false;
  fresh.forEach(function (m) {
    rememberChatId(chatMessageKey(m));
    if (m.ts > chatLastTs) chatLastTs = m.ts;
    lastSeenAt[m.from] = m.ts;
    /* Slack-style "New messages" divider: shown once, before the first
       message whose ts exceeds the cutoff captured when the room opened. */
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
  /* Consumed — subsequent batches should not re-insert the divider */
  _chatUnreadCutoff = 0;
  announceChatArrival(fresh);
  if (fresh.length && following) el.chatLog.scrollTop = el.chatLog.scrollHeight;
  syncChatLogEmpty(room || (el.chatRoom && el.chatRoom.value));
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
      ingestChatMessages(data.messages, room);
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
      var empty = document.getElementById("chat-log-empty");
      if (empty && !el.chatLog.querySelector(".chat-msg")) {
        empty.textContent = "Could not load messages. Retrying…";
      }
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


/* Room messages use the same markdown renderer as the agent transcript
   (`renderMarkdownWithFences`). Shortcodes expand first so :rocket: is
   text the renderer does not have to know about. */
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
function expandEmojiShortcodes(text) {
  return String(text || "").replace(/:[a-z0-9_+-]+:/g, function (m) {
    return _emojiShortcodes[m] || m;
  });
}
function formatChatText(raw) {
  var frag = document.createDocumentFragment();
  if (!raw) return frag;
  frag.appendChild(renderMarkdownWithFences(expandEmojiShortcodes(raw)));
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
  text.className = "chat-text md";
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
      unfurl.style.marginTop = "var(--space-2)";
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
  copyBtn.addEventListener("click", function(e){ e.stopPropagation(); copyText(m.text, copyBtn, "Copy", text); });
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
        else if (el.chatStatus) el.chatStatus.textContent = "Could not pin that message.";
      }).catch(function(err){
        if (el.chatStatus) el.chatStatus.textContent = "Could not pin: " + (err && err.message ? err.message : "request failed");
      });
    });
    actions.appendChild(pinBtn);
  }
  // Edit + Delete only for own messages
  if (m.from === instanceName && canAct) {
    var editBtn = document.createElement("button");
    editBtn.type = "button"; editBtn.className = "secondary"; editBtn.textContent = "Edit"; upgradePfButton(editBtn); editBtn.title = "Edit message";
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
            } else {
              text.textContent = m.text;
              if (el.chatStatus) el.chatStatus.textContent = "Could not save the edit.";
            }
          }).catch(function(err){
            text.textContent = m.text;
            if (el.chatStatus) el.chatStatus.textContent = "Could not save the edit: " + (err && err.message ? err.message : "request failed");
          });
        } else { text.textContent = m.text; if(m.edited){
          var ed2 = document.createElement("span"); ed2.className="chat-edited"; ed2.textContent=" (edited)"; text.appendChild(ed2); }}
      }
      inp.addEventListener("keydown", function(ev){ if(ev.key==="Enter"){ ev.preventDefault(); finishEdit(); } if(ev.key==="Escape"){ text.textContent=m.text; if(m.edited){
        var ed3=document.createElement("span"); ed3.className="chat-edited"; ed3.textContent=" (edited)"; text.appendChild(ed3); }} });
      inp.addEventListener("blur", finishEdit);
    });
    actions.appendChild(editBtn);
    var delBtn = document.createElement("button");
    delBtn.type = "button"; delBtn.className = "secondary danger"; delBtn.textContent = "Delete"; upgradePfButton(delBtn); delBtn.title = "Delete message";
    delBtn.setAttribute("aria-label", "Delete message");
    delBtn.addEventListener("click", function(e){ e.stopPropagation();
      uiConfirm("Delete this message?", { danger: true, confirmLabel: "Delete" }).then(function (yes) {
        if(!yes) return;
        fetch("/api/chat/delete", { method: "POST", headers: {"Content-Type":"application/json"},
          body: JSON.stringify({ room: el.chatRoom.value, msg_id: m.id })
        }).then(function(r){ return r.json(); }).then(function(d){
          if(d.ok) { wrap.classList.add("chat-msg-deleted"); text.textContent = "[This message was deleted]"; text.classList.add("chat-deleted"); }
          else if (el.chatStatus) el.chatStatus.textContent = "Could not delete that message.";
        }).catch(function(err){
          if (el.chatStatus) el.chatStatus.textContent = "Could not delete: " + (err && err.message ? err.message : "request failed");
        });
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

function roomsSidebarIsPhone() {
  return !!(window.matchMedia && window.matchMedia("(max-width: 48rem)").matches);
}

function setRoomsSidebarOpen(open, phoneOnly) {
  if (!el.chatSidebar) return;
  if (phoneOnly && !roomsSidebarIsPhone()) return;
  el.chatSidebar.classList.toggle("is-collapsed", !open);
  if (el.chatSidebarToggle) {
    el.chatSidebarToggle.setAttribute("aria-expanded", open ? "true" : "false");
    el.chatSidebarToggle.setAttribute("aria-label", open ? "Hide channels" : "Show channels");
  }
}

if (el.chatSidebarToggle) el.chatSidebarToggle.addEventListener("click", function () {
  setRoomsSidebarOpen(el.chatSidebar.classList.contains("is-collapsed"), false);
});

var chatSidebarScrim = document.getElementById("chat-sidebar-scrim");
if (chatSidebarScrim) chatSidebarScrim.addEventListener("click", function () {
  setRoomsSidebarOpen(false, true);
});

// First paint on a phone: start closed so the transcript is not under the
// drawer. Opening the view then picking a channel still closes it.
if (roomsSidebarIsPhone()) setRoomsSidebarOpen(false, true);
else setRoomsSidebarOpen(true, false);

// Group headers (Channels / Direct Messages) fold their own items away —
// .slack-room-group.is-collapsed hides .slack-room-items via CSS. The head
// is a real button (keyboard-operable); aria-expanded tracks the fold.
Array.prototype.forEach.call(document.querySelectorAll(".slack-room-group-head"), function (head) {
  head.addEventListener("click", function () {
    var group = head.closest(".slack-room-group");
    if (!group) return;
    var collapsed = group.classList.toggle("is-collapsed");
    head.setAttribute("aria-expanded", String(!collapsed));
  });
});

if (el.chatRoomFilter) el.chatRoomFilter.addEventListener("input", function () {
  var q = el.chatRoomFilter.value.trim().toLowerCase();
  var shown = 0;
  [el.chatRoomsItems, el.chatDmsItems].forEach(function (list) {
    if (!list) return;
    Array.prototype.forEach.call(list.querySelectorAll(".slack-room-item"), function (row) {
      var hide = q.length > 0 && row.textContent.toLowerCase().indexOf(q) === -1;
      row.hidden = hide;
      if (!hide) shown += 1;
    });
  });
  var host = document.getElementById("chat-room-list");
  var note = document.getElementById("chat-room-filter-empty");
  if (q && !shown) {
    if (!note && host) {
      note = document.createElement("p");
      note.id = "chat-room-filter-empty";
      note.className = "run-empty";
      host.appendChild(note);
    }
    if (note) {
      note.textContent = "";
      note.appendChild(document.createTextNode("No channel matches “" + el.chatRoomFilter.value.trim() + "”. "));
      var clear = document.createElement("button");
      clear.type = "button";
      clear.className = "secondary";
      clear.textContent = "Clear filter";
      clear.addEventListener("click", function () {
        el.chatRoomFilter.value = "";
        el.chatRoomFilter.dispatchEvent(new Event("input", { bubbles: true }));
        el.chatRoomFilter.focus();
      });
      note.appendChild(clear);
      note.hidden = false;
    }
  } else if (note) note.hidden = true;
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
          empty.textContent = "No messages mention “" + q + "”.";
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
  /* Expanded state travels with visibility: the toggle is a button, so a
     screen reader needs aria-expanded to know a popup is open, and Esc must
     close it the way it closes every other popup on the page. Focus follows
     the open/close: into the first emoji on open, back to the trigger on
     Esc. */
  function closeEmojiPicker(returnFocus) {
    if (el.chatEmojiPicker.hidden) return;
    el.chatEmojiPicker.hidden = true;
    el.chatEmojiBtn.setAttribute("aria-expanded", "false");
    if (returnFocus && el.chatEmojiPicker.contains(document.activeElement)) el.chatEmojiBtn.focus();
  }
  function openEmojiPicker() {
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
        closeEmojiPicker(false);
        syncChatSend();
      });
      el.chatEmojiPicker.appendChild(b);
    });
    el.chatEmojiPicker.hidden = false;
    el.chatEmojiBtn.setAttribute("aria-expanded", "true");
    var first = el.chatEmojiPicker.querySelector("button");
    if (first) first.focus();
  }
  el.chatEmojiBtn.addEventListener("click", function () {
    if (!el.chatEmojiPicker.hidden) { closeEmojiPicker(true); return; }
    openEmojiPicker();
  });
  el.chatEmojiBtn.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && !el.chatEmojiPicker.hidden) {
      e.preventDefault();
      closeEmojiPicker(false);
    }
  });
  el.chatEmojiPicker.addEventListener("keydown", function (e) {
    if (e.key === "Escape") {
      e.preventDefault();
      closeEmojiPicker(true);
    }
  });
  document.addEventListener("click", function (e) {
    if (el.chatEmojiPicker.hidden) return;
    if (e.target === el.chatEmojiBtn || el.chatEmojiPicker.contains(e.target)) return;
    closeEmojiPicker(false);
  });
}

if (el.chatCreateRoomBtn && el.chatCreateDialog) {
  el.chatCreateRoomBtn.addEventListener("click", function () {
    el.chatNewRoomName.value = "";
    el.chatCreateDialog.showModal();
    el.chatNewRoomName.focus();
  });
  if (el.chatNewRoomName) {
    el.chatNewRoomName.addEventListener("input", function () {
      var v = el.chatNewRoomName.value;
      var next = v.replace(/\s+/g, "-").replace(/[^a-zA-Z0-9_\-]/g, "");
      if (next !== v) el.chatNewRoomName.value = next;
    });
  }
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
  syncChatSend();
});

/* Ctrl+K is the Jump palette on every view. Rooms used to spawn a second
   overlay here; both listeners fired, so the switcher stacked on Jump.
   Filter channels in #chat-room-filter instead. */
el.chatText.addEventListener("keydown", function(e){
  if (e.key === "@" || (e.key.length === 1 && el.chatText.value.slice(-1) === "@")) {
    var peers = (knownPeers || []).map(function(p){ return p.name || p; }).join(", ");
    if (peers) el.chatStatus.textContent = "Mention: @" + (peers.split(",")[0].trim()) + (peers.indexOf(",") !== -1 ? " — also: " + peers.split(",").slice(1,2).join("") + "…" : "");
  }
});
var chatSending = false;
function syncChatSend() {
  if (!el.chatSend || !el.chatText) return;
  var noRoom = !el.chatRoom || el.chatRoom.disabled || !el.chatRoom.value;
  var empty = !el.chatText.value.trim();
  el.chatSend.disabled = chatSending || noRoom || el.chatText.disabled || empty;
  var hint = noRoom ? "Pick a channel first" : (empty ? "Write a message first" : "Send");
  el.chatSend.title = hint;
  el.chatSend.setAttribute("aria-label", hint);
}

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
  chatSending = true;
  syncChatSend();
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
    chatSending = false;
    syncChatSend();
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

wireRefresh(el.usageRefresh, function () { return loadUsage(); });

function loadUsage() {
  return fetch("/api/stats")
    .then(readJson)
    .then(function (data) { renderUsage(data.stats || []); })
    .catch(function (err) {
      var msg = "Could not load usage: " + err.message;
      showLoadError(el.usage, msg, loadUsage);
    });
}

// ---- goals: what runs are being steered toward -------------------------

/* Extracted to features/goals.js; wired from the board view loader with the
   app-level pieces it needs: view switching and the conversation the chat
   composer is on (a goal run joins that session). The goals module is loaded
   lazily with the board, so the wiring happens on first open — the goal list
   and its controls only matter once a goal exists. */

// ---- tools: every WASM plugin, and a switch for the optional ones ------

var allToolsHolder = { list: [] };

var toolState = uiState({ tools: [], filter: "" });

/* The tools catalogue (core/tools.js, ~20 KB) renders the Tools view and the
   Prompts view's workflow/skill lists. Neither is chat, so it loads on first
   open like the feature views rather than on every visit. `bindTools` used to
   run at page load; it now runs inside the loader, once. */
var toolsModulePromise = null;
function loadToolsModule() {
  if (!toolsModulePromise) {
    toolsModulePromise = import("./core/tools.js").then(function (m) {
      bindOnce("tools-module", function () {
        m.bindTools({
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
      });
      return m;
    }, function (err) {
      toolsModulePromise = null; // a failed chunk import must be retryable
      throw err;
    });
  }
  return toolsModulePromise;
}
/* Reached from the command palette, which can fire before the Tools view has
   ever been opened; the module loads on demand and the detail opens after. */
var showToolDetail = function (t) {
  loadToolsModule().then(function (m) { m.showToolDetail(t); }).catch(function () {});
};

// ---- views: one section visible at a time -----------------------------

var VIEWS = ["chat", "kanban", "runs", "fleet", "arena", "rooms", "models", "knowledge", "prompts", "tools", "system"];

var arenaModulePromise = null;
function loadArenaModule() {
  if (!arenaModulePromise) {
    arenaModulePromise = import("./features/arena.js").catch(function (err) {
      arenaModulePromise = null; // a failed chunk import must be retryable
      throw err;
    });
  }
  return arenaModulePromise;
}
var fleetModulePromise = null;
function loadFleetModule() {
  if (!fleetModulePromise) {
    fleetModulePromise = import("./features/fleet.js").then(function (fleet) {
      fleet.setNavShowView(showView);
      fleet.setOpenRun(openRun);
      return fleet;
    }, function (err) {
      fleetModulePromise = null; // a failed chunk import must be retryable
      throw err;
    });
  }
  return fleetModulePromise;
}
var todosModulePromise = null;
function loadTodosModule() {
  if (!todosModulePromise) {
    todosModulePromise = import("./features/todos.js").catch(function (err) {
      todosModulePromise = null; // a failed chunk import must be retryable
      throw err;
    });
  }
  return todosModulePromise;
}
/* The view modules below (board, goals, prompts, models)
   are loaded on first open, not at page load: together they are ~190 KB that
   a status-check-and-leave visit never executes. The promise is cached, so a
   second open of the same view does not re-fetch — but only a *resolved*
   promise is worth caching. A rejected import is dropped by each loader so
   the next open (or a view's Try again) re-attempts the fetch; a dead chunk
   otherwise poisoned the page for its lifetime. Module state these views
   share with app.js (the board card list, the goal list, the card modal key
   handler) is exposed through the module-scope vars here, which stay unset
   until the module has loaded; call sites that can run before then guard.
   Search and Compare are disk plugins under ui/plugins/. */
var boardModule = null;
var cardModalKeyHandler = null;
var boardModulePromise = null;
function loadBoardModule() {
  if (!boardModulePromise) boardModulePromise = import("./features/board.js").then(function (m) {
    boardModule = m;
    cardModalKeyHandler = m.cardModalKeyHandler;
    paletteRefs.board = m.board;
    return m;
  }, function (err) {
    boardModulePromise = null; // a failed chunk import must be retryable
    throw err;
  });
  return boardModulePromise;
}
var goalState = null;
var goalsModulePromise = null;
function loadGoalsModule() {
  if (!goalsModulePromise) goalsModulePromise = import("./features/goals.js").then(function (m) {
    goalState = m.goalState;
    paletteRefs.goalState = m.goalState;
    return m;
  }, function (err) {
    goalsModulePromise = null; // a failed chunk import must be retryable
    throw err;
  });
  return goalsModulePromise;
}
/* Both live inside views whose module is already loaded by the time the button
   can be pressed (Tools is its own view; Goal activity is a fold in Kanban), so
   the lazy import here only ever resolves an existing promise. */
wireRefresh(el.goalsRefresh, function () {
  return loadGoalsModule().then(function (gm) { return gm.loadGoals(); });
});
wireRefresh(el.toolsRefresh, function () {
  return loadToolsModule().then(function (m) { return m.loadTools(); });
});

var promptsModulePromise = null;
function loadPromptsModule() {
  if (!promptsModulePromise) {
    promptsModulePromise = import("./features/prompts.js").catch(function (err) {
      promptsModulePromise = null; // a failed chunk import must be retryable
      throw err;
    });
  }
  return promptsModulePromise;
}
var modelsModulePromise = null;
function loadModelsModule() {
  if (!modelsModulePromise) {
    modelsModulePromise = import("./features/models.js").catch(function (err) {
      modelsModulePromise = null; // a failed chunk import must be retryable
      throw err;
    });
  }
  return modelsModulePromise;
}
/* The System view's config editor and MCP server list. They used to be
   top-level IIFEs at the bottom of this file that bound *and* fetched at page
   load, so every chat-only visit downloaded ~12.5 KB raw it never ran and
   paid for two /api/config requests it never read. Lazy like the rest, with
   the same retryable-rejection rule. */
var systemModulePromise = null;
function loadSystemModule() {
  if (!systemModulePromise) {
    systemModulePromise = import("./features/system.js").catch(function (err) {
      systemModulePromise = null; // a failed chunk import must be retryable
      throw err;
    });
  }
  return systemModulePromise;
}
var knowledgeModulePromise = null;
/* The Knowledge view is lazy like every other feature view, but its selected
   collections are read by the run composer (the `knowledge:` field of each
   /api/run body) and written by the #mention autocomplete — both of which can
   happen without the view ever opening. This copy initializes from the same
   localStorage key the module uses; when the module loads it re-reads that
   key and we adopt its array, so the view's checkboxes and the composer keep
   one live array instead of two that drift. */
var kbSelected = (function () { try { var raw = window.localStorage.getItem("clanker.knowledge"); if (raw) return JSON.parse(raw); } catch (_) { } return []; })();
function loadKnowledgeModule() {
  if (!knowledgeModulePromise) knowledgeModulePromise = import("./features/knowledge.js").then(function (m) {
    kbSelected = m.selectedKnowledge;
    return m;
  }, function (err) {
    knowledgeModulePromise = null; // a failed chunk import must be retryable
    throw err;
  });
  return knowledgeModulePromise;
}
/* The command palette indexes board cards and goals, both of which live in
   lazy modules. The refs start as empty stand-ins and are swapped for the
   real module state the first time the board view loads — before any
   board/goal was ever opened this session the lists are empty anyway. */
var paletteRefs = {
  knownSessionsHolder: null,
  allRunsHolder: null,
  board: { columns: [], cards: [] },
  goalState: { val: [] },
  allToolsHolder: null,
  sessionLabel: null,
  runLabel: null
};
var renderBoard = function (b) { loadBoardModule().then(function (m) { try { m.renderBoard(b); } catch (_) {} }).catch(function () {}); };
var setOpenCardId = function (id) { loadBoardModule().then(function (m) { m.setOpenCardId(id); }).catch(function () {}); };
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
  runs: function () {
    return loadRunsModule().then(function (m) { bindOnce("runs", m.bindRuns); return m.loadRuns(); });
  },
  fleet: function () {
    return loadFleetModule().then(function (fleet) { return fleet.refreshFleet(); });
  },
  arena: function () {
    return loadArenaModule().then(function (arena) { bindOnce("arena", arena.bindArena); return arena.loadArenaView(); });
  },
  rooms: function () { return loadStatus().then(loadChatRooms); },
  // Goals ride along with the board: the board->goal sync (moving a card
  // marks its goal) needs the goal list, and the goal->board mirror needs to
  // run even when the Goals view was never opened. Both modules load here on
  // the board's first open; the wiring binds once for the life of the page.
  kanban: function () {
    return loadBoardModule().then(function (m) {
      bindOnce("kanban", function () {
        m.bindBoard({ el: el, setTabCount: setTabCount, openRun: openRun, getKnownPeers: function () { return knownPeers; } });
      });
      return m.loadBoardRooms().then(function () {
        return loadGoalsModule().then(function (gm) {
          bindOnce("goals", function () {
            gm.bindGoals({ el: el, showView: showView, getSessionId: function () { return sessionId; }, switchSession: switchSession });
          });
          return gm.loadGoals();
        });
      });
    });
  },
  models: function () {
    bindOnce("models", function () { loadModelsModule().then(function (m) { m.bindModels(); }); });
    return loadModelsModule().then(function (m) { return m.loadModelsView(); });
  },
  knowledge: function () {
    return loadKnowledgeModule().then(function (m) {
      bindOnce("knowledge", function () { m.bindKnowledge(); });
      return m.loadKnowledge();
    });
  },
  prompts: function () {
    bindOnce("prompts", function () { loadPromptsModule().then(function (m) { m.bindPrompts(); }); });
    return Promise.all([
      loadPromptsModule().then(function (m) { return m.loadPromptsView(); }),
      loadToolsModule().then(function (m) { return Promise.all([m.loadWorkflows(), m.loadSkills()]); })
    ]);
  },
  tools: function () { return loadToolsModule().then(function (m) { return m.loadTools(); }); },
  system: function () {
    return Promise.all([
      loadUsage(),
      loadStatus(),
      loadLogList(),
      loadWebuiPlugins(),
      loadSystemModule().then(function (m) { m.bindSystemAdmin(); })
    ]);
  }
};

/* An in-flight panel, an empty panel and a hung panel were pixel-identical.
   Each renderer overwrites this on success and each catch replaces it with the
   failure, so one line is enough. */
var VIEW_CONTAINERS = {
  models: "models-configured",
  runs: "run-graph",
  fleet: "fleet-runs",
  arena: "arena-list",
  rooms: "chat-log",
  kanban: "board-grid",
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
function persistRailFolds() {
  var data = {};
  document.querySelectorAll("details.rail-fold[id]").forEach(function (d) {
    data[d.id] = !!d.open;
  });
  try { window.localStorage.setItem("clanker.railFolds", JSON.stringify(data)); } catch (e) {}
}

function restoreRailFolds() {
  var raw;
  try { raw = JSON.parse(window.localStorage.getItem("clanker.railFolds") || "null"); } catch (e) { return; }
  if (!raw || typeof raw !== "object") return;
  document.querySelectorAll("details.rail-fold[id]").forEach(function (d) {
    if (Object.prototype.hasOwnProperty.call(raw, d.id)) d.open = !!raw[d.id];
  });
}

function syncRailFolds(name) {
  var tab = document.getElementById("tab-" + name);
  var fold = tab && tab.closest ? tab.closest("details.rail-fold") : null;
  if (fold) fold.open = true;
}

document.querySelectorAll("details.rail-fold[id]").forEach(function (d) {
  d.addEventListener("toggle", persistRailFolds);
});

var pluginsReady = false;
var pendingPluginView = null;

function viewBase(name) {
  var n = name || "";
  var slash = n.indexOf("/");
  var q = n.indexOf("?");
  var cut = n.length;
  if (slash !== -1) cut = slash;
  if (q !== -1 && q < cut) cut = q;
  return n.slice(0, cut);
}

function showView(name, focusPanel) {
  // A plugin view (schedule, search, compare, …) is not in VIEWS until its
  // script has registered. Falling through to Chat here used to overwrite
  // clanker.view and drop a refresh that was sitting on #schedule.
  if (VIEWS.indexOf(viewBase(name === "goals" || name === "board" ? "kanban" : name)) === -1 && !pluginsReady) {
    pendingPluginView = { name: name, focusPanel: focusPanel };
    return;
  }
  // Goals and kanban are one workflow. Old #board / #goals bookmarks
  // still land here.
  if (name === "goals" || name === "board") name = "kanban";
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
  if (name.indexOf("kanban/") === 0) { pendingBoardCard = decodeURIComponent(name.slice(7)); name = "kanban"; }
  if (name.indexOf("board/") === 0) { pendingBoardCard = decodeURIComponent(name.slice(6)); name = "kanban"; }
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
  // The fleet mesh poll is the same shape: refreshFleet re-arms it on return.
  if (currentView === "fleet" && name !== "fleet" && fleetModulePromise) {
    fleetModulePromise.then(function (fleet) { fleet.stopFleet(); });
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
      }, function (err) {
        // A failed view load was a blank panel: the skeleton cleared and
        // nothing said why, so a dead chunk (a dynamic import that 404'd, an
        // API call that failed) looked identical to an empty-but-healthy view.
        // Say what failed and offer to retry; `viewLoaded` stays false either
        // way, so simply reopening the view still retries it too.
        clearLoading(name);
        var cid = VIEW_CONTAINERS[name];
        var container = cid && document.getElementById(cid);
        if (!container) return;
        showLoadError(container, "Could not load the " + name + " view" + (err && err.message ? ": " + err.message : "") + ".", function () {
          markLoading(name);
          return viewLoaders[name]().then(function () {
            viewLoaded[name] = true;
            clearLoading(name);
          });
        });
      });
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
    // The view has never been opened, so the module is not loaded; hand it the
    // id it should open the moment its list arrives.
    else loadRunsModule().then(function (m) { m.setPendingRunId(deepRun); }).catch(function () {});
  }
  if (pendingKnowledgeId && viewLoaded.knowledge) loadKnowledgeModule().then(function (m) { m.loadKnowledge(); }).catch(function () {});
  if (pendingBoardCard) {
    // need board loaded first — defer until after viewLoaders[board] would have fired, then poll
    var tries = 0;
    loadBoardModule();
    (function tryOpen(){
      tries++;
      if (boardModule && boardModule.cardById(pendingBoardCard)) { boardModule.setOpenCardId(pendingBoardCard); try{ boardModule.renderBoard(boardModule.board); }catch(_){} return; }
      if (tries < 20) setTimeout(tryOpen, 250);
      else if (boardModule) { boardModule.setOpenCardId(pendingBoardCard); try{ boardModule.renderBoard(boardModule.board); }catch(_){} }
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
uiAdd(el.cancel, icon("stop", 14), document.createTextNode("Stop"));
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
   "knowledge-status", "prompts-status", "models-status", "fleet-status",
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
  setPromptListOpen(true, "prompt-item-" + promptIndex);
  el.promptList.setAttribute("data-count", String(matches.length));
}

function hidePromptList() {
  el.promptList.hidden = true;
  el.promptList.textContent = "";
  setPromptListOpen(false, null);
  // The one place that means "no suggestion list is open", so it is also where
  // the mention list's own state stops being true. Leaving the flag set is what
  // let a key meant for one list be dispatched against another.
  kbMentionActive = false;
  kbMentionIndex = 0;
}

/* One place says whether the composer's suggestion listbox is open, because
   that state now lives on two elements. ARIA allows `combobox` on an input and
   not on a textarea -- a textarea is already a textbox with aria-multiline, and
   overriding the role told an AT the field was single-line -- so the role, the
   popup reference and `aria-expanded` sit on the #task-combobox wrapper, while
   `aria-activedescendant` stays on #task, which is the textbox the ARIA 1.1
   combobox pattern points at. All four renderers and hidePromptList come
   through here so the two halves can never disagree. */
function setPromptListOpen(open, activeId) {
  el.taskCombobox.setAttribute("aria-expanded", open ? "true" : "false");
  if (open && activeId) el.task.setAttribute("aria-activedescendant", activeId);
  else el.task.removeAttribute("aria-activedescendant");
}

function runSlashModel(arg) {
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
}
var slashCtx = { showView: showView, runModel: runSlashModel };
slashReady();
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
  setPromptListOpen(true, "prompt-item-" + promptIndex);
}
function hideSlashList(){ hidePromptList(); }
function useSlash(entry, arg){
  hideSlashList();
  // keep the slash text out of the composer for pure-command entries
  el.task.value = "";
  runSlashEntry(entry, arg, slashCtx);
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
            .then(function (data) { return renderSessionHistory(data.messages || []); });
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
  var built = runsModule && runsModule.lastBuiltGraph();
  if (!built) {
    el.runStatus.textContent = "No run is open.";
    return;
  }
  copyText(runsModule.graphSummaryText(built), el.runCopy, "Copy summary", el.runGraph);
});

/* ---------- board ---------- */

/* The board is wired on its first open, not here: features/board.js is
   lazy-loaded (see the `board:` view loader) so opening the chat view never
   pulls the board module. A stale top-level `bindBoard(...)` call that
   survived that extraction threw `bindBoard is not defined` and killed the
   whole boot chain before sessions, prompts, and the transcript ever wired. */

// Archive + Import (history parity) — reuses existing session API, no invented state
(function(){
  var archBtn = document.getElementById("session-archive");
  var importBtn = document.getElementById("session-import");
  var tog = document.getElementById("archived-toggle");
  // upgradePfButton wrapped the label in a .pf-v6-c-button__text span;
  // assigning textContent on the button itself would tear that wrapper out.
  function setArchiveLabel(text){
    if (!archBtn) return;
    var span = archBtn.querySelector(".pf-v6-c-button__text");
    if (span) span.textContent = text; else archBtn.textContent = text;
  }
  if (archBtn) archBtn.addEventListener("click", function(){
    withSessionMeta(function(meta){
      var next = !meta.archived;
      archBtn.disabled = true;
      fetch("/api/sessions/" + encodeURIComponent(sessionId), { method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({ archived: next }) })
        .then(readJson).then(function(){
          sessionNotice(next ? "Archived. Toggle Show archived to see it." : "Unarchived.");
          setArchiveLabel(next ? "Unarchive" : "Archive");
          return loadSessions();
        }).catch(function(err){ sessionNotice("Archive failed: " + err.message); })
        .finally(function(){ archBtn.disabled = false; });
    });
  });
  function syncArchiveLabel(){
    try {
      var meta = currentSessionMeta && currentSessionMeta();
      setArchiveLabel(meta && meta.archived ? "Unarchive" : "Archive");
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
        else if (parsed && parsed.id && Array.isArray(parsed.messages)) { msgs = parsed.messages; title = parsed.title || ""; }
        else if (parsed && Array.isArray(parsed.messages)) { msgs = parsed.messages; title = parsed.title || ""; }
        else if (parsed && Array.isArray(parsed.conversations) && parsed.conversations[0]) { var c = parsed.conversations[0]; msgs = c.messages || c.mapping && Object.values(c.mapping).map(function(v){ var m=v.message; return m?{role:m.author&&m.author.role,content:(m.content&&m.content.parts&&m.content.parts[0])||m.content} : null; }).filter(Boolean) || []; title = c.title || ""; }
        if (!msgs || !msgs.length){ uiToast("No messages found in file. Expected {messages:[{role,content}]} or an array of messages."); return; }
        // Normalize to StoredMessage shape the server expects
        var norm = msgs.map(function(m){
          var role = (m.role==="assistant" || m.role==="system") ? m.role : (m.role==="user"?"user":String(m.role||"user"));
          var content = m.content!=null ? String(m.content) : (m.text!=null?String(m.text):"");
          if (role!=="user" && role!=="assistant") role="user";
          return { role: role, content: content };
        }).filter(function(m){ return m.content && m.content.trim(); });
        if (!norm.length){ uiToast("No importable messages."); return; }
        fetch("/api/sessions", { method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify({ import_chat: true, title: title || ("imported "+new Date().toLocaleString()), messages: norm }) })
          .then(function(r){ return r.json().then(function(d){ if(!r.ok||!d.ok) throw new Error(d.error||r.status); return d; }); })
          .then(function(d){
            el.sessionStatus.textContent = "Imported.";
            if (d.id){ chatPrefsCarry(sessionId, d.id); sessionId = d.id; rememberSession(sessionId); renderSessionChip(); }
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
pluginsBind({ VIEWS: VIEWS, viewLoaders: viewLoaders, wireTab: wireTab, showView: showView, el: el, readJson: readJson, fmtBytes: fmtBytes, fmtInt: fmtInt, fmtCost: fmtCost, formatChatTime: formatChatTime, openSession: function (id, jump) { switchSession(id, jump); showView("chat", true); } });

function loadLogList() { return logsLoadLogList(el, readJson, fmtBytes); }
function loadLog(name) { return logsLoadLog(name, el, readJson, fmtBytes); }

el.logSelect.addEventListener("change", function () { loadLog(el.logSelect.value); });
wireRefresh(el.logsRefresh, loadLogList);

// Phase 5 progress streaming — reuses /api/run event channel shape via fetch + reader.
// History lists recent runs from /api/runs (the same graph guest the Gate view reads);
// the Revert button only confirms — the actual revert is the CLI's `clanker revert <run-id>`.
(function(){
  var progCtrl=null, progEl=document.getElementById("progress-log"), progStatus=document.getElementById("progress-status"), progHist=document.getElementById("progress-history");
  var stopBtn=document.getElementById("progress-stop");
  function append(t){ if(!progEl) return; progEl.textContent += t; progEl.scrollTop=progEl.scrollHeight; }
  function renderHistory(){
    if(!progHist) return Promise.resolve();
    // Returned so the Refresh button can stay disabled until both fetches land.
    return Promise.all([
      fetch("/api/runs").then(function(r){ return r.json().then(function(d){ var txt=d.text||""; try{ return txt?JSON.parse(txt): (Array.isArray(d)?d:(d.runs||[])); }catch(_){ return []; } }); }).catch(function(){ return []; }),
      fetch("/api/providers").then(function(r){ return r.json(); }).catch(function(){ return null; })
    ]).then(function(vals){
      var runs=vals[0]||[]; progHist.textContent="";
      if(!runs.length){
        var p=document.createElement("p"); p.className="run-empty";
        p.appendChild(document.createTextNode("No runs yet. Start a task in Chat and it appears here and in the gate history. "));
        var go=document.createElement("button"); go.type="button"; go.className="primary"; go.textContent="Open Chat";
        go.addEventListener("click", function(){
          var tab=document.getElementById("tab-chat");
          if(tab) tab.click(); else showView("chat", true);
        });
        p.appendChild(go); progHist.appendChild(p); return;
      }
      var recent=runs.slice(0, 8);
      var ul=document.createElement("ul"); ul.className="fleet-roster-list";
      recent.forEach(function(r){
        var li=document.createElement("li"); li.className="fleet-meta";
        var a=document.createElement("a"); a.href="#"; a.textContent=(r.run_id||"run")+" · "+(r.provider||"?")+" · "+((r.duration_ms||0)+"ms");
        a.addEventListener("click", function(e){ e.preventDefault(); if(typeof openRun==="function") openRun(r.run_id); });
        li.appendChild(a);
        var rev=document.createElement("button"); rev.type="button"; rev.className="secondary"; rev.textContent="Revert"; upgradePfButton(rev); rev.style.marginLeft="var(--space-3)";
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
  wireRefresh(histBtn, renderHistory);
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
document.querySelectorAll("[data-system-jump]").forEach(function (btn) {
  btn.addEventListener("click", function () {
    var target = document.getElementById(btn.getAttribute("data-system-jump"));
    if (target) target.scrollIntoView({ block: "start", behavior: prefersReducedMotion() ? "auto" : "smooth" });
  });
});

var providerCacheHolder = { list: providerCache };
mpBind({ el: el, readJson: readJson, fmtInt: fmtInt, allUsage: allUsage, renderUsage: renderUsage, renderContextMeter: renderContextMeter, providerCacheHolder: providerCacheHolder, onModelChange: renderSessionChip, chatPrefs: { get: chatPrefsGet, set: chatPrefsSet } });
// Header chip and composer pill mirror the hidden select.
if (el.modelSelect) el.modelSelect.addEventListener("change", renderSessionChip);

paletteRefs.knownSessionsHolder = knownSessionsHolder;
paletteRefs.allToolsHolder = allToolsHolder;
paletteRefs.sessionLabel = sessionLabel;
paletteRefs.runLabel = runLabel;
paletteBind({
  VIEWS: VIEWS, showView: showView, el: el,
  refs: paletteRefs,
  setRailOpen: setRailOpen, switchSession: switchSession, openRun: openRun, renderBoard: renderBoard, showToolDetail: showToolDetail,
  setOpenCardId: setOpenCardId
});
document.addEventListener("keydown", function (e) {
  // Trello/Slack-style card modal owns focus while open — Esc closes, Tab
  // traps. Lives in features/board.js with the rest of the modal; the
  // handler is only wired once the board module has been loaded.
  if (cardModalKeyHandler && cardModalKeyHandler(e)) return;
  if (paletteKeyHandle(e, { el: el, finishTextPrompt: finishTextPrompt, setRailOpen: setRailOpen })) return;
});

// Settings surface wires the same header affordances (single source of truth)
try {
  (function(){
    var themeCycle = document.getElementById("settings-theme-cycle");
    var themeLabel = document.getElementById("settings-theme-label");
    if (themeCycle) bindThemeToggleMod(themeCycle);
    if (themeLabel) themeLabel.textContent = theme;
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
    var settingsEnter = document.getElementById("settings-enter-sends");
    if (settingsEnter && el.enterSends) {
      settingsEnter.checked = el.enterSends.checked;
      settingsEnter.addEventListener("change", function () {
        el.enterSends.checked = settingsEnter.checked;
        el.enterSends.dispatchEvent(new Event("change"));
      });
      el.enterSends.addEventListener("change", function () {
        settingsEnter.checked = el.enterSends.checked;
      });
    }
  })();
} catch(_){}


// # prompt for knowledge — typing # shows collections to inject context
var kbMentionActive = false;
var kbMentionIndex = 0;
// Same ticket as the @-mention list: only the newest listing may draw.
var kbMentionSeq = 0;
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
  if (!mq) { hidePromptList(); return; }
  var seq = ++kbMentionSeq;
  fetch("/api/knowledge").then(function(r){ return r.json(); }).then(function(data){
    if (seq !== kbMentionSeq) return;
    var cols = (data && data.collections) || [];
    var matches = cols.filter(function(c){ return c.title.toLowerCase().indexOf(mq.q) !== -1 || c.id.toLowerCase().indexOf(mq.q) !== -1; }).slice(0, 6);
    if (!matches.length) { hidePromptList(); return; }
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
        hidePromptList();
        el.task.focus();
        var hint = document.getElementById("knowledge-hint");
        if (hint) {
          var n = kbSelected.length;
          hint.textContent = n + (n === 1 ? " collection" : " collections") + " will be included in the next prompt.";
        }
      });
      el.promptList.appendChild(li);
    });
    el.promptList.hidden = false;
    setPromptListOpen(true, "prompt-item-" + kbMentionIndex);
  }).catch(function(){ if (seq === kbMentionSeq) hidePromptList(); });
}
// Integrated input handler so #knowledge and / prompts + Delete share one promptList cleanly
function integratedTaskInputHandler(){
  if (renderFileMentionList()) return;
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
   a deep link or a remembered last view cannot resolve until they have loaded.
   When the hash names a built-in view, plugins wait with everything else. */
var openingHash = window.location.hash.replace("#", "");

/* The view to open on load: a URL fragment naming a real view wins; otherwise
   the last view this browser was on (persisted by showView) is reopened so a
   hard refresh keeps you on the same page instead of dropping to chat.
   Plugin view names are returned even before they have registered. */
function lastView() {
  try {
    var v = window.localStorage.getItem("clanker.view");
    if (v === "board" || v === "goals") v = "kanban";
    return v || "";
  } catch (e) {}
  return "";
}
/* The full hash is handed to showView, whose prefix parsing resolves deep
   links (#runs/<id>, #kanban/<id>, #arena/<id>, #knowledge/<id>,
   #chat?session=<id>, #compare/<id>) that a bare view-name check used to drop on load. */
var openingView = openingHash || lastView() || "chat";
var needsPluginsNow = VIEWS.indexOf(viewBase(openingView === "goals" || openingView === "board" ? "kanban" : openingView)) === -1;

function afterFirstDraw(work) {
  if (window.requestIdleCallback) window.requestIdleCallback(work, { timeout: 2000 });
  else window.setTimeout(work, 0);
}

function markPluginsReady() {
  pluginsReady = true;
  if (!pendingPluginView) return;
  var p = pendingPluginView;
  pendingPluginView = null;
  if (VIEWS.indexOf(viewBase(p.name === "goals" || p.name === "board" ? "kanban" : p.name)) !== -1) {
    showView(p.name, p.focusPanel);
  } else {
    showView("chat", false);
  }
}

if (needsPluginsNow) {
  loadWebuiPlugins().then(markPluginsReady, markPluginsReady);
}

afterFirstDraw(function () {
  loadStatus();
  loadProviders();
  if (!needsPluginsNow) loadWebuiPlugins().then(markPluginsReady, markPluginsReady);
});
syncSubmitLabel();
updateComposerModeHint();
restoreRailFolds();
// Only the opening view's data is fetched now; the rest load when opened.
showView(openingView, false);
/* Session list for the sidebar only. Do not replay the last conversation:
   a load is a new chat. `#chat?session=` still opens a named one. */
Promise.all([loadSessions(), loadWorkspaces()]).then(function () {
  syncTranscriptEmpty();
});
});

