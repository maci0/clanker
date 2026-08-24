# RFC 0033 — How a goal queue sits beside the one active goal

## Status

Decided — 2026-08-21. ADR 0045

## Overview

Kimi Code /goal next queues upcoming objectives the agent does not see until the current goal completes. PRD 0035 is one loop. Decide the queue store and when the next goal starts.

## Options considered

Sources opened: kimi docs/en/guides/goals.md Queue upcoming goals (2026-08-21); PRD 0035 one active loop; ADR 0012 draft/persist/run are separate.

### Option A — per-session FIFO queue in the goal record, started only on complete

What it is: /goal next appends an objective the agent never sees. On complete (not blocked, paused, cancelled), the harness starts the head as a new goal loop the same way /goal does. Manager list/reorder/edit is phase 2.

How it would fit: state/goals.json queued[] or a per-session list; goal_loop.zig drain; REPL /goal next.

Pros: matches kimi; blocked does not auto-start the next (kimi's rule).

Cons: another list beside the board.

Cost to adopt: queue field + drain + slash. Cost to leave: drop the field.

Evidence: goals.md; PRD 0035.

### Option B — board cards in a Waiting column as the queue

What it is: reuse kanban.

Pros: no new store.

Cons: the agent would see board text; kimi's queue is hidden until start. ADR 0002 board is shared, this queue is private to the session.

### Option C — status quo

What it is: one goal.

Pros: PRD 0035 stays small.

Cons: operators wait and type /goal again.

### Option D — out of the box: clanker schedule a second goal

What it is: cron the next one.

Pros: ADR 0008 already fires.

Cons: wall-clock, not "when this goal completes".

## Implications by horizon

### Short term
- **If A:** /goal next queues; complete starts it.
- **If B:** cards leak to the agent.
- **If status quo:** one at a time.

### Medium term
- **If A:** manager UI.
- **If B:** board semantics muddy.
- **If status quo:** operators use the board anyway.

### Long term
- **If A:** session-scoped queue is a sibling of the durable goal record, not a third store.
- **If B:** waiting column means two things.
- **If status quo:** acceptable if goals stay rare.

## Next steps / action items

- [ ] ADR: queue starts only on complete, never on blocked
- [ ] PRD: phase 1 append+drain; phase 2 manager

## Recommendation

**Recommended option:** Adopt Option A: per-session FIFO queue, started only on complete

**Confidence:** 8/10

**Rationale.** Matches kimi blocked-does-not-start-next. Board cards would leak. Schedule is wall-clock.

## References

- Research: [Research — Kimi Code CLI feature inventory for clanker](../research/kimi-code-features.md) — read 2026-08-21. Its claims are unverified here until each is checked against the source it cites (the URL, repository, or file — the note itself is not the source).

