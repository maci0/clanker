# Investigation — TUI Shift+Enter logs vaxis_parser unhandled ss3 instead of newline

## TL;DR

- **Question:** Pressing Shift+Enter in clanker repl emits warning(vaxis_parser): unhandled ss3: 4d and no newline reaches the textbox; the terminal sends SS3 M (ESC O M) and the vendored vaxis parser has no case for it.
- **Finding:** Resolved on 2026-08-16. SS3 M mapped to kp_enter (patches/vaxis-ss3-keypad-enter.patch), std.log routed through util/log.zig via std_options.logFn, Shift+Enter inserts a ⏎-marked line break decoded to newline on submit; zig build test and clanker gate green
- **Resolution:** Resolved on 2026-08-16. SS3 M mapped to kp_enter (patches/vaxis-ss3-keypad-enter.patch), std.log routed through util/log.zig via std_options.logFn, Shift+Enter inserts a ⏎-marked line break decoded to newline on submit; zig build test and clanker gate green

## Status

Resolved on 2026-08-16. SS3 M mapped to kp_enter (patches/vaxis-ss3-keypad-enter.patch), std.log routed through util/log.zig via std_options.logFn, Shift+Enter inserts a ⏎-marked line break decoded to newline on submit; zig build test and clanker gate green

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## What was traced (2026-08-17)

Evidence:

- Operator screenshot: repeated `warning(vaxis_parser): unhandled ss3: 4d` painted raw across the repl alt-screen after each Shift+Enter press.
- `grep -n 'unhandled ss3' zig-pkg/vaxis-0.6.0-*/src/Parser.zig` → `parseSs3`: the SS3 table maps A–H and P–S only; any other final byte logs a warning and drops the sequence with no key event. `0x4d` is `M`, so the wire sequence was `ESC O M` — DECKPAM keypad Enter, and what Konsole's default keytab sends for Shift+Return (`key Return+Shift : "\EOM"`).
- Two further defects sat behind the visible one. (1) `grep -rn std_options src/` had no match: clanker never overrode `std.Options.logFn`, so vendored-dependency `std.log` output (the vaxis warning included) went through std's default stderr handler, bypassing the `log.setLevel(.error_)` the repl sets before the alt-screen exists — that is what painted over the UI. (2) `vxfw.TextField` is a single-line widget (its `draw` writes row 0 only) and the repl had no line-break insertion at all, so even a correctly parsed Shift+Enter would have done nothing.

Fix, in three parts:

- `patches/vaxis-ss3-keypad-enter.patch` (applied to `zig-pkg/vaxis-0.6.0-*`): `'M' => kp_enter` in `Parser.zig`'s SS3 table. Local-only like the sixel patch; a fresh clone merely loses Shift+Enter on legacy-Konsole terminals, since kitty-protocol terminals report the chord as enter+shift without it.
- `src/main.zig`: `std_options.logFn` now routes all `std.log` output through `util/log.zig`, so dependency logs honor the repl's runtime threshold and one-line format instead of tearing the alt-screen.
- `src/tui/repl.zig`: Shift+Enter (enter+shift or kp_enter) inserts a line break, stored and drawn as a `⏎` marker (`newline_marker`) because the TextField cannot render a raw newline; `takeComposerText` decodes markers to real newlines on every path text leaves the composer (submit, steering, input copy). Bracketed and OSC-52 pastes now preserve their line structure through the same markers instead of folding newlines to spaces. History recall re-encodes. Documented in the repl keys help.

Verification: `zig build test` green (round-trip and encode tests in repl.zig), `clanker gate` all gates PASS. Manual repro in Konsole pending operator confirmation; the parser mapping is byte-for-byte the sequence from the warning.
## Upstreaming (2026-08-17, follow-up)

The parser fix is now also on the fork: `github.com/ywy50/libvaxis` branch `ss3-keypad-enter` (commit 61dd1b8), based on `82cec0db` — the exact commit `build.zig.zon` pins — so it is the branch a PR to `rockorager/libvaxis` comes from, same arrangement as `sixel-graphics`. The branch adds a `parse: ss3 keypad enter` test beside the existing parser tests; `zig fmt --check` and `zig build test` pass on the branch. `patches/vaxis-ss3-keypad-enter.patch` was regenerated from `git diff 82cec0db..ss3-keypad-enter -- src/` and verified to apply to a pristine vendored copy and reproduce the tree byte-for-byte; the vendored `zig-pkg` copy carries the same two hunks.
Correction to the note above: the branch-diff regeneration was a one-time convenience, not the maintenance direction. The canonical record is `patches/vaxis-ss3-keypad-enter.patch` itself; the `ss3-keypad-enter` fork branch is a mirror derived from it and may go stale. Self-containment was re-verified 2026-08-17: a clean checkout of pinned `82cec0db` plus `vaxis-sixel-graphics.patch` and `vaxis-ss3-keypad-enter.patch` reproduces the vendored `zig-pkg` `src/` byte-for-byte (`diff -r` empty). Caveat found while checking: in-project `zig fetch` of the pinned URL returns the already-patched local package, so pristine sources must come from a git checkout of the pinned commit — recorded in `patches/README.md`.
## Reopened symptom: marker glyph garbled the input row (2026-08-17)

Operator screenshot after the first fix: the U+23CE markers rendered as overlapping garbage in Konsole. Mechanism: the width table (uucode) gives U+23CE one column and the TextField wrote it as a width-1 cell, but Konsole draws the glyph wider (U+23CE is East-Asian-Wide in common configurations), so every cell after a marker was painted over — a renderer/terminal width disagreement, the same class of bug as CJK width desync.

Fix: the marker grapheme is never rendered at all. `drawComposer` in src/tui/repl.zig replaces the single-row `TextField.draw` whenever the buffer holds a break: the input box grows one row per ⏎-separated line (capped, then it scrolls to the cursor's line), each line renders on its own row, the cursor line scrolls horizontally, other lines truncate with an ellipsis. `composerLayout` (host-tested) maps the TextField gap position to a line and display column. The marker remains the buffer representation — editing and takeComposerText are unchanged — it just never reaches a terminal cell.

Verification: `zig build test` green (composerLayout tests), `clanker gate` green, and the pty harness replayed through a terminal emulator shows the final frame with 'abc' and 'def' on separate composer rows inside a grown box, cursor after 'def', no U+23CE bytes and no vaxis warnings in the stream.
Fork review pass (2026-08-17): both `ywy50/libvaxis` mirror branches were reviewed against upstream style and re-pushed (`ss3-keypad-enter` a83e024, `sixel-graphics` bd1707f). The SS3 table comment was dropped — upstream's table is bare and the rationale lives in the commit message — and the sixel branch's narrative comments were cut to upstream's terse register, removing every clanker-specific reference (the mascot included). Both patch files were regenerated from the reviewed branches, the vendored `zig-pkg` copy was re-synced, and pristine `82cec0db` + the two patch files again reproduces vendored `src/` byte-for-byte; vaxis `zig build test` green on both branches, `clanker gate` green.
## Follow-ups: mangled echo, composer navigation, composer copy (2026-08-17)

Operator screenshot after the multi-row composer landed: the composer itself rendered correctly, but the transcript echo of a submitted multi-line task drew as a diagonal staircase of overlapping fragments.

Mechanism (the echo): `nextCell` in src/tui/repl.zig absorbs zero-width codepoints into the preceding cell so combining marks stay with their base. '\n' is zero-width, so it rode along inside the previous grapheme's cell ("4\n"), slipped past `writeWrapped`'s newline check — which compares the whole cell's bytes against "\n" — and reached the terminal raw, walking the cursor down a row mid-line. Two fixes: `nextCell` no longer absorbs control bytes (C0 or DEL), and `submitTaskWithGoal` appends one transcript entry per task line instead of one entry holding '\n' (each Line is one logical row by the draw loop's contract).

Composer navigation: Up/Down now move the cursor between draft lines keeping the display column (`composerVerticalMove`, host-tested), falling through to history recall at the first/last line — the readline convention. Because `drawComposer` scrolls to the cursor's line, this is also how a draft taller than the box is scrolled.

Composer copy: mouse drag-select was clamped to the transcript region, and Konsole intercepts Ctrl+Shift+C, so the textbox could not be copied from at all. The press now decides the selection's region (composer interior vs transcript) and the drag stays clamped to it; composer selections highlight and extract through the composer child surface — the parent's cells under a composited child are blank, so both operations must target the child.

Verification: pty harness — typed three ⏎-separated lines, two Ups plus an insert landed on the first line, an SGR mouse drag over the composer produced an OSC 52 write whose base64 decodes to exactly the selected text ('aaaX'), and after Enter the replayed final frame shows the echo as clean separate rows ("clanker> aaaX" / "bbb" / "ccc") with no staircase. `zig build test` and `clanker gate` green.
Addendum: the mouse wheel is composer-aware too. A notch with the pointer over the input box walks the cursor one draft line (the box follows the cursor's line, so this scrolls a tall draft with no second scroll state); at the draft's edge the notch is spent rather than leaking into transcript scrolling. Elsewhere the wheel scrolls the transcript as before. Verified via pty: two wheel-up SGR events over the composer moved the cursor from the third line to the first (inserted text landed there, read back over OSC 52).