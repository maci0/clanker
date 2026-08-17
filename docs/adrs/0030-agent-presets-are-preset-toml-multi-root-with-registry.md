# ADR 0030 — Agent presets are preset.toml multi-root with registry filter

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0018 — Agent presets: named tool + persona bundles](../rfcs/0018-agent-presets-named-tool-persona-bundles.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Every session sees the same tools and prompt; need a named enforceable bundle per session without editing global config; Feynman role files are advisory only, DSH preset shape is product precedent

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Adopt Option A — preset.toml multi-root with registry filter (--preset on run/repl, /preset in REPL, filter over loaded Registry, persona append, research/full examples)

> The RFC recommended: **Recommended option:** Adopt Option A — preset.toml multi-root with registry filter


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Adds preset dirs + CLI surface; alternative advisory role files remain usable but not enforceable

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
