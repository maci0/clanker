# Investigation — TUI selection copy never reaches the system clipboard in terminals that ignore OSC 52 or intercept Ctrl+Shift+C

## TL;DR

- **Question:** clanker repl grabs mouse reporting (vxfw.App.run enables it unconditionally), so the hosting terminal never has a native selection; drag-select copies via OSC 52 only, and Ctrl+Shift+C is intercepted by hosts like VS Code, which answer 'The terminal has no selection to copy'. Tracing the copy path and adding a host-clipboard fallback.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Evidence

- src/tui/repl.zig handleMouse: drag release extracts the selection and calls ctx.copyToClipboard (vxfw copy_to_clipboard command); copySelectionOrInput does the same for Ctrl+Shift+C. Checked in the tree at f9362143.
- zig-pkg/vaxis-0.6.0.../src/vxfw/App.zig handleCommand routes copy_to_clipboard to Vaxis.copyToSystemClipboard, which base64-encodes and writes the OSC 52 copy sequence and flushes. The write path emits bytes; nothing is dropped app-side.
- OSC 52 is therefore the only route to the system clipboard. A hosting terminal that does not apply OSC 52 clipboard writes gets nothing, and the terminal's own copy action cannot help because mouse reporting (enabled unconditionally by vxfw.App.run) means the terminal never has a native selection.
- Screenshot 2026-08-16: VS Code answers Ctrl+Shift+C with 'The terminal has no selection to copy' — VS Code binds that chord to its own copy-terminal-selection action, so the chord never reaches the app, and the terminal-side selection is empty by construction while mouse reporting is on.
- Unverified: whether the user's VS Code build applies OSC 52 clipboard writes; the fix does not depend on the answer.