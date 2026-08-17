# ADR 0029 — Tool-result pruning is deterministic head/marker/tail on the request copy

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0017 — Deterministic tool-result pruning (bounded head/marker/tail)](../rfcs/0017-deterministic-tool-result-pruning-bounded-head-marker-tail.md).

## Context

One oversized tool result dominates compaction; summarizing the whole window is costly when a trim suffices.

Options in RFC 0017: A bounded head/marker/tail, B always summarize, C status quo. PRD 0031 motivates cheap pruning before paid summarization.

## Decision

Prune only tool-role results over a threshold to head/marker/tail on a shallow request copy, driven by agent.tool_result_prune_bytes/head/tail, and skip the LLM summary when enough bytes are reclaimed.

> The RFC recommended: **Recommended option:** Adopt Option A — bounded head/marker/tail on a request copy before LLM summarization



## Consequences

Saves LLM cost for the common bulky-result case; head/tail is syntactic, not importance-aware. Reversible: remove pruner and its config.

