# Investigation — REPL UI thread and run worker allocate from one unlocked ArenaAllocator

## TL;DR

- **Question:** Model.arena (src/tui/repl.zig) is the process Init arena, a plain ArenaAllocator with no locking; runThreadMain hands it to Agent.init on the worker while the UI thread keeps allocating from it mid-turn (draw loop, steerWhileRunning). bridge_mutex guards self.lines, not the arena. Call sites checked 2026-08-22; no crash observed, impact unverified.
- **Finding:** Closed on 2026-08-23. Traced to no defect on Zig 0.16: std.heap.ArenaAllocator documents its Allocator threadsafe given a threadsafe child and implements alloc/resize/remap/free with atomics, and std.process.Init documents both arena and gpa as threadsafe. Only deinit/reset/queryCapacity are not, and none run while a worker lives. self.lines is the unlocked type and is already fully bridge_mutex-guarded on both the append and draw-read sides. The false safety rationale in Model.submit's comment is corrected.
- **Resolution:** Closed on 2026-08-23. Traced to no defect on Zig 0.16: std.heap.ArenaAllocator documents its Allocator threadsafe given a threadsafe child and implements alloc/resize/remap/free with atomics, and std.process.Init documents both arena and gpa as threadsafe. Only deinit/reset/queryCapacity are not, and none run while a worker lives. self.lines is the unlocked type and is already fully bridge_mutex-guarded on both the append and draw-read sides. The false safety rationale in Model.submit's comment is corrected.

## Status

Closed on 2026-08-23. Traced to no defect on Zig 0.16: std.heap.ArenaAllocator documents its Allocator threadsafe given a threadsafe child and implements alloc/resize/remap/free with atomics, and std.process.Init documents both arena and gpa as threadsafe. Only deinit/reset/queryCapacity are not, and none run while a worker lives. self.lines is the unlocked type and is already fully bridge_mutex-guarded on both the append and draw-read sides. The false safety rationale in Model.submit's comment is corrected.

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

## Root cause and resolution (2026-08-23)

Traced to no defect. The premise is wrong on Zig 0.16, and the load-bearing
evidence is the standard library rather than a test.

- `std/heap/ArenaAllocator.zig`, file doc comment: *"The `Allocator`
  implementation provided is threadsafe, given that `child_allocator` is
  threadsafe as well."* Not aspirational: `alloc`, `resize`, `remap` and `free`
  are implemented with `@atomicLoad` / `@cmpxchgStrong` / `@cmpxchgWeak` /
  `@atomicRmw` over `state.used_list`, `state.free_list` and `Node.size`, with
  documented acquire/release pairings. `deinit`, `reset` and `queryCapacity`
  each carry an explicit `/// Not threadsafe.`
- `std/process.zig`, `Init.arena`: *"Permanent storage for the entire process,
  cleaned automatically on exit. **Threadsafe.**"* And `Init.gpa`, the child
  allocator: *"Threadsafe."* `Model.arena` is exactly `init.arena.allocator()`.

So the mechanism this record proposed -- concurrent allocation corrupting the
arena's free list -- cannot occur. This answers the record's own "Not checked"
item ("whether `std.heap.ArenaAllocator` in Zig 0.16 mutates shared state on
every `alloc`"): it does, and it does so atomically, on purpose.

The three non-threadsafe operations are the ones nobody runs while a worker is
alive. `cmdReplVaxis` joins the worker (`bridge_stop_flag` + `askCancelPending`
+ `t.join()`) before returning, and the runtime destroys `init.arena` after
`main`.

Corroboration, offered as corroboration and not proof: two threads x 20k
allocations from one plain `ArenaAllocator`, each filling every block with its
own byte pattern and re-reading it afterwards. 5 runs, 0 overlaps. A race that
fails to reproduce five times is not thereby refuted, which is why the finding
does not rest on this.

### The thing that genuinely is not threadsafe is already guarded

`self.lines` is a plain `ArrayList`, and a concurrent append that reallocates
under a reader is a real hazard. Checked at the call sites rather than assumed:

- Worker-side appends -- `finishTurn`, `tuiGoalLoopDecision` -- hold
  `bridge_mutex`.
- `typeErasedDrawFn` holds `bridge_mutex` across the whole `self.lines` read
  loop, not merely the streaming snapshot, and drains `bridge_log_lines` inside
  that section so an append cannot reallocate mid-iteration. `scrollBounds`
  takes it too.
- The UI thread's *unlocked* appends (the unknown-slash-command line, the
  command arms) are only reachable when `bridge_streaming == false`, and that
  flag is cleared only in the `.tick` handler *after* `t.join()`. So "not
  streaming" really does mean "no worker exists".

That audit, not the arena docs, is what supports "no residual race at this
seam".

### What was actually wrong

The record was reading a comment, and the comment was wrong. `Model.submit`
gave the arena as a reason for the one-turn-at-a-time rule and named a
consequence -- "corrupt the arena's free-list" -- that cannot happen. The rule
itself is right, for `self.lines` and for the message list the worker appends to
through `Agent.run`, so the rule stays and only its stated reason changes.
Corrected in `src/tui/repl.zig`, with a pointer back to this record, because
left alone it sends the next reader down exactly this path.

One route this record proposed is worth explicitly declining: wrapping the arena
in a locking allocator would serialize every draw-loop allocation to buy nothing
at all. There is no `std.heap.ThreadSafeAllocator` in Zig 0.16 either -- it
would have had to be written -- so the cost of taking the record at face value
would not have been small.