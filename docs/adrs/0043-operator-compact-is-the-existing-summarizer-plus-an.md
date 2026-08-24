# ADR 0043 — Operator /compact is the existing summarizer plus an optional hint

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0031 — How operator-triggered compact takes a hint](../rfcs/0031-compact-hint.md).

## Context

Kimi /compact [instruction] compresses now. Clanker compact is automatic. RFC 0031 compared hint-on-existing-summarizer, trigger-only, a normal turn, and status quo.

## Decision

Add /compact [hint]. The hint is operator text appended to the existing compact prompt. History handling stays the current compact path.

> The RFC recommended: **Recommended option:** Adopt Option A: /compact [hint] calls the existing summarizer with an extra instruction


## Consequences

Operators can force and steer compact. Honest downside: compactMessages still rewrites the in-memory list (existing exception to append-only).
