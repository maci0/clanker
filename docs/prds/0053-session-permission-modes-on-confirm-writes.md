# PRD — Session permission modes on confirm_writes

## Status

Draft — opened 2026-08-21. Name the source files that are the single source of truth, and the surfaces that expose it.

Shipped / In progress / Draft. Name the source files that are the single
source of truth, and the surface(s) that expose it (tools, HTTP, CLI, web
UI). If a claim below is known to be stale or contradicted by the code,
say so here up front rather than burying it in Design — a reader who only
reads Status should not walk away misinformed.

## Problem

confirm_writes is never/browser/always. There is no session-scoped allow after one yes, and no yolo that still confirms plan-exit.

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

1. Mode manual/yolo/auto.  2. Session allow-set from Approve for this session.  3. Sandbox always-denied never lifts.  4. /yolo /auto /permission.  5. Pattern rules later.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

What this deliberately does not do, and why leaving it out is a feature
(not just unstarted work). This is what stops the next reader from
"fixing" a deliberate omission.

## Design

**Mode.** manual (ask), yolo (skip regular confirms, still confirm plan-exit and secrets), auto (skip confirms and ask_user). Session allow-set records tool names after Approve for this session.

**Floor.** Descriptor sandbox, exec_allow, secret_dotenv never lift.

**Dependencies.** Hard: ADR 0042, agent.confirm_writes, confirm_fn. Soft: /permission TUI.

**Implementation.**

1. later: mode enum + allow-set + /yolo /auto. Files: src/config.zig, src/agent/loop.zig, src/tui/repl.zig.
2. later: [[permission.rules]] config. Files: src/config.zig.

## Non-goals
YOLO as sandbox off. Marketplace.

## Failure modes
| Condition | Behaviour |
|---|---|
| yolo + plan exit | still confirms |
| dotenv under auto | still refused |

## Acceptance criteria
1. [ ] /yolo skips regular confirms (Goal 1)
2. [ ] sandbox dotenv still refused (Goal 3)

## Open questions / future work
Pattern rules are phase 2.

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
