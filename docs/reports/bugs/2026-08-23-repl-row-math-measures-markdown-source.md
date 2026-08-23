# Bug — The REPL transcript reserves rows for the markdown source and draws the rendered form

## TL;DR

- **What failed:** lineRows measures the source bytes while the rich path draws mdLineSegments output, markers stripped. Every prose line carrying markup was measured at one width and drawn at another: the bottom-anchored window reserved rows the draw never filled, dropped a line off the top that would have fitted, folded replies that did not need it, and let the reserved live-stream block shove the completed transcript around mid-turn.
- **Impact:** Any markdown-heavy reply leaves the transcript floating clear of the composer, hides a line that would have fitted, and jumps while the next turn streams.
- **Resolution:** Resolved on 2026-08-23. mdLineRows measures a prose line by running the draw's own segment builder over a stack buffer, rowsForLine routes each Line by the draw loop's branches, and streamRows tracks fence state; three new unit tests.

## Status

Resolved on 2026-08-23. mdLineRows measures a prose line by running the draw's own segment builder over a stack buffer, rowsForLine routes each Line by the draw loop's branches, and streamRows tracks fence state; three new unit tests.

## Symptom and impact

With a reply containing headings or bold text, the newest transcript line does
not sit against the input box: one or more blank rows separate them, the count
depending on how much markup the reply used. Scrolled to the top of a window,
a line that would have fitted is missing. While a turn streams, the reserved
live block over-claims and the completed lines above it shift row by row as
tokens arrive.

## Reproduction

Narrow the terminal to ~40 columns and send a task whose answer contains a
line like `**a very long emphasised sentence that reaches the wrap column**`.
The source wraps to two rows; the drawn line, with the four marker bytes
stripped, fits in one. The layout reserves two.

## Root cause

`lineRows` (`src/tui/repl.zig`) measures the source bytes. The transcript's
rich path draws `mdLineSegments`' output, where `**`/`` ` ``/`_` markers are
gone, a `# ` prefix is stripped, `> ` becomes a `▎ ` rule and a nested list's
indent is normalised. `tailWindow`, `topWindowEnd`, `foldForReply` and
`streamRows` all measured the source while the draw rendered something else,
so `row = top + (avail_rows -| (win.used_rows + reserved))` anchored the block
against rows the draw never filled.

This is the second half of the defect
`2026-08-23-repl-markdown-eats-snake-case-underscores.md` described ("`lineRows`
measured a longer string than the draw produced"): that report fixed the
emphasis pairing, not the measurement.

## Resolution

`mdLineRows` measures a prose line by running the *same* segment builder the
draw runs, over a stack buffer, so measurement and draw cannot drift the way a
second hand-rolled parser would; a line with more markup runs than the buffer
holds falls back to the source measurement. `rowsForLine` routes each `Line`
by the draw loop's own branches — the user's echo, dim notices and tool cards,
`error:` lines and fenced code are drawn literally and keep the source
measurement. `streamRows` takes `writeStream`'s `fence_on` and tracks fence
state, so a fence body (styled, never reshaped) is still measured literally.

## Verification

Three unit tests: "a markdown line is measured as it draws, not as it was
typed", "tailWindow anchors a markdown reply by its drawn height" and
"streamRows measures out-of-fence prose rendered and a fence body literally".
`clanker gate` green (all eleven checks), plus a live REPL turn watched on a
pty at 40 columns.

## Follow-up

`writeWrappedSegments` measures with vaxis' grapheme-aware `ctx.stringWidth`
while both row counters use `width_mod.displayWidth`. That divergence predates
this fix and is unchanged by it.

## References

- Investigation: none yet
