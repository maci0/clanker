# Bug — webui handles llm_start stream events the server never emits

## TL;DR

- **What failed:** `ui/app/app.js`'s run stream handler renders `llm_start`/`llm` events (`evt.model`) into the live run graph, but no server code path emits an event of either type.
- **Impact:** The intended live per-iteration model visibility never worked; the handler is dead code, and the live run graph shows iterations without their models.
- **Resolution:** Open.

## Status

Open.

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

Open. Either emit `llm_start` (with the active model name) at the top of each agent iteration on the serve stream path, or delete the frontend branch.

## Verification

Pending: with the emitter added, a two-iteration run's live graph should label each llm node with the model that served it; alternatively, with the branch deleted, no dead handler remains.

## Follow-up

- If the emitter is added, extend the `done`-event regression coverage to the new event type.

## References

- PR #315 — done event gained `model` and `reasoning_effort`.
