# Bug — The TUI width table panics on a codepoint a streamed delta cut in half

## TL;DR

- **What failed:** width.zig documents invalid UTF-8 as width 1 each, but displayWidth and truncateToWidth drive std.unicode.Utf8Iterator, which catch-unreachables an invalid start byte and slices past the end of a truncated tail. Both panic before the loop's own catch can run. SSE deltas split multi-byte codepoints routinely and the live stream buffer is measured every frame, so a CJK or emoji reply can take the REPL down at a delta boundary.
- **Impact:** A CJK or emoji reply can abort the REPL at an SSE delta boundary, and any latin-1 byte in tool output can do the same.
- **Resolution:** Resolved on 2026-08-23. width_mod.nextCodepoint yields a lone byte for an invalid start byte or a cut-short sequence, and decodeOne stops utf8Decode passing a raw 0x80 off as a C1 control; displayWidth, truncateToWidth, lineRows, mdLineRows and nextCell all walk with it.

## Status

Resolved on 2026-08-23. width_mod.nextCodepoint yields a lone byte for an invalid start byte or a cut-short sequence, and decodeOne stops utf8Decode passing a raw 0x80 off as a C1 control; displayWidth, truncateToWidth, lineRows, mdLineRows and nextCell all walk with it.

## Symptom and impact

The REPL aborts with `panic: attempt to unwrap error: Utf8InvalidStartByte`,
or with a slice-out-of-bounds panic, from inside the render path. Under
`ReleaseFast` the second case is an out-of-bounds read rather than a panic.

## Reproduction

```zig
test "prove the panic" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\x80"));
}
```

fails with `thread panic: attempt to unwrap error: Utf8InvalidStartByte` at
`width.zig:110`. `displayWidth("\xe4\xb8")` — two bytes of a three-byte
`中`, exactly what an SSE delta boundary hands over — panics on the slice
instead.

## Root cause

`std.unicode.Utf8Iterator.nextCodepointSlice` in Zig 0.16 is

```zig
const cp_len = utf8ByteSequenceLength(it.bytes[it.i]) catch unreachable;
it.i += cp_len;
return it.bytes[it.i - cp_len .. it.i];
```

so an invalid start byte panics on the `catch unreachable`, and a sequence the
slice cuts short advances `i` past `bytes.len` and slices past the end. Both
happen before the `utf8Decode(slice) catch` inside `displayWidth`'s loop can
run, so the module's documented contract ("invalid UTF-8 bytes count as width
1 each so a malformed string still lays out deterministically instead of
erroring mid-render") could not hold. `truncateToWidth`, `lineRows` and
`nextCell` drove the same iterator.

## Resolution

`width_mod.nextCodepoint` advances one byte and yields it alone when the start
byte is not a start byte or when the slice cuts the sequence short.
`displayWidth`, `truncateToWidth`, `lineRows`, `mdLineRows` and `nextCell` all
walk with it. A second std trap came with it: `utf8Decode` returns a one-byte
slice's byte verbatim, so a lone `0x80` would have "decoded" into a C1 control
of width 0 rather than counting as the broken byte it is — `decodeOne` accepts
a one-byte codepoint only below 0x80.

## Verification

Two unit tests in `src/tui/width.zig`: "a codepoint cut short at the end of
the slice is one byte, not a panic" and "malformed bytes lay out as width 1
each, the way this module documents". The reproduction above passes after the
fix. `clanker gate` green (all eleven checks).

## Follow-up

`src/tui/repl.zig` still never sanitizes encoding upstream of the width math
(it does not import `src/util/utf8.zig`), so malformed bytes reach the
terminal as themselves. That is now a layout question rather than a crash.

## References

- Investigation: none yet
