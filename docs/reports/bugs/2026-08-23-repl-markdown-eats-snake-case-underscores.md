# Bug — The REPL transcript renders bridge_stream_buf as bridgestreambuf

## TL;DR

- **What failed:** appendInline (src/tui/repl.zig) treats '_' as an emphasis delimiter exactly like '*': the first underscore finds the next one and the span between them is emitted italic with both underscores dropped. Model prose in this repo is full of snake_case identifiers. The other renderer, transcript_mod.MdStream (src/tui/transcript.zig), handles only '*' and '**' and never touches '_', so the same reply reads correctly under clanker run and mangled in the REPL.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. `appendInline` (src/tui/repl.zig) no longer shares one branch between `*` and `_`: `_` goes through `underscoreEmphasisEnd`, which applies CommonMark's intraword rule (an opener may not follow a word byte, a closer may not precede one), so snake_case identifiers keep every byte and word-boundary `_emphasis_` still italicises. `*` is unchanged. Pinned by the unit test "snake_case identifiers survive inline markdown, spaced _emphasis_ still works"; clanker gate green on all eleven checks; confirmed live over a pty against deepseek.

## Status

Resolved on 2026-08-23. `appendInline` (src/tui/repl.zig) no longer shares one branch between `*` and `_`: `_` goes through `underscoreEmphasisEnd`, which applies CommonMark's intraword rule (an opener may not follow a word byte, a closer may not precede one), so snake_case identifiers keep every byte and word-boundary `_emphasis_` still italicises. `*` is unchanged. Pinned by the unit test "snake_case identifiers survive inline markdown, spaced _emphasis_ still works"; clanker gate green on all eleven checks; confirmed live over a pty against deepseek.

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

`appendInline` (`src/tui/repl.zig`) had one branch for both delimiters:

```zig
} else if (c == '*' or c == '_') {
```

It is now two. `*` keeps the old scan — CommonMark does allow intraword `*`,
and nothing in the repo's prose trips over it. `_` calls a new
`underscoreEmphasisEnd(text, open)`, which answers null unless the run is
real emphasis:

- an opener may not be preceded by a word byte (`bridge_` is not an opener),
- an opener may not be followed by a space or tab (`a _ b` stays literal),
- the closer is the first later `_` that is not followed by a word byte and
  not preceded by a space, so `the _snake_case field_ here` closes after
  `field` rather than inside the identifier.

"Word byte" is ASCII alphanumeric plus every byte >= 0x80: a UTF-8 letter is
not punctuation, and treating it as such would re-open the same bug for
non-ASCII prose.

## Verification

Unit test `snake_case identifiers survive inline markdown, spaced _emphasis_
still works` (`src/tui/repl.zig`), confirmed failing on the pre-fix code:
`see bridge_stream_buf now` joined back as `see bridgestreambuf now`. It
covers one identifier, two identifiers on one line (the old scan paired the
first `_` of one with the first `_` of the next), `_really_` still going
italic, `_snake_case field_` closing at the word boundary, and `*b*`
unchanged.

`clanker gate` green on all eleven checks, on 52bfc739 + this change.

Live, over a real pty (100x30, TIOCSWINSZ) with
`--provider deepseek --model deepseek-v4-flash`, asking for the sentence
`The field bridge_stream_buf holds the text.` back verbatim:

- pre-fix binary built from an untouched 52bfc739 worktree, transcript row:
  `The field bridgestreambuf holds the text.`
- post-fix binary, same prompt, same model:
  `The field bridge_stream_buf holds the text.`

## Follow-up

## References

- Investigation: none yet
