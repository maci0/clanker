# RFC 0035 — How the REPL injects mid-stream like web steer

## Status

Decided — 2026-08-21. ADR 0047

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Kimi Code Ctrl-S injects composer text into the running turn. Web UI has POST /api/steer. The vaxis REPL has no equivalent. Decide the REPL inject path.

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

Sources opened: kimi docs/en/guides/interaction.md During streaming output Ctrl-S (2026-08-21); PRD 0006 8.6 POST /api/steer; src/tui/repl.zig (no inject while running).

### Option A — REPL Ctrl-S / a /steer command pushes onto the existing steer queue

What it is: the same Agent.steer_fn the web uses. While a turn runs, Ctrl-S (or /steer text) queues composer text as the next user interjection. Idle, it is a no-op with a hint.

How it would fit: repl.zig key handler; reuse Agent.steer_fn. No new protocol.

Pros: one queue, two surfaces.

Cons: vaxis keybinding must not steal Ctrl-S from the terminal's XOFF if the operator uses software flow control; /steer as the reliable spelling.

Cost to adopt: key + command + tests that the queue is the web one. Cost to leave: drop the binding.

Evidence: PRD 0006 8.6; interaction.md Ctrl-S.

### Option B — abort the turn and resubmit with the extra text

What it is: stop_flag then a new task.

Pros: no queue.

Cons: loses in-flight tool work; not kimi's inject.

### Option C — status quo

What it is: wait, or switch to the web UI.

Pros: zero code.

Cons: REPL cannot steer.

### Option D — out of the box: type in another clanker run --session

What it is: a second process.

Pros: exists.

Cons: not mid-turn, and concurrent sessions have a runbook for a reason.

## Implications by horizon

### Short term
- **If A:** REPL /steer and Ctrl-S share web's queue.
- **If B:** abort-resubmit.
- **If status quo:** web-only steer.

### Medium term
- **If A:** one steer mental model.
- **If B:** operators learn two cancel stories.
- **If status quo:** REPL stays watch-only mid-turn.

### Long term
- **If A:** Ctrl-S is the kimi key; /steer is the one that always works.
- **If B:** inject never exists.
- **If status quo:** acceptable if most steering is web.

## Next steps / action items

- [ ] ADR: REPL inject is the steer queue, not a second channel
- [ ] PRD: /steer phase 1; Ctrl-S later if it does not fight XOFF

## Recommendation

**Recommended option:** Adopt Option A: REPL /steer and Ctrl-S push onto the existing web steer queue

**Confidence:** 8/10

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** One queue two surfaces. Abort-resubmit drops in-flight tools. Ctrl-S may fight XOFF so /steer is the reliable spelling.

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
