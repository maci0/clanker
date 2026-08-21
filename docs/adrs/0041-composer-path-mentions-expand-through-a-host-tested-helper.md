# ADR 0041 — Composer @path mentions expand through a host-tested helper into the saved user message

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0029 — How composer @file mentions inject path contents](../rfcs/0029-file-mentions.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Kimi Code loads @path in the composer. Clanker has no expander. RFC 0029 compared inlining bytes, forging a tool result, /attach-for-text, and status quo.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Inline whitespace-bounded @rel/path tokens via a host-tested helper into the saved user message. Refuse secret_dotenv and out-of-prefix paths. Cap bytes with a truncated notice.

> The RFC recommended: **Recommended option:** Adopt Option A: host-tested expander inlines fenced file bytes into the saved user message


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Operators stop pasting files. Honest downside: a large mention still costs tokens; a cap that is too low looks like a truncated file. Email addresses must not expand.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
