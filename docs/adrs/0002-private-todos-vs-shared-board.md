# ADR 0002 — Private run todos and the shared board are separate mechanisms

## Status

Accepted. See `docs/prds/run-todos.md` for the full design and its current
gaps (private todos are wired only for sub-agent runs, not top-level ones).

## Context

A run needs a scratch plan — "check the gate, then patch, then re-test" —
that no other instance should see and that must not survive the run.
Putting that on the shared board would flood the room with ephemera and let
peers claim another run's working notes. The opposite need also exists:
work that outlives a run and that other clankers should be able to pick up.
Conflating the two was the original `state/board.json` design (ADR 0001):
one file trying to be both a run's private plan and the durable shared
list, which is what made the board and a room's todo list disagree.

## Decision

Two layers, same four verb names (`todo_add`/`todo_claim`/`todo_close`/
`todo_list` for private; `board_*` for shared), disambiguated at the host by
whether a private list is attached to the run — not by a `room` parameter
callers pass (an earlier shape did that; room-scoped shared todo lists were
removed once the board covered that need, see `docs/prds/chatrooms.md` §
Known issues). Private todos live in memory only
(`src/agent/private_todos.zig`), capped, and discarded when the run ends.

## Consequences

A sub-agent's working notes never leak to a room or a peer, and the board
never fills with scratch plans nobody but the run itself cared about. The
cost, currently unresolved: only sub-agent runs get a private list wired up
(`subagent.runNested` attaches one); a top-level run has nowhere to put a
scratch plan and `todo_*` simply fails there. That gap is tracked as an open
question in `docs/prds/run-todos.md`, not treated as settled by this ADR —
this decision fixes which two mechanisms exist and how they're told apart,
not that every run currently has access to the private one.
