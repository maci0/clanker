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

export function dueState(card) {
  if (!card.deadline) return "";
  var left = card.deadline - Math.floor(Date.now() / 1000);
  if (left < 0) return "late";
  if (left < 2 * 24 * 60 * 60) return "soon";
  return "ok";
}
