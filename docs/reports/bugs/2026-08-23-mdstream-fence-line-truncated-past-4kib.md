# Bug — A fenced line longer than 4 KiB is silently cut, not emitted unhighlighted

## TL;DR

- **What failed:** MdStream buffers a fenced line into a fixed 4096-byte array and drops every byte past it with no flag and no fallback. emitFenceLine's doc comment says lines longer than the buffer are emitted unhighlighted (still control-stripped); no such path exists, and the unhighlighted fallback emits the truncated 4096 bytes. A minified bundle, a long JSON blob or a one-line base64 payload inside a fence stops mid-line in clanker run with no truncation marker, unlike cardPreview which marks its cut.
- **Impact:** Long single-line payloads inside a fence lose everything past 4 KiB with no marker, in every `clanker run`.
- **Resolution:** Resolved on 2026-08-24. src/tui/transcript.zig: MdStream flushes a fenced line past its 4096-byte buffer unhighlighted in buffer-sized pieces (flushFencePiece + fence_line_split) instead of discarding the remainder; the rest of the line follows unhighlighted so it is never half coloured, and nothing is dropped so no marker is needed. Unit test pins both sides of the boundary; live pty run against a loopback SSE provider went from 4091 to 4590 of 4590 payload bytes.

## Status

Resolved on 2026-08-24. src/tui/transcript.zig: MdStream flushes a fenced line past its 4096-byte buffer unhighlighted in buffer-sized pieces (flushFencePiece + fence_line_split) instead of discarding the remainder; the rest of the line follows unhighlighted so it is never half coloured, and nothing is dropped so no marker is needed. Unit test pins both sides of the boundary; live pty run against a loopback SSE provider went from 4091 to 4590 of 4590 payload bytes.

## Symptom and impact

A fenced line longer than 4096 bytes renders up to the cut and stops. Nothing marks the truncation, so the output reads as though the model produced a short line.

## Reproduction

Ask for a minified bundle, a long single-line JSON blob or a base64 payload inside a fence and run it under `clanker run`.

## Root cause

`MdStream.fence_line` is a fixed `[4096]u8` and the append is guarded by `if (self.fence_line_len < self.fence_line.len)` with no else: the byte is discarded, no flag is set, no fallback runs. `emitFenceLine`'s doc says lines longer than the buffer are emitted unhighlighted; the only unhighlighted path is the `highlightLine` failure fallback, and it emits the truncated 4096 bytes.

## Resolution

Open. Found by a read of the code against its own doc comments and the PRD it implements, not from a live incident.

## Verification

None yet: nothing is fixed. A fix needs a unit test at the named seam plus a live REPL turn.

## Follow-up

`cardPreview` marks its cut with `…`; the same convention would do here, or the line could be flushed unhighlighted in chunks as the doc claims.

## References

- Investigation: none yet
