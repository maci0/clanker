# ADR 0022 — REPL multi-line input via Shift+Enter (Enter still submits)

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0010 — REPL multi-line task input](../rfcs/0010-repl-multi-line-task-input.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Single-line vxfw.TextField forces multiline via paste folding; roadmap gap requires deliberate multiline composition.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Bind Shift+Enter (and Alt+Enter fallback) to insert literal newline in composer; TextField stores newlines, submit joins with \n; Enter continues to submit.

> The RFC recommended: **Recommended option:** Adopt Option A — Shift+Enter inserts newline in composer, Enter still submits


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Improves composition for paste-heavy tasks; hand-rolled multiline TextField state in repl.zig adds maintenance vs. modal (B). Reversible: remove handler and revert to single-line. Extract later if second consumer needs it.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
