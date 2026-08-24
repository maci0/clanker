# ADR 0022 — REPL multi-line input via Shift+Enter (Enter still submits)

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0010 — REPL multi-line task input](../rfcs/0010-repl-multi-line-task-input.md).

## Context

Single-line vxfw.TextField forces multiline via paste folding; roadmap gap requires deliberate multiline composition.

## Decision

Bind Shift+Enter (and Alt+Enter fallback) to insert literal newline in composer; TextField stores newlines, submit joins with \n; Enter continues to submit.

> The RFC recommended: **Recommended option:** Adopt Option A — Shift+Enter inserts newline in composer, Enter still submits


## Consequences

Improves composition for paste-heavy tasks; hand-rolled multiline TextField state in repl.zig adds maintenance vs. modal (B). Reversible: remove handler and revert to single-line. Extract later if second consumer needs it.
