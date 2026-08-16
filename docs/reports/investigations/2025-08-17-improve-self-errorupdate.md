# Investigation — improve-self iterations fail on hallucinated @errorUpdate

## TL;DR

- **Question:** improve-self iterations 1 and 2 both proposed wrapping lib.hash() in tools/zig/alarm.zig load() with a context message using @errorUpdate, an invalid Zig builtin, so the staging tools build failed and the wrapper stopped after exhausting attempts. Need to determine the fixable root cause (model hallucination vs. a guardable gap in the improve loop).
- **Finding:** Duplicate of the 2026-06-12 record, which carries the evidence and the fix.
- **Resolution:** Closed as a duplicate on 2026-08-16.

## Status

Closed on 2026-08-16. duplicate of 2026-06-12-improve-self-erroreupdate-guest.md, which holds the finding and the prompt fix.

## Trigger and scope

Duplicate. The same failure — improve-self proposing `@errorUpdate` around
`lib.hash()` in `tools/zig/alarm.zig`, failing the tools gate on every attempt
of iterations 1 and 2 — was recorded twice, months apart, because nobody
searched the store before opening the second record.

## Evidence

Identical symptom, identical file, identical invented builtin.

## Hypotheses and tests

Carried in the surviving record.

## Finding

Closed as a duplicate of [improve-self iterations wasted on @errorUpdate in
WASM guest](2026-06-12-improve-self-erroreupdate-guest.md), which holds the
evidence, the finding and the fix. Kept rather than deleted: two independent
sightings are themselves evidence that the model returns to this idea.

## Resolution or handoff

None here. Follow the surviving record.

## References

- Related bug: none yet
