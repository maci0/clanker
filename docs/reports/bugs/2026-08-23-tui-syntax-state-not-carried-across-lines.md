# Bug — Fenced block comments and multi-line strings mis-highlight in the REPL but not in clanker run

## TL;DR

- **What failed:** syntax.zig states that highlighter state (unterminated strings, block comments) is carried across lines by the caller, and highlightLine reads and sets it. Both vaxis render paths construct State.init(lang) inside the per-line loop, so every fenced line starts fresh: a block comment's second line highlights as code. MdStream, the clanker run path, does carry the state, so the two renderers disagree on the same bytes.
- **Impact:** Any fenced C/JS/Zig block with a multi-line comment or string is coloured wrongly in the REPL.
- **Resolution:** Resolved on 2026-08-24. src/tui/repl.zig: writeStream re-inits syntax.State per opening fence instead of per line, and the transcript draw takes fenceLineSegments, which inherits the state from the line above or rebuilds it with fenceEntryState (rescan from Line.fence_first) when the window opens mid-block. syntax.advanceLine is the no-output rescan step. Two unit tests plus a live pty REPL run against a loopback SSE provider: line 2 of a /* */ came out ESC[35m keyword before, dim throughout after.

## Status

Resolved on 2026-08-24. src/tui/repl.zig: writeStream re-inits syntax.State per opening fence instead of per line, and the transcript draw takes fenceLineSegments, which inherits the state from the line above or rebuilds it with fenceEntryState (rescan from Line.fence_first) when the window opens mid-block. syntax.advanceLine is the no-output rescan step. Two unit tests plus a live pty REPL run against a loopback SSE provider: line 2 of a /* */ came out ESC[35m keyword before, dim throughout after.

## Symptom and impact

A fenced block whose comment or string spans lines colours only its first line as such; the rest reads as ordinary code, with `const` bold inside a comment and a stray `*/` in plain style.

## Reproduction

Send a reply containing a fenced ```js block with `/* start` on one line and `const x = 1; still comment */` on the next. `clanker run` renders both lines dim; `clanker repl` renders the second as code.

## Root cause

`src/tui/syntax.zig` documents that the caller carries `State` across lines, and `highlightLine` reads `state.in_block_comment` / `state.in_string`. Both vaxis paths in `src/tui/repl.zig` do `var state = syntax.State.init(lang);` *inside* the per-line loop — the transcript draw loop and `writeStream`. `MdStream` in `src/tui/transcript.zig` holds `syn_state` across lines, which is why syntax.zig's own cross-line test passes while the TUI is wrong.

## Resolution

Open. Found by a read of the code against its own doc comments and the PRD it implements, not from a live incident.

## Verification

None yet: nothing is fixed. A fix needs a unit test at the named seam plus a live REPL turn.

## Follow-up

The transcript draw loop starts at an arbitrary window line, so carrying state means rescanning from the fence's first line (the `fence_lang` tag marks the run) rather than hoisting the variable. Not a one-liner.

## References

- Investigation: none yet
