# RFC 0031 — How operator-triggered compact takes a hint

## Status

Decided — 2026-08-21. ADR 0043

## Overview

Kimi Code /compact [instruction] compresses now and can tell the summarizer what to keep. Clanker compact is automatic with no slash command. Decide the operator trigger and how a hint reaches the summarizer.

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

**Rationale.** The hint is the advertised value. Trigger-only is a subset. A new task does not drop history.

## References

- Research: [Research — Kimi Code CLI feature inventory for clanker](../research/kimi-code-features.md) — read 2026-08-21. Its claims are unverified here until each is checked against the source it cites (the URL, repository, or file — the note itself is not the source).

