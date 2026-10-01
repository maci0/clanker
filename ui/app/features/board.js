// Board view — ES module, no bundler.
// Owns #view-kanban: columns and cards, the card detail modal, filters, and
// the list view. The pure column/card helpers stay in ../lib/board.js; the
// goal side of the card<->goal mirroring lives in ./goals.js. bindBoard()
// wires the DOM and the app-level callbacks (tab counts, run opening, the
// peer roster for @ mention hints).
import { fmtInt, fmtCost, fmtPct, formatChatTime, fmtDeadline, readJson, clip, wireRefresh, plural, searchFold } from "../core/utils.js";
import { T, bind, state, add, toast, uiConfirm, uiPrompt, showLoadError, requireText } from "../core/ui.js";
import { icon } from "../core/icons.js";
import { openOverlay, closeOverlay, trapOverlayTab } from "../core/overlay.js";
import { reducedMotion } from "../core/vendor.js";
/* An empty field on a form that just `return`s is a button that looks broken
   from the other side: nothing tells the operator their text was dropped, and
   the press did nothing at all. `requireText` (core/ui.js) is that refusal, and
   it lives there so every form on the page makes it, not only the board's. */
import { doneColumn as doneColumnOf, blockers as blockersOf, dueState, priorityRank } from "../lib/board.js";
import { goalState, postGoal, goalIdForCard, mirrorCardForObjective, workCardAsGoal, syncCardsFromGoals, loadGoals, isGoalRunning } from "./goals.js";

var el = null;
var _setTabCount = null;
var _openRun = null;
var _getKnownPeers = null;
var _renderBoardList = null;


export var board = { columns: [], cards: [] };
var openCardId = null;

/* Deadline instants are stored as local end-of-day (the date input parses
   "YYYY-MM-DDT23:59:59" in the browser's own zone). The input must therefore
   be filled from the same zone: toISOString() would render a UTC-5 user's
   2026-08-14 deadline as "2026-08-15" (23:59:59-05:00 is 04:59:59Z the next
   day), and saving the card unchanged would move the deadline a day later. */
function deadlineToDateInput(deadline) {
  var d = typeof deadline === "number" ? new Date(deadline * 1000) : new Date(deadline);
  if (isNaN(d.getTime())) return "";
  var y = d.getFullYear();
  var m = String(d.getMonth() + 1).padStart(2, "0");
  var day = String(d.getDate()).padStart(2, "0");
  return y + "-" + m + "-" + day;
}

/* The inverse of deadlineToDateInput, in the same (local) zone: the end-of-day
   instant the input's date means, as epoch seconds. 0 when unparseable. */
function dateInputToDeadline(value) {
  var parsed = Date.parse(value + "T23:59:59");
  return isNaN(parsed) ? 0 : Math.floor(parsed / 1000);
}

/* Whether a board fetch has completed at least once. The goals module asks
   before mirroring goals onto the board: matching against a card list that
   was never fetched (always empty) is what used to create a duplicate card
   on every visit to the Goals view. */
var boardLoaded = false;
export function boardIsLoaded() { return boardLoaded; }

export function setOpenCardId(id) { openCardId = id; }

/* Board (columns) or list (one sortable table). Module state rather than a
   closure variable because the board's own render has to know it too: the
   Sort control belongs to the list and has to stay hidden behind the board,
   and that render runs on every card change, not only when the toggle is
   clicked. */
var listMode = false;
export function setListMode(on) {
  listMode = !!on;
  var grid = document.getElementById("board-grid");
  var listViewEl = document.getElementById("board-list-view");
  var toggleBtn = document.getElementById("board-toggle-list");
  if (grid) grid.hidden = listMode;
  if (listViewEl) listViewEl.hidden = !listMode;
  if (toggleBtn) {
    toggleBtn.setAttribute("aria-pressed", listMode ? "true" : "false");
    toggleBtn.textContent = "";
    toggleBtn.appendChild(icon(listMode ? "grid" : "list", 16));
    var next = listMode ? "Switch to board view" : "Switch to list view";
    toggleBtn.title = next;
    toggleBtn.setAttribute("aria-label", next);
  }
  syncListControls();
}
/* The Sort control is the list's, so it follows the mode as well as the card
   count. It used to follow only the count, which left it sitting under the
   columns in board mode sorting a table nobody could see. */
function syncListControls() {
  var listControls = document.getElementById("board-list-controls");
  if (listControls) listControls.hidden = !listMode || (boardState.val.cards || []).length === 0;
}

function doneColumn() { return doneColumnOf(board); }
function blockers(card) { return blockersOf(card, board, cardById); }

function boardHasActiveFilters(s) {
  return !!(s.mine || s.text || s.blockedOnly || s.priority || s.assignee || s.label);
}

function cardMatchesBoardFilter(c, s) {
  if (s.mine && c.assignee !== s.me) return false;
  if (s.assignee) {
    if (s.assignee === "(unassigned)") { if (c.assignee) return false; }
    else if (c.assignee !== s.assignee) return false;
  }
  if (s.blockedOnly && blockers(c).length === 0) return false;
  if (s.priority && (c.priority || "normal") !== s.priority) return false;
  if (s.label && !(c.labels || []).some(function (l) { return l.color === s.label; })) return false;
  var hay = c.title + " " + (c.body || "") + " " + (c.assignee || "") + " " +
    (c.labels || []).map(function (l) { return l.text || l.color || ""; }).join(" ");
  if (s.text && searchFold(hay).indexOf(s.text) === -1) return false;
  return true;
}

function clearBoardFilters() {
  var input = document.getElementById("board-filter-input");
  if (input) input.value = "";
  if (el && el.boardMine) el.boardMine.checked = false;
  var blocked = document.getElementById("board-filter-blocked");
  if (blocked) blocked.checked = false;
  var prio = document.getElementById("board-filter-priority");
  if (prio) prio.value = "";
  var who = document.getElementById("board-filter-assignee");
  if (who) who.value = "";
  var label = document.getElementById("board-filter-label");
  if (label) label.value = "";
  renderBoard();
}

/* A board belongs to a chatroom, because a card *is* a message in that room's
   log. The picker is the room list, so joining a room is what gives you its
   board; there is no separate "create a board" step and no board that exists
   without anyone subscribed to see it. */
export function loadBoardRooms() {
  return fetch("/api/chat/rooms")
    .then(readJson)
    .then(function (d) {
      // The listing calls the field "room", not "name".
      var rooms = (d.rooms || []).map(function (r) { return typeof r === "string" ? r : r.room; });
      if (rooms.indexOf("board") === -1) rooms.unshift("board");
      var defRoom = workspaceBoardRoom();
      if (defRoom !== "board" && rooms.indexOf(defRoom) === -1) rooms.unshift(defRoom);
      var keep = el.boardRoom.value;
      el.boardRoom.textContent = "";
      add(el.boardRoom, rooms.map(function (name) { return T.option({ value: name }, roomLabel(name)); }));
      if (keep && rooms.indexOf(keep) !== -1) el.boardRoom.value = keep;
      else el.boardRoom.value = defRoom;
      return loadBoard();
    })
    .catch(function (err) {
      // Loading the rooms and then the board against a stale room is a board
      // that looks right and is wrong; say the listing failed instead.
      if (el.boardStatus) el.boardStatus.textContent = "Could not load the channel list: " + err.message + " Showing the last one loaded.";
      return loadBoard();
    });
}

/* The board's default room for the currently selected workspace (RFC 0001):
   `ws:<id>` — the project's `#general` feed — for a non-empty workspace, and
   the legacy `board` room for the default workspace so today's log does not
   move. */
function workspaceBoardRoom() {
  var ws = "";
  try { ws = window.clankerWorkspace || ""; } catch (e) { ws = ""; }
  return ws ? ("ws:" + ws) : "board";
}

/* The current workspace's board room is displayed as `#general` (RFC 0001);
   every other room keeps its wire name. */
function roomLabel(name) {
  if (name && name !== "board" && name === workspaceBoardRoom()) return "#general";
  return name;
}

function boardRoom() {
  return (el.boardRoom && el.boardRoom.value) || workspaceBoardRoom();
}

export function loadBoard() {
  return fetch("/api/board?room=" + encodeURIComponent(boardRoom()))
    .then(readJson)
    .then(function (d) {
      boardLoaded = true;
      renderBoard(d.board || { columns: [], cards: [] });
    })
    .catch(function (err) {
      var msg = "Could not load the board: " + err.message;
      el.boardStatus.textContent = msg;
      if (el.boardEmpty) el.boardEmpty.hidden = true;
      showLoadError(el.board, msg, loadBoard);
      throw err;
    });
}

/* Posts one board operation. `payload.goal_sync: false` marks a write that
   *came from* goal state (the goals module keeping a mirror card in step);
   those must not bounce back into a goal-status write below, or a single
   change would ping-pong between the two stores. The flag is stripped before
   sending — the board tool has no business seeing it. Resolves with the
   server's response (truthy) or false on failure, so callers can gate on it. */
export function postBoard(payload, status) {
  var skipGoalSync = payload.goal_sync === false;
  delete payload.goal_sync;
  if (!payload.room) payload.room = boardRoom();
  var forCurrentRoom = payload.room === boardRoom();
  return fetch("/api/board", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  })
    .then(readJson)
    .then(function (d) {
      // A response for another room's board must not clobber the one on
      // screen; the write itself still happened.
      if (forCurrentRoom) renderBoard(d.board || board);
      // A card move is the board speaking about the work's state. When the
      // A goal card follows its lane: Done and Review are verdict states,
      // Archive is retained history, and pulling it back into planning
      // reactivates it. Done -> Review is the visible re-evaluation action.
      if (!skipGoalSync && forCurrentRoom && payload.op === "move") {
        var gid = goalIdForCard(payload.id);
        var goal = null;
        if (gid) {
          var gl = goalState.val || [];
          for (var gi = 0; gi < gl.length; gi++) {
            if (gl[gi].id === gid) { goal = gl[gi]; break; }
          }
        }
        if (goal) {
          var cur = goal.status || "active";
          if (payload.column === doneColumn() && cur !== "done") {
            postGoal({ id: gid, status: "done" }, "Goal marked done from the board.");
          } else if (payload.column === "review" && cur !== "review") {
            postGoal({ id: gid, status: "review" }, "Goal moved to review from the board.");
          } else if (payload.column === "archive" && cur !== "archived") {
            postGoal({ id: gid, status: "archived" }, "Goal archived and retained for future learning.");
          } else if (payload.column !== doneColumn() && payload.column !== "review" && payload.column !== "archive" &&
                     (cur === "done" || cur === "review" || cur === "blocked" || cur === "archived" || cur === "abandoned")) {
            postGoal({ id: gid, status: "active" }, "Goal reactivated from the board.");
          }
        }
      }
      if (status) {
        // The app-level #board-status observer already toasts this line.
        el.boardStatus.textContent = status;
      }
      return d;
    })
    .catch(function (err) {
      el.boardStatus.textContent = "Could not update the board: " + err.message;
      return false;
    });
}

export function cardById(id) {
  for (var i = 0; i < board.cards.length; i++) {
    if (board.cards[i].id === id) return board.cards[i];
  }
  return null;
}

/* The board derives from the card set, the column set and the "only mine"
   filter. It used to clear #board-grid and rebuild it, which is what forced the
   focus snapshot and the per-card edit drafts: a sub-action anywhere rebuilt
   everything. */
var boardState = state({ columns: [], cards: [], mine: false, me: "", open: null, text: "", blockedOnly: false, priority: "", assignee: "", label: "" });

function boardFilterState() {
  return {
    text: (document.getElementById("board-filter-input") || {}).value || "",
    blockedOnly: !!(document.getElementById("board-filter-blocked") || {}).checked,
    priority: (document.getElementById("board-filter-priority") || {}).value || "",
    assignee: (document.getElementById("board-filter-assignee") || {}).value || "",
    label: (document.getElementById("board-filter-label") || {}).value || ""
  };
}

export function renderBoard(next) {
  if (next) { board.columns = next.columns || []; board.cards = next.cards || []; }
  var bf = boardFilterState();
  boardState.val = {
    columns: board.columns || [],
    cards: board.cards || [],
    mine: el.boardMine.checked,
    me: (el.instanceChip.textContent || "").trim(),
    open: openCardId,
    text: searchFold(bf.text.trim()),
    blockedOnly: bf.blockedOnly,
    priority: bf.priority,
    assignee: bf.assignee,
    label: bf.label
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
  add(el.cardColumn, (board.columns || []).map(function (c) {
    return T.option({ value: c.id }, c.title);
  }));
  if (keepCol) el.cardColumn.value = keepCol;
  if (_renderBoardList) _renderBoardList();
}

/* The lane — column shell, header, quick-add and its options menu — as
   Tailwind utilities over the cabinet tokens (ui/app/tailwind.src.css). The
   column is a `group`, so a child can read the states the column itself
   carries (collapsed, drop); the menu's open state is `data-open` beside the
   class, because the class is what the port keeps rewriting. */
var COL_CLASS = "group flex-none basis-[272px] min-w-[272px] max-w-[272px] flex max-h-[calc(100vh-14rem)] flex-col rounded-plate-lg bg-surface-2 pt-0 transition-colors transition-shadow transition-opacity duration-200 data-[collapsed=true]:basis-[40px] data-[collapsed=true]:min-w-[40px] data-[collapsed=true]:max-w-[40px] data-[collapsed=true]:cursor-pointer data-[collapsed=true]:opacity-80 data-[collapsed=true]:hover:opacity-100 data-[drop=true]:bg-[color-mix(in_srgb,var(--accent)_12%,var(--surface))] data-[drop=true]:shadow-[inset_0_0_0_2px_var(--accent)] data-[over=true]:shadow-[inset_0_0_0_1.5px_var(--warn)] max-[640px]:basis-full max-[640px]:min-w-0 max-[640px]:max-w-none";
var COL_HEAD_CLASS = "flex cursor-pointer select-none items-center justify-between gap-2 px-3 pb-2 pt-3 font-sans text-sm font-semibold tracking-wide group-data-[collapsed=true]:justify-center group-data-[collapsed=true]:px-2 group-data-[collapsed=true]:py-3";
var COL_TITLE_CLASS = "min-w-0 flex-1 text-sm font-bold text-fg group-data-[collapsed=true]:overflow-hidden group-data-[collapsed=true]:text-ellipsis group-data-[collapsed=true]:whitespace-nowrap group-data-[collapsed=true]:[writing-mode:vertical-rl] group-data-[collapsed=true]:rotate-180";
var COL_COUNT_CLASS = "tabular-nums text-fg-muted data-[over=true]:text-warn-text";
var COL_HEAD_ACTIONS_CLASS = "flex items-center gap-1";
var COL_ACTIONS_CLASS = "flex items-center gap-1 group-data-[collapsed=true]:hidden";
var CARDS_CLASS = "m-0 flex min-h-8 flex-1 list-none flex-col gap-2 overflow-y-auto px-2 py-1 pb-2 scroll-smooth [scrollbar-color:color-mix(in_srgb,var(--fg)_15%,transparent)_transparent] [scrollbar-width:thin] group-data-[collapsed=true]:hidden";
var EMPTY_SLOT_CLASS = "rounded-plate border border-dashed border-rule bg-[color-mix(in_srgb,var(--surface)_70%,var(--surface-2))] px-3 py-4 text-center text-sm text-fg-muted group-data-[collapsed=true]:hidden group-data-[drop=true]:border-accent group-data-[drop=true]:text-accent-text [&_button]:mt-2 [&_button]:rounded-capsule [&_button]:text-sm";
var QUICK_ADD_CLASS = "group rounded-b-plate-lg border-t border-rule/50 bg-transparent px-2 py-2 [hidden]:hidden group-data-[collapsed=true]:hidden";
var ADD_TRIGGER_CLASS = "flex w-full cursor-pointer items-center gap-2 rounded-plate-lg border-0 bg-transparent px-2 py-2 font-sans text-sm text-fg-muted transition-colors hover:bg-[color-mix(in_srgb,var(--fg)_8%,transparent)] hover:text-fg focus-visible:outline-2 focus-visible:outline-accent focus-visible:-outline-offset-1 group-data-[adding=true]:hidden pointer-coarse:min-h-11 [&_.icon]:opacity-60";
var ADD_FORM_CLASS = "hidden flex-col gap-2 group-data-[adding=true]:flex";
var ADD_TEXTAREA_CLASS = "max-h-[140px] min-h-[54px] w-full resize-y rounded-plate-lg border border-rule bg-surface px-3 py-2 font-sans text-sm leading-snug shadow-[var(--lift-low)] max-[640px]:[font-size:16px] focus-visible:border-accent focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1 focus-visible:shadow-[var(--ring)]";
var ADD_ACTIONS_CLASS = "flex items-center gap-2 [&_button]:min-h-8 [&_button]:rounded-plate-lg [&_button]:text-sm pointer-coarse:[&_button]:min-h-11";
var ADD_CANCEL_CLASS = "pointer-coarse:min-h-11 pointer-coarse:min-w-11 cursor-pointer border-0 bg-transparent px-2 text-base leading-none text-fg-muted hover:text-fg";
var LANE_CONTROL_CLASS = "pointer-coarse:min-h-11 pointer-coarse:min-w-11";
/* The board's detail rows, goal row and subtask checklist: one row vocabulary
   shared by the card detail, the goal card and the checklist tree. */
var DETAIL_HEAD_CLASS = "mt-4 mb-1 font-sans text-xs font-semibold text-fg-muted first:mt-3";
var DETAIL_ROW_CLASS = "flex min-w-0 flex-1 basis-full items-center gap-x-3 gap-y-2 [&_input[type=date]]:min-w-0 [&_input[type=date]]:flex-1 [&_input[type=text]]:min-w-0 [&_input[type=text]]:flex-1 [&_label]:flex-none [&_label]:basis-22 [&_label]:font-sans [&_label]:text-sm [&_label]:font-medium [&_label]:text-fg-muted [&_select]:min-w-0 [&_select]:flex-1 [&_textarea]:min-w-0 [&_textarea]:flex-1";
var GOAL_ROW_CLASS = "flex min-w-0 flex-col items-stretch gap-1 [&_.secondary]:w-full [&_input[type=number]]:box-border [&_input[type=number]]:w-full [&_input[type=number]]:min-w-0";
var CHECKLIST_ADD_CLASS = DETAIL_ROW_CLASS + " [&_button]:flex-none [&_input]:min-w-0 [&_input]:flex-1 [&_input]:basis-auto";
var CHECKLIST_DEPS_CLASS = "mb-1 ml-4 flex flex-wrap gap-1 [&_.card-flag]:inline-flex [&_.card-flag]:items-center [&_.card-flag]:gap-1";
var CHECKLIST_TREE_CLASS = "w-full min-w-0 overflow-x-auto overscroll-x-contain";
var CHECKLIST_ITEM_CLASS = "min-w-0 min-[641px]:min-w-32";
var CHECKLIST_CHILDREN_CLASS = "ml-4 border-l border-rule pl-3 max-[640px]:ml-1 max-[640px]:pl-1";
var CHECKLIST_DEP_ADD_CLASS = "mb-1 ml-4 flex gap-1 [&_select]:min-w-0 [&_select]:max-w-[18rem] max-[640px]:flex-wrap";

var MENU_BTN_CLASS = "secondary min-w-auto rounded-plate px-1 text-base leading-none hover:bg-surface-hover focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1 pointer-coarse:min-h-11 pointer-coarse:min-w-11";
var MENU_CLASS = "absolute right-0 top-full z-50 hidden min-w-[220px] rounded-plate-lg border border-border bg-surface px-0 py-1 shadow-[var(--lift)] data-[open=true]:block";
var MENU_TITLE_CLASS = "px-3 py-2 text-sm font-bold text-fg-muted";
var MENU_SEP_CLASS = "my-px border-0 border-t border-border";
var MENU_ITEM_CLASS = "block w-full cursor-pointer rounded-none border-0 bg-transparent px-3 py-2 text-left text-sm text-fg enabled:cursor-pointer enabled:hover:bg-surface-hover enabled:hover:text-accent focus-visible:outline-2 focus-visible:outline-accent focus-visible:-outline-offset-2 disabled:cursor-default";
var MENU_BACKDROP_CLASS = "fixed inset-0 z-40";

function boardColumn(col, s) {
  var shown = s.cards
    .filter(function (c) { return c.column === col.id && cardMatchesBoardFilter(c, s); })
    .sort(function (a, b) { return (a.order || 0) - (b.order || 0); });

  var over = col.wip && shown.length > col.wip;
  var count = T.span({
    class: COL_COUNT_CLASS,
    "data-over": over ? "true" : null,
    // Over the limit is said in words as well as colour, because colour is the
    // one thing forced-colors and colour blindness both take away.
    title: over ? shown.length + " of " + col.wip + ", over the limit" : null
  }, shown.length + (col.wip ? " / " + col.wip : ""));

  // Trello-style empty lane placeholder — with quick-add affordance
  var items = shown.map(function (c) {
    return T.li({ class: CARD_ITEM_CLASS }, cardNode(c), cardMemberControl(c), cardQuickActions(c));
  });
  if (!shown.length) {
    var emptySlot = document.createElement("li");
    emptySlot.className = EMPTY_SLOT_CLASS;
    if (boardHasActiveFilters(s)) {
      emptySlot.textContent = "No cards in this lane match the filters";
    } else {
      emptySlot.textContent = "Drop here, or ";
      var addLink = document.createElement("button");
      addLink.type = "button"; addLink.className = "secondary";
      addLink.textContent = "Add goal";
      addLink.addEventListener("click", function(e){ e.stopPropagation(); openQuickAdd(); });
      emptySlot.appendChild(addLink);
    }
    items.push(emptySlot);
  }
  var list = T.ul({
    class: CARDS_CLASS,
    id: "board-cards-" + col.id,
    "aria-label": col.title + ", " + plural(shown.length, { one: "card", other: "cards" })
  }, items);

  /* Trello-style add card: a subtle "+ Add a card" trigger that expands to
     a textarea form on click. Cards are goals, so completing the form fills
     the goal objective and shifts focus to the criterion. */
  var quickAdd = T.div({ class: QUICK_ADD_CLASS });

  // Trigger button (visible by default)
  var qaTrigger = document.createElement("button");
  qaTrigger.type = "button";
  qaTrigger.className = ADD_TRIGGER_CLASS;
  qaTrigger.dataset.addTrigger = "";
  qaTrigger.appendChild(icon("plus", 14));
  qaTrigger.appendChild(document.createTextNode(" Add a card"));

  // Form (hidden by default, shown on trigger click)
  var qaForm = document.createElement("div");
  qaForm.className = ADD_FORM_CLASS;
  var qaTextarea = document.createElement("textarea");
  qaTextarea.className = ADD_TEXTAREA_CLASS;
  qaTextarea.placeholder = "Enter a goal for this card…";
  qaTextarea.maxLength = 500;
  qaTextarea.rows = 2;
  var qaActions = document.createElement("div");
  qaActions.className = ADD_ACTIONS_CLASS;
  var qaSave = document.createElement("button"); qaSave.type = "button"; qaSave.className = "secondary"; qaSave.textContent = "Add card";
  var qaCancel = document.createElement("button"); qaCancel.type = "button"; qaCancel.className = ADD_CANCEL_CLASS; qaCancel.appendChild(icon("close", 12));
  qaCancel.setAttribute("aria-label", "Cancel adding a goal to " + col.title);
  qaActions.appendChild(qaSave);
  qaActions.appendChild(qaCancel);
  qaForm.appendChild(qaTextarea);
  qaForm.appendChild(qaActions);
  quickAdd.appendChild(qaTrigger);
  quickAdd.appendChild(qaForm);

  function openQuickAdd(){ quickAdd.dataset.adding = "true"; qaTextarea.focus(); }
  function closeQuickAdd(){ quickAdd.dataset.adding = ""; qaTextarea.value = ""; qaTextarea.title = ""; }
  qaTrigger.addEventListener("click", function(e){ e.stopPropagation(); openQuickAdd(); });
  qaCancel.addEventListener("click", function(e){ e.stopPropagation(); closeQuickAdd(); });
  // The trailing "@partial" in quick-add, resolved against known peers. Both
  // the Tab accept and the create path read it, so the mention is either
  // completed into an assignee or absent, never silently dropped.
  function qaMention() {
    var v = qaTextarea.value;
    var at = v.lastIndexOf("@");
    if (at === -1) return null;
    var tail = v.slice(at + 1);
    if (/[\s]/.test(tail)) return null;
    var peers = (_getKnownPeers() || []).map(function(p){ return p.name || p; });
    var hit = peers.find(function(n){ return searchFold(n).indexOf(searchFold(tail)) === 0; });
    return hit ? { name: hit, at, end: at + 1 + tail.length } : null;
  }
  qaTextarea.addEventListener("keydown", function(e){
    if (e.key === "Enter" && !e.shiftKey && qaTextarea.value.trim()) { e.preventDefault(); doCreate(); }
    else if (e.key === "Escape") { e.preventDefault(); closeQuickAdd(); }
    else if (e.key === "Tab" && !e.shiftKey && qaMention()) {
      e.preventDefault();
      var m = qaMention();
      var v = qaTextarea.value;
      qaTextarea.value = v.slice(0, m.at) + "@" + m.name + " " + v.slice(m.end);
      qaTextarea.title = "";
    }
  });
  // Slack-like: typing @ in quick-add shows available assignees as placeholder hint
  qaTextarea.addEventListener("input", function(){
    var m = qaMention();
    qaTextarea.title = m ? "Assign to @" + m.name + " (press Tab to accept)" : "";
  });
  function doCreate(){
    var raw = qaTextarea.value;
    // An @mention addresses the assignee, not the objective: the goal record
    // has no assignee field, so the name is dropped from the text here and
    // written onto the card the goal mirror files below.
    var m = qaMention();
    var assignee = m ? m.name : "";
    var t = (m ? raw.slice(0, m.at) + " " + raw.slice(m.end) : raw).trim().replace(/\s+/g, " ");
    if (!requireText(qaTextarea, "Write the goal for this card.")) return;
    // The box can hold text and still leave nothing once the mention is
    // stripped, so the second refusal says which of the two it is.
    if (!t) {
      qaTextarea.setCustomValidity("Write the goal itself; the @mention only names who it is for.");
      qaTextarea.reportValidity();
      qaTextarea.setCustomValidity("");
      return;
    }
    closeQuickAdd();
    el.boardStatus.textContent = "Creating goal card…";
    postGoal({ objective: t }, "Goal card saved. It has not started.").then(function (d) {
      if (!d) {
        el.boardStatus.textContent = "Could not create the goal card.";
        return;
      }
      // The goal mirror files a new card in the lane the goal's state asks
      // for, so a card added under Doing or Archive used to appear in Ready.
      var card = mirrorCardForObjective(t);
      if (card && col.id && card.column !== col.id) {
        postBoard({ op: "move", id: card.id, column: col.id, goal_sync: false }, null);
      }
      if (card && assignee) postBoard({ op: "update", id: card.id, assignee }, null);
      el.boardStatus.textContent = "Added to " + (col.title || "the board") +
        (assignee ? ", assigned to " + assignee + "." : ".");
    });
  }
  qaSave.addEventListener("click", function(e){ e.stopPropagation(); doCreate(); });
  var colEl = T.section({
    class: COL_CLASS,
    "data-column": col.id,
    "aria-labelledby": "board-col-" + col.id,
    ondragover (e) { e.preventDefault(); colEl.setAttribute("data-drop", "true"); },
    ondragleave () { colEl.removeAttribute("data-drop"); },
    ondrop (e) {
      e.preventDefault();
      colEl.removeAttribute("data-drop");
      var id = e.dataTransfer.getData("text/plain");
      if (id) postBoard({ op: "move", id, column: col.id }, "Moved to " + col.title + ".");
    }
  },
    T.div({ class: COL_HEAD_CLASS },
      (function(){
        var collapse = document.createElement("button");
        collapse.type = "button"; collapse.className = "secondary";
        collapse.title = "Collapse lane";
        collapse.classList.add(...LANE_CONTROL_CLASS.split(" "));
        collapse.setAttribute("aria-label", "Collapse " + col.title + " lane");
        collapse.setAttribute("aria-expanded", "true");
        collapse.setAttribute("aria-controls", "board-cards-" + col.id);
        function setCollapseFace(expanded) {
          collapse.textContent = "";
          collapse.appendChild(icon(expanded ? "chevronLeft" : "chevron", 14));
        }
        setCollapseFace(true);
        collapse.addEventListener("click", function(e){
          e.stopPropagation();
          var isCol = colEl.getAttribute("data-collapsed") === "true";
          colEl.setAttribute("data-collapsed", String(!isCol));
          setCollapseFace(isCol);
          collapse.title = isCol ? "Collapse lane" : "Expand lane";
          collapse.setAttribute("aria-label", (isCol ? "Collapse " : "Expand ") + col.title + " lane");
          collapse.setAttribute("aria-expanded", String(isCol));
        });
        return collapse;
      })(),
      T.h3({ class: COL_TITLE_CLASS, id: "board-col-" + col.id }, col.title),
      T.span({ class: COL_HEAD_ACTIONS_CLASS },
        (function(){
          var add = document.createElement("button");
          add.type = "button"; add.className = "secondary";
          add.title = "Define a new goal card";
          add.classList.add(...LANE_CONTROL_CLASS.split(" "));
          add.setAttribute("aria-label", "Add a goal to " + col.title);
          add.appendChild(icon("plus", 14));
          add.addEventListener("click", function(e){
            e.stopPropagation();
            // Trello-style: open the inline quick-add form
            if (quickAdd.dataset.adding !== "true") openQuickAdd(); else closeQuickAdd();
          });
          var wrap = document.createElement("span");
          wrap.appendChild(add);
          return wrap;
        })(),
        /* Trello-style column options menu */
        (function(){
          var menuBtn = document.createElement("button");
          menuBtn.type = "button"; menuBtn.className = MENU_BTN_CLASS;
          menuBtn.appendChild(icon("more", 14)); menuBtn.title = "Column actions";
          menuBtn.setAttribute("aria-label", "Actions for " + col.title);
          menuBtn.setAttribute("aria-haspopup", "true");
          menuBtn.addEventListener("click", function(e){
            e.stopPropagation();
            /* close any other open column menu */
            document.querySelectorAll("[data-col-menu][data-open=true]").forEach(function(m){ m.dataset.open = ""; });
            var menu = document.createElement("div");
            menu.className = MENU_CLASS;
            menu.dataset.colMenu = "";
            menu.dataset.open = "true";
            menu.setAttribute("role", "menu");
            var title = document.createElement("div");
            title.className = MENU_TITLE_CLASS;
            title.textContent = "List actions";
            menu.appendChild(title);

            var sep1 = document.createElement("hr");
            sep1.className = MENU_SEP_CLASS;
            menu.appendChild(sep1);

            /* Reorders this lane in place, without a write: a sort is a way of
               reading the lane, and the board tool holds no per-column order to
               post it to.

               The node that moves is the card's <li>, not the card. A card is a
               button carrying `data-card`, wrapped in a list item; appending the
               button would pull it out of its item and leave an empty one behind.
               This asked for `[data-id]`, an attribute no card has ever carried,
               so all three sorts found nothing and did nothing at all. */
            function reorderLane(cmp) {
              var listEl = document.getElementById("board-cards-" + col.id);
              if (!listEl) return;
              shown.slice().sort(cmp).forEach(function (c) {
                var node = listEl.querySelector("[data-card='" + c.id + "']");
                var item = node && (node.closest ? node.closest("li") : node.parentNode);
                if (item) listEl.appendChild(item);
              });
            }
            function sortItem(label, cmp) {
              var b = document.createElement("button");
              b.type = "button"; b.className = MENU_ITEM_CLASS;
              b.textContent = label;
              b.setAttribute("role", "menuitem");
              b.addEventListener("click", function(){
                menu.remove(); backdrop.remove();
                reorderLane(cmp);
              });
              menu.appendChild(b);
            }

            sortItem("Sort by priority", function(a, b){ return priorityRank(a) - priorityRank(b); });
            sortItem("Sort by date created", function(a, b){ return (b.created || 0) - (a.created || 0); });
            sortItem("Sort alphabetically", function(a, b){ return (a.title || "").localeCompare(b.title || ""); });

            var sep2 = document.createElement("hr");
            sep2.className = MENU_SEP_CLASS;
            menu.appendChild(sep2);

            /* Move all cards to… (quick-move to another column) */
            var moveAll = document.createElement("button");
            moveAll.type = "button"; moveAll.className = MENU_ITEM_CLASS;
            moveAll.textContent = "Move all cards in this list…";
            moveAll.setAttribute("role", "menuitem");
            if (shown.length === 0) { moveAll.disabled = true; moveAll.style.opacity = "0.5"; }
            moveAll.addEventListener("click", function(){
              /* replace menu contents with column picker */
              while (menu.firstChild) menu.removeChild(menu.firstChild);
              var pickTitle = document.createElement("div");
              pickTitle.className = MENU_TITLE_CLASS;
              pickTitle.textContent = "Move all to…";
              menu.appendChild(pickTitle);
              var sep = document.createElement("hr");
              sep.className = MENU_SEP_CLASS;
              menu.appendChild(sep);
              s.columns.forEach(function(dest){
                if (dest.id === col.id) return;
                var opt = document.createElement("button");
                opt.type = "button"; opt.className = MENU_ITEM_CLASS;
                opt.textContent = dest.title;
                opt.setAttribute("role", "menuitem");
                opt.addEventListener("click", function(){
                  menu.remove(); backdrop.remove();
                  shown.forEach(function(c){
                    postBoard({ op: "move", id: c.id, column: dest.id }, null);
                  });
                  // The shared themed toast(): keep this off the app-level
                  // error path and on the "moved" update status.
                  toast("Moved " + plural(shown.length, { one: "card", other: "cards" }) + " to " + dest.title);
                });
                menu.appendChild(opt);
              });
            });
            menu.appendChild(moveAll);

            /* close backdrop */
            var backdrop = document.createElement("div");
            backdrop.className = MENU_BACKDROP_CLASS;
            backdrop.addEventListener("click", function(){ menu.remove(); backdrop.remove(); });

            menuBtn.parentElement.style.position = "relative";
            menuBtn.parentElement.appendChild(menu);
            document.body.appendChild(backdrop);
          });
          return menuBtn;
        })()
      ),
      count),
    list,
    quickAdd);
  return colEl;
}


/* ---- Trello-style label colours ---- */
var LABEL_COLORS = ["green","yellow","orange","red","purple","blue","sky","pink","lime","black"];

/* The shared board popups (member, priority, label and column pickers), the
   label editor, the work-in-progress banner and the activity list. The avatar
   tones pick from the chat-hue palette: eight utilities for eight hues, chosen
   once instead of eight classes the port would have to keep numbering. */
var POPUP_CLASS = "absolute z-[999] min-w-40 rounded-plate-lg border border-rule bg-surface-raised p-2 shadow-[var(--lift)]";
var POPUP_ANCHORED_CLASS = POPUP_CLASS + " left-0 top-full mt-1";
var POPUP_TITLE_CLASS = "mb-1 border-b border-rule px-2 pb-2 pt-1 text-sm font-semibold text-fg-muted data-[plain=true]:border-b-0";
var POPUP_ITEM_CLASS = "flex w-full cursor-pointer items-center gap-2 rounded-plate-lg border-0 bg-transparent px-2 py-2 text-left text-sm text-fg hover:bg-surface-hover data-[current=true]:bg-accent-dim data-[current=true]:font-bold data-[muted=true]:text-fg-muted";
var POPUP_AVATAR_CLASS = "flex h-6 w-6 flex-none items-center justify-center rounded-full bg-accent text-2xs font-bold text-on-accent";
var BOARD_REL_CLASS = "relative";
var LABELS_ROW_CLASS = "mb-3 flex flex-wrap gap-1";
var LABEL_ADD_BTN_CLASS = "cursor-pointer rounded-capsule border border-dashed border-rule bg-transparent px-2 py-0.5 text-xs text-fg-muted";
var LABEL_NAME_ROW_CLASS = "col-span-full flex gap-1 py-1";
var LABEL_NAME_INPUT_CLASS = "min-w-0 flex-1 rounded-plate-lg border border-rule bg-surface px-2 py-0.5 text-sm text-fg";
var LABEL_NAME_CONFIRM_CLASS = "flex-none cursor-pointer rounded-plate-lg border-0 bg-accent px-2 py-0.5 text-sm text-on-accent";
var WIP_BANNER_CLASS = "mx-2 my-1 rounded-plate border border-warn bg-[color-mix(in_srgb,var(--warn)_12%,var(--surface))] px-2 py-1 text-center text-xs font-semibold text-warn-text";
var DETAIL_META_LABEL_CLASS = "text-2xs font-semibold text-fg-muted";
var DETAIL_META_VALUE_CLASS = "inline-flex items-center gap-1 rounded-plate-lg bg-surface-2 px-2 py-1 text-sm text-fg";
var DETAIL_DESC_AREA_CLASS = "max-h-[300px] min-h-20 w-full resize-y rounded-plate-lg border border-rule bg-surface px-3 py-3 font-sans text-sm leading-normal transition-colors focus-visible:border-accent focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1 focus-visible:shadow-[var(--ring)]";
var ACTIVITY_CLASS = "flex flex-col gap-0";
var ACTIVITY_ITEM_CLASS = "flex gap-3 border-b border-rule py-2 last:border-b-0";
var ACTIVITY_AVATAR_CLASS = "mr-0 mt-px flex h-8 w-8 flex-none select-none items-center justify-center rounded-full text-xs font-bold tracking-wide";
var ACTIVITY_CONTENT_CLASS = "min-w-0 flex-1";
var ACTIVITY_WHO_CLASS = "mr-2 text-sm font-semibold text-fg";
var ACTIVITY_WHEN_CLASS = "text-sm tabular-nums text-fg-muted";
var ACTIVITY_TEXT_CLASS = "mt-1 whitespace-pre-wrap wrap-anywhere rounded-plate border border-rule bg-surface-raised px-3 py-2 text-sm leading-normal text-fg";

function menuPopup(anchored) {
  var popup = document.createElement("div");
  popup.className = anchored ? POPUP_ANCHORED_CLASS : POPUP_CLASS;
  return popup;
}
function menuTitle(text, plain) {
  var t = document.createElement("div");
  t.className = POPUP_TITLE_CLASS;
  if (plain) t.setAttribute("data-plain", "true");
  t.textContent = text;
  return t;
}
function menuItem(opts) {
  opts = opts || {};
  var btn = document.createElement("button");
  btn.type = "button";
  btn.className = POPUP_ITEM_CLASS;
  if (opts.muted) btn.setAttribute("data-muted", "true");
  if (opts.current) btn.setAttribute("data-current", "true");
  return btn;
}
function menuAvatar(name) {
  var av = document.createElement("span");
  av.className = POPUP_AVATAR_CLASS;
  av.textContent = (name || "?").slice(0, 2).toUpperCase();
  return av;
}
// The card avatar and the detail sidebar open the same Members picker; only
// the popup's anchoring differs.
function memberPicker(c, anchored) {
  var popup = menuPopup(anchored);
  popup.classList.add("member-picker-popup");
  popup.appendChild(menuTitle("Members", !anchored));
  var unBtn = menuItem({ muted: true });
  unBtn.appendChild(icon("close", 12));
  unBtn.appendChild(document.createTextNode(" Remove member"));
  unBtn.addEventListener("click", function () { popup.remove(); postBoard({ op: "update", id: c.id, assignee: "" }, "Unassigned."); });
  popup.appendChild(unBtn);
  var peers = (_getKnownPeers() || []).map(function (p) { return typeof p === "string" ? p : p.name || p; });
  if (c.assignee && peers.indexOf(c.assignee) === -1) peers.unshift(c.assignee);
  peers.forEach(function (name) {
    var opt = menuItem({ current: name === c.assignee });
    opt.appendChild(menuAvatar(name));
    opt.appendChild(document.createTextNode(name));
    opt.addEventListener("click", function () { popup.remove(); postBoard({ op: "update", id: c.id, assignee: name }, "Assigned to " + name + "."); });
    popup.appendChild(opt);
  });
  return popup;
}
function dismissOnOutside(node, extra) {
  var closePop = function (ev) {
    if (node.contains(ev.target) || (extra && extra.contains && extra.contains(ev.target))) return;
    if (ev.target === extra) return;
    node.remove();
    document.removeEventListener("click", closePop, true);
  };
  setTimeout(function () { document.addEventListener("click", closePop, true); }, 0);
  return closePop;
}

/* The card face — shell and its states, body, title, description preview,
   progress bar, flag and meta row — as Tailwind utilities over the cabinet
   tokens. The card is a `group`: the title's hover and current colours read the
   card's own state, and the states it carries are data attributes. */
var CARD_ITEM_CLASS = "relative";
var CARD_CLASS = "group relative flex w-full cursor-pointer flex-col overflow-hidden rounded-plate border border-rule bg-surface p-0 text-left font-sans text-sm leading-normal text-fg shadow-[var(--lift)] transition duration-150 hover:z-1 hover:border-border hover:shadow-[var(--lift-high)] focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1 active:translate-y-0 aria-[current=true]:shadow-[inset_3px_0_0_var(--accent),var(--lift-low)] data-[dragging=true]:rotate-1 data-[dragging=true]:scale-[0.97] data-[dragging=true]:opacity-85 data-[dragging=true]:shadow-[var(--lift-high)]";
var CARD_BODY_CLASS = "flex flex-col gap-1 px-3 pb-2 pt-2";
var CARD_TITLE_CLASS = "font-medium leading-snug wrap-anywhere group-hover:text-accent-text group-focus-visible:text-accent-text group-aria-[current=true]:text-accent-text";
var CARD_DESC_PREVIEW_CLASS = "mt-px line-clamp-2 text-xs leading-snug text-fg-muted";
var CARD_PROGRESS_CLASS = "text-xs text-fg-muted";
var CARD_PROGRESS_BAR_CLASS = "mt-1 h-1 overflow-hidden rounded-capsule bg-surface-2 [&>span]:block [&>span]:h-full [&>span]:rounded-capsule [&>span]:bg-accent [&[data-done=true]>span]:bg-ok-fill";
var CARD_BOTTOM_CLASS = "mt-px flex items-center justify-between gap-1";
var CARD_FLAG_CLASS = "rounded-capsule border border-rule px-2 py-1 text-xs font-medium data-[priority=high]:border-danger data-[priority=high]:bg-danger data-[priority=high]:text-on-danger data-[priority=low]:bg-[color-mix(in_srgb,var(--surface-2)_85%,transparent)] data-[priority=low]:text-fg-muted data-[due=soon]:border-warn data-[due=soon]:bg-warn data-[due=soon]:text-on-danger data-[due=late]:border-danger data-[due=late]:bg-danger data-[due=late]:text-on-danger data-[blocked=true]:bg-[color-mix(in_srgb,var(--surface-2)_88%,transparent)] data-[blocked=true]:text-fg-muted data-[goal=true]:bg-[color-mix(in_srgb,var(--surface-2)_88%,transparent)] data-[goal=true]:text-accent-text";
var CARD_META_CLASS = "flex flex-wrap gap-x-2 gap-y-1 text-xs leading-snug text-fg-muted tabular-nums";

function cardNode(c) {
  var b = document.createElement("button");
  b.type = "button";
  b.className = CARD_CLASS;
  if (c.priority && c.priority !== "normal") b.setAttribute("data-priority", c.priority);
  b.draggable = true;
  b.setAttribute("data-card", c.id);
  if (c.id === openCardId) b.setAttribute("aria-current", "true");
  // The card opens the card-detail dialog; say so and mirror its state.
  b.setAttribute("aria-haspopup", "dialog");
  b.setAttribute("aria-expanded", c.id === openCardId ? "true" : "false");

  // Trello cover strip — priority or label-color tint at top edge; also cover_color
  var labels = c.labels || [];
  var coverColor = c.cover_color || (labels.length && labels[0].color ? labels[0].color : null);
  if (coverColor) {
    var cover = document.createElement("div");
    cover.className = CARD_COVER_CLASS;
    cover.setAttribute("data-color", coverColor);
    b.appendChild(cover);
  } else if (c.priority && c.priority !== "normal") {
    var cover2 = document.createElement("div");
    cover2.className = CARD_COVER_CLASS;
    cover2.setAttribute("data-priority", c.priority);
    b.appendChild(cover2);
  }

  // Card body wrapper (inside padding)
  var body = document.createElement("div");
  body.className = CARD_BODY_CLASS;

  // The only way to move a card without a pointer, so it says so rather than
  // living in a source comment.
  b.setAttribute("aria-keyshortcuts", "Control+ArrowLeft Control+ArrowRight");
  b.title = "Ctrl or Cmd with the arrow keys moves this card between columns";

  // Labels row — Trello-style compact colour pills
  if (labels.length) {
    var labelsEl = document.createElement("span");
    labelsEl.className = CARD_LABELS_CLASS;
    labels.forEach(function(lbl) {
      var pill = document.createElement("span");
      pill.className = CARD_LABEL_CLASS;
      pill.setAttribute("data-color", lbl.color || "blue");
      pill.textContent = lbl.text || lbl.color || "";
      pill.title = lbl.text || lbl.color || "";
      labelsEl.appendChild(pill);
    });
    body.appendChild(labelsEl);
  }

  var title = document.createElement("span");
  title.className = CARD_TITLE_CLASS;
  title.textContent = c.title;
  body.appendChild(title);

  // Description preview. The card's notes are `body` — the field the detail
  // panel edits, the filter searches and the create payload sends. This read
  // `c.notes`, which nothing on either side of the wire has ever set, so no
  // card ever showed a preview.
  if (c.body && c.body.trim()) {
    var descPrev = document.createElement("span");
    descPrev.className = CARD_DESC_PREVIEW_CLASS;
    descPrev.textContent = clip(c.body.trim(), 120);
    body.appendChild(descPrev);
  }

  // Trello-style badges row (due, subtasks, blocked, goal, cost)
  var badges = document.createElement("span");
  badges.className = CARD_BADGES_CLASS;
  var hasBadges = false;

  if (c.deadline) {
    var ds = dueState(c);
    var due = document.createElement("span");
    due.className = CARD_BADGE_CLASS;
    due.setAttribute("data-due", ds);
    due.appendChild(icon("calendar", 14));
    due.appendChild(document.createTextNode(" " + (ds === "late" ? "Late · " : ds === "soon" ? "Soon · " : "") + fmtDeadline(c.deadline)));
    due.title = "Due " + fmtDeadline(c.deadline);
    badges.appendChild(due);
    hasBadges = true;
  }

  if ((c.subtasks || []).length) {
    var doneN = c.subtasks.filter(function (s) { return s.done; }).length;
    var totalN = c.subtasks.length;
    var subBadge = document.createElement("span");
    subBadge.className = CARD_BADGE_CLASS;
    if (doneN === totalN && totalN > 0) subBadge.setAttribute("data-done", "true");
    subBadge.appendChild(icon("checklist", 14));
    subBadge.appendChild(document.createTextNode(" " + doneN + "/" + totalN));
    subBadge.title = doneN + " of " + totalN + " checklist items complete";
    badges.appendChild(subBadge);
    hasBadges = true;
  }

  var blocked = blockers(c);
  if (blocked.length) {
    var bl = document.createElement("span");
    bl.className = CARD_BADGE_CLASS;
    bl.style.color = "var(--warn-text)";
    bl.appendChild(icon("blocked", 14));
    bl.appendChild(document.createTextNode(" " + blocked.length));
    bl.title = "Blocked by " + plural(blocked.length, { one: "card", other: "cards" });
    badges.appendChild(bl);
    hasBadges = true;
  }

  if (c.goal) {
    var gf = document.createElement("span");
    gf.className = CARD_BADGE_CLASS;
    gf.style.color = "var(--accent-text)";
    gf.appendChild(icon("goal", 14));
    gf.title = "Mirrors a goal, kept in step with the Goals view";
    badges.appendChild(gf);
    // The same start actuator the "Start work" button shows on the open card,
    // surfaced on the closed card so goal runs are visible at a glance. While
    // a run for this goal is in flight (streaming here or on another client)
    // the actuator lights up, so the closed card shows the live run state.
    var sw = document.createElement("span");
    sw.className = CARD_BADGE_CLASS;
    sw.appendChild(icon("rocket", 14));
    sw.title = "Goal: Start work (opens a run)";
    if (isGoalRunning(c.goal)) {
      sw.dataset.goalRun = "true";
      sw.title = "Goal run in progress";
    }
    badges.appendChild(sw);
    hasBadges = true;
  }

  if ((c.activity || []).length) {
    var actBadge = document.createElement("span");
    actBadge.className = CARD_BADGE_CLASS;
    actBadge.appendChild(icon("activity", 14));
    actBadge.appendChild(document.createTextNode(" " + c.activity.length));
    actBadge.title = c.activity.length + " activity entries";
    badges.appendChild(actBadge);
    hasBadges = true;
  }

  if (c.usage && c.usage.cost) {
    var costBadge = document.createElement("span");
    costBadge.className = CARD_BADGE_CLASS;
    costBadge.textContent = fmtCost(c.usage.cost);
    costBadge.title = "Cost so far";
    badges.appendChild(costBadge);
    hasBadges = true;
  }

  if (hasBadges) body.appendChild(badges);

  // Progress bar for subtasks (below badges, full card width)
  if ((c.subtasks || []).length) {
    var doneN2 = c.subtasks.filter(function (s) { return s.done; }).length;
    var totalN2 = c.subtasks.length;
    var pct2 = totalN2 ? Math.round(doneN2 / totalN2 * 100) : 0;
    var bar = document.createElement("div");
    bar.className = CARD_PROGRESS_BAR_CLASS;
    bar.setAttribute("data-done", String(doneN2 === totalN2 && totalN2 > 0));
    bar.setAttribute("role", "progressbar");
    bar.setAttribute("aria-valuenow", String(pct2));
    bar.setAttribute("aria-valuemin", "0");
    bar.setAttribute("aria-valuemax", "100");
    bar.setAttribute("aria-label", doneN2 + " of " + totalN2 + " checklist items complete");
    var fill = document.createElement("span");
    fill.style.width = pct2 + "%";
    bar.appendChild(fill);
    body.appendChild(bar);
  }

  // Bottom row: priority flag + members avatar
  var bottom = document.createElement("span");
  bottom.className = CARD_BOTTOM_CLASS;
  var hasBottom = false;

  if (c.priority && c.priority !== "normal") {
    var pr = document.createElement("span");
    pr.className = CARD_FLAG_CLASS;
    pr.setAttribute("data-priority", c.priority);
    pr.textContent = c.priority;
    bottom.appendChild(pr);
    hasBottom = true;
  }

  /* Trello-style member avatar (initials) when assigned. This one is scenery:
     it reserves the row the real control is painted over, and says nothing to
     the accessibility tree, which reads the sibling button `cardMemberControl`
     builds instead. See the note there for why it cannot live in here. */
  if (c.assignee) {
    var membersWrap = document.createElement("span");
    membersWrap.className = CARD_MEMBERS_CLASS;
    var slot = document.createElement("span");
    slot.className = CARD_MEMBER_SLOT_CLASS;
    slot.setAttribute("aria-hidden", "true");
    slot.textContent = memberInitials(c.assignee);
    membersWrap.appendChild(slot);
    bottom.appendChild(membersWrap);
    hasBottom = true;
  }

  if (hasBottom) body.appendChild(bottom);

  b.appendChild(body);

  b.addEventListener("click", function () {
    openCardId = openCardId === c.id ? null : c.id;
    renderBoard(board);
  });

  // ---- Drag-and-drop: within-column reordering + cross-column move ----
  b.addEventListener("dragstart", function (e) {
    e.dataTransfer.setData("text/plain", c.id);
    e.dataTransfer.effectAllowed = "move";
    b.setAttribute("data-dragging", "true");
  });
  b.addEventListener("dragend", function () {
    b.removeAttribute("data-dragging");
    clearDropIndicators();
  });
  // Cards are also drop targets for intra-column reorder
  b.addEventListener("dragover", function(e) {
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    showDropIndicator(b, e);
  });
  b.addEventListener("dragleave", function() {
    clearDropIndicators();
  });
  b.addEventListener("drop", function(e) {
    e.preventDefault(); e.stopPropagation();
    clearDropIndicators();
    var draggedId = e.dataTransfer.getData("text/plain");
    if (!draggedId || draggedId === c.id) return;
    handleCardDrop(draggedId, c.column);
  });

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

/* The card's chips, covers and in-list subtitle, as Tailwind utilities. The
   ten label hues and the eight cover hues were one rule each keyed on
   `data-color`, which is what the utilities still read. */
var CARD_LABELS_CLASS = "flex flex-wrap gap-1 [&>span]:cursor-default";
var CARD_LABEL_CLASS = "h-2 w-10 cursor-pointer overflow-hidden rounded-plate-lg p-0 font-bold leading-snug tracking-wide text-fg [font-size:0] transition-[font-size,width,height,padding] duration-150 [transition-timing-function:cubic-bezier(0.2,0.9,0.3,1)] group-hover:h-auto group-hover:w-auto group-hover:min-w-12 group-hover:px-2 group-hover:py-0.5 group-hover:text-xs group-focus-within:h-auto group-focus-within:w-auto group-focus-within:min-w-12 group-focus-within:px-2 group-focus-within:py-0.5 group-focus-within:text-xs data-[open=true]:h-auto data-[open=true]:w-auto data-[open=true]:cursor-pointer data-[open=true]:px-2 data-[open=true]:py-0.5 data-[open=true]:text-xs data-[sample=true]:h-auto data-[sample=true]:w-auto data-[sample=true]:flex-none data-[sample=true]:px-2 data-[sample=true]:py-0.5 data-[sample=true]:text-2xs card-hue";
var CARD_BADGES_CLASS = "mt-px flex flex-wrap items-center gap-x-2 gap-y-1";
var CARD_BADGE_CLASS = "inline-flex items-center gap-1 rounded-plate-lg px-1 py-px text-xs tabular-nums text-fg-muted [&_.icon]:h-3.5 [&_.icon]:w-3.5 [&_.icon]:opacity-65 data-[due=soon]:bg-warn data-[due=soon]:text-on-danger data-[due=late]:animate-card-pulse data-[due=late]:bg-danger data-[due=late]:text-on-danger data-[done=true]:text-ok data-[done=true]:[&_.icon]:opacity-100 data-[goal-run=true]:animate-card-pulse-fast data-[goal-run=true]:text-accent-text";
var CARD_COVER_CLASS = "h-1 flex-none rounded-t-plate bg-rule data-[color]:h-10 data-[priority=high]:h-1 data-[priority=high]:bg-danger data-[priority=low]:h-[3px] data-[priority=low]:bg-surface-2 card-hue";
var CARD_COVER_IMG_CLASS = "block h-35 w-full rounded-t-plate object-cover";
var CARD_COVER_IMG_OVER_CLASS = "h-auto bg-transparent";
var CARD_IN_LIST_CLASS = "mt-0.5 text-sm text-fg-muted";
var CARD_IN_LIST_NAME_CLASS = "cursor-pointer text-fg underline decoration-dotted";

function memberInitials(name) {
  return ((name || "").trim().substring(0, 2) || "?").toUpperCase();
}

/* The reassign control, a *sibling* of the card button for the same reasons the
   hover actions below are, plus one of its own.

   It used to be a `<span role="button" tabindex="0">` inside `cardNode`'s
   button, with the whole member picker appended into that span. Three things
   were wrong with that:

     * A button's children are presentational in ARIA, so neither the avatar nor
       any member in the picker it opened was in the accessibility tree at all:
       reassigning from the board was mouse-only, and nesting interactive
       content inside a button is invalid HTML besides (axe `nested-interactive`,
       the same finding the hover actions were moved out for).
     * A picker item's click bubbled up to the avatar's own click listener,
       which called `stopPropagation` and re-opened the picker -- so choosing a
       member left the popup on screen instead of closing it. The detail
       sidebar's copy of this picker is a sibling of its button, not a child,
       which is why only the card avatar had that.
     * `.card` is `overflow: hidden` and is the popup's containing-block
       ancestor, so a 160px-wide popup opened from the avatar was clipped to the
       card's own box. `.board-card-item` clips nothing, so out here it is not.

   Returns null when nobody is assigned; `appendInto` drops that. */
function cardMemberControl(c) {
  if (!c.assignee) return null;
  var wrap = document.createElement("span");
  wrap.className = CARD_MEMBERS_OVERLAY_CLASS;
  var btn = document.createElement("button");
  btn.type = "button";
  btn.className = CARD_MEMBER_CLASS;
  btn.textContent = memberInitials(c.assignee);
  btn.title = c.assignee + ", click to reassign";
  btn.setAttribute("aria-label", "Reassign " + c.assignee + ": " + (c.title || c.id));
  btn.setAttribute("aria-haspopup", "menu");
  btn.setAttribute("aria-expanded", "false");
  btn.addEventListener("click", function (e) {
    // The card behind this is a button too, and clicking the avatar must not
    // also open the card.
    e.stopPropagation();
    var mine = wrap.querySelector(".member-picker-popup");
    var open = document.querySelector(".member-picker-popup");
    if (open) open.remove();
    if (mine) return;
    var popup = memberPicker(c, false);
    /* Every way this popup closes -- a member picked, a click outside, the
       button again -- goes through `remove`, so that is the one seam where the
       button's state is put back. Without it `aria-expanded` would latch on
       "true" the first time a card was reassigned. */
    var removeSelf = popup.remove.bind(popup);
    popup.remove = function () {
      removeSelf();
      btn.setAttribute("aria-expanded", "false");
    };
    dismissOnOutside(popup, btn);
    wrap.appendChild(popup);
    btn.setAttribute("aria-expanded", "true");
  });
  wrap.appendChild(btn);
  return wrap;
}

/* The card's hover actions, built as a *sibling* of the card button rather
   than a child of it.

   They used to be appended into `cardNode`'s button. A button's children are
   presentational in ARIA, so a screen reader flattened both of these away and
   there was no way at all to reach them; nesting interactive content inside a
   button is also invalid HTML, and axe reported it as `nested-interactive`
   (logged in docs/reviews/webui.md's 2026-08-12 sweep as a handoff item). The
   card's own `<li>` is the positioning context now, so the overlay still sits
   on the card's top-right corner and still appears on hover or focus, while
   both controls are ordinary buttons the accessibility tree can see. */
/* The rest of the card face: the member avatars and the overlay that carries
   the real reassign control, the hover quick-actions and the drop indicator.
   A starred mark and a drag ghost used to be styled here; nothing has set
   `data-starred` or named `board-drag-ghost` for a while, so both are gone. */
var CARD_MEMBERS_CLASS = "ml-auto flex items-center";
var CARD_MEMBER_CLASS = "relative -ml-1.5 grid h-7 w-7 cursor-pointer place-items-center rounded-capsule border-2 border-surface bg-accent p-0 font-sans text-xs font-bold leading-none text-on-accent transition duration-150 first:ml-0 hover:z-2 hover:-translate-y-0.5 hover:shadow-[var(--lift)] focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-2";
var CARD_MEMBER_SLOT_CLASS = CARD_MEMBER_CLASS + " invisible";
var CARD_MEMBERS_OVERLAY_CLASS = "absolute bottom-[calc(0.5rem+1px)] right-[calc(0.65rem+1px)] z-3 flex items-center";
var CARD_QUICK_CLASS = "absolute right-0.5 top-0.5 z-3 hidden items-center gap-0.5 rounded-plate-lg border border-rule bg-surface p-0.5 shadow-[var(--lift)] group-hover:flex group-focus-within:flex";
var CARD_QUICK_BTN_CLASS = "grid min-h-[26px] min-w-[26px] cursor-pointer place-items-center rounded-plate-lg border-0 bg-transparent p-0 text-sm text-fg-muted transition-colors hover:bg-surface-2 hover:text-fg";
var DROP_INDICATOR_CLASS = "mx-2 -my-px h-0.5 rounded-capsule bg-accent";

function cardQuickActions(c) {
  var qa = document.createElement("span");
  qa.className = CARD_QUICK_CLASS;
  var qaEdit = document.createElement("button");
  qaEdit.type = "button";
  qaEdit.className = CARD_QUICK_BTN_CLASS;
  qaEdit.appendChild(icon("pencil", 14));
  qaEdit.title = "Open card";
  qaEdit.setAttribute("aria-label", "Open card: " + (c.title || c.id));
  qaEdit.addEventListener("click", function(e) {
    e.stopPropagation();
    openCardId = c.id;
    renderBoard(board);
  });
  qa.appendChild(qaEdit);
  // Quick move to next column
  var qaMove = document.createElement("button");
  qaMove.type = "button";
  qaMove.className = CARD_QUICK_BTN_CLASS;
  qaMove.appendChild(icon("arrowRight", 14));
  qaMove.title = "Move to next column";
  qaMove.setAttribute("aria-label", "Move to next column: " + (c.title || c.id));
  qaMove.addEventListener("click", function(e) {
    e.stopPropagation();
    if (!board) return;
    var ids = board.columns.map(function(col){ return col.id; });
    var at = ids.indexOf(c.column);
    var next = at + 1;
    if (next >= ids.length) return;
    postBoard({ op: "move", id: c.id, column: ids[next] }, "Moved to " + board.columns[next].title + ".");
  });
  qa.appendChild(qaMove);
  return qa;
}

function showDropIndicator(targetCard, e) {
  clearDropIndicators();
  var rect = targetCard.getBoundingClientRect();
  var above = (e.clientY - rect.top) < rect.height / 2;
  var indicator = document.createElement("div");
  indicator.className = DROP_INDICATOR_CLASS;
  indicator.dataset.dropIndicator = "";
  if (above) {
    targetCard.parentNode.insertBefore(indicator, targetCard);
  } else {
    targetCard.parentNode.insertBefore(indicator, targetCard.nextSibling);
  }
}

function clearDropIndicators() {
  var indicators = document.querySelectorAll("[data-drop-indicator]");
  for (var i = 0; i < indicators.length; i++) indicators[i].remove();
}

/* Only the column changes: the board has no per-column ordering to post, so a
   drop within one column is a no-op and the indicator is the only feedback. */
function handleCardDrop(draggedId, targetColumn) {
  var draggedCard = cardById(draggedId);
  if (!draggedCard || draggedCard.column === targetColumn) return;
  postBoard({ op: "move", id: draggedId, column: targetColumn }, "Moved.");
}

function cardDetailInner() { return el.cardDetailBox || el.cardDetail; }
function closeCardDetail() {
  if (!el.cardDetail.hidden) closeOverlay(el.cardDetail);
  else { el.cardDetail.hidden = true; cardDetailInner().textContent = ""; return; }
  // overlay helper clears hidden after focus restore; also clear inner content
  cardDetailInner().textContent = "";
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
  return { id: a.id, at };
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
  head.className = DETAIL_HEAD_CLASS;
  head.textContent = title;
  parent.appendChild(head);
  var box = document.createElement("div");
  box.className = "detail-body";
  parent.appendChild(box);
  return box;
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
   what it has cost, and what has happened to it.
   Rendered as a Trello-style panel with header, main column and sidebar. */
/* The card detail panel: the plate, its cover, header and sidebar, the
   description editor, the deadline hit area, the column move menu and the
   comment row. The cover and the label swatches name a hue through the same
   `card-hue` table the card face uses, so the ten colours are spelled once. */
var DETAIL_PANEL_CLASS = "relative mx-auto my-7 max-h-[calc(100vh-6rem)] w-[calc(100%-2rem)] max-w-3xl overflow-y-auto overflow-x-hidden rounded-plate-lg bg-surface shadow-[var(--lift-high)]";
var DETAIL_COVER_CLASS = "card-hue relative flex max-h-40 min-h-20 items-end justify-end rounded-t-plate-lg bg-cover bg-center p-2 data-[color]:min-h-[116px]";
var DETAIL_COVER_BTN_CLASS = "cursor-pointer rounded-plate-lg border-0 bg-[var(--scrim)] px-3 py-1 text-xs font-medium text-card-ink-on-dark transition-colors hover:bg-[color-mix(in_srgb,var(--fg)_12%,var(--scrim))]";
var DETAIL_HEADER_CLASS = "sticky top-0 z-2 flex items-start gap-3 rounded-t-plate-lg bg-surface px-4 pt-4";
var DETAIL_ICON_CLASS = "mt-px flex-none text-xl opacity-50";
var DETAIL_TITLE_CLASS = "m-0 flex-1 text-xl font-semibold leading-snug";
var DETAIL_CLOSE_CLASS = "grid min-h-9 min-w-9 flex-none cursor-pointer place-items-center rounded-capsule border-0 bg-transparent p-0 text-xl text-fg-muted transition-colors hover:bg-surface-2 hover:text-fg focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1";
var DETAIL_HEADER_TEXT_CLASS = "min-w-0 flex-1";
var DETAIL_HEADER_COL_CLASS = "ml-2 text-sm text-fg-muted";
var DETAIL_LAYOUT_CLASS = "grid grid-cols-[1fr_168px] gap-4 px-4 pb-4 pt-3";
var DETAIL_MAIN_CLASS = "flex min-w-0 flex-col gap-3";
var DETAIL_SIDEBAR_CLASS = "flex flex-col gap-2";
var DETAIL_SIDEBAR_TITLE_CLASS = "mb-px text-xs font-semibold text-fg-muted";
var DETAIL_SIDEBAR_BTN_CLASS = "flex min-h-8 w-full cursor-pointer items-center gap-2 rounded-plate-lg border border-transparent bg-surface-2 px-3 py-1 text-left text-sm text-fg transition duration-150 hover:translate-x-px hover:bg-[color-mix(in_srgb,var(--fg)_12%,var(--surface-2))] focus-visible:-outline-offset-1 focus-visible:outline-2 focus-visible:outline-accent";
var DETAIL_SECTION_HEAD_CLASS = "mb-2 flex items-center gap-2 text-base font-semibold text-fg [&_.icon]:text-base [&_.icon]:opacity-60";
var DETAIL_META_CLASS = "mb-2 flex flex-wrap gap-2";
var DETAIL_META_ITEM_CLASS = "flex flex-col gap-px";
var DETAIL_DESC_PREVIEW_CLASS = "min-h-20 cursor-pointer rounded-plate-lg border border-transparent bg-surface-2 px-3 py-3 text-sm leading-normal text-fg-muted transition-colors focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-1 empty:before:italic empty:before:text-fg-muted empty:before:content-['Add_a_more_detailed_description…']";
var DESC_DISPLAY_CLASS = "min-h-10 cursor-pointer whitespace-pre-wrap wrap-anywhere rounded-plate-lg px-3 py-2 text-sm leading-normal data-[empty=true]:bg-surface-2 data-[empty=true]:italic data-[empty=true]:text-fg-muted";
var DESC_EDIT_CLASS = "hidden w-full resize-y rounded-plate-lg border-2 border-accent bg-surface px-3 py-2 font-sans text-sm leading-normal data-[open=true]:block";
var DESC_ACTIONS_CLASS = "mt-2 hidden items-center gap-2 data-[open=true]:flex [&_button]:min-h-7 [&_button]:text-sm";
var DETAIL_DATE_HIT_CLASS = "absolute left-0 top-0 h-full w-full cursor-pointer opacity-0";
var DETAIL_MOVE_MENU_CLASS = "mt-1 flex flex-col gap-0.5";
var DETAIL_MOVE_OPT_CLASS = "min-h-7 cursor-pointer rounded-plate-lg border-0 bg-surface-2 px-2 py-1 text-left text-sm text-fg data-[current=true]:bg-accent data-[current=true]:text-on-accent";
var DETAIL_SAVE_ROW_CLASS = "mt-3 flex flex-wrap gap-2";
var DETAIL_SAVE_BTN_CLASS = "cursor-pointer rounded-plate-lg border-0 bg-accent px-5 py-2 text-sm font-semibold text-on-accent transition-[filter] hover:brightness-110";
var CARD_ACTIVITY_EMPTY_CLASS = "px-0 py-2 italic text-fg-muted";
var COMMENT_ROW_CLASS = "mt-2 flex items-center gap-2 [&_input]:min-w-0 [&_input]:flex-1";
var COMMENT_AVATAR_CLASS = "flex-none bg-accent text-on-accent";
var COMMENT_SEND_CLASS = "min-h-8 flex-none";
var LABEL_PICKER_CLASS = "flex flex-wrap gap-1 py-2";
var LABEL_PICKER_ITEM_CLASS = "card-hue relative h-8 w-12 min-w-8 cursor-pointer rounded-plate-lg border-2 border-transparent transition-colors hover:border-fg focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-2 data-[selected=true]:border-fg data-[selected=true]:shadow-[inset_0_0_0_2px_var(--surface)] pointer-coarse:h-11 pointer-coarse:min-h-11 pointer-coarse:min-w-11";

function showCardDetail(id) {
  var c = cardById(id);
  if (!c) return closeCardDetail();
  var box = cardDetailInner();
  // reopen as modal overlay (Trello-like card modal, Slack-like overlay); board stays put
  var wasHidden = el.cardDetail.hidden;
  box.textContent = "";
  if (wasHidden) {
    // preserve card id for trap handlers; don't clear content on close until next open
    openOverlay(el.cardDetail, null);
    el.cardDetail.setAttribute("aria-labelledby", "card-detail-title");
    /* Focus must move into the dialog when it opens: aria-modal="true" claims
       the rest of the page inert, but without this focus stayed on the card
       button behind the scrim, so a keyboard/screen-reader user got nothing
       from the panel that just opened (2.4.3 focus order, dialog pattern).
       Deferred past the synchronous panel build below — the close button does
       not exist yet at this point. No-op if the modal was closed again first. */
    window.setTimeout(function () {
      if (el.cardDetail.hidden) return;
      var first = el.cardDetail.querySelector(
        "[data-detail-close], button, input, select, textarea, a[href]");
      if (first) first.focus();
    }, 0);
  }
  // scrim click closes
  el.cardDetail.onclick = function(e){ if (e.target === el.cardDetail) { delete cardDrafts[c.id]; openCardId = null; closeCardDetail(); renderBoard(board); } };

  // ---- Trello-style panel wrapper ----
  var panel = document.createElement("div");
  panel.className = DETAIL_PANEL_CLASS;

  // ---- Header: icon + title + close ----
  var header = document.createElement("div");
  header.className = DETAIL_HEADER_CLASS;
  var headerIcon = document.createElement("span");
  headerIcon.className = DETAIL_ICON_CLASS;
  headerIcon.appendChild(icon("copy", 18));
  var headerTitle = document.createElement("h3");
  headerTitle.id = "card-detail-title";
  headerTitle.textContent = c.title;
  var headerCol = document.createElement("span");
  headerCol.className = DETAIL_HEADER_COL_CLASS;
  var colName = "";
  if (board && board.columns) {
    for (var ci = 0; ci < board.columns.length; ci++) {
      if (board.columns[ci].id === c.column) { colName = board.columns[ci].title; break; }
    }
  }
  if (colName) headerCol.textContent = "in " + colName;
  headerTitle.appendChild(headerCol);
  var close = document.createElement("button");
  close.type = "button";
  close.className = DETAIL_CLOSE_CLASS;
  close.dataset.detailClose = "";
  close.appendChild(icon("close", 14));
  close.title = "Close";
  close.setAttribute("aria-label", "Close card detail");
  close.addEventListener("click", function () {
    delete cardDrafts[c.id];
    openCardId = null;
    closeCardDetail();
    renderBoard(board);
  });
  // Header layout with title and "in list" subtitle
  var headerTextWrap = document.createElement("div");
  headerTextWrap.className = DETAIL_HEADER_TEXT_CLASS;
  headerTextWrap.appendChild(headerTitle);
  // "in list" subtitle like Trello
  var colLabel = c.column || "";
  var colTitle = colLabel.replace(/_/g, " ").replace(/\b\w/g, function(l){ return l.toUpperCase(); });
  var inListEl = document.createElement("div");
  inListEl.className = CARD_IN_LIST_CLASS;
  inListEl.appendChild(document.createTextNode("in list "));
  var inListName = document.createElement("strong");
  inListName.className = CARD_IN_LIST_NAME_CLASS;
  inListName.textContent = colTitle;
  inListEl.appendChild(inListName);
  // A <strong> with a click is unreachable by keyboard; the column picker
  // opens as a button.
  inListName.setAttribute("role", "button");
  inListName.tabIndex = 0;
  function openColMoveMenu() {
    var existing = headerTextWrap.querySelector(".col-move-menu");
    if (existing) { existing.remove(); return; }
    var menu = menuPopup();
    menu.classList.add("col-move-menu");
    menu.appendChild(menuTitle("Move to…"));
    (board.columns || []).forEach(function(col) {
      var opt = menuItem({ current: col.id === c.column });
      opt.textContent = col.title;
      opt.addEventListener("click", function() {
        menu.remove();
        if (col.id === c.column) return;
        postBoard({ op: "move", id: c.id, column: col.id }, "Moved to " + col.title + ".");
      });
      menu.appendChild(opt);
    });
    dismissOnOutside(menu);
    inListEl.style.position = "relative";
    inListEl.appendChild(menu);
  }
  inListName.addEventListener("click", function() { openColMoveMenu(); });
  inListName.addEventListener("keydown", function (e) {
    if (e.key !== "Enter" && e.key !== " ") return;
    e.preventDefault();
    openColMoveMenu();
  });
  headerTextWrap.appendChild(inListEl);
  header.appendChild(headerIcon);
  header.appendChild(headerTextWrap);
  header.appendChild(close);

  // ---- Cover color bar at top of panel ----
  var coverColor = c.cover_color || (c.labels && c.labels.length && c.labels[0].color ? c.labels[0].color : null);
  if (coverColor) {
    var coverDiv = document.createElement("div");
    coverDiv.className = DETAIL_COVER_CLASS;
    coverDiv.setAttribute("data-color", coverColor);
    panel.appendChild(coverDiv);
  }
  panel.appendChild(header);

  // ---- Two-column layout: main + sidebar ----
  var layout = document.createElement("div");
  layout.className = DETAIL_LAYOUT_CLASS;

  var mainCol = document.createElement("div");
  mainCol.className = DETAIL_MAIN_CLASS;

  var sidebarCol = document.createElement("div");
  sidebarCol.className = DETAIL_SIDEBAR_CLASS;

  // ---- Labels section in main (Trello-style clickable label pills) ----
  var labelsHead = document.createElement("p");
  labelsHead.className = DETAIL_HEAD_CLASS;
  labelsHead.textContent = "Labels";
  mainCol.appendChild(labelsHead);

  var labelsRow = document.createElement("div");
  labelsRow.className = LABELS_ROW_CLASS;
  var currentLabels = c.labels || [];
  currentLabels.forEach(function(lbl) {
    var pill = document.createElement("button");
    pill.type = "button";
    pill.className = CARD_LABEL_CLASS;
    pill.dataset.open = "true";
    pill.setAttribute("data-color", lbl.color || "blue");
    pill.textContent = lbl.text || lbl.color;
    pill.title = "Remove label";
    pill.setAttribute("aria-label", "Remove " + (lbl.text || lbl.color) + " label");
    pill.addEventListener("click", function() {
      var newLabels = currentLabels.filter(function(l) { return l.color !== lbl.color; });
      postBoard({ op: "update", id: c.id, labels: newLabels }, "Label removed.");
    });
    labelsRow.appendChild(pill);
  });
  // Add label button
  var addLabelBtn = document.createElement("button");
  addLabelBtn.type = "button";
  addLabelBtn.className = LABEL_ADD_BTN_CLASS;
  addLabelBtn.appendChild(icon("plus", 12));
  addLabelBtn.appendChild(document.createTextNode(" Add"));
  addLabelBtn.addEventListener("click", function() {
    labelPicker.hidden = !labelPicker.hidden;
  });
  labelsRow.appendChild(addLabelBtn);
  mainCol.appendChild(labelsRow);

  var labelPicker = document.createElement("div");
  labelPicker.className = LABEL_PICKER_CLASS;
  labelPicker.hidden = true;
  LABEL_COLORS.forEach(function(color) {
    var swatch = document.createElement("button");
    swatch.type = "button";
    swatch.className = LABEL_PICKER_ITEM_CLASS;
    swatch.setAttribute("data-color", color);
    var isSelected = currentLabels.some(function(l) { return l.color === color; });
    swatch.setAttribute("aria-label", (isSelected ? "Remove " : "Add ") + color + " label");
    if (isSelected) swatch.setAttribute("data-selected", "true");
    swatch.addEventListener("click", function() {
      if (isSelected) {
        var newLabels = currentLabels.filter(function(l) { return l.color !== color; });
        postBoard({ op: "update", id: c.id, labels: newLabels }, "Labels updated.");
      } else {
        var existing = labelPicker.querySelector(".label-text-input-wrap");
        if (existing) existing.remove();
        var wrap = document.createElement("div");
        wrap.className = LABEL_NAME_ROW_CLASS;
        var samplePill = document.createElement("span");
        samplePill.className = CARD_LABEL_CLASS;
        samplePill.dataset.sample = "true";
        samplePill.setAttribute("data-color", color);
        samplePill.textContent = color;
        wrap.appendChild(samplePill);
        var txtIn = document.createElement("input");
        txtIn.type = "text";
        txtIn.placeholder = "Label name…";
        txtIn.value = color;
        txtIn.className = LABEL_NAME_INPUT_CLASS;
        txtIn.addEventListener("input", function(){ samplePill.textContent = txtIn.value || color; });
        wrap.appendChild(txtIn);
        var addBtn = document.createElement("button");
        addBtn.type = "button";
        addBtn.textContent = "Add";
        addBtn.className = LABEL_NAME_CONFIRM_CLASS;
        addBtn.addEventListener("click", function(){
          var text = txtIn.value.trim() || color;
          var newLabels = currentLabels.concat([{ color, text }]);
          postBoard({ op: "update", id: c.id, labels: newLabels }, "Labels updated.");
        });
        wrap.appendChild(addBtn);
        labelPicker.appendChild(wrap);
        txtIn.focus();
        txtIn.select();
      }
    });
    labelPicker.appendChild(swatch);
  });
  mainCol.appendChild(labelPicker);

  // ---- Description/Notes (Trello-style: click to edit, save/cancel) ----
  var fields = detailSection(mainCol, "Description");
  var descDisplay = document.createElement("div");
  descDisplay.className = DESC_DISPLAY_CLASS;
  // Click-to-edit is pointer-only; the same edit must open from the keyboard.
  descDisplay.setAttribute("role", "button");
  descDisplay.tabIndex = 0;
  if (c.body && c.body.trim()) {
    descDisplay.textContent = c.body;
  } else {
    descDisplay.textContent = "Add a more detailed description…";
    descDisplay.dataset.empty = "true";
  }
  var bodyIn = document.createElement("textarea");
  bodyIn.id = "card-f-body";
  bodyIn.rows = 6;
  bodyIn.placeholder = "Add a more detailed description…";
  bodyIn.className = DESC_EDIT_CLASS;
  bindDraft(bodyIn, c.id, "body", c.body);
  var descActions = document.createElement("div");
  descActions.className = DESC_ACTIONS_CLASS;
  var descSave = document.createElement("button");
  descSave.type = "button";
  descSave.className = DETAIL_SAVE_BTN_CLASS;
  descSave.textContent = "Save";
  var descCancel = document.createElement("button");
  descCancel.type = "button";
  descCancel.className = "secondary";
  descCancel.textContent = "Cancel";
  descActions.appendChild(descSave);
  descActions.appendChild(descCancel);
  function openDescEdit() {
    descDisplay.hidden = true;
    bodyIn.style.display = "block";
    descActions.dataset.open = "true";
    bodyIn.focus();
  }
  descDisplay.addEventListener("click", openDescEdit);
  descDisplay.addEventListener("keydown", function (e) {
    if (e.key !== "Enter" && e.key !== " ") return;
    e.preventDefault();
    openDescEdit();
  });
  descCancel.addEventListener("click", function() {
    bodyIn.value = c.body || "";
    bodyIn.style.display = "none";
    descActions.dataset.open = "";
    descDisplay.hidden = false;
  });
  descSave.addEventListener("click", function() {
    // Post, don't just redraw. This button is the only control visible while
    // the description is being edited, so reading as its save it has to
    // write; the draft-only version lost the text on the next rebuild.
    var text = bodyIn.value;
    postBoard({ op: "update", id: c.id, body: text }, "Description saved.");
    var filled = !!text.trim();
    descDisplay.textContent = filled ? text : "Add a more detailed description…";
    descDisplay.dataset.empty = filled ? "" : "true";
    bodyIn.style.display = "none";
    descActions.dataset.open = "";
    descDisplay.hidden = false;
  });
  fields.appendChild(descDisplay);
  fields.appendChild(bodyIn);
  fields.appendChild(descActions);

  // ---- Sidebar: quick actions ----
  var sideTitle1 = document.createElement("div");
  sideTitle1.className = DETAIL_SIDEBAR_TITLE_CLASS;
  sideTitle1.textContent = "Add to card";
  sidebarCol.appendChild(sideTitle1);

  // Assignee sidebar button with member picker dropdown
  var assignWrap = document.createElement("div");
  assignWrap.className = BOARD_REL_CLASS;
  var assignBtn = document.createElement("button");
  assignBtn.type = "button";
  assignBtn.appendChild(icon("person", 14));
  assignBtn.appendChild(document.createTextNode(c.assignee ? " Members: " + c.assignee : " Members: "));
  if (!c.assignee) {
    var unassigned = document.createElement("em");
    unassigned.textContent = "unassigned";
    assignBtn.appendChild(unassigned);
  }
  assignBtn.addEventListener("click", function() {
    var existing = assignWrap.querySelector(".member-picker-popup");
    if (existing) { existing.remove(); return; }
    var popup = memberPicker(c, true);
    dismissOnOutside(popup, assignBtn);
    assignWrap.appendChild(popup);
  });
  assignWrap.appendChild(assignBtn);
  sidebarCol.appendChild(assignWrap);

  // Priority sidebar button with dropdown
  var prioWrap = document.createElement("div");
  prioWrap.className = BOARD_REL_CLASS;
  var curPrio = c.priority || "normal";
  var prioIcons = { low: "arrowDown", normal: "minus", high: "arrowUp" };
  var prioBtn = document.createElement("button");
  prioBtn.type = "button";
  prioBtn.appendChild(icon(prioIcons[curPrio] || "minus", 14));
  prioBtn.appendChild(document.createTextNode(" Priority: " + curPrio));
  prioBtn.addEventListener("click", function() {
    var existing = prioWrap.querySelector(".prio-picker-popup");
    if (existing) { existing.remove(); return; }
    var popup = menuPopup(true);
    popup.classList.add("prio-picker-popup");
    popup.appendChild(menuTitle("Priority"));
    ["high", "normal", "low"].forEach(function(p){
      var opt = menuItem({ current: p === curPrio });
      opt.appendChild(icon(prioIcons[p] || "minus", 14));
      opt.appendChild(document.createTextNode(" " + p.charAt(0).toUpperCase() + p.slice(1)));
      opt.addEventListener("click", function(){ popup.remove(); postBoard({ op: "update", id: c.id, priority: p }, "Priority → " + p); });
      popup.appendChild(opt);
    });
    dismissOnOutside(popup, prioBtn);
    prioWrap.appendChild(popup);
  });
  prioWrap.appendChild(prioBtn);
  sidebarCol.appendChild(prioWrap);

  // Deadline sidebar — native date picker
  var deadlineWrap = document.createElement("div");
  deadlineWrap.className = BOARD_REL_CLASS;
  var deadlineBtn = document.createElement("button");
  deadlineBtn.type = "button";
  deadlineBtn.appendChild(icon("calendar", 14));
  deadlineBtn.appendChild(document.createTextNode(c.deadline ? " Due: " + fmtDeadline(c.deadline) : " Dates"));
  var deadlineInput = document.createElement("input");
  deadlineInput.type = "date";
  deadlineInput.className = DETAIL_DATE_HIT_CLASS;
  if (c.deadline) {
    // Convert deadline to YYYY-MM-DD if it's a unix timestamp. Local, not
    // UTC: toISOString() would show a local end-of-day deadline as the next
    // day for zones west of UTC (see deadlineToDateInput).
    deadlineInput.value = deadlineToDateInput(c.deadline);
  }
  deadlineInput.addEventListener("change", function() {
    var val = deadlineInput.value;
    if (!val) {
      // 0, not null: the field is a ?i64 the guest only writes when present
      // (cards.zig `if (act.deadline) |v|`), so a null posted a successful
      // update that dropped the field and left the date on the card.
      postBoard({ op: "update", id: c.id, deadline: 0 }, "Deadline cleared.");
    } else {
      // The board tool takes epoch seconds, not a date string; posting the
      // raw input used to fail the whole update against the guest's ?i64.
      postBoard({ op: "update", id: c.id, deadline: dateInputToDeadline(val) }, "Due " + fmtBoardDate(dateInputToDeadline(val)));
    }
  });
  deadlineWrap.appendChild(deadlineBtn);
  deadlineWrap.appendChild(deadlineInput);
  sidebarCol.appendChild(deadlineWrap);

  // No cover swatches here: they posted `cover_color`, a field no card holds
  // (the guest's update action has no such key and ignores unknown ones), so
  // every click claimed "Cover → green" and changed nothing. The strip is
  // derived from what persists — the first label's colour, else priority.

  var sideTitle2 = document.createElement("div");
  sideTitle2.className = DETAIL_SIDEBAR_TITLE_CLASS;
  sideTitle2.style.marginTop = "var(--space-3)";
  sideTitle2.textContent = "Actions";
  sidebarCol.appendChild(sideTitle2);

  // Move column sidebar — dropdown instead of prompt
  var moveBtn = document.createElement("button");
  moveBtn.type = "button";
  moveBtn.appendChild(icon("arrowRight", 14));
  moveBtn.appendChild(document.createTextNode(" Move"));
  moveBtn.addEventListener("click", function() {
    if (!board || !board.columns) return;
    var existing = moveBtn.parentNode.querySelector("[data-move-menu]");
    if (existing) { existing.remove(); return; }
    var menu = document.createElement("div");
    menu.className = DETAIL_MOVE_MENU_CLASS;
    menu.dataset.moveMenu = "";
    board.columns.forEach(function(col) {
      var opt = document.createElement("button");
      opt.type = "button";
      opt.className = DETAIL_MOVE_OPT_CLASS;
      if (col.id === c.column) opt.dataset.current = "true";
      opt.textContent = col.title;
      if (col.id === c.column) {
        opt.appendChild(icon("held", 12));
      }
      opt.addEventListener("click", function() {
        if (col.id === c.column) { menu.remove(); return; }
        postBoard({ op: "move", id: c.id, column: col.id }, "Moved to " + col.title + ".");
        menu.remove();
      });
      menu.appendChild(opt);
    });
    moveBtn.parentNode.appendChild(menu);
  });
  sidebarCol.appendChild(moveBtn);

  // Copy card button
  var copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.appendChild(icon("copy", 14));
  copyBtn.appendChild(document.createTextNode(" Copy"));
  copyBtn.addEventListener("click", function() {
    var newTitle = c.title + " (copy)";
    var payload = { op: "add", title: newTitle, column: c.column };
    if (c.assignee) payload.assignee = c.assignee;
    if (c.priority) payload.priority = c.priority;
    if (c.body) payload.body = c.body;
    postBoard(payload, "Card copied.");
  });
  sidebarCol.appendChild(copyBtn);

  // Archive/delete sidebar button
  var archiveBtn = document.createElement("button");
  archiveBtn.type = "button";
  archiveBtn.appendChild(icon("trash", 14));
  archiveBtn.appendChild(document.createTextNode(" Delete"));
  archiveBtn.classList.add("danger");
  archiveBtn.addEventListener("click", function() {
    uiConfirm("Delete card \"" + c.title + "\"? This cannot be undone.", { danger: true, confirmLabel: "Delete" }).then(function (yes) {
      if (!yes) return;
      openCardId = null;
      closeCardDetail();
      postBoard({ op: "delete", id: c.id }, "Card deleted.");
    });
  });
  sidebarCol.appendChild(archiveBtn);

  // ---- Hidden original fields for save: title, assignee, priority ----
  var hiddenFields = document.createElement("div");
  hiddenFields.className = DETAIL_ROW_CLASS;
  // The container itself, not each child: `.detail-row` is a flex row, so
  // hiding only the inputs left a second "Title" box beside the header's
  // rename and a second date box beside the sidebar's, each overwriting the
  // other on save.
  hiddenFields.hidden = true;
  var titleIn = input("card-f-title", "text", "");
  titleIn.maxLength = 500;
  var titleLabel = document.createElement("label");
  titleLabel.htmlFor = titleIn.id;
  titleLabel.textContent = "Title";
  bindDraft(titleIn, c.id, "title", c.title);
  hiddenFields.appendChild(titleLabel);
  hiddenFields.appendChild(titleIn);
  var assignIn = input("card-f-assignee", "text", "", "unassigned");
  assignIn.hidden = true;
  bindDraft(assignIn, c.id, "assignee", c.assignee);
  hiddenFields.appendChild(assignIn);
  var prioIn = document.createElement("select");
  prioIn.id = "card-f-priority";
  prioIn.hidden = true;
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
  hiddenFields.appendChild(prioIn);
  mainCol.appendChild(hiddenFields);

  // A deadline needs no second control here: the sidebar's date input posts
  // on change, so there is nothing for a save button to carry.

  // ---- Inline title editing (click header to rename) ----
  headerTitle.style.cursor = "pointer";
  headerTitle.title = "Click to rename";
  headerTitle.addEventListener("click", function(e) {
    if (e.target !== headerTitle) return;
    uiPrompt("Card title", c.title, { maxlength: 500 }).then(function (newTitle) {
      if (newTitle && newTitle.trim() && newTitle.trim() !== c.title) {
        postBoard({ op: "update", id: c.id, title: newTitle.trim() }, "Title updated.");
      }
    });
  });

  // ---- Save button in main column ----
  var saveRow = document.createElement("div");
  saveRow.className = DETAIL_SAVE_ROW_CLASS;
  var save = document.createElement("button");
  save.type = "button";
  save.className = DETAIL_SAVE_BTN_CLASS;
  save.textContent = "Save changes";
  save.addEventListener("click", function () {
    if (save.disabled) return;
    save.disabled = true;
    postBoard({
      op: "update", id: c.id,
      title: titleIn.value || c.title, body: bodyIn.value,
      assignee: assignIn.value, priority: prioIn.value
    }, "Card saved.").then(function (d) {
      // The draft is what carries half-typed text across a rebuild, so it
      // only goes once the server has the values: a refused write left the
      // draft cleared and the next rebuild replaced the form with the old copy.
      if (d !== false) delete cardDrafts[c.id];
    }).then(function () {
      save.disabled = false;
    });
  });
  saveRow.appendChild(save);

  // Assign-to-me quick button
  var takeIt = document.createElement("button");
  takeIt.type = "button";
  takeIt.className = "secondary";
  takeIt.appendChild(icon("person", 14));
  takeIt.appendChild(document.createTextNode(" Assign to me"));
  takeIt.addEventListener("click", function () {
    postBoard({ op: "update", id: c.id, assignee: (el.instanceChip.textContent || "").trim() }, "Assigned.");
  });
  sidebarCol.appendChild(takeIt);

  // Start work / Convert to goal
  var asGoal = document.createElement("button");
  asGoal.type = "button";
  asGoal.className = "secondary";
  asGoal.appendChild(icon(c.goal ? "rocket" : "goal", 14));
  asGoal.appendChild(document.createTextNode(c.goal ? " Start work" : " Convert to goal"));
  asGoal.title = c.goal
    ? "Start a run for this goal. The card moves to Doing, then Review when the run finishes."
    : "Turn this legacy card into a goal and start it.";
  // The same per-run iteration budget box the Goals view offers, so assigning
  // a card as a goal honours the same cap instead of silently running at the
  // goal's stored default (or the global agent.max_iterations). Prefill the
  // placeholder with the mirrored goal's stored default, like the Goals view.
  var goalRow = document.createElement("div");
  goalRow.className = GOAL_ROW_CLASS;
  var goalIters = input("card-f-goal-iters", "number", "", "steps (default)");
  goalIters.min = "1"; goalIters.step = "1";
  goalIters.title = "Optional per-run step limit. Leave blank to use this goal's saved default, then the configured default (usually 50).";
  var gid = goalIdForCard(c.id);
  var gl = goalState.val || [];
  for (var gi = 0; gi < gl.length; gi++) {
    if (gl[gi].id === gid && gl[gi].max_iterations) {
      goalIters.placeholder = "\u2264 " + gl[gi].max_iterations + " steps";
      break;
    }
  }
  asGoal.addEventListener("click", function () {
    delete cardDrafts[c.id];
    var n = parseInt(goalIters.value, 10);
    workCardAsGoal(c, { maxIterations: Number.isFinite(n) && n > 0 ? n : null });
  });
  goalRow.appendChild(goalIters);
  goalRow.appendChild(asGoal);
  sidebarCol.appendChild(goalRow);

  mainCol.appendChild(saveRow);

  // Stored as `subtasks` for tool/API compatibility. `parent` forms an
  // arbitrary-depth display tree; `depends_on` is a separate graph that may
  // connect any two nodes in this card.
  var subs = detailSection(mainCol, "Checklist");
  var allSubs = c.subtasks || [];
  var subById = {};
  var childMap = {};
  allSubs.forEach(function (s) { subById[s.id] = s; });
  allSubs.forEach(function (s) {
    var parent = s.parent && subById[s.parent] ? s.parent : "";
    if (!childMap[parent]) childMap[parent] = [];
    childMap[parent].push(s);
  });

  function checklistBlockers(s) {
    return (s.depends_on || []).filter(function (id) {
      return !subById[id] || !subById[id].done;
    });
  }

  // Adding `candidate` as a prerequisite of `item` is invalid when the
  // candidate already reaches item. Keep those cycle-forming choices out of
  // the picker instead of making the user discover the rule via an error.
  function dependencyReaches(fromId, wantedId, seen) {
    if (fromId === wantedId) return true;
    if (seen[fromId]) return false;
    seen[fromId] = true;
    var from = subById[fromId];
    if (!from) return false;
    return (from.depends_on || []).some(function (next) {
      return dependencyReaches(next, wantedId, seen);
    });
  }

  function addChecklistItem(inputNode, buttonNode, parentId) {
    var text = inputNode.value.trim();
    if (!requireText(inputNode, parentId ? "Write the child item's text." : "Write the checklist item's text.")) return;
    buttonNode.disabled = true;
    var payload = { op: "subtask_add", id: c.id, text };
    if (parentId) payload.parent_subtask_id = parentId;
    postBoard(payload, parentId ? "Child checklist item added." : "Checklist item added.")
      .then(function (ok) { if (ok) inputNode.value = ""; })
      .finally(function () { buttonNode.disabled = false; });
  }

  function renderChecklistItem(s) {
    var item = document.createElement("div");
    item.className = CHECKLIST_ITEM_CLASS;
    var row = document.createElement("div");
    row.className = DETAIL_ROW_CLASS;
    var tick = document.createElement("input");
    tick.type = "checkbox";
    tick.checked = !!s.done;
    tick.id = "sub-" + s.id;
    var blocked = checklistBlockers(s);
    tick.disabled = blocked.length > 0 && !s.done;
    tick.addEventListener("change", function () {
      var wanted = tick.checked;
      postBoard({ op: "subtask_toggle", id: c.id, subtask_id: s.id, done: wanted }, null)
        .then(function (ok) {
          // The click already moved the checkbox; put it back rather than leave a
          // state the server refused on screen. The refusal itself already
          // carries its reason in #board-status, so nothing is said here.
          if (!ok) tick.checked = !wanted;
        });
    });
    var lab = document.createElement("label");
    lab.htmlFor = tick.id;
    lab.textContent = s.text;
    lab.setAttribute("data-subtask", "true");
    lab.setAttribute("data-done", String(!!s.done));
    if (blocked.length) {
      lab.setAttribute("data-blocked", "true");
      lab.title = "Waiting on: " + blocked.map(function (id) { return subById[id] ? subById[id].text : id; }).join(", ");
      tick.setAttribute("aria-description", lab.title);
    }
    var child = document.createElement("button");
    child.type = "button";
    child.className = "rail-pin";
    child.appendChild(icon("plus", 14));
    child.setAttribute("aria-label", "Add child checklist item under: " + s.text);
    var drop = document.createElement("button");
    drop.type = "button";
    drop.className = "rail-pin";
    drop.appendChild(icon("strike", 14));
    drop.setAttribute("aria-label", "Remove checklist item: " + s.text);
    drop.addEventListener("click", function () {
      uiConfirm("Remove the checklist item \"" + s.text + "\"? This cannot be undone.",
        { danger: true, confirmLabel: "Remove" }).then(function (yes) {
        if (!yes) return;
        postBoard({ op: "subtask_remove", id: c.id, subtask_id: s.id }, "Removed checklist item: " + s.text);
      });
    });
    row.appendChild(tick);
    row.appendChild(lab);
    row.appendChild(child);
    row.appendChild(drop);
    item.appendChild(row);

    if ((s.depends_on || []).length) {
      var deps = document.createElement("div");
      deps.className = CHECKLIST_DEPS_CLASS;
      (s.depends_on || []).forEach(function (id) {
        var dep = document.createElement("span");
        dep.className = CARD_FLAG_CLASS;
        dep.textContent = "waits on " + (subById[id] ? subById[id].text : id);
        var clear = document.createElement("button");
        clear.type = "button";
        clear.className = "rail-pin";
        clear.appendChild(icon("close", 12));
        clear.setAttribute("aria-label", "Remove dependency on " + (subById[id] ? subById[id].text : id));
        clear.addEventListener("click", function () {
          postBoard({ op: "subtask_depend", id: c.id, subtask_id: s.id, depends_on: id, off: true }, "Checklist dependency removed.");
        });
        dep.appendChild(clear);
        deps.appendChild(dep);
      });
      item.appendChild(deps);
    }

    var childForm = document.createElement("div");
    childForm.className = CHECKLIST_ADD_CLASS;
    childForm.hidden = true;
    var childIn = input("child-" + s.id, "text", "", "Add a child item…");
    childIn.maxLength = 500;
    var childSave = document.createElement("button");
    childSave.type = "button";
    childSave.className = "secondary";
    childSave.textContent = "Add child";
    child.addEventListener("click", function () {
      childForm.hidden = !childForm.hidden;
      if (!childForm.hidden) childIn.focus();
    });
    childSave.addEventListener("click", function () { addChecklistItem(childIn, childSave, s.id); });
    childIn.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); addChecklistItem(childIn, childSave, s.id); }
      if (e.key === "Escape") { childForm.hidden = true; child.focus(); }
    });
    childForm.appendChild(childIn);
    childForm.appendChild(childSave);
    item.appendChild(childForm);

    var candidates = allSubs.filter(function (x) {
      return x.id !== s.id &&
        (s.depends_on || []).indexOf(x.id) === -1 &&
        !dependencyReaches(x.id, s.id, {});
    });
    if (candidates.length) {
      var depForm = document.createElement("div");
      depForm.className = CHECKLIST_DEP_ADD_CLASS;
      var depSelect = document.createElement("select");
      depSelect.setAttribute("aria-label", "Dependency for " + s.text);
      candidates.forEach(function (x) {
        var option = document.createElement("option");
        option.value = x.id; option.textContent = "Wait on " + x.text;
        depSelect.appendChild(option);
      });
      var depAdd = document.createElement("button");
      depAdd.type = "button"; depAdd.className = "secondary"; depAdd.textContent = "Link";
      depAdd.addEventListener("click", function () {
        postBoard({ op: "subtask_depend", id: c.id, subtask_id: s.id, depends_on: depSelect.value }, "Checklist dependency added.");
      });
      depForm.appendChild(depSelect); depForm.appendChild(depAdd);
      item.appendChild(depForm);
    }

    var children = childMap[s.id] || [];
    if (children.length) {
      var nested = document.createElement("div");
      nested.className = CHECKLIST_CHILDREN_CLASS;
      children.forEach(function (x) { nested.appendChild(renderChecklistItem(x)); });
      item.appendChild(nested);
    }
    return item;
  }

  var tree = document.createElement("div");
  tree.className = CHECKLIST_TREE_CLASS;
  (childMap[""] || []).forEach(function (s) { tree.appendChild(renderChecklistItem(s)); });
  subs.appendChild(tree);
  // Trello-style checklist progress bar (also on card face)
  if ((c.subtasks || []).length) {
    var dN = c.subtasks.filter(function(ss){ return ss.done; }).length;
    var tN = c.subtasks.length;
    var pct2 = tN ? Math.round(dN / tN * 100) : 0;
    var track = document.createElement("div");
    track.className = CARD_PROGRESS_BAR_CLASS;
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
    pctLabel.className = CARD_PROGRESS_CLASS; pctLabel.textContent = fmtInt(dN) + "/" + fmtInt(tN) + " · " + fmtPct(pct2, 0);
    pctLabel.style.marginLeft = "var(--space-3)";
    var progRow = document.createElement("div");
    progRow.className = DETAIL_ROW_CLASS;
    progRow.style.alignItems = "center";
    progRow.appendChild(track); track.style.flex = "1";
    progRow.appendChild(pctLabel);
    subs.appendChild(progRow);
  }
  var subIn = input("card-f-subtask", "text", "", "Add a checklist item…");
  subIn.maxLength = 500;
  var subAdd = document.createElement("button");
  subAdd.type = "button";
  subAdd.className = "secondary";
  subAdd.textContent = "Add item";
  subIn.addEventListener("keydown", function (e) {
    if (e.key !== "Enter" || !subIn.value.trim()) return;
    e.preventDefault();
    addChecklistItem(subIn, subAdd, "");
  });
  subAdd.addEventListener("click", function () { addChecklistItem(subIn, subAdd, ""); });
  var checklistAdd = document.createElement("div");
  checklistAdd.className = CHECKLIST_ADD_CLASS;
  checklistAdd.appendChild(subIn);
  checklistAdd.appendChild(subAdd);
  subs.appendChild(checklistAdd);

  // ---- dependencies ----
  var deps = detailSection(mainCol, "Waiting on");
  (c.depends_on || []).forEach(function (depId) {
    var dep = cardById(depId);
    var row = document.createElement("div");
    row.className = DETAIL_ROW_CLASS;
    var name = document.createElement("span");
    name.textContent = dep ? dep.title + "  ·  " + dep.column : depId + " (missing)";
    if (dep && dep.column !== doneColumn() && dep.column !== "archive") name.className = "dep-open";
    var drop = document.createElement("button");
    drop.type = "button";
    drop.className = "rail-pin";
    drop.appendChild(icon("strike", 14));
    drop.setAttribute("aria-label", "Stop waiting on " + (dep ? dep.title : depId));
    drop.addEventListener("click", function () {
      postBoard({ op: "depend_remove", id: c.id, depends_on: depId },
        "No longer waiting on " + (dep ? dep.title : depId) + ".");
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
    var added = depPick.value;
    var addedCard = cardById(added);
    postBoard({ op: "depend_add", id: c.id, depends_on: added },
      "Now waiting on " + (addedCard ? addedCard.title : added) + ".");
  });
  deps.appendChild(depPick);

  // ---- usage ----
  var usage = c.usage || {};
  if (usage.prompt_tokens || usage.completion_tokens || usage.cost) {
    var u = detailSection(mainCol, "Cost so far");
    var line = document.createElement("p");
    line.className = "meta";
    line.textContent = fmtInt(usage.prompt_tokens || 0) + " prompt + " + fmtInt(usage.completion_tokens || 0) +
      " completion  ·  " + fmtCost(usage.cost || 0) +
      ((usage.runs || []).length ? "  ·  " + plural(usage.runs.length, { one: "run", other: "runs" }) : "");
    u.appendChild(line);
    (usage.runs || []).forEach(function (rid) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "secondary";
      b.textContent = rid;
      b.title = "Open this run's graph";
      b.addEventListener("click", function () { _openRun(rid); });
      u.appendChild(b);
    });
  }

  // ---- Activity timeline (Trello-style) ----
  var logBox = detailSection(mainCol, "Activity");
  var entries = (c.log || []).slice().reverse();
  if (!entries.length) {
    var empty = document.createElement("p");
    empty.className = "meta " + CARD_ACTIVITY_EMPTY_CLASS;
    empty.textContent = "No activity yet. Moving, assigning, or commenting on this card will build its history here.";
    logBox.appendChild(empty);
  }
  var activityList = document.createElement("div");
  activityList.className = ACTIVITY_CLASS;
  entries.forEach(function (e) {
    var item = document.createElement("div");
    item.className = ACTIVITY_ITEM_CLASS;
    var avatar = document.createElement("div");
    avatar.className = ACTIVITY_AVATAR_CLASS;
    var whoName = e.who || "?";
    avatar.textContent = whoName.slice(0, 2).toUpperCase();
    var nameHash = 0;
    for (var ci = 0; ci < whoName.length; ci++) nameHash = ((nameHash << 5) - nameHash + whoName.charCodeAt(ci)) | 0;
    // One stable tone per name, from the theme-aware chat-hue palette (in
    // tailwind.src.css), which re-saturates per theme so the initials stay legible in
    // light and dark alike. No literal hex or white-is-assumed text here.
    avatar.classList.add("bg-chat-hue-" + (Math.abs(nameHash) % 8), "text-on-accent");
    item.appendChild(avatar);
    var content = document.createElement("div");
    content.className = ACTIVITY_CONTENT_CLASS;
    var line1 = document.createElement("div");
    var whoSpan = document.createElement("span");
    whoSpan.className = ACTIVITY_WHO_CLASS;
    whoSpan.textContent = whoName;
    var whenSpan = document.createElement("span");
    whenSpan.className = ACTIVITY_WHEN_CLASS;
    whenSpan.textContent = e.ts ? formatChatTime(e.ts) : "";
    line1.appendChild(whoSpan);
    line1.appendChild(whenSpan);
    content.appendChild(line1);
    var whatDiv = document.createElement("div");
    whatDiv.className = ACTIVITY_TEXT_CLASS;
    whatDiv.textContent = e.what || "";
    content.appendChild(whatDiv);
    item.appendChild(content);
    activityList.appendChild(item);
  });
  logBox.appendChild(activityList);
  // Activity input with send button
  var noteWrap = document.createElement("div");
  noteWrap.className = COMMENT_ROW_CLASS;
  var noteAvatar = document.createElement("div");
  noteAvatar.className = ACTIVITY_AVATAR_CLASS + " " + COMMENT_AVATAR_CLASS;
  noteAvatar.textContent = "ME";
  noteWrap.appendChild(noteAvatar);
  var noteIn = input("card-f-log", "text", "", "Write a comment…");
  noteIn.maxLength = 2000;
  noteIn.addEventListener("keydown", function (e) {
    if (e.key !== "Enter" || !noteIn.value.trim()) return;
    e.preventDefault();
    postBoard({ op: "log", id: c.id, what: noteIn.value.trim() }, "Recorded.");
  });
  noteWrap.appendChild(noteIn);
  var noteSend = document.createElement("button");
  noteSend.type = "button";
  noteSend.className = DETAIL_SAVE_BTN_CLASS + " " + COMMENT_SEND_CLASS;
  // The description's own save sits above this one and writes a different
  // thing; two Saves in one panel said nothing about which was which.
  noteSend.textContent = "Post comment";
  noteSend.addEventListener("click", function() {
    if (!requireText(noteIn, "Write a comment before posting.")) return;
    postBoard({ op: "log", id: c.id, what: noteIn.value.trim() }, "Recorded.");
  });
  noteWrap.appendChild(noteSend);
  logBox.appendChild(noteWrap);

  // ---- Assemble layout ----
  layout.appendChild(mainCol);
  layout.appendChild(sidebarCol);
  panel.appendChild(layout);
  box.appendChild(panel);

  // focus the notes textarea (Trello: opening a card gives you the description)
  try { setTimeout(function(){ bodyIn.focus(); }, 0); } catch(_){}
}


/* The card modal's keyboard contract, called first from app.js's document
   keydown so the palette handler never sees a key the modal owns: Esc closes
   (discarding the draft, as the Close button does), Tab is trapped inside.
   Returns true when the event was consumed. */
export function cardModalKeyHandler(e) {
  // Trello/Slack-style card modal owns focus while open — Esc closes, Tab traps
  if (el && el.cardDetail && !el.cardDetail.hidden) {
    if (e.key === "Escape") { e.preventDefault(); delete cardDrafts[openCardId || ""]; openCardId = null; closeCardDetail(); renderBoard(board); return true; }
    if (e.key === "Tab") { trapOverlayTab(e, el.cardDetail); return true; }
  }
  return false;
}

/* Wires the view to the DOM and the app: `deps.el` is app.js's element map,
   `deps.setTabCount` badges the Board tab, `deps.openRun` jumps to a recorded
   run's graph, and `deps.getKnownPeers` reads the current peer roster for the
   quick-add @ mention hint. */
export function bindBoard(deps) {
  el = deps.el;
  _setTabCount = deps.setTabCount;
  _openRun = deps.openRun;
  _getKnownPeers = deps.getKnownPeers;
  var headerIcon = document.getElementById("board-header-icon");
  if (headerIcon && !headerIcon.firstChild) headerIcon.appendChild(icon("grid", 20));

  bind(el.board, boardState, function (s) {
    var open = 0;
    s.cards.forEach(function (c) {
      if (c.column !== "done" && c.column !== "archive" && (!s.mine || c.assignee === s.me)) open += 1;
    });
    _setTabCount("kanban", open);
    el.boardEmpty.hidden = !boardLoaded || s.cards.length > 0;
    var filterEmpty = document.getElementById("board-filter-empty");
    if (filterEmpty) {
      var shownN = 0;
      s.cards.forEach(function (c) { if (cardMatchesBoardFilter(c, s)) shownN += 1; });
      filterEmpty.hidden = !(s.cards.length && boardHasActiveFilters(s) && shownN === 0);
    }
    var createFold = document.getElementById("board-create-fold");
    if (createFold && boardLoaded && !s.cards.length) createFold.open = true;
    syncListControls();

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

  el.cardForm.addEventListener("submit", function (e) {
    e.preventDefault();
    var title = el.cardTitle.value.trim();
    if (!requireText(el.cardTitle, "Give the card a title.")) return;
    el.cardAdd.disabled = true;
    postBoard({ op: "create", title, column: el.cardColumn.value }, "Card added.").then(function (ok) {
      el.cardAdd.disabled = false;
      if (ok) el.cardTitle.value = "";
    });
  });

  wireRefresh(el.boardRefresh, loadBoard);
  el.boardRoom.addEventListener("change", function () { loadBoard(); });
  // Re-sync from goals: put every goal's mirror card in the column its
  // status asks for (done -> done, waiting for review -> review, running ->
  // doing, idle active goals out of the in-flight columns). Goals are
  // re-fetched first so the sync reads current statuses even when the Goals
  // view was never opened; the handler is the goals module's, which owns the
  // goal->card mapping.
  el.boardResyncGoals.addEventListener("click", function () {
    el.boardResyncGoals.disabled = true;
    loadGoals()
      .then(function () {
        var moved = syncCardsFromGoals();
        el.boardStatus.textContent = moved
          ? ("Moved " + plural(moved, { one: "card", other: "cards" }) + " to match their goals.")
          : "Every card already matches its goal.";
        // Let the moves' renderBoard calls flush, then re-enable.
        return loadBoard();
      })
      .finally(function () { el.boardResyncGoals.disabled = false; });
  });
  // The text filter runs on every keystroke, so debounce it: a full board
  // rebuild per keypress (bind() clears and re-renders every column) is what
  // made typing lag. Structured filters coalesce to one rAF so a double
  // listener cannot stack two rebuilds in the same frame.
  var filterTimer = null;
  var filterRaf = 0;
  function scheduleFilterRebuild(fromText) {
    function run() {
      filterRaf = 0;
      var next = boardFilterState();
      var cur = boardState.val;
      if (cur &&
          (next.text || "").trim().toLowerCase() === (cur.text || "") &&
          !!next.blockedOnly === !!cur.blockedOnly &&
          (next.priority || "") === (cur.priority || "") &&
          (next.assignee || "") === (cur.assignee || "") &&
          (next.label || "") === (cur.label || "") &&
          !!el.boardMine.checked === !!cur.mine) return;
      renderBoard(null);
    }
    if (fromText) {
      if (filterTimer) window.clearTimeout(filterTimer);
      filterTimer = window.setTimeout(function () {
        filterTimer = null;
        if (filterRaf) return;
        filterRaf = window.requestAnimationFrame(run);
      }, 150);
      return;
    }
    if (filterRaf) return;
    filterRaf = window.requestAnimationFrame(run);
  }
  var clearBtn = document.getElementById("board-filter-clear");
  if (clearBtn) clearBtn.addEventListener("click", function () { clearBoardFilters(); });
  var emptyCreate = document.getElementById("board-empty-create");
  if (emptyCreate) emptyCreate.addEventListener("click", function () {
    var fold = document.getElementById("board-create-fold");
    if (fold) fold.open = true;
    var obj = document.getElementById("goal-objective");
    if (obj) {
      try { obj.scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth", block: "center" }); } catch (_) {}
      obj.focus();
    }
  });
  ["board-filter-input","board-mine","board-filter-blocked","board-filter-priority","board-filter-assignee","board-filter-label"].forEach(function(id){
    var n=document.getElementById(id);
    if(!n) return;
    if (id === "board-filter-input") {
      n.addEventListener("input", function () { scheduleFilterRebuild(true); });
    } else {
      n.addEventListener("change", function(){ scheduleFilterRebuild(false); });
    }
  });
  // ---- Keyboard shortcuts (Trello-style) ----
  // n = new card, / = focus filter, ? = show shortcuts, Escape = close detail
  document.addEventListener("keydown", function(e) {
    // Only when the board view is visible and no input is focused.
    //
    // This used to read el.board, which is #board-grid — the columns, which
    // nothing ever hid. The test was therefore always false and these
    // shortcuts were live on every view, so `/` on the Runs view jumped focus
    // into the board's filter. #view-kanban is the panel showView() toggles,
    // which is the thing "the board view is visible" actually means, and it
    // keeps the shortcuts working in list mode, where the grid is hidden but
    // the view is not.
    var panel = document.getElementById("view-kanban");
    if (!panel || panel.hidden) return;
    var tag = (document.activeElement || {}).tagName || "";
    var isInput = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";

    // Escape closes card detail
    if (e.key === "Escape") {
      if (!el.cardDetail.hidden) {
        openCardId = null;
        closeCardDetail();
        renderBoard(board);
        e.preventDefault();
      }
      return;
    }
    if (isInput) return;

    // n = open the first column's quick-add and put the cursor in it.
    //
    // This asked for #card-qa-title, an id nothing defines: the quick-add is
    // built per column in boardColumn() and its textarea carries no id at all,
    // so `n` had silently done nothing since the composer was added. Clicking
    // the trigger rather than focusing the textarea directly is what expands
    // the collapsed form — openQuickAdd() does both.
    if (e.key === "n") {
      var trigger = el.board && el.board.querySelector("[data-add-trigger]");
      if (trigger) { trigger.click(); e.preventDefault(); }
      return;
    }
    // / = focus filter
    if (e.key === "/") {
      var fi = document.getElementById("board-filter-input");
      if (fi) { fi.focus(); e.preventDefault(); }
      return;
    }
  });

  // Wire header list toggle button.
  //
  // The columns live in #board-grid. This asked for #board-columns, which no
  // markup has ever defined, so the lookup was null and the grid was never
  // hidden: the list rendered under a board that stayed where it was, both at
  // once, while the button's icon and aria-pressed flipped as if it had
  // worked. The id is deliberately not "board" — see index.html on why the
  // route and the element cannot share that name.
  (function(){
    var toggleBtn = document.getElementById("board-toggle-list");
    var columns = document.getElementById("board-grid");
    var listViewEl = document.getElementById("board-list-view");
    if (!toggleBtn) return;
    toggleBtn.addEventListener("click", function(){
      setListMode(!listMode);
    });
    // Draw the starting state rather than assume it: #board-list-view carries
    // no `hidden` in the markup and renderList() fills it on every board
    // render, so without this the list is already on screen before the button
    // has been touched.
    setListMode(false);
    if (columns) columns.hidden = false;
  })();

  // board list view (full-fledged todo list)
  (function(){
    var listView=document.getElementById("board-list-view");
    var sortSel=document.getElementById("board-sort");
    if(!listView) return;
    /* The Due column reads a date, so it is rendered as one in the reader's
       locale (and field order) rather than as the ISO string a machine would.
       deadlineToDateInput still produces YYYY-MM-DD, because that is what
       <input type="date"> takes; this is the display side of the same value. */
    function fmtBoardDate(ts){
      if(!ts) return "";
      return new Date(ts*1000).toLocaleDateString(undefined,{year:"numeric",month:"short",day:"numeric"});
    }
    function boardListRows(){
      var s=boardState.val;
      var rows=[].concat(s.cards||[]);
      rows=rows.filter(function(c){ return cardMatchesBoardFilter(c, s); });
      var how=(sortSel && sortSel.value) || "updated";
      rows.sort(function(a,b){
        if(how==="priority"){
          var ra=priorityRank(a), rb=priorityRank(b);
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
        // The board-level first-use message already explains how cards get
        // here. Reserve this list message for the genuinely different case
        // where cards exist but the active filters hide all of them.
        // #board-filter-empty already explains a filter miss for both views.
        return;
      }
      var table=document.createElement("table");
      table.className="border-collapse font-mono text-sm";
      var caption=document.createElement("caption");
      caption.className="sr-only"; caption.textContent="Goal cards matching the current board filters"; table.appendChild(caption);
      var thead=document.createElement("thead");
      var hr=document.createElement("tr");
      ["Title","Column","Assignee","Due","Priority","Cost","Actions"].forEach(function(h){
        var th=document.createElement("th"); th.scope="col"; th.textContent=h; hr.appendChild(th);
      });
      thead.appendChild(hr); table.appendChild(thead);
      var tbody=document.createElement("tbody");
      rows.forEach(function(c){
        var tr=document.createElement("tr");
        var titleTd=document.createElement("th"); titleTd.scope="row"; titleTd.textContent=c.title; titleTd.className="max-w-72 truncate text-left"; titleTd.title=c.title; tr.appendChild(titleTd);
        var colTd=document.createElement("td"); colTd.textContent=c.column; tr.appendChild(colTd);
        var whoTd=document.createElement("td"); whoTd.textContent=c.assignee||"n/a"; tr.appendChild(whoTd);
        var dueTd=document.createElement("td"); dueTd.textContent=c.deadline?fmtBoardDate(c.deadline):"n/a"; if(c.deadline){ var ds=dueState(c); if(ds==="late") dueTd.style.color="var(--danger)"; else if(ds==="soon") dueTd.style.color="var(--warn-text)"; } tr.appendChild(dueTd);
        var prTd=document.createElement("td"); prTd.textContent=c.priority||"normal"; tr.appendChild(prTd);
        var costTd=document.createElement("td"); costTd.className="text-right tabular-nums"; costTd.textContent=(c.usage&&c.usage.cost)?fmtCost(c.usage.cost):"n/a"; tr.appendChild(costTd);
        var actTd=document.createElement("td");
        var openBtn=document.createElement("button"); openBtn.type="button"; openBtn.className="secondary"; openBtn.textContent="Open"; openBtn.addEventListener("click", function(){ openCardId=c.id; renderBoard(board); }); actTd.appendChild(openBtn);
        if(c.assignee!==((document.getElementById("instance-chip")||{}).textContent||"").trim()){
          var claimBtn=document.createElement("button"); claimBtn.type="button"; claimBtn.className="secondary"; claimBtn.textContent="Claim"; claimBtn.style.marginLeft="var(--space-2)"; claimBtn.addEventListener("click", function(){ postBoard({op:"update", id:c.id, assignee: ((document.getElementById("instance-chip")||{}).textContent||"").trim()}, "Claimed."); }); actTd.appendChild(claimBtn);
        }
        tr.appendChild(actTd);
        tbody.appendChild(tr);
      });
      table.appendChild(tbody); listView.appendChild(table);
    }
    // Board writes already flow through renderBoard, so the list can update
    // synchronously with the columns instead of polling forever in the
    // background to rediscover the same state.
    _renderBoardList = renderList;
    if(sortSel) sortSel.addEventListener("change", renderList);
    // initial
    try{ renderList(); }catch(_){}
  })();
}
