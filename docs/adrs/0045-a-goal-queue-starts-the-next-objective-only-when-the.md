# ADR 0045 — A goal queue starts the next objective only when the current goal completes

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0033 — How a goal queue sits beside the one active goal](../rfcs/0033-goal-queue.md).

## Context

Kimi /goal next queues hidden upcoming work. PRD 0035 is one loop. RFC 0033 compared a FIFO on the goal record, board Waiting cards, schedule, and status quo.

## Decision

Per-session FIFO of upcoming objectives the agent does not see. Drain into a new goal loop only on complete, never on blocked, paused, or cancelled.

> The RFC recommended: **Recommended option:** Adopt Option A: per-session FIFO queue, started only on complete


## Consequences

Operators can line up work. Honest downside: another list beside the board; a complete-vs-blocked bug would start the next goal while the human still needs to talk.
