# Bug — webui handles llm_start stream events the server never emits

## TL;DR

- **What failed:** `ui/app/app.js`'s run stream handler renders `llm_start`/`llm` events (`evt.model`) into the live run graph, but no server code path emits an event of either type.
- **Impact:** The intended live per-iteration model visibility never worked; the handler is dead code, and the live run graph shows iterations without their models.
- **Resolution:** Resolved on 2026-08-22. serve's streaming /api/run now emits an llm_start frame per agent iteration; e2e + unit tests pin it, clanker gate passes

## Status

Resolved on 2026-08-22. serve's streaming /api/run now emits an llm_start frame per agent iteration; e2e + unit tests pin it, clanker gate passes

## Symptom and impact

`ui/app/app.js` (chat submit handler, stream splitter) contains:

```js
else if (evt.type === "llm_start" || evt.type === "llm") { pushLiveNode("llm", evt.model||"llm", evt.model||"llm", 0); }
```

`grep -rn "llm_start" src/` finds no emitter; `writeStreamEvent` call sites in `src/cli.zig` emit `tool_call`, `tool_result`, `todos`, `goal`, `status`, `ask`, `confirm`, `error`, `usage`, `done` — never `llm_start` or `llm`. The branch is unreachable.

PR #315 (2026-08-22) added the serving model and pinned reasoning effort to the `done` event and renders them in the turn footer, which covers per-turn visibility after the fact. The live per-iteration case remains unserved.

## Reproduction

Run any webui chat turn and capture the stream: no frame with `"type":"llm_start"` or `"type":"llm"` ever arrives.

## Root cause

Frontend was written against an event the backend never grew (or lost); no test pinned the contract in either direction.

## Resolution

Emitted. `src/agent/loop.zig` fires `on_llm_start` at the top of each agent iteration; `src/cli.zig`'s streaming `/api/run` path frames it. The frontend branch was kept, not deleted.

## Verification

`tests/e2e/run_stream_llm_start_test.zig` drives the real binary's `clanker serve` against a scripted mock provider, POSTs `/api/run` with `stream: true`, and asserts the stream carries an `llm_start` frame naming `e2e-mock`/`mock` at iteration 0, ahead of the `done` trailer. Confirmed to fail when the expected provider name is altered, so it reads the frame rather than passing vacuously. A unit test in `src/cli.zig` pins the wire shape of the frame itself (one `\x01` line, one newline, the four fields). `clanker gate` passes.

## Follow-up

- If the emitter is added, extend the `done`-event regression coverage to the new event type.

## References

- PR #315 — done event gained `model` and `reasoning_effort`.
## Fix

The agent loop grew an `on_llm_start` hook (`src/agent/loop.zig`), fired at the
top of each iteration just before that iteration's request goes out, with the
provider name, the model about to serve it, and the zero-based iteration
number. `clanker serve`'s streaming `/api/run` path wires it to
`runStreamLlmStart` (`src/cli.zig`), which frames it as one `\x01` control
line: `{"type":"llm_start","served_by":...,"model":...,"iteration":N}`.

Field names are the `done` trailer's on purpose, so a client keeps one
vocabulary for "who served this" rather than two. `served_by` here is who the
turn *started* on; the fallback chain can still repoint it, which is why
`done` remains the record of who finished it.

The web UI branch is unchanged — it reads `evt.model`, which the frame now
carries.