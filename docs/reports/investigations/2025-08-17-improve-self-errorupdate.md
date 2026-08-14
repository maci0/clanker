# Investigation — improve-self iterations fail on hallucinated @errorUpdate

## TL;DR

- **Question:** improve-self iterations 1 and 2 both proposed wrapping lib.hash() in tools/zig/alarm.zig load() with a context message using @errorUpdate, an invalid Zig builtin, so the staging tools build failed and the wrapper stopped after exhausting attempts. Need to determine the fixable root cause (model hallucination vs. a guardable gap in the improve loop).
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
