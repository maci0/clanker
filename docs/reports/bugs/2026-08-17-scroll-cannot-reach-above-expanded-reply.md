# Bug — TUI scrolling cannot reach the messages above an expanded reply

## TL;DR

- **What failed:** The scroll math measured the transcript in line units against a screen measured in rows. An expanded fold adds a header row and wrapped lines add more, so the wheel/PgUp guards refused to scroll a transcript that overflowed in rows while fitting in lines, and the anchor floor stranded the window mid-fold when they did. All bounds now come from topWindowEnd, a wrap- and fold-aware row walk.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. Resolved on 2026-08-17. Scroll guards, clamps, search jump, anchor dissolve and scrollbar all take their bounds from the row-aware topWindowEnd; unit tests cover the tall-terminal expanded-fold case.

## Status

Resolved on 2026-08-17. Resolved on 2026-08-17. Scroll guards, clamps, search jump, anchor dissolve and scrollbar all take their bounds from the row-aware topWindowEnd; unit tests cover the tall-terminal expanded-fold case.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Root cause

Three sites in src/tui/repl.zig assumed one transcript line is one screen row:

- `scrollUpEnd` / `scrollWheelEnd` guarded with `line_count <= avail_rows` — on a terminal taller than the line count, an expanded reply overflows in rows (header + wraps) while the guard sees it fitting, so every notch and PgUp returns null.
- `clampViewEnd` floored the anchor at `avail_rows` lines, assuming that window fills from line 0 — with the header and wraps it overflows instead, so `tailWindow` drops the earliest lines and no anchor can show them.
- The draw loop dissolved a set anchor on the same line-unit test, snapping a scrolled reader back to the tail.

## Resolution

`topWindowEnd(lines, folds, avail_rows, width)`: a forward, wrap- and fold-aware row walk (collapsed/animating folds count as atomic blocks, a fully open fold per-line plus its header row) returning the largest anchor whose window still reaches line 0, or `lines.len` when everything fits. It now feeds every scroll surface: the wheel and PgUp/PgDn/Home guards and clamps (via `Model.scrollBounds`, read under the bridge lock), the search jump (`searchViewEnd`), the draw's anchor dissolve and clamp, and the scrollbar's overflow decision (`show_bar`), which was the same line-unit test.

Found alongside and fixed in the same change: `Model.last_text_width` was never assigned anywhere, so `maybeFoldReply` had always judged foldability at its 80-column fallback; the draw now records the width it wrapped at.

## Verification

Two new unit tests: "an expanded fold does not disable scrolling on a tall terminal" (13 lines / 14 drawn rows on a 13-row screen: floor 12, wheel moves, floor window reaches line 0; and the exact-fit case stays unscrollable) and "topWindowEnd is wrap- and fold-aware" (plain, wrapped, collapsed-block cases). All prior scroll tests pass with floor semantics. zig build test green.