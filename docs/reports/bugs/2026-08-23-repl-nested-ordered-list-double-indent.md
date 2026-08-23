# Bug — A nested ordered list in the REPL indents twice as far as the bullet beside it

## TL;DR

- **What failed:** mdLineSegments emitted the source indent AND a normalised two-columns-per-level indent for an ordered-list marker, where the bullet branch emits one or the other. So '  1. x' drew four columns in and '    1. x' eight, an ordered sub-list stepped twice as far right as the bullet sub-list at the same depth, and the drawn row came out wider than lineRows had measured, clipping the tail of a full-width line.
- **Impact:** Every nested ordered list in the REPL transcript reads as one level deeper than it is, and a full-width one loses its tail.
- **Resolution:** Resolved on 2026-08-23. The ordered-list branch of mdLineSegments now makes the same either/or indent choice the bullet branch makes; pinned by the ordered-vs-bullet lead-width assertions in the inline-markdown test.

## Status

Resolved on 2026-08-23. The ordered-list branch of mdLineSegments now makes the same either/or indent choice the bullet branch makes; pinned by the ordered-vs-bullet lead-width assertions in the inline-markdown test.

## Symptom and impact

A model reply containing a nested ordered list renders its sub-items twice as
far right as the bullet sub-items around them, so the list's shape no longer
tells the reader its depth. The same reply reads correctly under `clanker run`,
whose `MdStream` is a different renderer.

## Reproduction

Send a reply containing:

```
1. top
  1. nested
    1. deeper
```

In `clanker repl` the second item draws four columns in and the third eight,
against two and four for the same list written with `-` bullets.

## Root cause

`mdLineSegments` (`src/tui/repl.zig`) had two indent emitters in one branch:

```zig
if (indent > 0) try out.append(arena, .{ .text = text[0..indent], ... });
const level = indent / 2;
for (0..level) |_| try out.append(arena, .{ .text = "  ", ... });
```

The bullet branch below it makes the same decision as an either/or — the
source indent for a depth-0 marker, a normalised two-columns-per-level indent
for a nested one. The ordered branch emitted both, so the indent doubled with
depth. The drawn row was then wider than `lineRows` had measured for it, which
clipped the tail of a line already near the wrap column.

## Resolution

The ordered branch now makes the bullet branch's either/or choice. Pinned by
"inline markdown splits into styled segments and leaves plain text whole",
which asserts the ordered lead width equals the bullet lead width at the same
depth, and that depth 2 is four columns.

## Verification

`clanker gate` green (all eleven checks) and a live `clanker repl` turn that
asked the model for a nested ordered list, read back off the pty capture.

## Follow-up

None. PRD 0039's goal 3 (correct nesting indentation) now holds for ordered
lists as well as bullets.

## References

- Investigation: none yet
