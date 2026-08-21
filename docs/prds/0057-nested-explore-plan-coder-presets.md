# PRD — Nested explore/plan/coder presets

## Status

Draft — opened 2026-08-21. Name the source files that are the single source of truth, and the surfaces that expose it.

Shipped / In progress / Draft. Name the source files that are the single
source of truth, and the surface(s) that expose it (tools, HTTP, CLI, web
UI). If a claim below is known to be stale or contradicted by the code,
say so here up front rather than burying it in Design — a reader who only
reads Status should not walk away misinformed.

## Problem

ck_subagent is one generic nested Agent. explore is a polite request the model can ignore by writing files.

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

1. Ship explore/plan/coder preset.toml.  2. subagent_type names one, default coder.  3. tools_deny is enforced.  4. Nested types do not recurse.  5. Tests refuse a write from explore.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

What this deliberately does not do, and why leaving it out is a feature
(not just unstarted work). This is what stops the next reader from
"fixing" a deliberate omission.

## Design

**Presets.** Ship presets/explore.toml (deny writes and exec), plan.toml (deny exec), coder.toml (current default). subagent_type names one. Nested types do not recurse.

**Dependencies.** Hard: ADR 0046, ADR 0030, tools/zig/subagent.zig.

**Implementation.**
1. later: three preset files + subagent_type. Files: presets/explore.toml, presets/plan.toml, presets/coder.toml, tools/zig/subagent.zig, src/agent/loop.zig.

## Non-goals
Host enum of types. Prompt-only explore.

## Failure modes
| Condition | Behaviour |
|---|---|
| explore calls edit_file | refused |
| unknown type | fail the tool call |

## Acceptance criteria
1. [ ] explore denies writes (Goal 3)
2. [ ] default type is coder (Goal 2)

## Open questions / future work
Recurse allowlist later.

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
