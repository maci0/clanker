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
- [~] Markdown tables `| a | b |` render as cells joined by ` │ ` (row-local; column alignment and header emphasis are still open — see Known issues)
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

- **(Fixed) A nested ordered list indented twice per level.** Goal 3 asks for
  "correct indentation"; the ordered branch of `mdLineSegments` emitted the
  source indent *and* a normalised two-columns-per-level indent, where the
  bullet branch beside it emits one or the other. `  1. x` drew four columns
  in and `    1. x` eight, so an ordered sub-list stepped twice as far right as
  the bullet sub-list at the same depth, and the drawn row came out wider than
  `lineRows` had measured, clipping the tail of a full-width line. Resolved in
  `docs/reports/bugs/2026-08-23-repl-nested-ordered-list-double-indent.md`.
- **(Fixed) Row measurement read the markdown source, the draw rendered the
  stripped form.** `lineRows` measures source bytes while the rich path draws
  `mdLineSegments`' output — markers gone, `# ` stripped, `> ` swapped for a
  rule, list indents normalised — so `tailWindow`, `topWindowEnd`,
  `foldForReply` and `streamRows` all reserved rows the draw never filled.
  This is the half of
  `docs/reports/bugs/2026-08-23-repl-markdown-eats-snake-case-underscores.md`
  ("`lineRows` measured a longer string than the draw produced") that the
  underscore fix did not address. `mdLineRows` now measures by running the
  draw's own segment builder, and `rowsForLine` routes each line by the draw
  loop's branches. Resolved in
  `docs/reports/bugs/2026-08-23-repl-row-math-measures-markdown-source.md`.
- **(Fixed) The turn arrow put every block rule out of reach on a reply's
  first line.** `finishTurn` stores that line as `turn_arrow ++ line`, and
  every rule this PRD added tests the start of the text, so a reply opening
  with `## Plan` drew its `##` and one opening with a list drew its `-`. Found
  on a live pty run, not by reading the code; only unfolded replies show it,
  since `foldForReply` strips the arrow when a reply folds. `mdLineSegments`
  now emits the arrow as its own segment and re-enters on the remainder.
  Resolved in
  `docs/reports/bugs/2026-08-23-turn-arrow-defeats-markdown-on-first-reply-line.md`.
- **Open: tables are not column-aligned and the header is not styled.** Goal 2
  and acceptance criterion 2 say "aligned columns and bold header", and the
  doc comment on `mdLineSegments` says the block callers detect multi-line
  constructs by peeking at neighbours. No caller does: a table row is rendered
  independently, cells joined with ` │ ` and a separator row's cells drawn as
  `───`, with no width agreement between rows and no header emphasis. The
  helpers this PRD's Implementation names (`isTableBlock`, `parseTableRow`,
  `tableColWidths`, `mdBlockSegments`) were never written. Alignment also has
  to land together with a measurement rule, since padded cells draw *wider*
  than their source.

## Open questions / future work

- Shared extraction to `md_block.zig` once second consumer needs block markdown (per ADR 0021).
- Max table width policy vs. terminal resize.
