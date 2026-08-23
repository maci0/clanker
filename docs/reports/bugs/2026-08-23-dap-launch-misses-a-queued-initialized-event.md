# Bug — DAP launch waits for an initialized event that initialize already queued, so a correct adapter times out

## TL;DR

- **What failed:** Session.launch (src/debug/dap.zig) loops while `resp == null or !saw_init` and only inspects frames it reads itself. An adapter that emits `initialized` before its initialize response has it drained into self.events by initialize's waitResponse, so saw_init stays false, launch blocks in readFrame on an idle adapter, runBounded expires, the adapter is killed and the tool returns LaunchTimeout. waitEvent pre-scans self.events for exactly this; launch omits the scan.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

`Session.launch` (`src/debug/dap.zig`):

```zig
var saw_init = false;
var resp: ?[]const u8 = null;
var spins: usize = 0;
while (spins < 64 and (resp == null or !saw_init)) : (spins += 1) {
    const frame = self.readFrame(arena) catch break;
```

`opInline` runs `initialize()` immediately before `launch()`, and
`initialize()` -> `waitResponse()` queues every `type:event` frame it reads
ahead of the matching response into `self.events`. DAP allows the adapter to
emit `initialized` at any point after it receives `initialize`, so that event
can already be in `self.events` when `launch` starts. `launch` never looks
there: `saw_init` stays false, the loop condition stays true after `resp` is
set, and `readFrame` blocks on an adapter with nothing left to say. The whole
launch rides `runBounded`, so it ends in SIGTERM/SIGKILL and
`error.LaunchTimeout` for an adapter that answered correctly.

`waitEvent` two functions up does the scan `launch` is missing:

```zig
for (self.events.items) |e| {
    if (frameIs(e, "event", event)) return;
}
```

Both in-tree fake adapters (`fake_adapter_src`, `delayed_stop_adapter_src`)
answer `initialize` with only the response and send `initialized` after the
launch request, which is the one ordering that works, so the suite is green.

Suggested pin: a fake adapter that sends `{"event":"initialized"}` before its
initialize response, driven through `handle(..., {"op":"launch",...})` with a
short `launch_timeout_ms`, asserting `"ok":true` and a surviving adapter.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
