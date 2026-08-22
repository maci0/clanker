# PRD — Operator /compact with optional hint

## Status

In progress — TUI half shipped 2026-08-21 (/compact + compact_hint through tools/zig/compact_hint.zig into the summarizer prompt); web UI Compact hint field open. Source of truth: src/tui/repl.zig, src/agent/loop.zig, tools/zig/compact_hint.zig. Decision: [ADR 0043](../adrs/0043-operator-compact-is-the-existing-summarizer-plus-an.md). RFC: [0031](../rfcs/0031-compact-hint.md).

Shipped / In progress / Draft. Name the source files that are the single
source of truth, and the surface(s) that expose it (tools, HTTP, CLI, web
UI). If a claim below is known to be stale or contradicted by the code,
say so here up front rather than burying it in Design — a reader who only
reads Status should not walk away misinformed.

## Problem

Compact is automatic. Operators cannot force it or tell the summarizer what to keep.

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

1. /compact [hint] exists.  2. Hint is operator text on the existing summarizer prompt.  3. Idle-only.  4. Tests concat the hint.  5. Web button later.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

What this deliberately does not do, and why leaving it out is a feature
(not just unstarted work). This is what stops the next reader from
"fixing" a deliberate omission.

## Design

**Command.** /compact [hint] is idle-only. Empty hint means trigger the existing summarizer as-is. A hint is operator text appended to the compact prompt, never retrieved knowledge.

**Path.** Same maybeCompactMessages / compactMessages already used automatically. No second summarizer.

**Dependencies.** Hard: ADR 0043, src/agent/loop.zig maybeCompactMessages, src/tui/repl.zig command_registry. Soft: web Compact button.

**Implementation.**

1. implement-now: /compact plus hint concat helper + tests. Files: src/tui/repl.zig, src/agent/loop.zig (hint field), a tiny host-tested concat if the prompt lives in a helper.
2. later: web UI Compact with hint field. Files: ui/app.

## Non-goals

A new compact algorithm. Rewriting already-sent provider prefix (append-only rule stays).

## Failure modes

| Condition | Behaviour |
|---|---|
| /compact while streaming | refused, idle-only |
| empty session | no-op with a notice |
| summarizer fails | existing extractive fallback |

## Acceptance criteria

1. [x] /compact exists in command_registry (Goal 1)
2. [x] a hint appears in the summarizer prompt (Goal 2)
3. [x] streaming refuses it (Goal 3)
4. [x] tests drive the concat, not a copy (Goal 4)

## Open questions / future work

Web button is phase 2.

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
