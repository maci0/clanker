# PRD — Run Todo Checklists (private vs shared)

## Status

Shipped. Two layers, meant to be deliberately separate:

- **Private todos** — `todo_add` / `todo_claim` / `todo_close` / `todo_list`
  with no `room`. Routed host-side to the run's own in-memory list
  (`src/agent/private_todos.zig`, capped at 100 items). `Agent.run` attaches
  a fresh list for every top-level run and `subagent.runNested` supplies its
  own list for nested work. It is gone when that run ends.
- **Shared work** — the Kanban board (`docs/prds/0002-kanban-board.md`): cards,
  columns (`backlog`, `ready`, `doing`, `review`, `done` — five, not the
  three this doc originally said), claims, subtasks, cost, replicated to
  peers. `todo_*` **with** a `room` now hard-errors and points callers at
  the board instead of routing to a shared room list.

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
3. `todo_add`/`todo_claim`/`todo_close`/`todo_list` keep one vocabulary for
   private todos; shared durable work uses the board's own verbs, not a
   room-scoped variant of these four.

## Non-goals

- Promoting a private todo to a board card automatically. The agent does this
  explicitly with `board_add`.
- Private todo history after run end. Ephemerality is the feature.

## Design

**Routing on absence.** The `todo_*` tools share the chat module. Naming
`room` now unconditionally hard-errors (`src/sandbox/host.zig`: "room todo
lists are board cards now: use board_add, board_move, board_claim or
board_list."); the shared room-list path this doc originally described no
longer exists. Omitting `room` routes to `src/agent/private_todos.zig`.
`Agent.run` attaches a fresh list for every top-level run and removes it when
the run returns; `subagent.runNested` attaches a distinct list for its nested
run. A missing list is therefore a host wiring error, not a cue to pass
`room` (see Failure modes).

**Lifecycle.** Private: open → claimed → closed, per run, in memory, capped
at 100 items (error: "private todo list is full; close items instead of
adding more") and 512-char titles. Shared: backlog → ready → doing → review
→ done (five fixed columns), claims race and the first stands, cost accrues
per run against the card.

**Choosing the layer.** Rule of thumb in the tool catalog: a private todo is
your working plan, gone when the run ends; if another clanker should see or
claim it, it belongs on the board. This rule of thumb still holds even
though the room-scoped middle ground it used to also cover is gone.

## Failure modes

| Condition | Behaviour |
|---|---|
| `todo_*` with `room` | Hard error: room todo lists are gone, use `board_add`/`board_move`/`board_claim`/`board_list` |
| `todo_*` with no `room` and no list attached (caller never ran through `Agent.run`) | Hard error: host wiring error |
| `todo_add` past 100 items | "private todo list is full; close items instead of adding more" |
| `todo_add` with empty or >512-char title | Named error, no item added |
| `todo_claim`/`todo_close` with an unknown or shared-list id | "unknown todo id in your private list; call todo_list first" |
| Board claim race | First (ts, id) wins; the loser's answer shows who holds it (see `docs/prds/0002-kanban-board.md`) |

## Acceptance criteria

- [x] Omitting `room` never touches any room log.
- [x] Sub-agent private todos are invisible to the parent and to peers during
      the run; the list's final state is appended to the sub-agent's answer
      whenever the list is non-empty (in practice this covers, but is not
      conditioned on, hitting the iteration cap).
- [x] Board claims resolve races deterministically across peers.
- [x] A top-level run can use private todos.

## Open questions / future work

- Should a top-level run's final answer also summarise its leftover open
  private todos? The sub-agent path already does this via the answer
  appendix; top-level runs currently keep the checklist private until return.
