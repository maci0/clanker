# ADR 0021 — REPL block-level markdown renders in-place in repl.zig

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0009 — REPL block-level markdown in the vaxis transcript](../rfcs/0009-repl-block-level-markdown-in-the-vaxis-transcript.md).

## Context

REPL renders markdown line-by-line; tables/blockquotes/nested lists remain plain, degrading readability. Drivers: Zig 0.16 only, no new dep, vaxis-native, preserve inline semantics, 30fps budget.
Options are detailed in RFC 0009 (A: in-place block parser, B: shared MdStream refactor, C: C markdown lib, D: status quo). See PRD 0005 for the REPL's widget mapping.

## Decision

Extend src/tui/repl.zig with a pure-Zig block parser that reuses appendInline/mdStyles and emits vaxis segments for tables, block quotes and nested lists; no change to MdStream, no new dependency.

> The RFC recommended: **Recommended option:** Adopt Option A — extend repl.zig with a pure-Zig block parser emitting vaxis segments

PRD 0005 tracks the remaining gaps; this ADR governs block-level markdown only.

## Consequences

Closes the Planned REPL gap with smallest scope; table alignment is hand-rolled and may need later polish. Easy to reverse: delete helpers and fall back to plain segments. Can later be extracted to shared md_block if a second consumer needs block markdown.

