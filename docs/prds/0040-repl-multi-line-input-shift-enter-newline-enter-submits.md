# PRD — REPL multi-line input: Shift+Enter newline, Enter submits

## Status

Shipped — 2026-08-17. src/tui/repl.zig: Shift+Enter/Alt+Enter multi-line composer (newline_marker, drawComposer, takeComposerText, history re-encode)

Source `src/tui/repl.zig` (newline_marker ⏎, Shift+Enter/Alt+Enter→newline, drawComposer multi-row, takeComposerText join, history recall re-encode). PRD 0005 and ADR 0022 are dependencies. All acceptance criteria met.

## Problem

Users cannot compose multi-paragraph tasks without bracketed paste; single-line TextField loses deliberate intent.

Constraints: Zig 0.16, vaxis-native, preserve Enter-to-submit, keep sanitize/width/theme across lines.

## Goals

1. Shift+Enter (and Alt+Enter fallback) inserts newline in composer, displayed as wrapped second line
2. Enter still submits the whole buffer joined with newline; paste folding preserved
3. sanitize/width/theme still apply across newline boundaries


## Non-goals

- No image/multimodal, no block-level md change, no plan-mode wiring — separate PRDs.
- No dedicated modal editor (Option B) — revisit if single-field approach proves too frail.

## Design
**Dependencies.** PRD 0005, ADR 0022, `src/tui/repl.zig` TextField and submit path.

**Design.** Modifier-aware key handler inserts literal newline into composer buffer; draw renders buffer with wrapping; submit joins lines with newline. Bracketed paste CR/LF folding stays. Theme/sanitize/width honored per line.

**Implementation.**
1. Extend composer buffer to multi-line and map Shift+Enter/Alt+Enter to newline — `src/tui/repl.zig`.
2. Handle Enter vs. modified Enter in input handler; ensure history and agent task receive joined newlines — `src/tui/repl.zig`.
3. Tests for newline insert, submit join, and fallback — `src/tui/repl.zig` tests.
4. `zig fmt` + `zig build test` + `zig build tools` green.

## Failure modes

| Condition | Behaviour |
|---|---|
| Shift+Enter on single-line TextField without handler | No action (fallback to submit); no crash |
| Very long multi-line paste | Wrapped rendering, no O(n^2) |
| Newlines in history recall | Recalled verbatim |


## Acceptance criteria

- [x] Shift+Enter inserts newline, Enter still submits
- [x] Joined buffer preserves newlines to agent task/history
- [x] Existing line-level/block markdown tests still pass
- [x] `zig build test` + `zig build tools` green, fmt clean

## Open questions / future work

- Key mapping for Shift+Enter vs. Alt+Enter on different terminals.


