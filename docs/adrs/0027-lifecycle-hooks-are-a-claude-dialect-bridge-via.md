# ADR 0027 — Lifecycle hooks are a Claude-dialect bridge via execUnderPolicy

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0015 — Lifecycle hooks: Claude Code hooks.json bridge](../rfcs/0015-lifecycle-hooks-claude-code-hooks-json-bridge.md).

## Context

Users need a hooks.json bridge for policy scripts at PreToolUse/PostToolUse/UserPromptSubmit/Stop/SessionStart without duplicating confirm/plan gates.

Options in RFC 0015: A Claude bridge with neutral core, B confirm/plan only, C status quo. ROADMAP Planned (Kimi harness parity) motivates a hooks.json bridge.

## Decision

Clanker runs Claude-shaped hooks.json through a dialect-neutral core (matcher/exit-code/JSON-stdout merge most-restrictively) at five points in Agent, via host.execUnderPolicy with filtered env and timeouts, gated by [hooks] enabled.

> The RFC recommended: **Recommended option:** Adopt Option A — Claude-dialect bridge with dialect-neutral core (5 points, matcher/exit-code/JSON decode, most-restrictive merge)



## Consequences

Hooks add deterministic policy without rewriting per-tool logic; wire adds five loop sites to maintain. Reversible: drop the hook calls and the hooks module.

