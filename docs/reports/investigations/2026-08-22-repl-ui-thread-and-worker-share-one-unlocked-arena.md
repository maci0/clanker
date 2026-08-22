# Investigation — REPL UI thread and run worker allocate from one unlocked ArenaAllocator

## TL;DR

- **Question:** Model.arena (src/tui/repl.zig) is the process Init arena, a plain ArenaAllocator with no locking; runThreadMain hands it to Agent.init on the worker while the UI thread keeps allocating from it mid-turn (draw loop, steerWhileRunning). bridge_mutex guards self.lines, not the arena. Call sites checked 2026-08-22; no crash observed, impact unverified.
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
## What was checked

- `cmdReplVaxis` (`src/tui/repl.zig`): `const arena = init.arena.allocator();` and `.arena = arena` in the `Model` literal, so the model's arena is `std.process.Init`'s `std.heap.ArenaAllocator`.
- `runThreadMain`: `Agent.init(&self.ctx, self.arena, &self.provider, &self.cfg, &self.reg, self.tool_defs)` — the worker's agent allocates from the same arena for the whole turn, outside `bridge_mutex`.
- `Model.submit`'s comment states the constraint in its own words: *self.arena is a plain ArenaAllocator (no internal locking)*, and gives it as the reason a second turn may never start.
- UI-thread allocations from `self.arena` while `bridge_streaming` is true: `steerWhileRunning` (`allocPrint` for the echo and refusals, under `bridge_mutex`), the mid-run command arm added for the slash-command bug, and the draw loop's `allocPrint(self.arena, ...)` sites (66 in the file; which of them run per frame during a turn was not enumerated).

## Not checked

- Whether `std.heap.ArenaAllocator` in Zig 0.16 mutates shared state on every `alloc` (it did in earlier releases: the bump offset and the buffer list), so whether a concurrent pair of allocations corrupts the arena or only races benignly is unverified here.
- No reproduction was attempted and no crash was observed in the session that filed this; that is absence of evidence, not evidence of safety, and says nothing about ReleaseFast.

## Possible routes

- Give the worker its own arena per turn (`Agent.init` with a turn-scoped `ArenaAllocator` the worker owns, reset at join), leaving `self.arena` to the UI thread.
- Or wrap the shared arena in `std.heap.ThreadSafeAllocator`, which serializes every allocation including the draw loop's.
