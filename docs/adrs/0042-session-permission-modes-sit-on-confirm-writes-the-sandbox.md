# ADR 0042 — Session permission modes sit on confirm_writes; the sandbox always-denied tier never lifts

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0030 — How session permission modes sit on confirm_writes](../rfcs/0030-permission-modes.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Kimi has manual/yolo/auto and approve-for-this-session. Clanker has confirm_writes never|browser|always. RFC 0030 compared a mode enum plus allow-set, aliasing onto confirm_writes, hooks, and status quo.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Add a session mode (manual/yolo/auto) and a session allow-set on top of confirm_writes. Yolo skips regular confirms but not plan-exit or secrets. Auto also skips ask_user. Descriptor sandbox and dotenv refusal never lift.

> The RFC recommended: **Recommended option:** Adopt Option A: session mode enum on top of confirm_writes, plus a session allow-set


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Attended and unattended sessions get kimi-shaped names. Honest downside: two knobs (confirm_writes and mode) need a precedence table or operators will think /yolo disables the sandbox.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
