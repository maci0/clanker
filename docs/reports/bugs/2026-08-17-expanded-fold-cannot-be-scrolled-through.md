# Bug — TUI scrolling never advances through a fully expanded fold

## TL;DR

- **What failed:** tailWindow treated a fold as an atomic block in every state, so any anchor inside an expanded fold snapped the window back to the header: a screen-taller reply repeated the identical frame on every wheel notch or PgDn until the anchor passed the whole fold, then jumped. A fully open fold is now counted per-line (+1 header row at its first line); the block stays atomic only while collapsed or animating.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. Resolved on 2026-08-17. tailWindow counts a fully open fold per-line (+1 header row at f.start); atomic block only while collapsed/animating. Regression test in src/tui/repl.zig.

## Status

Resolved on 2026-08-17. Resolved on 2026-08-17. tailWindow counts a fully open fold per-line (+1 header row at f.start); atomic block only while collapsed/animating. Regression test in src/tui/repl.zig.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Mechanism

src/tui/repl.zig `tailWindow` walks backward from `view_end` accumulating wrapped rows. Its fold branch treated any line inside a fold's range as the whole block — `rows = 1 + revealed body rows`, `start = f.start` — in every state. That is required while the fold is collapsed or animating, because the rows drawn differ from the lines stored. But it also held when the fold was fully open, where the draw loop falls through to ordinary per-line rendering: with the anchor anywhere inside an expanded fold the window start snapped back to the fold header, so every wheel notch (3 lines) and PgDn inside a screen-taller reply advanced `view_end` yet rendered the identical frame, until the anchor passed `f.start + f.count` and the view jumped past the whole reply (operator screenshot, 2026-08-17).

## Fix

`tailWindow` now checks `foldShownLines(f) >= f.count` first: a fully open fold is counted per-line, plus one header row when the walk reaches `f.start` — exactly what the draw loop draws (header + first line at `f.start`, plain lines elsewhere; a window starting mid-fold draws no header, and `foldIndexAtStart` only matches `f.start`). The atomic block remains for collapsed and animating folds.

## Verification

`test "tailWindow scrolls line-by-line through a fully expanded fold"` in src/tui/repl.zig — written first and failing (win.start snapped to 1, the fold header, instead of 4), green after the fix; a second case pins the +1 header row when the window covers `f.start`. The existing straddle-clamp test still passes, and a second-opinion diff review (clanker run, deepseek-v4-pro) confirmed the draw/layout agreement and found no off-by-one. `zig build test` green.