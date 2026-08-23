# Bug — DAP waitEvent appends every frame to the event queue, so attach can lose its own response

## TL;DR

- **What failed:** waitEvent (src/debug/dap.zig) appends each frame it reads to self.events, event or not, where waitResponse beside it queues only type:event frames. In attach(), an attach response arriving before the initialized event is consumed into the event queue: the following waitResponse can never match it, attach swallows the error into the literal {"ok":true}, and writeEvents splices a type:response object into the tool's events array as if it were an adapter event.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

`waitEvent` (`src/debug/dap.zig`):

```zig
const frame = self.readFrame(arena) catch |err| return err;
try self.events.append(self.gpa, try self.gpa.dupe(u8, frame));
if (frameIs(frame, "event", event)) return;
```

versus `waitResponse`, which is deliberate about it:

```zig
if (frameIs(frame, "type", "event")) {
    try self.events.append(self.gpa, try self.gpa.dupe(u8, frame));
    continue;
}
if (frameRequestSeq(frame) == id) return frame;
```

`attach()` calls `waitEvent(arena, "initialized")` and then
`waitResponse(arena, id) catch "{\"ok\":true}"`. An adapter that answers
`attach` before it emits `initialized` therefore has its response eaten by
`waitEvent`; `waitResponse` cannot match it, and the placeholder is returned
in its place. `renderResult`/`writeEvents` then embed the raw frame in the
tool's `"events"` array, so the model is handed a `"type":"response"` object
labelled as an adapter event.

Suggested pin: a fake adapter whose `attach` branch sends the response first
and `initialized` ~50 ms later; assert the returned JSON's `events` array
holds no `"type":"response"` element and that `body` is the real response.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
