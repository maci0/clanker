# Bug — REPL log sink frees the logger's stack buffer on the first [ERROR] record

## TL;DR

- **What failed:** Since e9c70606 (2026-08-20) the REPL panics 'Invalid free' on the first [ERROR] log record of a session: logSinkWrite stored sanitizeAlloc's no-copy alias of log.log's stack buffer and drainLogLines freed it through bridge_gpa. Fixed by copying the aliased case in the sink; pinned by a unit test.
- **Impact:** Every `clanker repl` session built from e9c70606 onward aborts (core dump, terminal left on the alt screen) the moment any code path logs at `.error_` — a failed or timed-out provider request, a sandbox refusal. Sessions against providers that never error were unaffected, which is why it surfaced first on a local llamacpp server.
- **Resolution:** Resolved on 2026-08-21. logSinkWrite dupes the aliased sanitizeAlloc result; unit test 'logSinkWrite owns every record it buffers' pins it (fails before, passes after).

## Status

Resolved on 2026-08-21. logSinkWrite dupes the aliased sanitizeAlloc result; unit test 'logSinkWrite owns every record it buffers' pins it (fails before, passes after).

## Symptom and impact

`clank --model "llamacpp/qwen3.8-27b-bf-tuned"`, one turn, ~84 s later:

```
[ERROR] ts_ms=1787326626045 panic: Invalid free
thread 1880516 panic: Invalid free
/usr/lib/zig/std/heap/debug_allocator.zig:885:49: in free
    if (bucket.canary != config.canary) @panic("Invalid free");
/usr/lib/zig/std/mem/Allocator.zig:160:25: in rawFree
src/tui/repl.zig:361:47: in drainLogLines
src/tui/repl.zig:5528:22: in typeErasedDrawFn
```

The record that triggered it is lost: the sink swallowed it and the panic took the transcript with it. The provider is incidental — the trigger is the first `[ERROR]` record logged while the REPL's sink is installed. The REPL's log threshold is `.error_`, so that is also the first record the sink ever receives. A ReleaseFast build would corrupt memory silently instead of panicking.

## Reproduction

Unit test `logSinkWrite owns every record it buffers, including one sanitizeAlloc hands back unchanged` in `src/tui/repl.zig`: it hands `logSinkWrite` a stack buffer holding a control-free record and asserts the buffered entry does not point into that buffer. Before the fix it failed on that assertion (`zig build test -Dtest-filter="logSinkWrite owns"`).

Live: any REPL turn whose provider request fails, e.g. a `base_url` nothing listens on.

## Root cause

Four steps, each correct on its own:

1. `log.log` (`src/util/log.zig`) formats the record into a local `var buf: [4096]u8` and calls `s.write(s.ctx, buf[0..w.end])`. The slice is valid only until `log.log` returns.
2. `logSinkWrite` (`src/tui/repl.zig`) calls `clean(bridge_gpa, body)` to take an owned, control-stripped copy and appends the result to the global `bridge_log_lines`.
3. `clean` is `sanitize.sanitizeAlloc`, whose contract (`src/tui/sanitize.zig`) is *returns `bytes` unchanged when nothing needs stripping (common case, no allocation)*. An ordinary record has no control bytes, so the list receives a pointer into `log.log`'s stack frame, and `log.log` returns.
4. `drainLogLines` treats every entry as `bridge_gpa`-owned: arena-dupes it (reading whatever now occupies that stack slot) and `bridge_gpa.free(l)`s a stack address. `DebugAllocator.free` finds no matching bucket canary and panics. The trace names line 361 because that is the return address of the `free` call on 362.

`finishTurn` uses the same dupe-then-free pattern on `bridge_tool_lines`, but those entries are allocated by the worker callbacks, so that path is sound; the sink was the only caller feeding `sanitizeAlloc`'s no-copy path into a free.

## Resolution

`logSinkWrite` dupes the record when `sanitizeAlloc` hands back the caller's slice (`safe.ptr == body.ptr`), so every entry in `bridge_log_lines` is `bridge_gpa`-owned as `drainLogLines` assumes. `drainLogLines` is unchanged. AGENTS.md gained the caveat that `sanitizeAlloc`'s result must be duped before it is stored or freed.

## Verification

- The unit test above fails on the assertion before the fix and passes after it under `std.testing.allocator`, which also rejects a foreign free.
- `clanker gate` green in the fix worktree.

## Follow-up

None. `sanitizeAlloc`'s no-copy return is deliberate (the common case allocates nothing) and its doc comment states it; the defect was the one caller that ignored the contract.

## References

- Investigation: none; traced directly from the panic trace.
- Introduced by e9c70606 (2026-08-20), `log: add a Sink for redirecting records; route REPL errors to the transcript`.
- `src/tui/repl.zig` `logSinkWrite` / `drainLogLines`, `src/util/log.zig` `log`, `src/tui/sanitize.zig` `sanitizeAlloc`.
