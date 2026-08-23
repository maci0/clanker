# Bug — an unreadable or oversize improvements.jsonl reads as no history, disabling the improve loop's dedup and revert gates

## TL;DR

- **What failed:** loadAll and loadTail in src/improve/history.zig both end in catch return &.{}. append is an unbounded seekToEnd write with no trim anywhere in the module, so once state/improvements.jsonl passes the 16 MiB readFileAlloc limit every reader silently sees an empty history: fingerprintHit answers not-accepted and not-reverted, so the loop re-promotes work it already promoted and re-proposes work a human reverted. markReverted in the same file refuses to do exactly this and says why.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

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

Open. `loadAll`/`loadTail` should return the error and let the engine decide, or
at minimum log at error and set a flag the gates read as "unknown" rather than
"clean". Separately the log wants a bound: `tailLines` already exists in this
module for exactly that shape.

## Verification

Needs a test that makes the read fail (an oversize or unreadable file) and
asserts `fingerprintHit` does not answer "not accepted".

## Follow-up

The engine's `liveGate` cache invalidation was audited alongside this and is
correct. The invariant test that guards it (`engine.zig`, the source-scanning
one) is vacuous, though: it matches the first `mergeBack` call in the file — the
end-of-run stranded-commit fold, which needs no invalidation — and then any
`invalidateLiveGate()` anywhere after it, so it would pass with the real
invalidation deleted.

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
