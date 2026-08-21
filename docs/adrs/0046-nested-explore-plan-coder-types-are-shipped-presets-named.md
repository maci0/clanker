# ADR 0046 — Nested explore/plan/coder types are shipped presets named by subagent_type

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0034 — How nested runs pick explore/plan/coder profiles](../rfcs/0034-nested-profiles.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Kimi ships explore (read-only), plan (no shell), coder (writes). ck_subagent is generic. RFC 0034 compared shipped presets, a host enum, parent-preset inherit, and status quo.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Ship presets/explore.toml, plan.toml, coder.toml. subagent_type names one (default coder). Enforcement is tools_allow/tools_deny (ADR 0030), not prompt prose. Built-in nested types do not recurse.

> The RFC recommended: **Recommended option:** Adopt Option A: shipped presets explore/plan/coder, subagent_type names one


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Explore is actually read-only. Honest downside: three presets must stay in sync with the catalog; a missing deny silently becomes coder.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
