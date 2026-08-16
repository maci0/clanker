// Board view — ES module, no bundler.
// Owns #view-kanban: columns and cards, the card detail modal, filters, and
// the list view. The pure column/card helpers stay in ../lib/board.js; the
// goal side of the card<->goal mirroring lives in ./goals.js. bindBoard()
// wires the DOM and the app-level callbacks (tab counts, run opening, the
// peer roster for @ mention hints).
import { fmtInt, fmtCost, formatChatTime, fmtDeadline, readJson, clip } from "../core/utils.js";
import { T, bind, state, add, toast, uiConfirm, uiPrompt, showLoadError } from "../core/ui.js";
import { icon } from "../core/icons.js";
import { openOverlay, closeOverlay, trapOverlayTab } from "../core/overlay.js";
import { doneColumn as doneColumnOf, blockers as blockersOf, dueState, priorityRank } from "../lib/board.js";
import { goalState, postGoal, goalIdForCard, workCardAsGoal, syncCardsFromGoals, loadGoals, isGoalRunning } from "./goals.js";

var el = null;
var _setTabCount = null;
var _openRun = null;
var _getKnownPeers = null;
var _renderBoardList = null;


export var board = { columns: [], cards: [] };
var openCardId = null;

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
  if (s.text && hay.toLowerCase().indexOf(s.text) === -1) return false;
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
      add(el.boardRoom, rooms.map(function (name) { return T.option({ value: name }, name); }));
      if (keep && rooms.indexOf(keep) !== -1) el.boardRoom.value = keep;
      else el.boardRoom.value = defRoom;
      return loadBoard();
    })
    .catch(function () { return loadBoard(); });
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
    text: bf.text.trim().toLowerCase(),
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

function boardColumn(col, s) {
  var shown = s.cards
    .filter(function (c) { return c.column === col.id && cardMatchesBoardFilter(c, s); })
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
    if (boardHasActiveFilters(s)) {
      emptySlot.textContent = "No cards in this lane match the filters";
    } else {
      emptySlot.textContent = "Drop here — or ";
      var addLink = document.createElement("button");
      addLink.type = "button"; addLink.className = "secondary";
      addLink.textContent = "Add goal";
      addLink.addEventListener("click", function(e){ e.stopPropagation(); openQuickAdd(); });
      emptySlot.appendChild(addLink);
    }
    items.push(emptySlot);
  }
  var list = T.ul({
    class: "board-cards",
    id: "board-cards-" + col.id,
    "aria-label": col.title + ", " + shown.length + (shown.length === 1 ? " card" : " cards")
  }, items);

  /* Trello-style add card: a subtle "+ Add a card" trigger that expands to
     a textarea form on click. Cards are goals, so completing the form fills
     the goal objective and shifts focus to the criterion. */
  var quickAdd = T.div({ class: "board-quick-add" });

  // Trigger button (visible by default)
  var qaTrigger = document.createElement("button");
  qaTrigger.type = "button";
  qaTrigger.className = "board-add-trigger";
  qaTrigger.appendChild(icon("plus", 14));
  qaTrigger.appendChild(document.createTextNode(" Add a card"));

  // Form (hidden by default, shown on trigger click)
  var qaForm = document.createElement("div");
  qaForm.className = "board-add-form";
  var qaTextarea = document.createElement("textarea");
  qaTextarea.placeholder = "Enter a goal for this card…";
  qaTextarea.maxLength = 500;
  qaTextarea.rows = 2;
  var qaActions = document.createElement("div");
  qaActions.className = "board-add-actions";
  var qaSave = document.createElement("button"); qaSave.type = "button"; qaSave.className = "secondary"; qaSave.textContent = "Add card";
  var qaCancel = document.createElement("button"); qaCancel.type = "button"; qaCancel.className = "board-add-cancel"; qaCancel.appendChild(icon("close", 12));
  qaCancel.setAttribute("aria-label", "Cancel adding a goal to " + col.title);
  qaActions.appendChild(qaSave);
  qaActions.appendChild(qaCancel);
  qaForm.appendChild(qaTextarea);
  qaForm.appendChild(qaActions);
  quickAdd.appendChild(qaTrigger);
  quickAdd.appendChild(qaForm);

  function openQuickAdd(){ quickAdd.classList.add("is-adding"); qaTextarea.focus(); }
  function closeQuickAdd(){ quickAdd.classList.remove("is-adding"); qaTextarea.value = ""; }
  qaTrigger.addEventListener("click", function(e){ e.stopPropagation(); openQuickAdd(); });
  qaCancel.addEventListener("click", function(e){ e.stopPropagation(); closeQuickAdd(); });
  qaTextarea.addEventListener("keydown", function(e){
    if (e.key === "Enter" && !e.shiftKey && qaTextarea.value.trim()) { e.preventDefault(); doCreate(); }
    else if (e.key === "Escape") { e.preventDefault(); closeQuickAdd(); }
  });
  // Slack-like: typing @ in quick-add shows available assignees as placeholder hint
  qaTextarea.addEventListener("input", function(){
    var v = qaTextarea.value;
    var atIdx = v.lastIndexOf("@");
    if (atIdx !== -1) {
      var q = v.slice(atIdx + 1).toLowerCase();
      var peers = (_getKnownPeers() || []).map(function(p){ return p.name || p; });
      var hit = peers.find(function(n){ return n.toLowerCase().indexOf(q) === 0; });
      if (hit) qaTextarea.title = "Assign to @" + hit + " — press Tab to accept";
      else qaTextarea.title = "";
    } else qaTextarea.title = "";
  });
  function doCreate(){
    var t = qaTextarea.value.trim(); if (!t) return;
    closeQuickAdd();
    el.boardStatus.textContent = "Creating goal card…";
    postGoal({ objective: t }, "Goal card saved. It has not started.").then(function (d) {
      if (!d) {
        el.boardStatus.textContent = "Could not create the goal card.";
        return;
      }
      el.boardStatus.textContent = "Goal card added to Backlog.";
    });
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
        collapse.type = "button"; collapse.className = "secondary";
        collapse.title = "Collapse lane";
        collapse.classList.add("board-lane-control");
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
      T.h3({ class: "board-col-title", id: "board-col-" + col.id }, col.title),
      T.span({ class: "board-col-head-actions" },
        (function(){
          var add = document.createElement("button");
          add.type = "button"; add.className = "secondary";
          add.title = "Define a new goal card";
          add.classList.add("board-lane-control");
          add.setAttribute("aria-label", "Add a goal to " + col.title);
          add.appendChild(icon("plus", 14));
          add.addEventListener("click", function(e){
            e.stopPropagation();
            // Trello-style: open the inline quick-add form
            if (!quickAdd.classList.contains("is-adding")) openQuickAdd(); else closeQuickAdd();
          });
          var wrap = document.createElement("span");
          wrap.appendChild(add);
          return wrap;
        })(),
        /* Trello-style column options menu */
        (function(){
          var menuBtn = document.createElement("button");
          menuBtn.type = "button"; menuBtn.className = "secondary board-lane-control board-col-menu-btn";
          menuBtn.appendChild(icon("more", 14)); menuBtn.title = "Column actions";
          menuBtn.setAttribute("aria-label", "Actions for " + col.title);
          menuBtn.setAttribute("aria-haspopup", "true");
          menuBtn.addEventListener("click", function(e){
            e.stopPropagation();
            /* close any other open column menu */
            document.querySelectorAll(".board-col-menu.is-open").forEach(function(m){ m.classList.remove("is-open"); });
            var menu = document.createElement("div");
            menu.className = "board-col-menu is-open";
            menu.setAttribute("role", "menu");
            var title = document.createElement("div");
            title.className = "board-col-menu-title";
            title.textContent = "List actions";
            menu.appendChild(title);

            var sep1 = document.createElement("hr");
            sep1.className = "board-col-menu-sep";
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
              b.type = "button"; b.className = "board-col-menu-item";
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
            sep2.className = "board-col-menu-sep";
            menu.appendChild(sep2);

            /* Move all cards to… (quick-move to another column) */
            var moveAll = document.createElement("button");
            moveAll.type = "button"; moveAll.className = "board-col-menu-item";
            moveAll.textContent = "Move all cards in this list…";
            moveAll.setAttribute("role", "menuitem");
            if (shown.length === 0) { moveAll.disabled = true; moveAll.style.opacity = "0.5"; }
            moveAll.addEventListener("click", function(){
              /* replace menu contents with column picker */
              while (menu.firstChild) menu.removeChild(menu.firstChild);
              var pickTitle = document.createElement("div");
              pickTitle.className = "board-col-menu-title";
              pickTitle.textContent = "Move all to…";
              menu.appendChild(pickTitle);
              var sep = document.createElement("hr");
              sep.className = "board-col-menu-sep";
              menu.appendChild(sep);
              s.columns.forEach(function(dest){
                if (dest.id === col.id) return;
                var opt = document.createElement("button");
                opt.type = "button"; opt.className = "board-col-menu-item";
                opt.textContent = dest.title;
                opt.setAttribute("role", "menuitem");
                opt.addEventListener("click", function(){
                  menu.remove(); backdrop.remove();
                  shown.forEach(function(c){
                    postBoard({ op: "move", id: c.id, column: dest.id }, null);
                  });
                  // The shared themed toast(): keep this off the app-level
                  // error path and on the "moved" update status.
                  toast("Moved " + shown.length + " card" + (shown.length > 1 ? "s" : "") + " to " + dest.title);
                });
                menu.appendChild(opt);
              });
            });
            menu.appendChild(moveAll);

            /* close backdrop */
            var backdrop = document.createElement("div");
            backdrop.className = "board-col-menu-backdrop";
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

function menuPopup(anchored) {
  var popup = document.createElement("div");
  popup.className = anchored ? "menu-popup is-anchored" : "menu-popup";
  return popup;
}
function menuTitle(text, plain) {
  var t = document.createElement("div");
  t.className = plain ? "menu-popup-title is-plain" : "menu-popup-title";
  t.textContent = text;
  return t;
}
function menuItem(opts) {
  opts = opts || {};
  var btn = document.createElement("button");
  btn.type = "button";
  btn.className = "menu-popup-item" + (opts.muted ? " is-muted" : "") + (opts.current ? " is-current" : "");
  return btn;
}
function menuAvatar(name) {
  var av = document.createElement("span");
  av.className = "menu-popup-avatar";
  av.textContent = (name || "?").slice(0, 2).toUpperCase();
  return av;
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

function cardNode(c) {
  var b = document.createElement("button");
  b.type = "button";
  b.className = "card";
  if (c.priority && c.priority !== "normal") b.setAttribute("data-priority", c.priority);
  b.draggable = true;
  b.setAttribute("data-card", c.id);
  if (c.id === openCardId) b.setAttribute("aria-current", "true");

  // Trello cover strip — priority or label-color tint at top edge; also cover_color
  var labels = c.labels || [];
  var coverColor = c.cover_color || (labels.length && labels[0].color ? labels[0].color : null);
  if (coverColor) {
    var cover = document.createElement("div");
    cover.className = "card-cover";
    cover.setAttribute("data-color", coverColor);
    b.appendChild(cover);
  } else if (c.priority && c.priority !== "normal") {
    var cover2 = document.createElement("div");
    cover2.className = "card-cover";
    cover2.setAttribute("data-priority", c.priority);
    b.appendChild(cover2);
  }

  // Quick edit pencil — always present, shown on hover via CSS
  var pencil = document.createElement("button");
  pencil.type = "button";
  pencil.className = "card-quick-edit-btn";
  pencil.appendChild(icon("pencil", 14));
  pencil.title = "Quick edit";
  pencil.setAttribute("aria-label", "Quick edit card");
  pencil.addEventListener("click", function(e) {
    e.stopPropagation();
    openCardId = c.id;
    renderBoard(board);
  });
  b.appendChild(pencil);

  // Card body wrapper (inside padding)
  var body = document.createElement("div");
  body.className = "card-body";

  // Quick actions overlay (Trello pencil icon on hover)
  var qa = document.createElement("span");
  qa.className = "card-quick-actions";
  var qaEdit = document.createElement("button");
  qaEdit.type = "button";
  qaEdit.appendChild(icon("pencil", 14));
  qaEdit.title = "Open card";
  qaEdit.setAttribute("aria-label", "Open card");
  qaEdit.addEventListener("click", function(e) {
    e.stopPropagation();
    openCardId = c.id;
    renderBoard(board);
  });
  qa.appendChild(qaEdit);
  // Quick move to next column
  var qaMove = document.createElement("button");
  qaMove.type = "button";
  qaMove.appendChild(icon("arrowRight", 14));
  qaMove.title = "Move to next column";
  qaMove.setAttribute("aria-label", "Move to next column");
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
  b.appendChild(qa);

  // The only way to move a card without a pointer, so it says so rather than
  // living in a source comment.
  b.setAttribute("aria-keyshortcuts", "Control+ArrowLeft Control+ArrowRight");
  b.title = "Ctrl or Cmd with the arrow keys moves this card between columns";

  // Labels row — Trello-style compact colour pills
  if (labels.length) {
    var labelsEl = document.createElement("span");
    labelsEl.className = "card-labels";
    labels.forEach(function(lbl) {
      var pill = document.createElement("span");
      pill.className = "card-label";
      pill.setAttribute("data-color", lbl.color || "blue");
      pill.textContent = lbl.text || lbl.color || "";
      pill.title = lbl.text || lbl.color || "";
      labelsEl.appendChild(pill);
    });
    body.appendChild(labelsEl);
  }

  var title = document.createElement("span");
  title.className = "card-title";
  title.textContent = c.title;
  body.appendChild(title);

  // Description preview. The card's notes are `body` — the field the detail
  // panel edits, the filter searches and the create payload sends. This read
  // `c.notes`, which nothing on either side of the wire has ever set, so no
  // card ever showed a preview.
  if (c.body && c.body.trim()) {
    var descPrev = document.createElement("span");
    descPrev.className = "card-desc-preview";
    descPrev.textContent = clip(c.body.trim(), 120);
    body.appendChild(descPrev);
  }

  // Trello-style badges row (due, subtasks, blocked, goal, cost)
  var badges = document.createElement("span");
  badges.className = "card-badges";
  var hasBadges = false;

  if (c.deadline) {
    var ds = dueState(c);
    var due = document.createElement("span");
    due.className = "card-badge";
    due.setAttribute("data-due", ds);
    due.appendChild(icon("calendar", 14));
    due.appendChild(document.createTextNode(" " + (ds === "late" ? "Late · " : ds === "soon" ? "Soon · " : "") + fmtDeadline(c.deadline)));
    due.title = "Due " + c.deadline;
    badges.appendChild(due);
    hasBadges = true;
  }

  if ((c.subtasks || []).length) {
    var doneN = c.subtasks.filter(function (s) { return s.done; }).length;
    var totalN = c.subtasks.length;
    var subBadge = document.createElement("span");
    subBadge.className = "card-badge";
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
    bl.className = "card-badge";
    bl.style.color = "var(--warn-text)";
    bl.appendChild(icon("blocked", 14));
    bl.appendChild(document.createTextNode(" " + blocked.length));
    bl.title = "Blocked by " + blocked.length + " card(s)";
    badges.appendChild(bl);
    hasBadges = true;
  }

  if (c.goal) {
    var gf = document.createElement("span");
    gf.className = "card-badge";
    gf.style.color = "var(--accent-text)";
    gf.appendChild(icon("goal", 14));
    gf.title = "Mirrors a goal — kept in step with the Goals view";
    badges.appendChild(gf);
    // The same start actuator the "Start work" button shows on the open card,
    // surfaced on the closed card so goal runs are visible at a glance. While
    // a run for this goal is in flight (streaming here or on another client)
    // the actuator lights up, so the closed card shows the live run state.
    var sw = document.createElement("span");
    sw.className = "card-badge";
    sw.appendChild(icon("rocket", 14));
    sw.title = "Goal — Start work (opens a run)";
    if (isGoalRunning(c.goal)) {
      sw.dataset.goalRun = "true";
      sw.title = "Goal run in progress";
    }
    badges.appendChild(sw);
    hasBadges = true;
  }

  if ((c.activity || []).length) {
    var actBadge = document.createElement("span");
    actBadge.className = "card-badge";
    actBadge.appendChild(icon("activity", 14));
    actBadge.appendChild(document.createTextNode(" " + c.activity.length));
    actBadge.title = c.activity.length + " activity entries";
    badges.appendChild(actBadge);
    hasBadges = true;
  }

  if (c.usage && c.usage.cost) {
    var costBadge = document.createElement("span");
    costBadge.className = "card-badge";
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
    bar.className = "card-progress-bar";
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
  bottom.className = "card-bottom";
  var hasBottom = false;

  if (c.priority && c.priority !== "normal") {
    var pr = document.createElement("span");
    pr.className = "card-flag";
    pr.setAttribute("data-priority", c.priority);
    pr.textContent = c.priority;
    bottom.appendChild(pr);
    hasBottom = true;
  }

  // Trello-style member avatar (initials) when assigned
  if (c.assignee) {
    var membersWrap = document.createElement("span");
    membersWrap.className = "card-members";
    var av = document.createElement("span");
    av.className = "card-member";
    av.textContent = (c.assignee.trim().substring(0, 2) || "?").toUpperCase();
    av.title = c.assignee + " — click to reassign";
    av.addEventListener("click", function(e){
      e.stopPropagation();
      // Trello-style member picker popup
      var existing = document.querySelector(".member-picker-popup");
      if (existing) existing.remove();
      var popup = menuPopup();
      popup.classList.add("member-picker-popup");
      popup.appendChild(menuTitle("Members", true));
      var unBtn = menuItem({ muted: true });
      unBtn.appendChild(icon("close", 12));
      unBtn.appendChild(document.createTextNode(" Remove assignee"));
      unBtn.addEventListener("click", function(){ popup.remove(); postBoard({ op: "update", id: c.id, assignee: "" }, "Unassigned."); });
      popup.appendChild(unBtn);
      var peers = (_getKnownPeers() || []).map(function(p){ return typeof p === "string" ? p : p.name || p; });
      if (peers.indexOf(c.assignee) === -1 && c.assignee) peers.unshift(c.assignee);
      peers.forEach(function(name){
        var opt = menuItem({ current: name === c.assignee });
        opt.appendChild(menuAvatar(name));
        opt.appendChild(document.createTextNode(name));
        opt.addEventListener("click", function(){ popup.remove(); postBoard({ op: "update", id: c.id, assignee: name }, "Assigned to " + name + "."); });
        popup.appendChild(opt);
      });
      dismissOnOutside(popup);
      // Position near the avatar
      av.style.position = "relative";
      av.appendChild(popup);
    });
    membersWrap.appendChild(av);
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
    // Store the column we are dragging from
    boardDragSource = { cardId: c.id, column: c.column };
  });
  b.addEventListener("dragend", function () {
    b.removeAttribute("data-dragging");
    boardDragSource = null;
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
    var rect = b.getBoundingClientRect();
    var above = (e.clientY - rect.top) < rect.height / 2;
    handleCardDrop(draggedId, c.column, c.id, above);
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

/* ---- Drag-and-drop helpers for within-column reordering ---- */
var boardDragSource = null;

function showDropIndicator(targetCard, e) {
  clearDropIndicators();
  var rect = targetCard.getBoundingClientRect();
  var above = (e.clientY - rect.top) < rect.height / 2;
  var indicator = document.createElement("div");
  indicator.className = "board-drop-indicator";
  if (above) {
    targetCard.parentNode.insertBefore(indicator, targetCard);
  } else {
    targetCard.parentNode.insertBefore(indicator, targetCard.nextSibling);
  }
}

function clearDropIndicators() {
  var indicators = document.querySelectorAll(".board-drop-indicator");
  for (var i = 0; i < indicators.length; i++) indicators[i].remove();
}

function handleCardDrop(draggedId, targetColumn, targetCardId, above) {
  // For now, move card to the target column (cross-column drag)
  // The server doesn't support position ordering yet, so we just move columns
  var draggedCard = cardById(draggedId);
  if (!draggedCard) return;
  if (draggedCard.column !== targetColumn) {
    // Cross-column move
    postBoard({ op: "move", id: draggedId, column: targetColumn }, "Moved.");
  }
  // Within-column reorder: visually swap and track position
  // (Server-side ordering support would go here)
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
   what it has cost, and what has happened to it.
   Rendered as a Trello-style panel with header, main column and sidebar. */
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
  }
  // scrim click closes
  el.cardDetail.onclick = function(e){ if (e.target === el.cardDetail) { delete cardDrafts[c.id]; openCardId = null; closeCardDetail(); renderBoard(board); } };

  // ---- Trello-style panel wrapper ----
  var panel = document.createElement("div");
  panel.className = "card-detail-panel";

  // ---- Header: icon + title + close ----
  var header = document.createElement("div");
  header.className = "card-detail-header";
  var headerIcon = document.createElement("span");
  headerIcon.className = "card-detail-icon";
  headerIcon.appendChild(icon("copy", 18));
  var headerTitle = document.createElement("h3");
  headerTitle.id = "card-detail-title";
  headerTitle.textContent = c.title;
  var headerCol = document.createElement("span");
  headerCol.className = "card-detail-header-col";
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
  close.className = "card-detail-close";
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
  headerTextWrap.className = "card-detail-header-text";
  headerTextWrap.appendChild(headerTitle);
  // "in list" subtitle like Trello
  var colLabel = c.column || "";
  var colTitle = colLabel.replace(/_/g, " ").replace(/\b\w/g, function(l){ return l.toUpperCase(); });
  var inListEl = document.createElement("div");
  inListEl.className = "card-in-list";
  inListEl.appendChild(document.createTextNode("in list "));
  var inListName = document.createElement("strong");
  inListName.className = "card-in-list-name";
  inListName.textContent = colTitle;
  inListEl.appendChild(inListName);
  inListName.addEventListener("click", function() {
    // Open column picker
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
  });
  headerTextWrap.appendChild(inListEl);
  header.appendChild(headerIcon);
  header.appendChild(headerTextWrap);
  header.appendChild(close);

  // ---- Cover color bar at top of panel ----
  var coverColor = c.cover_color || (c.labels && c.labels.length && c.labels[0].color ? c.labels[0].color : null);
  if (coverColor) {
    var coverDiv = document.createElement("div");
    coverDiv.className = "card-detail-cover";
    coverDiv.setAttribute("data-color", coverColor);
    panel.appendChild(coverDiv);
  }
  panel.appendChild(header);

  // ---- Two-column layout: main + sidebar ----
  var layout = document.createElement("div");
  layout.className = "card-detail-layout";

  var mainCol = document.createElement("div");
  mainCol.className = "card-detail-main";

  var sidebarCol = document.createElement("div");
  sidebarCol.className = "card-detail-sidebar";

  // ---- Labels section in main (Trello-style clickable label pills) ----
  var labelsHead = document.createElement("p");
  labelsHead.className = "detail-head";
  labelsHead.textContent = "Labels";
  mainCol.appendChild(labelsHead);

  var labelsRow = document.createElement("div");
  labelsRow.className = "labels-row";
  var currentLabels = c.labels || [];
  currentLabels.forEach(function(lbl) {
    var pill = document.createElement("button");
    pill.type = "button";
    pill.className = "card-label is-open";
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
  addLabelBtn.className = "label-add-btn";
  addLabelBtn.appendChild(icon("plus", 12));
  addLabelBtn.appendChild(document.createTextNode(" Add"));
  addLabelBtn.addEventListener("click", function() {
    // Toggle label picker visibility
    labelPicker.hidden = !labelPicker.hidden;
  });
  labelsRow.appendChild(addLabelBtn);
  mainCol.appendChild(labelsRow);

  // Label picker (hidden by default)
  var labelPicker = document.createElement("div");
  labelPicker.className = "label-picker";
  labelPicker.hidden = true;
  LABEL_COLORS.forEach(function(color) {
    var swatch = document.createElement("button");
    swatch.type = "button";
    swatch.className = "label-picker-item";
    swatch.setAttribute("data-color", color);
    var isSelected = currentLabels.some(function(l) { return l.color === color; });
    swatch.setAttribute("aria-label", (isSelected ? "Remove " : "Add ") + color + " label");
    if (isSelected) swatch.setAttribute("data-selected", "true");
    swatch.addEventListener("click", function() {
      if (isSelected) {
        var newLabels = currentLabels.filter(function(l) { return l.color !== color; });
        postBoard({ op: "update", id: c.id, labels: newLabels }, "Labels updated.");
      } else {
        // Show inline text input for label name
        var existing = labelPicker.querySelector(".label-text-input-wrap");
        if (existing) existing.remove();
        var wrap = document.createElement("div");
        wrap.className = "label-name-row";
        var samplePill = document.createElement("span");
        samplePill.className = "card-label is-sample";
        samplePill.setAttribute("data-color", color);
        samplePill.textContent = color;
        wrap.appendChild(samplePill);
        var txtIn = document.createElement("input");
        txtIn.type = "text";
        txtIn.placeholder = "Label name…";
        txtIn.value = color;
        txtIn.className = "label-name-input";
        txtIn.addEventListener("input", function(){ samplePill.textContent = txtIn.value || color; });
        wrap.appendChild(txtIn);
        var addBtn = document.createElement("button");
        addBtn.type = "button";
        addBtn.textContent = "Add";
        addBtn.className = "label-name-confirm";
        addBtn.addEventListener("click", function(){
          var text = txtIn.value.trim() || color;
          var newLabels = currentLabels.concat([{ color: color, text: text }]);
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
  descDisplay.className = "card-desc-display";
  if (c.body && c.body.trim()) {
    descDisplay.textContent = c.body;
  } else {
    descDisplay.textContent = "Add a more detailed description…";
    descDisplay.classList.add("is-empty");
  }
  var bodyIn = document.createElement("textarea");
  bodyIn.id = "card-f-body";
  bodyIn.rows = 6;
  bodyIn.placeholder = "Add a more detailed description…";
  bodyIn.className = "card-desc-edit";
  bindDraft(bodyIn, c.id, "body", c.body);
  var descActions = document.createElement("div");
  descActions.className = "card-desc-actions";
  var descSave = document.createElement("button");
  descSave.type = "button";
  descSave.className = "card-detail-save-btn";
  descSave.textContent = "Save";
  var descCancel = document.createElement("button");
  descCancel.type = "button";
  descCancel.className = "secondary";
  descCancel.textContent = "Cancel";
  descActions.appendChild(descSave);
  descActions.appendChild(descCancel);
  descDisplay.addEventListener("click", function() {
    descDisplay.hidden = true;
    bodyIn.style.display = "block";
    descActions.classList.add("is-open");
    bodyIn.focus();
  });
  descCancel.addEventListener("click", function() {
    bodyIn.value = c.body || "";
    bodyIn.style.display = "none";
    descActions.classList.remove("is-open");
    descDisplay.hidden = false;
  });
  descSave.addEventListener("click", function() {
    bodyIn.dispatchEvent(new Event("change"));
    var filled = !!bodyIn.value.trim();
    descDisplay.textContent = filled ? bodyIn.value : "Add a more detailed description…";
    descDisplay.classList.toggle("is-empty", !filled);
    bodyIn.style.display = "none";
    descActions.classList.remove("is-open");
    descDisplay.hidden = false;
  });
  fields.appendChild(descDisplay);
  fields.appendChild(bodyIn);
  fields.appendChild(descActions);

  // ---- Sidebar: quick actions ----
  var sideTitle1 = document.createElement("div");
  sideTitle1.className = "card-detail-sidebar-title";
  sideTitle1.textContent = "Add to card";
  sidebarCol.appendChild(sideTitle1);

  // Assignee sidebar button with member picker dropdown
  var assignWrap = document.createElement("div");
  assignWrap.className = "board-rel";
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
    var popup = menuPopup(true);
    popup.classList.add("member-picker-popup");
    popup.appendChild(menuTitle("Members"));
    var unBtn = menuItem({ muted: true });
    unBtn.appendChild(icon("close", 12));
    unBtn.appendChild(document.createTextNode(" Remove member"));
    unBtn.addEventListener("click", function(){ popup.remove(); postBoard({ op: "update", id: c.id, assignee: "" }, "Unassigned."); });
    popup.appendChild(unBtn);
    var peers = (_getKnownPeers() || []).map(function(p){ return typeof p === "string" ? p : p.name || p; });
    if (c.assignee && peers.indexOf(c.assignee) === -1) peers.unshift(c.assignee);
    peers.forEach(function(name){
      var opt = menuItem({ current: name === c.assignee });
      opt.appendChild(menuAvatar(name));
      opt.appendChild(document.createTextNode(name));
      opt.addEventListener("click", function(){ popup.remove(); postBoard({ op: "update", id: c.id, assignee: name }, "Assigned to " + name + "."); });
      popup.appendChild(opt);
    });
    dismissOnOutside(popup, assignBtn);
    assignWrap.appendChild(popup);
  });
  assignWrap.appendChild(assignBtn);
  sidebarCol.appendChild(assignWrap);

  // Priority sidebar button with dropdown
  var prioWrap = document.createElement("div");
  prioWrap.className = "board-rel";
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
  deadlineWrap.className = "board-rel";
  var deadlineBtn = document.createElement("button");
  deadlineBtn.type = "button";
  deadlineBtn.appendChild(icon("calendar", 14));
  deadlineBtn.appendChild(document.createTextNode(c.deadline ? " Due: " + fmtDeadline(c.deadline) : " Dates"));
  var deadlineInput = document.createElement("input");
  deadlineInput.type = "date";
  deadlineInput.className = "card-detail-date-hit";
  if (c.deadline) {
    // Convert deadline to YYYY-MM-DD if it's a unix timestamp
    try {
      var dDate = typeof c.deadline === "number" ? new Date(c.deadline * 1000) : new Date(c.deadline);
      if (!isNaN(dDate.getTime())) deadlineInput.value = dDate.toISOString().slice(0, 10);
    } catch(e) {}
  }
  deadlineInput.addEventListener("change", function() {
    var val = deadlineInput.value;
    if (!val) {
      postBoard({ op: "update", id: c.id, deadline: null }, "Deadline cleared.");
    } else {
      postBoard({ op: "update", id: c.id, deadline: val }, "Due " + val);
    }
  });
  deadlineWrap.appendChild(deadlineBtn);
  deadlineWrap.appendChild(deadlineInput);
  sidebarCol.appendChild(deadlineWrap);

  // Cover color picker
  var coverTitle = document.createElement("div");
  coverTitle.className = "card-detail-sidebar-title";
  coverTitle.style.marginTop = "var(--space-2)";
  coverTitle.textContent = "Cover";
  sidebarCol.appendChild(coverTitle);
  var coverPicker = document.createElement("div");
  coverPicker.className = "cover-color-picker";
  var coverColors = ["green", "yellow", "orange", "red", "purple", "blue", "sky", "pink", "none"];
  var currentCover = c.cover_color || "";
  coverColors.forEach(function(clr) {
    var sw = document.createElement("button");
    sw.type = "button";
    sw.className = "cover-color-swatch";
    sw.setAttribute("data-color", clr);
    sw.title = clr === "none" ? "Remove cover" : clr;
    if (clr === currentCover || (clr === "none" && !currentCover)) sw.setAttribute("data-selected", "true");
    sw.addEventListener("click", function() {
      var val = clr === "none" ? "" : clr;
      postBoard({ op: "update", id: c.id, cover_color: val }, val ? "Cover → " + val : "Cover removed.");
    });
    coverPicker.appendChild(sw);
  });
  sidebarCol.appendChild(coverPicker);

  var sideTitle2 = document.createElement("div");
  sideTitle2.className = "card-detail-sidebar-title";
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
    // Build a small dropdown
    var existing = moveBtn.parentNode.querySelector(".card-detail-move-menu");
    if (existing) { existing.remove(); return; }
    var menu = document.createElement("div");
    menu.className = "card-detail-move-menu";
    board.columns.forEach(function(col) {
      var opt = document.createElement("button");
      opt.type = "button";
      opt.className = "card-detail-move-opt" + (col.id === c.column ? " is-current" : "");
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

  // ---- Hidden original fields for save: title, assignee, priority, deadline ----
  var hiddenFields = document.createElement("div");
  hiddenFields.className = "detail-row";
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

  // A date input, because a deadline typed as a unix timestamp is not a
  // deadline anyone will set twice.
  var dueIn = input("card-f-deadline", "date", "");
  bindDraft(dueIn, c.id, "deadline", c.deadline ? new Date(c.deadline * 1000).toISOString().slice(0, 10) : "");
  hiddenFields.appendChild(dueIn);

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
  saveRow.className = "card-detail-save-row";
  var save = document.createElement("button");
  save.type = "button";
  save.className = "card-detail-save-btn";
  save.textContent = "Save changes";
  save.addEventListener("click", function () {
    var deadline = 0;
    if (dueIn.value) {
      var parsed = Date.parse(dueIn.value + "T23:59:59");
      if (!isNaN(parsed)) deadline = Math.floor(parsed / 1000);
    }
    delete cardDrafts[c.id];
    postBoard({
      op: "update", id: c.id,
      title: titleIn.value || c.title, body: bodyIn.value,
      assignee: assignIn.value, priority: prioIn.value, deadline: deadline
    }, "Card saved.");
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
  goalRow.className = "goal-row";
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
    if (!text) return;
    buttonNode.disabled = true;
    var payload = { op: "subtask_add", id: c.id, text: text };
    if (parentId) payload.parent_subtask_id = parentId;
    postBoard(payload, parentId ? "Child checklist item added." : "Checklist item added.")
      .then(function (ok) { if (ok) inputNode.value = ""; })
      .finally(function () { buttonNode.disabled = false; });
  }

  function renderChecklistItem(s) {
    var item = document.createElement("div");
    item.className = "checklist-item";
    var row = document.createElement("div");
    row.className = "detail-row";
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
          // state the server refused on screen.
          if (!ok) tick.checked = !wanted;
        });
    });
    var lab = document.createElement("label");
    lab.htmlFor = tick.id;
    lab.textContent = s.text;
    lab.className = "subtask";
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
      postBoard({ op: "subtask_remove", id: c.id, subtask_id: s.id }, "Removed checklist item: " + s.text);
    });
    row.appendChild(tick);
    row.appendChild(lab);
    row.appendChild(child);
    row.appendChild(drop);
    item.appendChild(row);

    if ((s.depends_on || []).length) {
      var deps = document.createElement("div");
      deps.className = "checklist-deps";
      (s.depends_on || []).forEach(function (id) {
        var dep = document.createElement("span");
        dep.className = "card-flag";
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
    childForm.className = "detail-row checklist-add";
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
      depForm.className = "checklist-dependency-add";
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
      nested.className = "checklist-children";
      children.forEach(function (x) { nested.appendChild(renderChecklistItem(x)); });
      item.appendChild(nested);
    }
    return item;
  }

  var tree = document.createElement("div");
  tree.className = "checklist-tree";
  (childMap[""] || []).forEach(function (s) { tree.appendChild(renderChecklistItem(s)); });
  subs.appendChild(tree);
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
  checklistAdd.className = "detail-row checklist-add";
  checklistAdd.appendChild(subIn);
  checklistAdd.appendChild(subAdd);
  subs.appendChild(checklistAdd);

  // ---- dependencies ----
  var deps = detailSection(mainCol, "Waiting on");
  (c.depends_on || []).forEach(function (depId) {
    var dep = cardById(depId);
    var row = document.createElement("div");
    row.className = "detail-row";
    var name = document.createElement("span");
    name.textContent = dep ? dep.title + "  ·  " + dep.column : depId + " (missing)";
    if (dep && dep.column !== doneColumn() && dep.column !== "archive") name.className = "dep-open";
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
    var u = detailSection(mainCol, "Cost so far");
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
      b.addEventListener("click", function () { _openRun(rid); });
      u.appendChild(b);
    });
  }

  // ---- Activity timeline (Trello-style) ----
  var logBox = detailSection(mainCol, "Activity");
  var entries = (c.log || []).slice().reverse();
  if (!entries.length) {
    var empty = document.createElement("p");
    empty.className = "meta card-activity-empty";
    empty.textContent = "No activity yet. Moving, assigning, or commenting on this card will build its history here.";
    logBox.appendChild(empty);
  }
  var activityList = document.createElement("div");
  activityList.className = "card-activity";
  entries.forEach(function (e) {
    var item = document.createElement("div");
    item.className = "card-activity-item";
    // Avatar
    var avatar = document.createElement("div");
    avatar.className = "card-activity-avatar";
    var whoName = e.who || "?";
    avatar.textContent = whoName.slice(0, 2).toUpperCase();
    // Set a unique color based on name hash
    var nameHash = 0;
    for (var ci = 0; ci < whoName.length; ci++) nameHash = ((nameHash << 5) - nameHash + whoName.charCodeAt(ci)) | 0;
    // One stable tone per name, from the theme-aware chat-hue palette (in
    // app.css), which re-saturates per theme so the initials stay legible in
    // light and dark alike. No literal hex or white-is-assumed text here.
    avatar.classList.add("avatar-tone-" + (Math.abs(nameHash) % 8));
    item.appendChild(avatar);
    // Content
    var content = document.createElement("div");
    content.className = "card-activity-content";
    var line1 = document.createElement("div");
    var whoSpan = document.createElement("span");
    whoSpan.className = "card-activity-who";
    whoSpan.textContent = whoName;
    var whenSpan = document.createElement("span");
    whenSpan.className = "card-activity-when";
    whenSpan.textContent = e.ts ? formatChatTime(e.ts) : "";
    line1.appendChild(whoSpan);
    line1.appendChild(whenSpan);
    content.appendChild(line1);
    var whatDiv = document.createElement("div");
    whatDiv.className = "card-activity-text";
    whatDiv.textContent = e.what || "";
    content.appendChild(whatDiv);
    item.appendChild(content);
    activityList.appendChild(item);
  });
  logBox.appendChild(activityList);
  // Activity input with send button
  var noteWrap = document.createElement("div");
  noteWrap.className = "card-comment-row";
  var noteAvatar = document.createElement("div");
  noteAvatar.className = "card-activity-avatar card-comment-avatar";
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
  noteSend.className = "card-detail-save-btn card-comment-send";
  noteSend.textContent = "Save";
  noteSend.addEventListener("click", function() {
    if (!noteIn.value.trim()) return;
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
    if (!title) return;
    el.cardAdd.disabled = true;
    postBoard({ op: "create", title: title, column: el.cardColumn.value }, "Card added.").then(function (ok) {
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
          ? ("Moved " + moved + " card" + (moved === 1 ? "" : "s") + " to match their goals.")
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
      try { obj.scrollIntoView({ behavior: "smooth", block: "center" }); } catch (_) {}
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
      var trigger = el.board && el.board.querySelector(".board-add-trigger");
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
    function fmtBoardDate(ts){
      if(!ts) return "";
      var d=new Date(ts*1000);
      var y=d.getFullYear(), m=String(d.getMonth()+1).padStart(2,"0"), da=String(d.getDate()).padStart(2,"0");
      return y+"-"+m+"-"+da;
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
      table.className="usage board-list-table";
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
        var titleTd=document.createElement("th"); titleTd.scope="row"; titleTd.textContent=c.title; titleTd.className="board-list-title"; titleTd.title=c.title; tr.appendChild(titleTd);
        var colTd=document.createElement("td"); colTd.textContent=c.column; tr.appendChild(colTd);
        var whoTd=document.createElement("td"); whoTd.textContent=c.assignee||"—"; tr.appendChild(whoTd);
        var dueTd=document.createElement("td"); dueTd.textContent=c.deadline?fmtBoardDate(c.deadline):"—"; if(c.deadline){ var ds=dueState(c); if(ds==="late") dueTd.style.color="var(--danger)"; else if(ds==="soon") dueTd.style.color="var(--warn-text)"; } tr.appendChild(dueTd);
        var prTd=document.createElement("td"); prTd.textContent=c.priority||"normal"; tr.appendChild(prTd);
        var costTd=document.createElement("td"); costTd.className="num"; costTd.textContent=(c.usage&&c.usage.cost)?fmtCost(c.usage.cost):"—"; tr.appendChild(costTd);
        var actTd=document.createElement("td");
        var openBtn=document.createElement("button"); openBtn.type="button"; openBtn.className="secondary"; openBtn.textContent="Open"; openBtn.addEventListener("click", function(){ openCardId=c.id; renderBoard(board); }); actTd.appendChild(openBtn);
        if(c.assignee!==((document.getElementById("instance-chip")||{}).textContent||"").trim()){
          var claimBtn=document.createElement("button"); claimBtn.type="button"; claimBtn.className="secondary"; claimBtn.textContent="Claim"; claimBtn.style.marginLeft="0.4rem"; claimBtn.addEventListener("click", function(){ postBoard({op:"update", id:c.id, assignee: ((document.getElementById("instance-chip")||{}).textContent||"").trim()}, "Claimed."); }); actTd.appendChild(claimBtn);
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
