# Bug — TUI reply fold can be opened but never closed again

## TL;DR

- **What failed:** The fold header row is the only toggle, and the draw loop only drew it (and registered its click hit) while foldShownLines < count — a fully expanded reply lost its header, so it could not be collapsed; tailWindow also counts the header row unconditionally, so expanded replies were bottom-aligned one row off.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. header row and click hit now drawn in every fold state; verified via pty click round-trip and clanker gate

## Status

Resolved on 2026-08-17. header row and click hit now drawn in every fold state; verified via pty click round-trip and clanker gate

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence and mechanism

Operator screenshot (2026-08-17): a long reply expanded via its `▸` header could not be folded back; the transcript shows the reply fully open with no header row above it.

- src/tui/repl.zig draw loop: the fold branch was guarded by `if (shown < f.count)` — header row and `fold_hits` registration both lived inside the guard, so a fully expanded fold (`foldShownLines == count`) fell through to plain per-line rendering with no header and no click target. `toggleFold` and the reversible animation were already bidirectional; only the affordance vanished.
- Same guard also made the draw disagree with `tailWindow`, which counts `1 + shown` rows for any line in a fold's range unconditionally: expanded replies were bottom-aligned for one row more than was drawn.

## Resolution

The header row is now drawn, and its hit registered, in every fold state — `▸ reply, N more lines` collapsed, `▾ reply` open — so clicking toggles both ways and draw and layout agree on the header row. The fully-open body falls through to the normal rich path (markdown, fences, tool cards); only partially-revealed animation frames draw plain, as before.

## Verification

pty harness against the built binary with a live model reply (14 marker lines): collapsed shows `▸ reply, 14 more lines` with the body hidden; one click on the header shows `▾ reply` with the body visible; one click on the open header returns to `▸ reply, 14 more lines` with the body hidden. `zig build test` and `clanker gate` green.