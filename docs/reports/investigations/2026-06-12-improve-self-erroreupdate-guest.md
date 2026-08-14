# Investigation — improve-self iterations wasted on @errorUpdate in WASM guest

## TL;DR

- **Question:** improve-self exhausted iterations 1 and 2 because the model proposed wrapping lib.hash() failures with @errorUpdate in tools/zig/alarm.zig — a WASM guest, where @errorUpdate is a host-only builtin invalid in wasm32-freestanding. The tools gate failed every attempt. Root cause to confirm: improve loop has no guard/prompt preventing host-only builtins in guest code, so each iteration burns all attempts on a patch that can never compile.
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
