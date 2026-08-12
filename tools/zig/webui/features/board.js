// Board view — ES module, no bundler.
// Owns #view-board: columns and cards, the card detail modal, filters, and
// the list view. The pure column/card helpers stay in ../lib/board.js; the
// goal side of the card<->goal mirroring lives in ./goals.js. bindBoard()
// wires the DOM and the app-level callbacks (tab counts, run opening, the
// peer roster for @ mention hints).
import { fmtInt, fmtCost, formatChatTime, fmtDeadline, readJson } from "../core/utils.js";
import { T, bind, state, add } from "../core/ui.js";
import { icon } from "../core/icons.js";
import { openOverlay, closeOverlay, trapOverlayTab } from "../core/overlay.js";
import { doneColumn as doneColumnOf, blockers as blockersOf, dueState } from "../lib/board.js";
import { goalState, postGoal, goalIdForCard, workCardAsGoal, syncCardsFromGoals, loadGoals } from "./goals.js";

var el = null;
var _setTabCount = null;
var _openRun = null;
var _getKnownPeers = null;


export var board = { columns: [], cards: [] };
var openCardId = null;

/* Whether a board fetch has completed at least once. The goals module asks
   before mirroring goals onto the board: matching against a card list that
   was never fetched (always empty) is what used to create a duplicate card
   on every visit to the Goals view. */
var boardLoaded = false;
export function boardIsLoaded() { return boardLoaded; }

export function setOpenCardId(id) { openCardId = id; }

function doneColumn() { return doneColumnOf(board); }
function blockers(card) { return blockersOf(card, board, cardById); }

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
      var keep = el.boardRoom.value;
      el.boardRoom.textContent = "";
      add(el.boardRoom, rooms.map(function (name) { return T.option({ value: name }, name); }));
      if (keep && rooms.indexOf(keep) !== -1) el.boardRoom.value = keep;
      return loadBoard();
    })
    .catch(function () { return loadBoard(); });
}

function boardRoom() {
  return (el.boardRoom && el.boardRoom.value) || "board";
}

export function loadBoard() {
  return fetch("/api/board?room=" + encodeURIComponent(boardRoom()))
    .then(readJson)
    .then(function (d) {
      boardLoaded = true;
      renderBoard(d.board || { columns: [], cards: [] });
    })
    .catch(function (err) { el.boardStatus.textContent = "Could not load the board: " + err.message; });
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
      // card mirrors a goal, the goal follows: done -> the goal is done,
      // review -> it waits for review, and pulling a card back out of
      // done/review reopens the goal. Anywhere else changes nothing — an
      // active goal's card may sit in backlog, ready or doing, and an
      // abandoned goal stays abandoned until someone reactivates it
      // deliberately.
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
          } else if (payload.column !== doneColumn() && payload.column !== "review" &&
                     (cur === "done" || cur === "review")) {
            postGoal({ id: gid, status: "active" }, "Goal reactivated from the board.");
          }
        }
      }
      if (status) el.boardStatus.textContent = status;
      return d;
    })
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
var boardState = state({ columns: [], cards: [], mine: false, me: "", open: null, text: "", blockedOnly: false, priority: "", assignee: "" });

function boardFilterState() {
  return {
    text: (document.getElementById("board-filter-input") || {}).value || "",
    blockedOnly: !!(document.getElementById("board-filter-blocked") || {}).checked,
    priority: (document.getElementById("board-filter-priority") || {}).value || "",
    assignee: (document.getElementById("board-filter-assignee") || {}).value || ""
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
  add(el.cardColumn, (board.columns || []).map(function (c) {
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
      var peers = (_getKnownPeers() || []).map(function(p){ return p.name || p; });
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
  if (c.goal) {
    var gf = document.createElement("span");
    gf.className = "card-flag";
    gf.setAttribute("data-goal", "true");
    gf.textContent = "goal";
    gf.title = "Mirrors a goal — kept in step with the Goals view";
    meta.appendChild(gf);
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
   what it has cost, and what has happened to it. */
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

  var head = document.createElement("div");
  head.className = "run-detail-head";
  var title = document.createElement("span");
  title.className = "run-detail-title";
  title.id = "card-detail-title";
  title.textContent = c.title;
  var close = document.createElement("button");
  close.type = "button";
  close.className = "secondary";
  close.textContent = "Close";
  close.addEventListener("click", function () {
    delete cardDrafts[c.id];
    openCardId = null;
    closeCardDetail();
    renderBoard(board);
  });
  head.appendChild(title);
  head.appendChild(close);
  box.appendChild(head);

  // ---- fields ----
  var fields = detailSection(box, "Card");
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
    if (!titleIn.value.trim()) {
      // Don't post an empty title just to have the backend refuse it with the
      // cryptic "title must be 1-512 characters"; say what to do in place and
      // leave the draft intact so the user can type a title.
      el.boardStatus.textContent = "A card needs a title before it can be saved.";
      titleIn.focus();
      return;
    }
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

  var moveRow = document.createElement("div");
  moveRow.className = "detail-row";
  var moveSel = document.createElement("select");
  moveSel.id = "card-f-column";
  (board.columns || []).forEach(function(col){ var o=document.createElement("option"); o.value=col.id; o.textContent=col.title; moveSel.appendChild(o); });
  moveSel.value = c.column;
  var moveBtn = document.createElement("button"); moveBtn.type="button"; moveBtn.className="secondary"; moveBtn.textContent="Move";
  moveBtn.addEventListener("click", function(){ if(moveSel.value !== c.column) postBoard({op:"move", id:c.id, column: moveSel.value}, "Moved to " + moveSel.value + "."); });
  moveSel.addEventListener("change", function(){ moveBtn.disabled = moveSel.value === c.column; });
  moveBtn.disabled = true;
  moveRow.appendChild(moveSel); moveRow.appendChild(moveBtn);
  fields.appendChild(moveRow);

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
  asGoal.title = "Run this card as a goal — reuses the goal it already mirrors, or creates one. The card moves to Doing, then to Review when the run finishes.";
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
  var subs = detailSection(box, "Subtasks");
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
  var deps = detailSection(box, "Waiting on");
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
    var u = detailSection(box, "Cost so far");
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

  // ---- log ----
  var logBox = detailSection(box, "Activity");
  var entries = (c.log || []).slice().reverse();
  if (!entries.length) {
    var empty = document.createElement("p");
    empty.className = "meta";
    empty.textContent = "No activity yet. Moving, assigning, or commenting on this card will build its history here.";
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
  // focus first editable field in the modal (Slack/Trello: opening a card puts you on Title)
  try { var first = box.querySelector("#card-f-title"); if (first) setTimeout(function(){ first.focus(); first.select(); }, 0); } catch(_){}
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

  bind(el.board, boardState, function (s) {
    var open = 0;
    var done = s.columns.length ? s.columns[s.columns.length - 1].id : "done";
    s.cards.forEach(function (c) {
      if (c.column !== done && (!s.mine || c.assignee === s.me)) open += 1;
    });
    _setTabCount("board", open);
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
        // The board-level first-use message already explains how cards get
        // here. Reserve this list message for the genuinely different case
        // where cards exist but the active filters hide all of them.
        if(!(boardState.val.cards||[]).length) return;
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
        var openBtn=document.createElement("button"); openBtn.type="button"; openBtn.className="secondary"; openBtn.textContent="Open"; openBtn.addEventListener("click", function(){ openCardId=c.id; renderBoard(board); }); actTd.appendChild(openBtn);
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
      // bind doesn't expose subscribe; poll via mutation: boardState.val setter triggers list
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
}
