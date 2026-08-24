# ADR 0047 — REPL mid-stream inject is the existing steer queue

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0035 — How the REPL injects mid-stream like web steer](../rfcs/0035-repl-inject.md).

## Context

Kimi Ctrl-S injects composer text into the running turn. Web has POST /api/steer. RFC 0035 compared reusing that queue, abort-and-resubmit, a second process, and status quo.

## Decision

REPL /steer and Ctrl-S push onto Agent.steer_fn, the same queue the web uses. /steer is the reliable spelling because Ctrl-S may be XOFF.

> The RFC recommended: **Recommended option:** Adopt Option A: REPL /steer and Ctrl-S push onto the existing web steer queue


## Consequences

One steer model. Honest downside: a binding that fights software flow control looks like a hung terminal.
