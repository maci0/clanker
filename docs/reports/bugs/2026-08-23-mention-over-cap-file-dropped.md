# Bug — A composer @path mention of a file over the 32 KiB cap is dropped instead of truncated

## TL;DR

- **What failed:** The REPL read an @path mention with readFileAlloc(.limited(per_file_cap + 1)); that limit answers error.StreamTooLong when reached or exceeded, so every file at or over 32 KiB read as unreadable and the mention stayed a bare @path token with no fenced block and no notice, against PRD 0052's 'file > 32 KiB -> truncated with notice' row. The helper also cut at a raw byte offset, so a cut landing mid-codepoint sent invalid UTF-8 to the provider.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. readMentionFile (src/tui/repl.zig) reads a bounded prefix with readSliceShort instead of readFileAlloc's throwing .limited ceiling, and capUtf8 in tools/zig/mention_expand.zig backs the cut up to a codepoint boundary. Pinned by two unit tests that fail on the pre-fix code; clanker gate green on all eleven checks; live pty REPL run against deepseek answers from the truncated file (30361 in) where the pre-fix binary said no file content was included (23667 in).

## Status

Resolved on 2026-08-23. readMentionFile (src/tui/repl.zig) reads a bounded prefix with readSliceShort instead of readFileAlloc's throwing .limited ceiling, and capUtf8 in tools/zig/mention_expand.zig backs the cut up to a codepoint boundary. Pinned by two unit tests that fail on the pre-fix code; clanker gate green on all eleven checks; live pty REPL run against deepseek answers from the truncated file (30361 in) where the pre-fix binary said no file content was included (23667 in).

## Symptom and impact

Typing `@docs/reviews/webui.md` (95 KiB) in the REPL composer and pressing
Enter sent the model the literal text `@docs/reviews/webui.md` and nothing
else: no fenced block, no `[mention refused: ...]` line, no `[truncated]`
notice. The operator sees a normal turn and the model answers about a path it
was never given the contents of. PRD 0052's Failure modes promise
"file > 32 KiB | truncated with notice", and its acceptance criterion 3
("a 40 KiB file is truncated") was checked on the strength of a helper-level
test with a synthetic reader, not the REPL's own reader.

## Reproduction

In a REPL, `@<any file over 32768 bytes>`. The expansion falls through to
the plain-byte branch and the token is copied verbatim.

## Root cause

`src/tui/repl.zig` read the mention with
`readFileAlloc(io, path, arena, .limited(mention_expand.per_file_cap + 1))`.
The `+ 1` was meant to hand `mention_expand.expandAlloc` one byte past the
cap so it could tell the file had been cut. But `std.Io.Limit` on
`readFileAlloc` is documented "if reached or exceeded, `error.StreamTooLong`
is returned instead" — it is a ceiling, not a truncating read. So the call
errored for exactly the files it was supposed to truncate, and the
`catch null` beside it made an over-cap file indistinguishable from a missing
one.

Second defect on the same path: `expandAlloc` truncated with
`src[0..per_file_cap]`, a raw byte cut. PRD 0052's Design says "truncated on
a UTF-8 boundary". A file whose byte 32768 falls inside a multi-byte codepoint
produced invalid UTF-8 in both the provider request body and the saved user
message.

## Resolution

- `readMentionFile` (`src/tui/repl.zig`) opens the file and reads a bounded
  prefix of `per_file_cap + 1` bytes with `readSliceShort`, which returns
  short only at end of stream. The ceiling is kept (a huge file is never
  fully allocated) and there are now bytes to truncate.
- `capUtf8` in `tools/zig/mention_expand.zig` backs the cut up to a codepoint
  boundary. The copy is local rather than `@import("utf8")` because this file
  is both a host-tested helper and linked into `src/` by name, and a file may
  belong to only one module per compilation — the same reason
  `advisor_logic` carries its own.

## Verification

Two Zig unit tests, each confirmed failing on the pre-fix code for the right
reason:

- `a mention of a file over the cap is truncated, not dropped`
  (`src/tui/repl.zig`) writes a 64 KiB file of two-byte codepoints, calls
  `readMentionFile`, and runs the result through `expandAlloc`. Pre-fix it
  failed `MentionFileWasDropped` at the `orelse`.
- `expandAlloc truncates on a UTF-8 boundary`
  (`tools/zig/mention_expand.zig`). Pre-fix it failed
  `utf8ValidateSlice`. The fixture puts one ASCII byte first so every
  following codepoint starts on an odd offset and the even cap lands inside
  one; an all-two-byte fixture happens to cut cleanly and proves nothing.

`clanker gate` green, all eleven checks, on 781a2e99 + this change.

Live, over a real pty with `--provider deepseek --model deepseek-v4-flash`,
against a 60 KiB file whose first line held a marker phrase, asking for the
phrase "using only the text in this message and no tools":

- pre-fix binary: `No cipher phrase - no file content was included in this
  message, and I cannot read files without tools.` Turn accounting
  `23667 in` - the system prompt and nothing else.
- post-fix binary: `PLUMWHISTLE-7742`, turn accounting `30361 in` - the
  extra ~6.7k tokens are the truncated file.

## Follow-up

## References

- Investigation: none yet
