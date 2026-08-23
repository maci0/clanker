# Bug — A reply opening with a heading or a list draws its markdown markers literally

## TL;DR

- **What failed:** finishTurn stores a reply's first line with the turn arrow prepended, so mdLineSegments sees '> ## Plan' and none of its prefix rules — heading, bullet, ordered marker, quote, table row — can fire. A reply that opens with '## Plan' drew the '##'; one that opens with a list drew the '-'. Only the first line of each reply is affected, and only while the reply is unfolded: foldForReply strips the arrow when a reply folds.
- **Impact:** Every short reply that opens with a heading or a list shows raw markdown on its first line.
- **Resolution:** Resolved on 2026-08-23. mdLineSegments emits the turn arrow as its own segment and re-enters on the remainder, so every prefix rule sees the model's own line; verified by unit test and by a before/after pty capture.

## Status

Resolved on 2026-08-23. mdLineSegments emits the turn arrow as its own segment and re-enters on the remainder, so every prefix rule sees the model's own line; verified by unit test and by a before/after pty capture.

## Symptom and impact

A reply whose first prose line is a heading renders as `› ## Plan` instead of
`› Plan` in accent bold; one opening with `- item` renders the `-` instead of
the accent bullet. Found live on a pty at 40 columns, not by reading the code.

## Reproduction

Ask the model to answer with `## Plan` as its very first line. Screen capture
before the fix:

```
11|› ## Plan                               |
12|1. outer                                |
```

and after:

```
11|› Plan                                  |
12|1. outer                                |
```

The second and later lines were always styled correctly, which is what makes
it easy to miss.

## Root cause

`finishTurn` stores a reply's first line as `turn_arrow ++ src_line`, so
`mdLineSegments` is handed `"\u{203a} ## Plan"`. Its heading, bullet,
ordered-marker, quote and table-row rules all test the *start* of the text, so
none of them fire, and the whole line falls through to `appendInline` as
prose. `foldForReply` strips the arrow when a reply is long enough to fold,
which is why the defect only shows on short replies.

## Resolution

`mdLineSegments` emits the arrow as its own segment and re-enters on the
remainder, so every prefix rule sees the model's own line. The arrow is two
columns before and after, so row measurement is unchanged.

## Verification

Unit test "a reply's first line is styled past the turn arrow" covers the
heading and bullet cases and pins that the arrow's columns still count in
`mdLineRows`. Live: the two captures above, same session, same prompt.

## Follow-up

`clanker run`'s `MdStream` has no turn arrow, so the two renderers were
disagreeing on the same reply here too; they now agree.

## References

- Investigation: none yet
