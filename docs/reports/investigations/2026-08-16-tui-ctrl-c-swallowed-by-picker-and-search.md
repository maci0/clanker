# Investigation — TUI Ctrl+C cannot interrupt a streaming turn while the picker or search modal is open

## TL;DR

- **Question:** handlePickerKey and handleSearchKey in src/tui/repl.zig end with an unconditional consumeAndRedraw and have no Ctrl+C branch, so while the model/theme picker, command palette (Ctrl+P), or transcript search (Ctrl+R) is open every Ctrl+C is swallowed: a streaming turn cannot be interrupted and the modal does not close. The ask modal handles this case explicitly (handleAskKey declines and sets bridge_stop_flag); the other two keyboard-owning modals do not.
- **Finding:** Resolved on 2026-08-16. Fixed in src/tui/repl.zig: handlePickerKey and handleSearchKey now consult modalCtrlCAction, closing the modal and stopping a streaming turn on Ctrl+C; verified by the new unit test and a full clanker gate pass.
- **Resolution:** Resolved on 2026-08-16. Fixed in src/tui/repl.zig: handlePickerKey and handleSearchKey now consult modalCtrlCAction, closing the modal and stopping a streaming turn on Ctrl+C; verified by the new unit test and a full clanker gate pass.

## Status

Resolved on 2026-08-16. Fixed in src/tui/repl.zig: handlePickerKey and handleSearchKey now consult modalCtrlCAction, closing the modal and stopping a streaming turn on Ctrl+C; verified by the new unit test and a full clanker gate pass.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
Evidence (src/tui/repl.zig):

- Key dispatch (.key_press arm) routes a key to exactly one modal handler when its flag is set — ask_open to handleAskKey, picker_open to handlePickerKey, search_open to handleSearchKey — before any composer-level binding, including the Ctrl+C interrupt/quit handler.
- handleAskKey matches Ctrl+C explicitly: it declines the pending ask and stores bridge_stop_flag, so a run parked on a question stays stoppable.
- handlePickerKey and handleSearchKey had no Ctrl+C branch and both end in an unconditional 'return ctx.consumeAndRedraw()', so Ctrl+C fell through to the swallow: no interrupt, no modal close, no quit. Verified by reading both handlers; neither matched 'c' with ctrl anywhere.
- Reproduction: start a streaming turn in 'clanker repl', press Ctrl+P (or Ctrl+R) to open the palette/search, then press Ctrl+C — nothing happens until the modal is dismissed with Escape.

Finding: the two keyboard-owning modals other than ask swallowed the interrupt chord. Fix: a shared pure helper modalCtrlCAction(key, streaming) decides the chord's meaning (streaming: close the modal and stop the turn via bridge_stop_flag + askCancelPending, idle: close the modal like Escape; Ctrl+Shift+C stays the copy chord), and both handlers consult it first. Unit test 'modalCtrlCAction stops a streaming turn from inside picker/search and closes when idle' was written first and failed with 'expected .close_and_stop, found .none' against a stub before the implementation.

Verification: zig build test passes (1131 tests, the new test included) and clanker gate reports all gates passed (build, tests, tools, fmt, lint, provider-kind, tools-ts-toolchain, release-contract).