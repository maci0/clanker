// Vanilla, no bundler. Board card-action helpers extracted from app.js.
// Pure: no DOM, no el, no page state. Importable as ES module; also
// bridged onto window.ckBoard so classic app.js keeps working until it
// becomes a module itself.

export var BOARD_COLUMNS = { backlog: "Backlog", ready: "Ready", doing: "Doing", review: "Review", done: "Done" };

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

if (typeof window !== "undefined") window.ckBoard = { BOARD_COLUMNS: BOARD_COLUMNS, boardActionLine: boardActionLine };
