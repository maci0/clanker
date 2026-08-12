// Vanilla, no bundler. The run's private todo checklist, live in the turn
// card (webui PRD 0006 phase 3.3).
//
// Scope, deliberately: this is the *private* per-run list
// (src/agent/private_todos.zig) — the run's own working plan, in memory,
// discarded when the run returns. Shared durable work is the Kanban board and
// already has a view of its own (features/board.js); room-scoped todo lists no
// longer exist at all (docs/adrs/0002-private-todos-vs-shared-board.md). So
// there is no fetch and no polling here: the list arrives as `todos` control
// events on the run's own /api/run stream and dies with the turn that carries
// it, exactly like the list it mirrors.
//
// Reactivity is the house one — a per-turn state() signal, bind()ed to the
// panel. Per turn rather than per module because a finished turn must keep
// showing the checklist that run ended with, not the next run's.

import { T, state, bind } from "../core/ui.js";

// A title is capped at 512 chars server-side and the list at 100 items; both
// are honest numbers to render, but a pathological run should not be able to
// push 50 KB of text into one turn card either. Clip for display only.
export var max_title_chars = 240;
export var max_items = 100;

/// Normalizes whatever came down the stream into the shape the panel renders.
/// Pure, and defensive: a malformed event must not take the turn down.
export function normalizeTodos(raw) {
  if (!raw || !raw.length) return [];
  var out = [];
  for (var i = 0; i < raw.length && out.length < max_items; i++) {
    var it = raw[i];
    if (!it || typeof it !== "object") continue;
    var title = it.title == null ? "" : String(it.title);
    if (title.length > max_title_chars) title = title.slice(0, max_title_chars) + "…";
    var status = it.status === "closed" || it.status === "claimed" ? it.status : "open";
    out.push({ id: it.todo == null ? "" : String(it.todo), title: title, status: status });
  }
  return out;
}

/// "2/5 done", or "" for an empty list. Pure, so the count shown and the count
/// tested are the same function.
export function todoSummary(todos) {
  if (!todos || !todos.length) return "";
  var closed = 0;
  for (var i = 0; i < todos.length; i++) if (todos[i].status === "closed") closed++;
  return closed + "/" + todos.length + " done";
}

function todoRow(item) {
  // No glyph standing in for state: the box is drawn in CSS off data-status
  // and marked aria-hidden, and the state is also spelled out in words beside
  // it, so a screen reader and a stylesheet-less page both still read it.
  return T.li(
    { class: "todo-item", "data-status": item.status },
    T.span({ class: "todo-box", "aria-hidden": "true" }),
    T.span({ class: "todo-title" }, item.title),
    T.span({ class: "todo-state" }, item.status === "closed" ? "done" : item.status)
  );
}

function panelContent(todos) {
  if (!todos || !todos.length) return null;
  return [
    T.div(
      { class: "todos-head" },
      T.span({ class: "todos-label" }, "Checklist"),
      T.span({ class: "meta" }, todoSummary(todos))
    ),
    T.ul({ class: "todo-list" }, todos.map(todoRow))
  ];
}

/// Renders (or updates) this turn's checklist panel. Called for every `todos`
/// control event on the run's stream; the panel is created once and the signal
/// carries every later revision, so a 20-step plan does not rebuild the turn.
export function renderTurnTodos(turn, rawTodos) {
  if (!turn || !turn.answer) return null;
  if (!turn.todosPanel) {
    turn.todosState = state([]);
    var panel = T.div({ class: "turn-todos", "aria-live": "polite" });
    bind(panel, turn.todosState, panelContent);
    turn.todosPanel = panel;
    // Above the answer, below the tool chips: the checklist is context for
    // the answer being written, not part of it.
    if (turn.answer.parentNode) turn.answer.parentNode.insertBefore(panel, turn.answer);
  }
  turn.todosState.val = normalizeTodos(rawTodos);
  return turn.todosPanel;
}
