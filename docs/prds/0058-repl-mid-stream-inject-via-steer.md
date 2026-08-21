# PRD — REPL mid-stream inject via steer

## Status

Draft — opened 2026-08-21. Name the source files that are the single source of truth, and the surfaces that expose it.

Shipped / In progress / Draft. Name the source files that are the single
source of truth, and the surface(s) that expose it (tools, HTTP, CLI, web
UI). If a claim below is known to be stale or contradicted by the code,
say so here up front rather than burying it in Design — a reader who only
reads Status should not walk away misinformed.

## Problem

Web can POST /api/steer. The vaxis REPL cannot inject into a running turn.

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

1. /steer queues onto Agent.steer_fn.  2. Ctrl-S does the same if it does not fight XOFF.  3. Idle is a hint not a send.  4. Same queue as web.  5. Tests the queue, not a second channel.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

What this deliberately does not do, and why leaving it out is a feature
(not just unstarted work). This is what stops the next reader from
"fixing" a deliberate omission.

## Design

**Queue.** /steer and Ctrl-S push onto Agent.steer_fn, the same poll web POST /api/steer uses. Idle /steer is a hint, not a send. /steer is the reliable spelling; Ctrl-S is skipped if it is XOFF.

**Dependencies.** Hard: ADR 0047, PRD 0006 8.6, src/tui/repl.zig tuiSteerPoll.

**Implementation.**
1. later: /steer command. Files: src/tui/repl.zig.
2. later: Ctrl-S if terminals allow. Files: src/tui/repl.zig.

## Non-goals
Abort-and-resubmit. A second steer channel.

## Failure modes
| Condition | Behaviour |
|---|---|
| /steer while idle | notice, no send |
| Ctrl-S is XOFF | /steer still works |

## Acceptance criteria
1. [ ] /steer uses steer_fn (Goal 1, Goal 4)
2. [ ] idle is a hint (Goal 3)

## Open questions / future work
Ctrl-S vs XOFF is phase 2.

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
