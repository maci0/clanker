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
| Shift+Insert and the terminal never answers the clipboard read | Enter folds to a newline for 1500 ms, then submits again with a one-line notice (see Known issues) |


## Acceptance criteria

- [x] Shift+Enter inserts newline, Enter still submits
- [x] Joined buffer preserves newlines to agent task/history
- [x] Existing line-level/block markdown tests still pass
- [x] `zig build test` + `zig build tools` green, fmt clean

## Known issues

- **(Fixed) An unanswered clipboard read used to latch the composer out of
  submitting.** Shift+Insert set `in_paste` on the guess that the terminal
  would replay the clipboard as raw keystrokes, and only a `.paste` payload or
  a bracketed `.paste_end` cleared it. Most terminals refuse an OSC 52 read,
  so neither ever arrived: Enter took the paste branch forever and nothing
  could be sent, `/quit` included, against this PRD's "no action / fallback to
  submit" row. `in_paste` now means only "inside a bracketed-paste pair", the
  Shift+Insert guess is bounded by `paste_window_until_ms` (1500 ms,
  monotonic), and `composerEnterAction` (src/tui/repl.zig) decides Enter from
  the two. Resolved in
  `docs/reports/bugs/2026-08-23-repl-composer-latches-into-paste-mode.md`.

- **(Fixed) Alt+Enter, this PRD's own fallback, was bound nowhere.** Goal 1
  and ADR 0022 both read "Shift+Enter (and Alt+Enter fallback)", and only
  `enter+shift`, `kp_enter` and `kp_enter+shift` were bound. `vaxis.Key.matches`
  compares modifiers for exact equality, so `enter+alt` matched neither that
  branch nor the bare-Enter submit, and `vxfw.TextField` drops it too — the
  keystroke did nothing at all, not even the "fallback to submit" the Failure
  modes table promises. That mattered most where it was meant to help: a
  terminal outside the kitty keyboard protocol cannot report Shift+Enter, so
  the chord arrives as a plain Enter and submits, leaving Alt+Enter as the
  only line-break chord. `isComposerNewlineChord` (src/tui/repl.zig) now
  collects all five spellings and `keys_help` names Alt-Enter. Resolved in
  `docs/reports/bugs/2026-08-23-repl-alt-enter-newline-never-bound.md`.

## Open questions / future work

- Key mapping for Shift+Enter vs. Alt+Enter on different terminals: settled
  for the fallback (see Known issues) — Shift+Enter needs the kitty keyboard
  protocol, keypad Enter covers Konsole's SS3 M, Alt+Enter covers the rest.
  Shift+Alt+Enter is deliberately still unbound.


