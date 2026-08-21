# RFC 0033 — How a goal queue sits beside the one active goal

## Status

Decided — 2026-08-21. ADR 0045

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Kimi Code /goal next queues upcoming objectives the agent does not see until the current goal completes. PRD 0035 is one loop. Decide the queue store and when the next goal starts.

**Decision to make.** One sentence, phrased as the question the reader must
answer — "which X do we adopt for Y", not "we should adopt X".

**Why now.** What forces the choice: a blocked implementation, a cost, a
failure, a deadline, a dependency that is going away.

**Drivers.** The constraints any acceptable option has to satisfy (language and
toolchain, sandbox model, dependency budget, licence, operational cost, who
maintains it). These are what the options are scored against below, so keep
them concrete enough to disqualify something.

**Out of scope.** What this RFC deliberately does not decide, so a reader does
not read a broader mandate into it.

## Current state

How the thing works today, including the workaround being used in place of a
decision. Name the files, tools, or config that would change. If the status quo
is viable, it belongs in the options below as a real candidate, not as a
strawman.

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

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** Matches kimi blocked-does-not-start-next. Board cards would leak. Schedule is wall-clock.

**Reversibility.** How hard it is to undo, and the point of no return (a
migrated data format, a public API, a dependency baked into the build).

## Open questions

Questions whose answers could change the recommendation, each with who or what
can answer it. Keep them here until they are answered; do not silently drop the
ones that turned out to be inconvenient.

## Next steps / action items

- [ ] What happens if this recommendation is accepted, in order.
- [ ] The experiment or spike that would settle an open question above.
- [ ] Who is being asked for comment, and by when.
- [ ] Write the ADR once the decision is made.

## References

- Research: [Research — Kimi Code CLI feature inventory for clanker](../research/kimi-code-features.md) — read 2026-08-21. Its claims are unverified here until each is checked against the source it cites (the URL, repository, or file — the note itself is not the source).


- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
