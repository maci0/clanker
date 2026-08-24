# ADR 0030 — Agent presets are preset.toml multi-root with registry filter

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0018 — Agent presets: named tool + persona bundles](../rfcs/0018-agent-presets-named-tool-persona-bundles.md).

## Context

Every session sees the same tools and prompt; need a named enforceable bundle per session without editing global config; Feynman role files are advisory only, DSH preset shape is product precedent

## Decision

Adopt Option A — preset.toml multi-root with registry filter (--preset on run/repl, /preset in REPL, filter over loaded Registry, persona append, research/full examples)

> The RFC recommended: **Recommended option:** Adopt Option A — preset.toml multi-root with registry filter


## Consequences

Adds preset dirs + CLI surface; alternative advisory role files remain usable but not enforceable
