# ADR 0045 — A goal queue starts the next objective only when the current goal completes

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0033 — How a goal queue sits beside the one active goal](../rfcs/0033-goal-queue.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Kimi /goal next queues hidden upcoming work. PRD 0035 is one loop. RFC 0033 compared a FIFO on the goal record, board Waiting cards, schedule, and status quo.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Per-session FIFO of upcoming objectives the agent does not see. Drain into a new goal loop only on complete, never on blocked, paused, or cancelled.

> The RFC recommended: **Recommended option:** Adopt Option A: per-session FIFO queue, started only on complete


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Operators can line up work. Honest downside: another list beside the board; a complete-vs-blocked bug would start the next goal while the human still needs to talk.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
