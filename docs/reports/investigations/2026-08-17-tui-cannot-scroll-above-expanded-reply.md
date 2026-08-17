# Investigation — TUI cannot scroll above an expanded reply

## TL;DR

- **Question:** Operator report: with a reply fold expanded, scrolling up cannot reach the messages above the reply. The scroll math measures the transcript in line units against a screen measured in rows; an expanded fold adds a header row and wrapping adds more, so the guards, the anchor floor, and the draw's anchor dissolve all misjudge what fits.
- **Finding:** Resolved on 2026-08-17. Resolved on 2026-08-17. Root cause and fix in docs/reports/bugs/2026-08-17-scroll-cannot-reach-above-expanded-reply.md: every scroll bound now comes from the row-aware, fold-aware topWindowEnd.
- **Resolution:** Resolved on 2026-08-17. Resolved on 2026-08-17. Root cause and fix in docs/reports/bugs/2026-08-17-scroll-cannot-reach-above-expanded-reply.md: every scroll bound now comes from the row-aware, fold-aware topWindowEnd.

## Status

Resolved on 2026-08-17. Resolved on 2026-08-17. Root cause and fix in docs/reports/bugs/2026-08-17-scroll-cannot-reach-above-expanded-reply.md: every scroll bound now comes from the row-aware, fold-aware topWindowEnd.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Evidence

Three sites in src/tui/repl.zig share the line-units-vs-rows assumption:

1. `scrollUpEnd` / `scrollWheelEnd`: `if (line_count <= avail_rows) return null` — 'the whole transcript fits, nothing to scroll'. An expanded 30-line fold is 31+ rows (header + wraps), so on a terminal taller than the line count the content overflows in rows while the guard sees it fitting in lines: every wheel notch and PgUp returns null and the view never moves. This is the operator's 'not possible to scroll above the reply'.
2. `clampViewEnd`: `min_end = @min(line_count, avail_rows)` floors the anchor at a screenful of *lines*, assuming that window fills from line 0. With the header row and wraps, the first avail_rows lines occupy more than avail_rows rows, so `tailWindow` drops the earliest lines and no reachable anchor shows them — the top of the transcript is unreachable even when scrolling works.
3. The draw loop (`if (view_end != null and line_count <= avail_rows) view_end = null`) dissolves a set anchor on the same line-unit test, snapping a reader back to the tail.

All three predate folds (single wrapped lines already break the arithmetic mildly); an expanded fold makes the error a whole header row plus every wrap at once, which is why it presents as 'expanded replies broke scrolling'.
## Review

Second-opinion diff review via clanker run (deepseek-v4-pro). Its answer confirmed the loop-side fix (non-length finish reasons unaffected) and flagged two things it could not see because tool-result pruning spilled the diff middle: topWindowEnd termination and the lock discipline of scrollBounds. Both verified directly: topWindowEnd's next index is always greater than i (block jump ends past i, default is i+1), and the only caller holding bridge_mutex (jumpToCurrentHitLocked) inlines the floor computation with a comment saying why — the mutex is not reentrant. The review run itself is a live sample of the pruning limitation on large diffs.