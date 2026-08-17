# Investigation — TUI fold shows a stray turn arrow and cannot be scrolled through

## TL;DR

- **Question:** Two operator-reported fold defects: the first body line of an expanded reply fold renders with the '› ' turn arrow appendAnswerLines adds to every reply, reading as a stray prompt marker under the '▾ reply' header; and tailWindow treats a fold as an atomic block in every state, so scrolling through a fully expanded fold taller than the screen never advances the window past the header until the anchor passes the whole fold, then jumps.
- **Finding:** Resolved on 2026-08-17. Resolved on 2026-08-17. Both defects fixed in src/tui/repl.zig; see bugs 2026-08-17-fold-first-line-keeps-turn-arrow.md and 2026-08-17-expanded-fold-cannot-be-scrolled-through.md.
- **Resolution:** Resolved on 2026-08-17. Resolved on 2026-08-17. Both defects fixed in src/tui/repl.zig; see bugs 2026-08-17-fold-first-line-keeps-turn-arrow.md and 2026-08-17-expanded-fold-cannot-be-scrolled-through.md.

## Status

Resolved on 2026-08-17. Resolved on 2026-08-17. Both defects fixed in src/tui/repl.zig; see bugs 2026-08-17-fold-first-line-keeps-turn-arrow.md and 2026-08-17-expanded-fold-cannot-be-scrolled-through.md.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Evidence

Operator screenshots (2026-08-17): an expanded 12-line reply fold whose first body line reads `› Line 1` while every later line has no arrow; and after expanding, wheel/PgDn scrolling repeats the same frame instead of rolling on to the fold's later lines.

Both mechanisms are in src/tui/repl.zig:

- Arrow: `appendAnswerLines` prefixes the first line of every completed reply with the `› ` turn arrow (the comment above it says so: 'the first visible line marked with the › turn arrow'). `maybeFoldReply` then folds the same range without touching that line, so a folded reply carries both the `▾ reply` header row and the arrow — two turn markers, the second reading as a prompt glyph.

- Scroll: `tailWindow` treats any line inside a fold's range as the whole block ('Folds are atomic blocks: any line inside a reply's range contributes that reply's folded height and the walk jumps the whole block in one step'). That is required while the fold is collapsed or animating, because drawn rows differ from line rows. But it also holds when the fold is fully open, where the draw loop falls through to normal per-line rendering: with `view_end` anywhere inside an expanded fold, the walk snaps `start` to `f.start`, so every wheel notch or PgDn inside a screen-taller fold renders the identical window (header at top) until the anchor passes `f.start + f.count`, then the view jumps past the whole reply.
## Follow-up: header prominence (2026-08-17)

The fold header was still easy to overlook after the fixes landed. Two styling rounds:

1. `tool_style` (dim + tool tint) → `brand_style` (bold accent), 6520e5c2. Operator screenshot showed no improvement: the active theme's accent sits at near-white, the same place as body text, so bold accent ≈ bold prose. Color-based prominence is theme-fragile by construction.
2. Chosen from four options (reverse chip, chip + rule, full-width rule, underline + hint): a dedicated `fold_style` — bold + `ul_style = .single`, hyperlink-shaped — plus explicit wording, `▾ reply (click to fold)` / `▸ reply, N more lines (click to expand)`. Underline renders in every theme regardless of palette, and the wording says the row is a control instead of hoping the styling implies it.
Known edge, unchanged in kind: tailWindow counts the header as exactly 1 row while writeWrapped wraps it, so a text width narrower than the header desyncs the layout by a row. Pre-existing (the old collapsed header was ~23 cells); the '(click to expand)' wording raises the threshold to ~41 cells. Not addressed: the repl is not usable at such widths for other reasons.