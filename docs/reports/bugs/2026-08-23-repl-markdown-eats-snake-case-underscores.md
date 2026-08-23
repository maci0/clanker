# Bug — The REPL transcript renders bridge_stream_buf as bridgestreambuf

## TL;DR

- **What failed:** appendInline (src/tui/repl.zig) treats '_' as an emphasis delimiter exactly like '*': the first underscore finds the next one and the span between them is emitted italic with both underscores dropped. Model prose in this repo is full of snake_case identifiers. The other renderer, transcript_mod.MdStream (src/tui/transcript.zig), handles only '*' and '**' and never touches '_', so the same reply reads correctly under clanker run and mangled in the REPL.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

`appendInline` (`src/tui/repl.zig`):

```zig
} else if (c == '*' or c == '_') {
    if (std.mem.findScalarPos(u8, text, i + 1, c)) |end| {
        if (end > i + 1) {
            try flush(arena, out, text[seg_start..i], st.plain);
            try out.append(arena, .{ .text = text[i + 1 .. end], .style = st.italic });
```

Any line with two underscores renders with the underscores gone:
`bridge_stream_buf` becomes `bridge` + italic `stream` + `buf`, drawn as
`bridgestreambuf`.

Two reasons this is drift rather than a style choice:

- `src/tui/transcript.zig`'s `MdStream`, the renderer PRD 0039 measures
  against, handles only `*` and `**` and has no `'_'` branch at all. The same
  answer is correct under `clanker run` and mangled in the REPL.
- The dropped bytes desync layout: `lineRows` measures the raw text while the
  render is shorter.

CommonMark's own rule is that `_` inside a word is not emphasis. A closing
`_` must not be left-flanked by an alphanumeric, and an opening `_` must not
be right-flanked by one.

Suggested pin: `mdLineSegments(&theme, arena, "see bridge_stream_buf now",
&segs)`, join `segs[*].text`, and `expectEqualStrings` the original. The
existing test at the same site only covers `**` and backticks.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
