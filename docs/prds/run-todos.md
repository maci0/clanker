# PRD — Run Todo Checklists (private vs shared)

## Status

Shipped, but the "disambiguated by presence of `room`" framing below is now
half-true. Two layers, meant to be deliberately separate:

- **Private todos** — `todo_add` / `todo_claim` / `todo_close` / `todo_list`
  with no `room`. Routed host-side to the run's own in-memory list
  (`src/agent/private_todos.zig`, capped at 100 items). Gone when the run
  ends. **Only wired for sub-agent runs** (`subagent.runNested` attaches the
  list); a top-level run never gets one, so `todo_*` without `room` fails
  there too (see Design).
- **Shared work** — the Kanban board (`docs/prds/kanban-board.md`): cards,
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
3. The same four verb names on both layers, disambiguated by the presence of
   `room`, so the agent's habit transfers.

## Non-goals

- Promoting a private todo to a board card automatically. The agent does this
  explicitly with `board_add`.
- Private todo history after run end. Ephemerality is the feature.

## Design

**Routing on absence — narrower than "on absence".** The `todo_*` tools
share the chat module. Naming `room` now unconditionally hard-errors
(`src/sandbox/host.zig`: "room todo lists are board cards now: use
board_add, board_move, board_claim or board_list instead") — the shared
room-list path this doc originally described no longer exists. Omitting
`room` routes to `src/agent/private_todos.zig`, but **only if a private list
is attached**, which only happens for sub-agent runs launched via
`subagent.runNested`. A top-level run's `Agent.private_todos` is always
`null`; nothing in the top-level agent loop ever sets it. So a top-level
`todo_*` call with no `room` also fails today, with an error
("no room given, and private todo lists exist only inside sub-agent runs;
pass room to use a shared room list") that is itself wrong on both branches:
private lists aren't available at the top level, and passing `room` also
errors. **Net effect: `todo_*` is currently usable only from inside a
sub-agent run.** Sub-agent runs do get their own private list, not the
parent's.

**Lifecycle.** Private: open → claimed → closed, per run, in memory, capped
at 100 items (error: "private todo list is full; close items instead of
adding more") and 512-char titles. Shared: backlog → ready → doing → review
→ done (five fixed columns), claims race and the first stands, cost accrues
per run against the card.

**Choosing the layer.** Rule of thumb in the tool catalog: a private todo is
your working plan, gone when the run ends; if another clanker should see or
claim it, it belongs on the board. This rule of thumb still holds even
though the room-scoped middle ground it used to also cover is gone.

## Known issues

- **Top-level runs can't use `todo_*` at all.** No code path ever attaches a
  private list to a top-level `Agent` (only `subagent.zig` does, after
  calling `runNested`). Every `todo_*` call outside a sub-agent run fails
  regardless of whether `room` is given.
- **The failure error recommends a dead option.** `src/sandbox/host.zig`'s
  message for "no private list attached" tells the caller to pass `room`
  instead — but passing `room` unconditionally errors too (room-scoped todos
  were replaced by the board). Fix the message regardless of how the
  top-level-support open question below resolves.

## Acceptance criteria

- [x] Omitting `room` never touches any room log.
- [x] Sub-agent private todos are invisible to the parent and to peers during
      the run; the list's final state is appended to the sub-agent's answer
      whenever the list is non-empty (in practice this covers, but is not
      conditioned on, hitting the iteration cap).
- [x] Board claims resolve races deterministically across peers.
- [ ] A top-level run can use private todos. Not true today — see Known
      issues.

## Open questions

- Should a top-level (non-sub-agent) run be able to use private todos at
  all, or is "private todos" meant to stay a sub-agent-only concept with
  top-level work always going straight to the board? Right now it's neither
  decision on purpose — it's an unwired path plus a stale error message
  (Known issues). This needs an explicit answer, since the current state is
  silently broken rather than deliberately scoped.
- Should a top-level run's final answer also summarise its leftover open
  private todos, once/if the above is resolved? The sub-agent path already
  does this via the answer appendix; the top-level path has no list to
  summarise.
