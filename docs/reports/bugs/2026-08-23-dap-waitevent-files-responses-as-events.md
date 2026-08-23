# Bug — DAP waitEvent appends every frame to the event queue, so attach can lose its own response

## TL;DR

- **What failed:** waitEvent (src/debug/dap.zig) appends each frame it reads to self.events, event or not, where waitResponse beside it queues only type:event frames. In attach(), an attach response arriving before the initialized event is consumed into the event queue: the following waitResponse can never match it, attach swallows the error into the literal {"ok":true}, and writeEvents splices a type:response object into the tool's events array as if it were an adapter event.
- **Impact:** Against an adapter that answers `attach` before it emits `initialized`, the attach response was consumed as an event: the tool returned the literal `{"ok":true}` placeholder instead of the adapter's body, and the model was handed a `"type":"response"` object inside the tool's `events` array as if it were an adapter event. In the common case the following `waitResponse` then blocks on an idle adapter until the launch watchdog kills it.
- **Resolution:** Resolved on 2026-08-23. waitEvent routes non-event frames through noteFrame, which parks a response in Session.responses for the waitResponse that wants it instead of filing it as an event. Pinned by resp_first_attach_adapter_src, a real python3 adapter that answers attach before it emits initialized.

## Status

Resolved on 2026-08-23. waitEvent routes non-event frames through noteFrame, which parks a response in Session.responses for the waitResponse that wants it instead of filing it as an event. Pinned by resp_first_attach_adapter_src, a real python3 adapter that answers attach before it emits initialized.
responses as events; a response read out of turn is parked and `waitResponse`
takes it.

## Symptom and impact

Two visible symptoms from one cause. The tool's `body` is the placeholder
rather than the adapter's response, so nothing the adapter said about the
attach reaches the caller; and `renderResult`/`writeEvents` splice the raw
response frame into `"events"`, so the model reads a request/response envelope
as a debug event.

## Reproduction

`resp_first_attach_adapter_src` in src/debug/dap.zig: a stdio adapter whose
`attach` branch sends the response immediately and the `initialized` event
~50 ms later from a thread. Driven through `handle(..., {"op":"attach",...})`.

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

`waitEvent`'s blind `self.events.append` became `try self.noteFrame(frame)`.
`noteFrame` already filed `type:event` frames and dropped everything else; it
now parks a frame carrying a `request_seq` in a new `Session.responses` list
instead of dropping it, capped at `max_parked_responses` (32, oldest evicted).
`waitResponse` checks that list first via `takeParkedResponse`, which hands the
frame back in the caller's arena and frees the gpa copy, so no lifetime rule
changes. The list is freed in `deinit` and cleared in `spawnAdapter` alongside
`events`. `drainAvailable` shares `noteFrame`, so an opportunistic drain no
longer discards a response either.

## Verification

New test "an attach response arriving before initialized is not filed as an
event" (src/debug/dap.zig), against a real `python3` adapter. It parses the
returned JSON and asserts `body.body.attached` is the adapter's own value (not
the placeholder) and that every element of `events` has `"type":"event"`. The
test fails when `noteFrame` is swapped back for the blind append. `clanker
gate`: 11/11 PASS.

## Follow-up

`waitResponse`'s own loop still drops a non-matching, non-event frame. That is
deliberate and pre-existing - it is the one place that knows which id it wants -
but it is the same shape of loss if a second waiter ever appears.

## References

- Investigation: none yet
