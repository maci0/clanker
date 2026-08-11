# PRD — Run Todo Checklists (private vs shared)

## Status

Shipped. Two layers, deliberately separate:

- **Private todos** — `todo_add` / `todo_claim` / `todo_close` / `todo_list`
  with no `room`. Routed host-side to the run's own in-memory list
  (`src/agent/private_todos.zig`). Gone when the run ends.
- **Shared work** — the Kanban board (`docs/prd-kanban-board.md`): cards,
  columns, claims, subtasks, cost, replicated to peers.

## Problem

A run needs a scratch plan — "check the gate, then patch, then re-test" —
that no other instance should see and that must not survive the run. Putting
that on the shared board would flood the room with ephemera and let peers
claim another run's working notes. The opposite need also exists: work that
outlives a run and that other clankers should pick up. One mechanism cannot
be both; conflating them was the original `state/board.json` mistake.

## Goals

1. A private checklist scoped to a single run (or sub-agent run), zero
   persistence, zero fan-out.
2. A shared, replicated board for durable work, with claims, subtasks,
   deadlines, and cost accrual.
3. The same four verb names on both layers, disambiguated by the presence of
   `room`, so the agent's habit transfers.

## Non-goals

- Promoting a private todo to a board card automatically. The agent does this
  explicitly with `board_add`.
- Private todo history after run end. Ephemerality is the feature.

## Design

**Routing on absence.** The `todo_*` tools share the chat module; when the
request omits `room`, the host routes to `src/agent/private_todos.zig`
instead of a room. Sub-agent runs get their own private list, not the
parent's.

**Lifecycle.** Private: open → claimed → closed, per run, in memory. Shared:
backlog → doing → done (fixed columns), claims race and the first stands,
cost accrues per run against the card.

**Choosing the layer.** Rule of thumb in the tool catalog: a private todo is
your working plan, gone when the run ends; if another clanker should see or
claim it, it belongs on the board.

## Acceptance criteria

- [x] Omitting `room` never touches any room log.
- [x] Sub-agent private todos are invisible to the parent and to peers during
      the run; the list's final state is appended to the sub-agent's answer
      so the parent sees progress even when the run hits its iteration cap.
- [x] Board claims resolve races deterministically across peers.

## Open questions

- Should a top-level run's final answer also summarise its leftover open
  private todos? The sub-agent path already does this via the answer
  appendix; the top-level path discards them.
