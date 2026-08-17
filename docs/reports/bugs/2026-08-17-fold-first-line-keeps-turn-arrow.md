# Bug — TUI expanded reply fold shows a stray › on its first body line

## TL;DR

- **What failed:** appendAnswerLines arrows the first line of every reply; folding kept it, so an expanded fold showed both the '▾ reply' header and the '› ' arrow — two turn markers, the second reading as a stray prompt glyph. foldForReply now strips the arrow when a reply folds; the header row is the turn marker from then on.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. Resolved on 2026-08-17. foldForReply strips the turn arrow when a reply folds; the fold header row is the turn marker. Regression test in src/tui/repl.zig.

## Status

Resolved on 2026-08-17. Resolved on 2026-08-17. foldForReply strips the turn arrow when a reply folds; the fold header row is the turn marker. Regression test in src/tui/repl.zig.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Mechanism

- src/tui/repl.zig `appendAnswerLines`: the first line of every completed answer is prefixed with the `turn_arrow` (`› `, now a named constant) — its doc comment says so, and that is right for an unfolded reply, where the arrow is the only marker of where a turn's prose begins.
- `maybeFoldReply` then folded the same range untouched, so a folded reply carried two turn markers: the `▾ reply` header row (drawn in every fold state since 2026-08-17-fold-header-vanishes-when-expanded.md) and the arrow on the first body line, which under the header reads as a stray prompt glyph (operator screenshot, 2026-08-17).

## Fix

The fold decision is extracted from `maybeFoldReply` into `foldForReply(lines, reply_start, width)`, pure over its arguments so it is host-testable, and it strips `turn_arrow` from the first line when (and only when) the reply folds. Short replies never fold and keep the arrow.

## Verification

`test "a reply that folds drops its turn arrow: the header is the turn marker"` in src/tui/repl.zig — written first and failing (expectEqualStrings saw `› Line 1`), green after the strip; the short-reply case pins the arrow's survival. `zig build test` green.