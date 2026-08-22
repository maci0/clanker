# PRD — Anthropic cache-cold warning

## Status

In progress — phase 1 shipped 2026-08-21; phases 2 (turn_stats segment) and 3 (per-provider ttl_ms config) open. Decision: [ADR 0035](../adrs/0035-anthropic-cache-cold-is-a-timestamp-compare-at-request-time.md). RFC: [0023](../rfcs/0023-cache-cold.md). Source of truth: src/llm/cache_cold.zig plus stamp in src/llm/client.zig.

## Problem

A pause longer than Anthropic prompt-cache TTL silently pays a full prompt on the next Claude turn. Cache accounting exists after the fact but nothing warns before send.

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

1. A pure helper classifies cold vs warm given last success, now, and TTL.  2. Last success is stamped at the client choke point for cache-accounted completions.  3. A cold send is named on stderr/turn_stats before the request.  4. An unexpected miss (warm expected, cache_hit 0) is logged.  5. No daemon and no dummy warmer.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

A dummy cache warmer (ADR 0008). Switching on ProviderKind outside src/llm/providers/. Pinning prompt-cache prefixes (autolearn already advises that).

## Design

**Helper.** cacheCold(last_ok_ms, now_ms, ttl_ms) returns cold when last_ok is 0 or now-last_ok >= ttl. Default ttl 300_000. Pure, host-tested.

**Stamp.** After a completion whose usage has cache accounting, record last_ok_ms per provider/model in process memory (and optionally a line already going to token_stats). No daemon.

**Warn.** Before send, if cold, a diagnostic on stderr / turn_stats. After send, if we expected warm and cache_hit is 0, log unexpected miss.

**Dependencies.** Hard: ADR 0008, ADR 0035, src/llm/client.zig, src/tui/turn_stats.zig, anthropic usage parse. Soft: PRD 0005.

**Implementation.**

1. implement-now: helper + tests in src/llm/cache_cold.zig; stamp last_ok in client.zig; warn log. Files: src/llm/cache_cold.zig (create), src/llm/client.zig (edit), src/main.zig comptime import if needed.
2. later: turn_stats segment and REPL line. Files: src/tui/turn_stats.zig.
3. later: per-provider ttl_ms config. Files: src/config.zig.

## Failure modes

| Condition | Behaviour |
|---|---|
| No prior stamp (process start) | Treat as cold; warn once, fail-open |
| Provider reports no cache accounting | Do not stamp; no warning |
| Clock skew / now < last_ok | Treat as warm |
| Dummy warmer requested | Out of scope; refuse in Design |

## Acceptance criteria

1. [x] cacheCold(0, now, 300000) is cold; cacheCold(now-1000, now, 300000) is warm; cacheCold(now-300000, now, 300000) is cold (Goal 1)
2. [x] stamp(provider, model) stores last_ok for that pair; recordUsage calls afterUsage before the token_stats guard when usage has cache accounting (Goal 2)
3. [x] shouldWarn logs before send in chat and chatStream (Goal 3)
4. [x] unexpectedMiss is true when warm was expected and cache_hit is 0 (Goal 4)
5. [x] No new thread or schedule entry is added (Goal 5)

## Open questions / future work

Whether Anthropic's published TTL changes (retune the default). Per-provider ttl is phase 3, not a blocker.
