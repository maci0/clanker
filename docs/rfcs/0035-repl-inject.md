# RFC 0035 — How the REPL injects mid-stream like web steer

## Status

Decided — 2026-08-21. ADR 0047

## Overview

Kimi Code Ctrl-S injects composer text into the running turn. Web UI has POST /api/steer. The vaxis REPL has no equivalent. Decide the REPL inject path.

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

- [x] ADR: REPL inject is the steer queue, not a second channel — ADR 0047
- [x] PRD: /steer phase 1; Ctrl-S later if it does not fight XOFF — PRD 0058
      (shipped as the composer-as-steer-box, not a /steer command; see the
      PRD's Status for the drift)

## Recommendation

**Recommended option:** Adopt Option A: REPL /steer and Ctrl-S push onto the existing web steer queue

**Confidence:** 8/10

**Rationale.** One queue two surfaces. Abort-resubmit drops in-flight tools. Ctrl-S may fight XOFF so /steer is the reliable spelling.

## References

- Research: [Research — Kimi Code CLI feature inventory for clanker](../research/kimi-code-features.md) — read 2026-08-21. Its claims are unverified here until each is checked against the source it cites (the URL, repository, or file — the note itself is not the source).

