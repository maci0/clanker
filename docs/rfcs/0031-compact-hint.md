# RFC 0031 — How operator-triggered compact takes a hint

## Status

Decided — 2026-08-21. ADR 0043

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Kimi Code /compact [instruction] compresses now and can tell the summarizer what to keep. Clanker compact is automatic with no slash command. Decide the operator trigger and how a hint reaches the summarizer.

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

Sources opened: kimi docs/en/guides/sessions.md Context compression (2026-08-21); src/agent/loop.zig maybeCompactMessages; src/tui/repl.zig command_registry (no /compact).

### Option A — /compact [hint] calls the existing summarizer with an extra instruction

What it is: slash command, idle-only, optional hint string appended to the compact prompt. Saved session keeps the summary the way auto-compact does (append-only: summary message, not a rewrite of sent prefix). Hint is operator text, not retrieved.

How it would fit: command_registry action compact; Agent.compact_hint for one shot; maybeCompactMessages already in loop.zig.

Pros: reuses the summarizer; hint is one string.

Cons: compactMessages still rewrites in-memory list (existing exception).

Cost to adopt: slash command + hint field + tests on the prompt concat. Cost to leave: drop the command.

Evidence: sessions.md; loop.zig maybeCompactMessages.

### Option B — /compact only triggers, no hint

What it is: operator button for the auto path.

Pros: smaller.

Cons: kimi's advertised value is the hint ("Keep the migrations").

### Option C — status quo

What it is: automatic compact only.

Pros: no command.

Cons: cannot force a compact or steer it.

### Option D — out of the box: clanker run a "summarize keeping X" task

What it is: an ordinary turn.

Pros: zero code.

Cons: burns a turn and does not actually drop history.

## Implications by horizon

### Short term
- **If A:** /compact hint works in REPL.
- **If B:** trigger only.
- **If status quo:** wait for the threshold.

### Medium term
- **If A:** web UI Compact button can pass the same hint.
- **If B:** still no steer.
- **If status quo:** operators /new instead.

### Long term
- **If A:** hint is a first-class compact input.
- **If B:** missing the kimi shape.
- **If status quo:** auto remains enough for some.

## Next steps / action items

- [ ] ADR: /compact is the existing summarizer plus an operator hint
- [ ] PRD: REPL command phase 1; web later

## Recommendation

**Recommended option:** Adopt Option A: /compact [hint] calls the existing summarizer with an extra instruction

**Confidence:** 8/10

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** The hint is the advertised value. Trigger-only is a subset. A new task does not drop history.

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
