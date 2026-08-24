# ADR 0035 — Anthropic cache-cold is a timestamp compare at request time

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0023 — How clanker warns that Anthropic prompt cache has gone cold](../rfcs/0023-cache-cold.md).

## Context

Anthropic prompt cache expires after about five minutes idle. clanker already parsed cache_read_input_tokens and printed a cache segment after the turn, so an expensive miss was visible only after it was paid. RFC 0023 compared a stamp-and-warn helper, a dummy warmer, the status quo, and stats-after-the-fact.

## Decision

Stamp last successful cache-accounted completion per provider/model. Before the next request, if idle exceeds a TTL (default 300s), warn. After the response, if a hit was expected and cache_hit is 0, log an unexpected miss. No daemon, no dummy warmer (ADR 0008).

> The RFC recommended: **Recommended option:** Option A: stamp last success and warn when idle exceeds TTL; log unexpected misses


## Consequences

A pause over five minutes is named before the bill. The honest downside: 300s is Anthropic-specific and will be wrong if they change the window; a config override is a later phase. False warnings after a process restart (no stamp) are fail-open, not a hang. The helper must not switch on ProviderKind outside src/llm/providers/.
