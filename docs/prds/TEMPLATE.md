# PRD — {{title}}

## Status

{{status}}

Draft / In progress / Partial / Implemented / Shipped. Name the source files that are the single
source of truth, and the surface(s) that expose it (tools, HTTP, CLI, web
UI). If a claim below is known to be stale or contradicted by the code,
say so here up front rather than burying it in Design — a reader who only
reads Status should not walk away misinformed.

## Problem

{{problem}}

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

{{goals}}

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

What this deliberately does not do, and why leaving it out is a feature
(not just unstarted work). This is what stops the next reader from
"fixing" a deliberate omission.

## Design

The mechanism, in the fewest sections that convey the real shape of the
thing. Prefer named sub-sections in bold (`**Thing.**`) over prose walls.
State *why* a non-obvious choice was made where it matters (e.g. "the guest
never touches state, so a misbehaving guest can't widen its reach") — the
why is what keeps a future editor from breaking an invariant they can't see.

If a table of ops/fields/endpoints exists in code, mirror it here exactly;
treat a mismatch between this table and the code as a bug in the PRD, not
a stylistic choice, and fix it the same day it's noticed.

For a **Draft** (or partially shipped) PRD, Design must also settle build
blockers and sequencing — do not leave "must decide before coding" items
only under Open questions:

- **Dependencies.** Other PRDs, ADRs, and existing code this rides on.
  Hard blockers first; soft/related after.
- **Implementation.** Numbered phases with concrete file paths (create /
  edit). Each phase should be independently checkable. Put "decide X"
  work in Design policy above, not as a phase that re-opens the decision.

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
