# ADR 0047 — REPL mid-stream inject is the existing steer queue

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0035 — How the REPL injects mid-stream like web steer](../rfcs/0035-repl-inject.md). Shipped differently from the RFC wording: no `/steer` command and no Ctrl-S binding exist, so the XOFF concern below never arose. See [PRD 0058 — REPL mid-stream inject via steer](../prds/0058-repl-mid-stream-inject-via-steer.md) (Shipped 2026-08-22).

## Context

Kimi Ctrl-S injects composer text into the running turn. Web has POST /api/steer. RFC 0035 compared reusing that queue, abort-and-resubmit, a second process, and status quo.

## Decision

While a turn is running the REPL composer is the steer box: Enter on the composer runs the typed line through `steerWhileRunning`, which pushes it onto `bridge_steer` and drains into `Agent.steer_fn` — the same queue the web uses. No `/steer` command and no Ctrl-S binding ship, so nothing fights software flow control.

> The RFC recommended: **Recommended option:** Adopt Option A: REPL /steer and Ctrl-S push onto the existing web steer queue


## Consequences

One steer model. The composer's Enter does two jobs, so the inline slash preview and the steer notice have to be distinguishable. The XOFF cost the record predicted disappears with the binding.
