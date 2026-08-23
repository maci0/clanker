# Bug — DAP launch waits for an initialized event that initialize already queued, so a correct adapter times out

## TL;DR

- **What failed:** Session.launch (src/debug/dap.zig) loops while `resp == null or !saw_init` and only inspects frames it reads itself. An adapter that emits `initialized` before its initialize response has it drained into self.events by initialize's waitResponse, so saw_init stays false, launch blocks in readFrame on an idle adapter, runBounded expires, the adapter is killed and the tool returns LaunchTimeout. waitEvent pre-scans self.events for exactly this; launch omits the scan.
- **Impact:** Every `debug` launch against an adapter that emits `initialized` before its initialize response ends in `error.LaunchTimeout` after the full `debug.launch_timeout_ms` (15 s by default), with the adapter SIGTERMed and reaped. DAP explicitly permits that ordering, so a correct adapter was unusable and the model was told the adapter had timed out.
- **Resolution:** Resolved on 2026-08-23. Session.launch (src/debug/dap.zig) pre-scans self.events for a queued initialized before its read loop, the way waitEvent does. Pinned by early_init_adapter_src, a real python3 adapter that emits initialized before its initialize response.

## Status

Resolved on 2026-08-23. Session.launch (src/debug/dap.zig) pre-scans self.events for a queued initialized before its read loop, the way waitEvent does. Pinned by early_init_adapter_src, a real python3 adapter that emits initialized before its initialize response.
`self.events` for `initialized` before entering its read loop.

## Symptom and impact

`{"op":"launch",...}` returns
`{"ok":false,"error":"launch timed out (debug.launch_timeout_ms); adapter
terminated"}` and the adapter process is killed, for an adapter that answered
both requests correctly. Nothing about the failure names the ordering, so the
operator sees a working adapter reported as unresponsive.

## Reproduction

`early_init_adapter_src` in src/debug/dap.zig: a stdio adapter that answers
`initialize` by sending the `initialized` event first and the response second,
and answers `launch` with a response only. Driven through
`handle(..., {"op":"launch",...})` with `launch_timeout_ms = 5000`.

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

`Session.launch` now runs the same pre-scan `waitEvent` does:

```zig
var saw_init = false;
for (self.events.items) |e| {
    if (frameIs(e, "event", "initialized")) { saw_init = true; break; }
}
```

The read loop is otherwise unchanged, so an adapter that sends `initialized`
after the launch request still works exactly as before.

## Verification

New test "launch accepts an initialized event that the initialize response
already queued" (src/debug/dap.zig), driving a real `python3` adapter over real
pipes. It asserts the launch body carries the adapter's own payload and that
`reg.get` still holds the process, i.e. the watchdog did not kill it. The test
fails with `LaunchTimeout` when the pre-scan is removed. `clanker gate`: 11/11
PASS.

## Follow-up

Still no coverage against a real adapter binary; PRD 0017 keeps that as a known
issue. An attempt with Apple's `lldb-dap` on this machine got no answer to
`launch` at all - but plain `lldb -b -o run` hangs at `run` here too, so that is
the environment refusing to debug, not the client.

## References

- Investigation: none yet
