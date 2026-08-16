# Investigation — TUI selection copy never reaches the system clipboard in terminals that ignore OSC 52 or intercept Ctrl+Shift+C

## TL;DR

- **Question:** clanker repl grabs mouse reporting (vxfw.App.run enables it unconditionally), so the hosting terminal never has a native selection; drag-select copies via OSC 52 only, and Ctrl+Shift+C is intercepted by hosts like VS Code, which answer 'The terminal has no selection to copy'. Tracing the copy path and adding a host-clipboard fallback.
- **Finding:** Resolved on 2026-08-16. Fixed by the host-clipboard fallback in src/tui/clipboard.zig called from both repl.zig copy sites alongside OSC 52; verified by clanker gate all green on 2026-08-17 (build, tests incl. the new candidates unit test, tools, fmt, lint).
- **Resolution:** Resolved on 2026-08-16. Fixed by the host-clipboard fallback in src/tui/clipboard.zig called from both repl.zig copy sites alongside OSC 52; verified by clanker gate all green on 2026-08-17 (build, tests incl. the new candidates unit test, tools, fmt, lint).

## Status

Resolved on 2026-08-16. Fixed by the host-clipboard fallback in src/tui/clipboard.zig called from both repl.zig copy sites alongside OSC 52; verified by clanker gate all green on 2026-08-17 (build, tests incl. the new candidates unit test, tools, fmt, lint).

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
## Resolution

- Fix: src/tui/clipboard.zig pipes the copied text into the first working host clipboard tool — wl-copy (Wayland), xclip/xsel (X11), pbcopy (macOS), chosen from WAYLAND_DISPLAY/DISPLAY and the build target — as a fallback called at both copy sites in src/tui/repl.zig (mouse-release copy in handleMouse, and copySelectionOrInput) in addition to the OSC 52 write. Candidate ordering is a pure function with a unit test; every spawn/write failure is swallowed so a headless session never breaks the OSC 52 path.
- keys_help now documents that Shift+drag bypasses the app for the terminal's own selection and that the hosting terminal may intercept Ctrl-Shift-C.
- Verified: clanker gate all green (build, tests, tools, fmt, lint, provider-kind, tools-ts-toolchain, release-contract) on 2026-08-17.
- Not verified: whether the user's VS Code applies OSC 52 writes; the fallback makes the answer irrelevant on a desktop with a clipboard tool installed.