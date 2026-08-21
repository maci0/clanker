# ADR 0047 — REPL mid-stream inject is the existing steer queue

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0035 — How the REPL injects mid-stream like web steer](../rfcs/0035-repl-inject.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Kimi Ctrl-S injects composer text into the running turn. Web has POST /api/steer. RFC 0035 compared reusing that queue, abort-and-resubmit, a second process, and status quo.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

REPL /steer and Ctrl-S push onto Agent.steer_fn, the same queue the web uses. /steer is the reliable spelling because Ctrl-S may be XOFF.

> The RFC recommended: **Recommended option:** Adopt Option A: REPL /steer and Ctrl-S push onto the existing web steer queue


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

One steer model. Honest downside: a binding that fights software flow control looks like a hung terminal.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
