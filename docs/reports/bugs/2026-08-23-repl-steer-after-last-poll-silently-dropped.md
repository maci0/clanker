# Bug — A steer typed while the final iteration streams is echoed as queued and then discarded

## TL;DR

- **What failed:** steer_fn is polled only at the top of each agent iteration, but bridge_streaming stays true until the UI tick joins the worker, and that path never drains, delivers or reports bridge_steer. Anything typed after the last poll is echoed as queued, never seen by the model, and freed at the next turn start. The status count is gated on streaming too, so it vanishes while messages are still queued.
- **Impact:** The most natural moment to course-correct a turn — while the final answer streams — accepts the correction and throws it away.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

Mid-answer the user types a correction, sees `steering queued (1 pending)`, and the turn finishes having ignored it. The pending count also disappears the moment the turn ends while the message is still queued.

## Reproduction

Send a task, wait for the last iteration to start streaming prose, type a steer and press Enter. It echoes as queued and never reaches the model.

## Root cause

`steer_fn` is polled once per agent iteration (`src/agent/loop.zig`). `bridge_streaming` stays true until the UI tick joins the worker (`src/tui/repl.zig`), and that path never drains, delivers or reports `bridge_steer`; `clearBridgeSteer` frees it at the next turn start. The status count is gated `if (streaming and steer_pending > 0)`, so it hides a non-empty queue.

## Resolution

Open. Found by a read of the code against its own doc comments and the PRD it implements, not from a live incident.

## Verification

None yet: nothing is fixed. A fix needs a unit test at the named seam plus a live REPL turn.

## Follow-up

Either drain-or-report at turn end (a notice naming how many were not delivered, keeping the text recoverable the way the queue-full refusal does) or keep the count visible while the queue is non-empty. The poll site is in agent-core, so the fix spans two territories.

## References

- Investigation: none yet
