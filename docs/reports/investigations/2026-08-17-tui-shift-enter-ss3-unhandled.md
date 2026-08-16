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