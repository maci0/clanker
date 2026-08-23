# PRD — Goal queue started only on complete

## Status

Draft — opened 2026-08-21. Name the source files that are the single source of truth, and the surfaces that expose it.

## Problem

PRD 0035 is one active goal. Operators who know the next job wait and type /goal again.

## Goals

1. /goal next appends a hidden objective.  2. Drain starts it only on complete.  3. Blocked/paused/cancelled do not drain.  4. Agent never sees the queue.  5. Manager later.

## Design

**Queue.** Per-session FIFO of upcoming objectives the agent does not see. /goal next appends. Drain starts the head only on complete, never blocked/paused/cancelled.

**Dependencies.** Hard: ADR 0045, PRD 0035, src/agent/goal_loop.zig. Soft: manager UI.

**Implementation.**
1. later: queued[] + /goal next + drain. Files: tools/zig/goal_store.zig, src/agent/goal_loop.zig, src/tui/repl.zig.
2. later: manager. Files: src/tui/repl.zig.

## Non-goals
Board Waiting column as the queue. Wall-clock schedule as the trigger.

## Failure modes
| Condition | Behaviour |
|---|---|
| blocked with a queue | next stays queued |
| empty queue | no-op |

## Acceptance criteria
1. [ ] /goal next appends (Goal 1)
2. [ ] complete starts it (Goal 2)
3. [ ] blocked does not (Goal 3)

## Open questions / future work
Manager is phase 2.
