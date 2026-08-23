# PRD — REPL block-level markdown: tables, block quotes, nested lists

## Status

Shipped — 2026-08-17. src/tui/repl.zig: block quotes/tables/nested+ordered lists via mdLineSegments; tests in repl.zig

Planned: sources `src/tui/repl.zig`, `src/tui/transcript.zig` (reference). Draft per checklist.

## Problem

The vaxis REPL transcript renders markdown line-by-line (headings, bold/italic, single bullet). Tables, block quotes and nested/ordered lists appear as plain text, unlike clanker run's richer MdStream, hurting readability of structured model output.

Constraint: Zig 0.16 only, vaxis-native, no new runtime dependency, must reuse `theme.zig`/`sanitize.zig`/`width.zig` and preserve line-level inline semantics.

## Goals

1. Block quotes (`>`, `>>` nesting) render with a dim left rule and styled inline content
2. Markdown tables (`| col |`) render with aligned columns and header styling
3. Nested/ordered lists render with correct indentation and nesting markers


## Non-goals

- No change to `MdStream` / `clanker run` rendering — its block handling already exceeds this scope.
- No C markdown lib (comrak/cmark) — would add build fragility for three constructs.
- No shared `md_block.zig` extraction in this slice — can be done later once block helpers stabilize (per ADR 0021).

## Design
**Dependencies.** PRD 0005 (REPL), ADR 0021 (in-place block parser), `src/tui/repl.zig:mdLineSegments/appendInline`, `src/tui/transcript.zig:MdStream` as reference.

**Design.** In-place block parser in `src/tui/repl.zig` reusing `appendInline`/`mdStyles`. Quote: leading `> ` stripped line-by-line, `▎ ` rule column in `quote` style. Table: contiguous `|...|` block parsed into cells, header bold, columns width-aligned, wrapping caps huge tables. Nested lists: indent depth → `  ` per level + `•`/`1.` marker, recurse into inline. No new dependency; ANSI MdStream untouched.

**Implementation.**

1. Add helpers `isTableBlock`, `parseTableRow`, `tableColWidths`, `isQuoteLine`, `listDepth`, `mdBlockSegments` and extend transcript draw to call them before `mdLineSegments` — `src/tui/repl.zig`.
2. Unit tests for quotes/tables/nested/ordered lists and graceful fallbacks — `src/tui/repl.zig` (test blocks).
3. `zig fmt` + `zig build test` + `zig build tools` green.

## Failure modes

| Condition | Behaviour |
|---|---|
| Not a table row (`|`) but contains pipes | Falls back to `mdLineSegments` (plain/inline) — no crash |
| Malformed table (unequal columns) | Render with available cells, no alignment panic |
| Nested quote `>>` | Double rule column, depth reflected |
| Huge table (100+ rows) | Capped width/rows before styling; no O(n^2) draw |
| Non-markdown text | Plain segments via `appendInline` |

## Acceptance criteria

- [x] Block quotes `> text` show a left rule (`▎`) and inline-styled content
- [x] Markdown tables `| a | b |` render with aligned columns and bold header
- [x] Nested lists (`  -`, `    -`) show depth indentation and correct bullet/number markers
- [x] Existing line-level markdown (headings/bold/italic/bullets) still passes its tests
- [x] `zig build test` + `zig build tools` green, `zig fmt` clean

## Known issues

- **(Fixed) `appendInline` treated `_` as an emphasis delimiter anywhere.**
  The `*`/`_` branch was shared, so the first `_` on a line paired with the
  next one and the span between them was emitted italic with both underscores
  dropped: `bridge_stream_buf` drew as `bridgestreambuf`, and `lineRows`
  measured a longer string than the draw produced. `src/tui/transcript.zig`'s
  `MdStream` — the renderer this PRD measures against — has no `_` branch at
  all, so the same reply read correctly under `clanker run` and mangled in the
  REPL. `_` now goes through `underscoreEmphasisEnd` (CommonMark's intraword
  rule); `*` is unchanged. Resolved in
  `docs/reports/bugs/2026-08-23-repl-markdown-eats-snake-case-underscores.md`.

## Open questions / future work

- Shared extraction to `md_block.zig` once second consumer needs block markdown (per ADR 0021).
- Max table width policy vs. terminal resize.
