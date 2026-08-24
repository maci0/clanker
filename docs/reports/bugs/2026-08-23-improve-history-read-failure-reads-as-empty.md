# Bug — an unreadable or oversize improvements.jsonl reads as no history, disabling the improve loop's dedup and revert gates

## TL;DR

- **What failed:** loadAll and loadTail in src/improve/history.zig both end in catch return &.{}. append is an unbounded seekToEnd write with no trim anywhere in the module, so once state/improvements.jsonl passes the 16 MiB readFileAlloc limit every reader silently sees an empty history: fingerprintHit answers not-accepted and not-reverted, so the loop re-promotes work it already promoted and re-proposes work a human reverted. markReverted in the same file refuses to do exactly this and says why.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-24. Fixed in 17115abb; verified by clanker gate. loadAll/loadTail treat only FileNotFound as empty and propagate everything else; improve-self probes the log before spending anything and refuses to start, and a mid-run read failure stops the run instead of promoting past a blind gate. append now trims the log to its newest records at half the read cap, so it cannot reach the unreadable size. Tests assert fingerprintHit errors rather than answering not-accepted, and that the bound holds.

## Status

Resolved on 2026-08-24. Fixed in 17115abb; verified by clanker gate. loadAll/loadTail treat only FileNotFound as empty and propagate everything else; improve-self probes the log before spending anything and refuses to start, and a mid-run read failure stops the run instead of promoting past a blind gate. append now trims the log to its newest records at half the read cap, so it cannot reach the unreadable size. Tests assert fingerprintHit errors rather than answering not-accepted, and that the bound holds.

## Symptom and impact

`History.loadAll` and `History.loadTail` in `src/improve/history.zig` both end
their read in `catch return &.{}`. `History.append` is an unbounded
`seekToEnd` + write, and nothing in the module trims, so
`state/improvements.jsonl` grows for the life of the checkout. The moment it
crosses the 16 MiB `readFileAlloc` limit, `StreamTooLong` is indistinguishable
from "no history" and every reader silently sees an empty log:

- `fingerprintHit` answers `alreadyAccepted = false` and
  `revertedByHuman = false`, so the improve engine's two dedup gates stop
  firing: the loop re-promotes work it has already promoted, and re-proposes
  work a human reverted — the exact failure `reverts.zig` exists to prevent.
- `acceptedIds` comes back empty, so `contentReverts` convicts nothing.

The same file already refuses to do this, and says why, in `markReverted`:

> A log that exists but cannot be read is not "no reverts to record": the
> caller treats a zero return as the steady state and stays silent…

The two read paths that feed the gates do the thing that comment forbids.

## Reproduction

Pad `state/improvements.jsonl` past 16 MiB (or `chmod 000` it) and run
`clanker improve-self`. The dedup gates go quiet; a previously-promoted
improvement is proposed and promoted again.

## Root cause

`catch return &.{}` on a read whose failure and whose empty result mean opposite
things to the caller.

## Resolution

Fixed in 17115abb. `loadAll` and `loadTail` treat only `FileNotFound` as empty
history — that is a first run — and propagate everything else.

The engine-side decision is to not run. Every gate that reads history fails
open, and the safest thing each of them can individually do with no data adds
up to a loop with no memory, so there is no per-gate answer: `Engine.run`
probes the log with `History.checkReadable` before it spends a token and
refuses, and the `fingerprintHit` call in `improveOnce` stops the run rather
than promoting past a gate it knows is blind. `contentReverts` still convicts
nothing on a read failure (that is the safe verdict) but now says which of the
two it was.

The bound: `append` trims the log to its newest 4000 records once it passes
half the read cap, under the same lock and through `atomic_write`. Half, not
the whole cap, because an append can overshoot by at most one record — so a log
that is being written can never reach the size at which a reader gives up.

## Verification

`zig build test`, both in `src/improve/history.zig`:

- "an unreadable log is an error from the fingerprint gates, not a clean
  answer" replaces the log with a directory and asserts `checkReadable`,
  `fingerprintHit`, `alreadyAccepted`, `revertedByHuman`, `acceptedIds` and
  `recentSummary` all report it. Controls on both sides: a MISSING log stays
  silent, and the same fingerprint answers accepted while the log is readable,
  or the assertions would pass on a fingerprint that never matched.
- "append bounds the log so it can never grow past what a reader accepts" pads
  the log past the trim threshold, appends one record, and asserts the file
  came back under the threshold with the new record kept, the oldest dropped,
  and every kept record still parsing.

## Follow-up

The engine's `liveGate` cache invalidation was audited alongside this and is
correct. The invariant test that guards it (`engine.zig`, the source-scanning
one) is vacuous, though: it matches the first `mergeBack` call in the file — the
end-of-run stranded-commit fold, which needs no invalidation — and then any
`invalidateLiveGate()` anywhere after it, so it would pass with the real
invalidation deleted.

Still open as of 17115abb: a vacuous test is a separate defect in a separate
test, and folding it into this fix would have put an unrelated change in the
same commit.

## References

- Code: `src/improve/history.zig` (`loadAll`, `loadTail`, `append`,
  `markReverted`, `tailLines`), `src/improve/engine.zig` (the dedup gates,
  `contentReverts`), `src/improve/reverts.zig`

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
