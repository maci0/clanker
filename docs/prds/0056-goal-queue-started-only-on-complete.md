# PRD — Goal queue started only on complete

## Status

Draft — opened 2026-08-21. Name the source files that are the single source of truth, and the surfaces that expose it.

Shipped / In progress / Draft. Name the source files that are the single
source of truth, and the surface(s) that expose it (tools, HTTP, CLI, web
UI). If a claim below is known to be stale or contradicted by the code,
say so here up front rather than burying it in Design — a reader who only
reads Status should not walk away misinformed.

## Problem

PRD 0035 is one active goal. Operators who know the next job wait and type /goal again.

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

1. /goal next appends a hidden objective.  2. Drain starts it only on complete.  3. Blocked/paused/cancelled do not drain.  4. Agent never sees the queue.  5. Manager later.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

What this deliberately does not do, and why leaving it out is a feature
(not just unstarted work). This is what stops the next reader from
"fixing" a deliberate omission.

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

## Known issues

Only needed when verification against code turned up real drift between
what was designed/promised (in this doc, in a manifest, in a code comment)
and what the code actually does. Omit this section entirely for a PRD with
no known drift — an empty "Known issues: none" is noise. Each entry: what
was promised, what actually happens, and where the fix belongs (file, not
just "somewhere").

## Failure modes

A table: condition -> behaviour. Every "what happens when X goes wrong"
answer a caller would otherwise have to read the source to find out. Mark
a row as a known bug (cross-reference Known issues) rather than describing
buggy behavior as if it were the design.

## Acceptance criteria

Checkboxes, each traceable to a Goal. Use `[ ]` honestly for anything not
currently true — an unchecked box that names the gap is more useful than a
checked box that's aspirational. Re-verify this section, not just Design,
whenever the code changes underneath a shipped PRD.

## Open questions / future work

Real unresolved decisions, each phrased so a reader unfamiliar with the
history can tell what's actually being asked and why it's still open
(what would resolving it cost or break?). Distinguish a genuine open
design question from a plain bug that just hasn't been fixed yet — a bug
belongs in Known issues, not here, even if fixing it is future work.

Do not park build blockers here. If implementation cannot start until a
choice is made, make the choice in Design (and say why), then leave only
follow-on / optional refinements in this section.
