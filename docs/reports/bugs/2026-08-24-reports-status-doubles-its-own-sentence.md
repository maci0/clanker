# Bug — reports status doubles its own 'Resolved on <date>.' sentence when the note repeats it

## TL;DR

- **What failed:** status composes '<Label> on <date>. <note>', so a note that opens with that same sentence -- the natural thing to write, since it is what the finished record reads like -- lands twice in both the Status section and the TL;DR bullet
- **Impact:** Cosmetic but in the store's most machine-read line, and it lands in two of the three places a record states its state. Reproduced.
- **Resolution:** Resolved on 2026-08-24. doc.stripStatusEcho absorbs a note that opens with the tool's own sentence; narrow so authored prose starting with the label survives

## Status

Resolved on 2026-08-24. doc.stripStatusEcho absorbs a note that opens with the tool's own sentence; narrow so authored prose starting with the label survives

## Blocked on

## Symptom and impact

`reports status` composes the status line itself:

```zig
"{s} on {s}. {s}"   // label, date, note
```

A caller whose note opens with that same sentence gets it twice. Observed:

```
- **Resolution:** Resolved on 2026-08-24. Resolved on 2026-08-24. testing the doubling claim

## Status

Resolved on 2026-08-24. Resolved on 2026-08-24. testing the doubling claim
```

Writing the echo is the natural mistake, because it is exactly what the
finished record reads like — a caller composing "Resolved on <date>. <what
changed>" is writing the line they expect to see. The damage is small per
record and lands in two of the three places a record states its state (the
`## Status` section and the TL;DR `**Resolution:**` bullet), which are the
lines other tooling reads.

## Reproduction

```
clanker reports create bug "$(date -u +%Y-%m-%d)-probe" "probe" "probe TL;DR"
clanker reports status docs/reports/bugs/<slug>.md resolved "Resolved on 2026-08-24. testing"
```

The `## Status` body reads `Resolved on 2026-08-24. Resolved on 2026-08-24.
testing`. Confirmed at `ea59ba3a`.

## Root cause

`status` in `tools/zig/reports.zig` treated the note as opaque text and
concatenated it after a sentence it had just built, with no check for the
caller having written that sentence too. Same shape as the doubled `Bug — `
title prefix fixed in #383: the tool owns a piece of text, the caller
reasonably supplies it as well, and the tool concatenates instead of
absorbing.

## Resolution

New `doc.stripStatusEcho(label, note)` in `tools/zig/doc_scaffold.zig` (the
host-tested logic module the record stores already share), called from
`status` before the note is used.

Deliberately narrow: it strips only a literal `<Label> on ` opening, up to and
including the first `.` that follows. An authored sentence that merely starts
with the label — "Resolved by reverting the merge" — means something, and
losing its first clause would be worse than the doubling. An unterminated
phrase ("Resolved on a hunch") is ambiguous, so it is left whole, and another
status's echo is not this status's echo.

Stripped *before* the existing "a resolved record needs a note" guard, so a
note consisting of nothing but the echo carries no evidence and is refused
with the message that says what to write, rather than silently accepted.

## Verification

Unit: `stripStatusEcho absorbs the tool's own sentence and keeps authored
prose` in `doc_scaffold.zig` — echo absorbed for two labels and arbitrary
dates with surrounding whitespace, authored prose starting with the label kept
whole, unterminated phrase kept, foreign label's echo kept, echo-only note
reduced to empty. `doc_scaffold` is in `host_tested_helpers` in `build.zig`,
so these run in `zig build test`.

Live, against the rebuilt guest, all three paths:

- echo note ⇒ `Resolved on 2026-08-24. fixed by the strip` (single, was double)
- `"Resolved by reverting the merge, which is authored prose"` ⇒ kept whole
- `"Resolved on 2026-08-24."` alone ⇒ refused: "a resolved record needs a note
  naming the fix and what verified it"

All twelve gate checks pass.

## Follow-up

Reported by a peer session as a mechanical gotcha alongside a second one worth
recording here, since it is unfixed and will bite the next caller:
**`--replace-all` must precede the `--` terminator** on `reports update`, or it
parses as a positional. Not filed separately; it is an argument-order
surprise in the CLI wrapper rather than a defect in the store, and nothing
silently corrupts a record when it happens.

## References

- Code: `tools/zig/reports.zig` (`status`), `tools/zig/doc_scaffold.zig`
  (`stripStatusEcho`)
- Prior art: the doubled `Bug — ` title prefix, fixed in #383 — same
  tool-owns-the-text shape
- Investigation: none
