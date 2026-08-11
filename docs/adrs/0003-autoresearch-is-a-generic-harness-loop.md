# ADR 0003 — Autoresearch is a generic harness loop

## Status

Accepted.

## Context

[karpathy/autoresearch](https://github.com/karpathy/autoresearch) is narrow: one file, one metric. Clanker has `src/improve/engine.zig`. Options: copy narrowly, extend improve-self, or generic sibling loop.

## Decision

Sibling `src/research/` loop shares `validatePath` idiom but own state/CLI/tool. Generic harness: any shell command, metric via substring or `metric.json`.

## Consequences

Reusable across domains; preserves anti-cheat. Deferred: parallel via swarm, web UI live ledger as dedicated view.
