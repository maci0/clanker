# ADR 0043 — Operator /compact is the existing summarizer plus an optional hint

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0031 — How operator-triggered compact takes a hint](../rfcs/0031-compact-hint.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Kimi /compact [instruction] compresses now. Clanker compact is automatic. RFC 0031 compared hint-on-existing-summarizer, trigger-only, a normal turn, and status quo.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Add /compact [hint]. The hint is operator text appended to the existing compact prompt. History handling stays the current compact path.

> The RFC recommended: **Recommended option:** Adopt Option A: /compact [hint] calls the existing summarizer with an extra instruction


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Operators can force and steer compact. Honest downside: compactMessages still rewrites the in-memory list (existing exception to append-only).

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
