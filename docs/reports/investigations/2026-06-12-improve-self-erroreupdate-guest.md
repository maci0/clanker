# Investigation — improve-self iterations wasted on @errorUpdate in WASM guest

## TL;DR

- **Question:** improve-self exhausted iterations 1 and 2 because the model proposed wrapping lib.hash() failures with @errorUpdate in tools/zig/alarm.zig — a WASM guest, where @errorUpdate is a host-only builtin invalid in wasm32-freestanding. The tools gate failed every attempt. Root cause to confirm: improve loop has no guard/prompt preventing host-only builtins in guest code, so each iteration burns all attempts on a patch that can never compile.
- **Finding:** A guardable gap: the improve prompt never said tools/zig guests are wasm32-freestanding, and an invented builtin is only caught by the per-attempt tools gate.
- **Resolution:** Prompt fixed on 2026-08-16; a pre-gate builtin check is the open follow-up.

## Status

Resolved on 2026-08-16. improve_system now states the guest compilation target and its constraints; a pre-gate builtin check remains as a named follow-up in this record.

## Trigger and scope

improve-self exhausted iterations 1 and 2 proposing a `@errorUpdate` wrapper
around `lib.hash()` in `tools/zig/alarm.zig`. `@errorUpdate` is not a Zig
builtin at all, so the tools gate failed every attempt of both iterations.
Scope is the improve loop's guidance, not that one patch.

This record absorbs [improve-self iterations fail on hallucinated
@errorUpdate](2025-08-17-improve-self-errorupdate.md), which is the same
failure on the same file.

## Evidence

- Both batches burned every attempt on a patch that could not compile.
- The same idea recurred across separate runs months apart, so it is a
  standing bias of the model on this file, not one bad sample.
- `tools/zig/` and `tools/ts/` compile to wasm32-freestanding. A guest has no
  libc and no host-only builtins; everything it reaches goes through the
  `ck_*` imports in `tools/zig/lib.zig`.

## Hypotheses and tests

Two candidates: plain model hallucination, or a gap in what the loop tells the
model. Reading `improve_system` in `src/improve/engine.zig` settled it — the
prompt described the project as a "zwasm WebAssembly tool sandbox" but never
said that files under `tools/zig/` are themselves guests, or what that forbids.
The loop pins `tools/zig/lib.zig` into context for a tools instruction
(`engine.zig`, the `pinNamedFiles` call), which supplies the ABI but not the
constraint.

## Finding

A guardable gap, not just hallucination. Nothing in the loop stated the guest
compilation target or its consequences, and nothing failed the shape early:
an invented builtin is only caught by the tools gate, which is per-attempt, so
one bad idea consumes a whole iteration.

## Resolution or handoff

`improve_system` in `src/improve/engine.zig` now states that `tools/zig/` and
`tools/ts/` are wasm32-freestanding guests, that a builtin absent from the Zig
language reference does not exist, and that guest error context goes through
`lib.fail`/`lib.failErr`. It names `@errorUpdate` explicitly, since that is the
specific attractor this loop has fallen into.

Open follow-up: the prompt makes the failure less likely but nothing rejects an
invented builtin before the tools gate spends an attempt on it. A cheap
pre-gate check over a staged guest patch — reject `@` identifiers that are not
in Zig's builtin list — would turn a wasted iteration into an immediate retry.

## References

- Related bug: none yet
