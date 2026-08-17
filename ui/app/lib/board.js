// Vanilla, no bundler. Board card-action helpers — pure, no DOM, no page state.
// Importable as ES module.

export var BOARD_COLUMNS = { backlog: "Backlog", ready: "Ready", doing: "Doing", review: "Review", done: "Done", archive: "Archive" };

export function boardActionLine(raw) {
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
      if (a.goal !== undefined) parts.push(a.goal ? "its goal link" : "no goal link");
      if (a.body !== undefined && !parts.length) parts.push("the notes");
      return "changed " + (parts.length ? parts.join(", ") : "a card");
    }
    case "move": return "moved a card to " + col(a.column);
    case "close": return "moved a card to Done";
    case "claim": return "claimed a card";
    case "assign": return a.who ? "assigned a card to " + a.who : "left a card unassigned";
    case "delete": return "deleted a card";
    case "subtask_add": return "added the checklist item " + quoted(a.text);
    case "subtask_toggle": return (a.done === false ? "unticked" : "ticked") + " a checklist item";
    case "subtask_remove": return "removed a checklist item";
    case "subtask_depend": return a.off ? "removed a checklist dependency" : "linked two checklist items";
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

export function doneColumn(board) {
  for (var i = 0; i < (board.columns || []).length; i++) {
    if (board.columns[i].id === "done") return "done";
  }
  return "done";
}

export function blockers(card, board, cardByIdFn) {
  var lookup = cardByIdFn || function (id) {
    for (var i = 0; i < board.cards.length; i++) if (board.cards[i].id === id) return board.cards[i];
    return null;
  };
  return (card.depends_on || []).filter(function (id) {
    var dep = lookup(id);
    return dep && dep.column !== doneColumn(board) && dep.column !== "archive";
  });
}

/* Which priority sorts first. `normal` is what a card without one counts as
   everywhere else on the board, and `high` is rank 0 — so a lookup has to test
   for a missing key rather than for a falsy rank. Testing for falsy is what
   quietly folded every high card in with the normal ones, in both places that
   offer to sort by priority. */
export var PRIORITY_RANK = { high: 0, normal: 1, low: 2 };

export function priorityRank(card) {
  var rank = PRIORITY_RANK[(card && card.priority) || "normal"];
  return rank === undefined ? PRIORITY_RANK.normal : rank;
}

export function dueState(card) {
  if (!card.deadline) return "";
  var left = card.deadline - Math.floor(Date.now() / 1000);
  if (left < 0) return "late";
  if (left < 2 * 24 * 60 * 60) return "soon";
  return "ok";
}


/* One dated timeline of everything the board knows happened, newest first.

   Two feeds, because neither is complete on its own. A card's `log` array is
   written by exactly one action — `log` — so a board where cards were added,
   moved, claimed and archived recorded nothing at all in it; that is what made
   the Activity view read as idle while the board was being worked on. The room
   messages carry every action, but only as far back as the room's history
   window reaches, and a card's log survives past it.

   `cards` is `/api/board`'s `board.cards`, `messages` is
   `/api/chat/messages?room=board`. Either may be missing; a view that has one
   feed should show that feed rather than nothing. */
export function boardTimeline(cards, messages) {
  var list = Array.isArray(cards) ? cards : [];
  var titles = Object.create(null);
  var rows = [];

  list.forEach(function (c) {
    if (!c) return;
    if (c.id) titles[c.id] = c.title || "";
    (c.log || []).forEach(function (e) {
      if (!e) return;
      rows.push({ ts: e.ts || 0, who: e.who || "", what: e.what || "", card: c.title || "", id: c.id || "", kind: "log" });
    });
  });

  (Array.isArray(messages) ? messages : []).forEach(function (m) {
    if (!m) return;
    var action = boardAction(m.text);
    if (!action) return;
    // A `log` action reaches us on both feeds. The card's copy is the one to
    // keep: it outlives the room's history window, and it reads as the note
    // itself rather than through boardActionLine's "noted: " prefix.
    if (action.action === "log") return;
    var what = boardActionLine(m.text);
    if (!what) return;
    var id = action.todo || "";
    rows.push({ ts: m.ts || 0, who: m.from || "", what: what, card: titles[id] || "", id: id, kind: "action" });
  });

  // Newest first: coming back to a board, the last thing that happened is the
  // thing you are looking for.
  rows.sort(function (a, b) { return (b.ts || 0) - (a.ts || 0); });
  return rows;
}

/* The parsed action behind a `@todo` line, or null. boardActionLine renders
   one; the timeline also needs the action name and the card it names. */
function boardAction(raw) {
  if (typeof raw !== "string" || raw.slice(0, 6) !== "@todo ") return null;
  try {
    var a = JSON.parse(raw.slice(6));
    return a && typeof a === "object" ? a : null;
  } catch (e) {
    return null;
  }
}
