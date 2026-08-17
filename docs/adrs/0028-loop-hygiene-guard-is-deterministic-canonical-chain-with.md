# ADR 0028 — Loop-hygiene guard is deterministic canonical chain with advisory reminders

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0016 — Loop-hygiene guard: deterministic repeated-tool reminder](../rfcs/0016-loop-hygiene-guard-deterministic-repeated-tool-reminder.md).

## Context

Agent needs a cheap circuit-breaker for identical repeated tool calls distinct from priced LLM review.

Options in RFC 0016: A deterministic canonical chain, B advisor LLM, C status quo. PRD 0029 documents the shipped guard.

## Decision

Implement a pure canonical JSON-key-sorted chain in LoopGuard with configurable thresholds and excludes that injects an advisory reminder at [3,5,8] via Agent.executeCalls, never blocking a call.

> The RFC recommended: **Recommended option:** Adopt Option A — deterministic canonical chain with thresholds [3,5,8] and excludes (advisory-only)



## Consequences

Gives zero-cost hygiene; fuzzy cases deferred; adds a small config surface (thresholds/excludes) to maintain. Reversible: remove guard and its config keys.

