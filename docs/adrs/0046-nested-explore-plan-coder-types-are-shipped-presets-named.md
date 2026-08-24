# ADR 0046 — Nested explore/plan/coder types are shipped presets named by subagent_type

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0034 — How nested runs pick explore/plan/coder profiles](../rfcs/0034-nested-profiles.md).

## Context

Kimi ships explore (read-only), plan (no shell), coder (writes). ck_subagent is generic. RFC 0034 compared shipped presets, a host enum, parent-preset inherit, and status quo.

## Decision

Ship presets/explore.toml, plan.toml, coder.toml. subagent_type names one (default coder). Enforcement is tools_allow/tools_deny (ADR 0030), not prompt prose. Built-in nested types do not recurse.

> The RFC recommended: **Recommended option:** Adopt Option A: shipped presets explore/plan/coder, subagent_type names one


## Consequences

Explore is actually read-only. Honest downside: three presets must stay in sync with the catalog; a missing deny silently becomes coder.
