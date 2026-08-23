# Bug — the persistent-learnings prompt section keeps the oldest 4 KiB, so every note past the cap is invisible forever

## TL;DR

- **What failed:** state/learnings.md is append-only with the newest note last, but the system prompt capped it with utf8.cap, a prefix cap. Once the file passed max_learnings_prompt_bytes (4096) the section froze on the notes written first and every note note_write added after that was invisible to every future prompt, while the tool kept answering {ok:true}. The cap's own docstring says keep recent notes.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. learningsTail keeps the newest max_learnings_prompt_bytes on a line boundary; unit test asserts newest-present and oldest-absent, and a live run over a 27 KiB learnings.md quoted the newest note.

## Status

Resolved on 2026-08-23. learningsTail keeps the newest max_learnings_prompt_bytes on a line boundary; unit test asserts newest-present and oldest-absent, and a live run over a 27 KiB learnings.md quoted the newest note.

## Symptom and impact

`state/learnings.md` is the agent's persistent memory. The `note_write` guest
appends one `- <note>\n` line per note, newest last (`tools/zig/write_note.zig`
`lib.fsAppend`), and nothing anywhere bounds the file.

The system prompt capped that file at `max_learnings_prompt_bytes` (4096) with
`utf8.cap`, which returns a **prefix**. So the Learnings section showed the
first ~40-60 notes the agent ever wrote and nothing else. Past that point every
note the agent wrote was invisible to every future prompt, and `note_write`
kept answering `{"ok":true}`, so nothing surfaced the loss.

The cap's own docstring states the opposite intent:

> Persistent learnings section in the system prompt: enough to keep recent
> notes, not enough to crowd out skills and instructions.

## Reproduction

```bash
python3 - <<'PY'
lines = ["- OLDEST-CANARY-ZEBRA is the very first note ever written.\n"]
lines += ["- filler note %04d: occupying bytes.\n" % i for i in range(300)]
lines += ["- NEWEST-CANARY-QUOKKA is the most recently written note.\n"]
open('state/learnings.md','w').write(''.join(lines))
PY
clanker run 'Answer from your own system prompt only; call no tools. In your Learnings (persistent memory) section, quote verbatim the note that mentions a CANARY.'
```

Before the fix the answer is `OLDEST-CANARY-ZEBRA…`; the newest note is not in
the prompt at all.

## Root cause

`src/agent/system_prompt.zig`:

```zig
if (l.len > max_learnings_prompt_bytes) {
    try buf.appendSlice(arena, utf8.cap(l, max_learnings_prompt_bytes));
    try buf.appendSlice(arena, "...");
```

`utf8.cap` is documented as a prefix cap (`src/util/utf8.zig`: "a prefix of at
most `max_bytes` that ends on a codepoint boundary"). Pairing a prefix cap with
an append-newest-last writer keeps exactly the wrong end.

Two neighbours already do this correctly and were the pattern to copy:
`src/agent/auto_learn.zig` (`lines.items.len - keep_lines`) and
`src/improve/history.zig` (`tailLines`). Neither is byte-based, so neither was
directly reusable.

## Resolution

`src/agent/system_prompt.zig` gains a private `learningsTail(text, max_bytes)`:
it takes the last `max_bytes`, then advances past the first newline inside that
window so the section starts on a whole note rather than mid-note. A window
with no newline at all is one enormous note, and a suffix of it beats dropping
the section. The elision marker moved to the front (`[older learnings
elided]`), where the elision now is.

The result is a suffix of a valid-UTF-8 file cut at an ASCII `\n`, so it cannot
split a codepoint; no separate UTF-8 pass is needed.

## Verification

- New unit test `the learnings section keeps the newest notes, not the oldest`
  in `src/agent/system_prompt.zig`. It asserts **both** sides — the newest note
  is present *and* the oldest is absent — so a regression to a prefix cap fails
  rather than passing on "the output is shorter". It also pins the line-boundary
  cut and the single-note-longer-than-the-cap case.
- `clanker gate` green.
- Live, against deepseek-v4-pro with a 27,417-byte `state/learnings.md` built
  by the reproduction above:

  ```
  $ clanker run 'Answer from your own system prompt only; call no tools at all.
    In your Learnings (persistent memory) section, quote verbatim the single
    note that mentions a CANARY. Reply with just that one line.'
  NEWEST-CANARY-QUOKKA is the most recently written note.
  ```

## Follow-up

The file itself is still unbounded on disk. Only the prompt window is capped,
which is the right split, but a `learnings.md` in the tens of megabytes is read
in full on every prompt build (`.limited(1 << 20)` caps the read at 1 MiB, so
past that the section silently disappears entirely). Worth a bounded-tail read
rather than read-then-cap.

## References

- Code: `src/agent/system_prompt.zig` (`learningsTail`,
  `max_learnings_prompt_bytes`), `src/util/utf8.zig` (`cap`),
  `tools/zig/write_note.zig` (the append-only writer)
- Same shape, done right: `src/agent/auto_learn.zig`,
  `src/improve/history.zig` (`tailLines`)

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
