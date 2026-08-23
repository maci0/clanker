# Bug — DAP stop events were attached to the next tool call

## TL;DR

- **What failed:** drainAvailable never read the pipe, so a stopped event arriving after continue's response surfaced on whatever call came next; fixed by fillAvailable (zero-timeout poll drain) plus a bounded, non-killing stop wait on resuming ops (HandleOpts.stop_wait_ms). PR 349.
- **Impact:** An agent driving the debugger could not see that execution had stopped from the `continue` result itself; the `stopped` event surfaced attached to whatever tool call came next (a `variables` or `stack_trace` it happened to issue), so breakpoint hits were invisible or misattributed in every DAP session.
- **Resolution:** Resolved on 2026-08-23. Fixed in PR 349 (merged 2026-08-23); verified by the delayed-stop adapter tests in src/debug/dap.zig and a green gate.

## Status

Resolved on 2026-08-23. Fixed in PR 349 (merged 2026-08-23); verified by the delayed-stop adapter tests in src/debug/dap.zig and a green gate.

## Symptom and impact

PRD 0017 listed "event buffering is drain-on-next-read" as a known issue. It was worse: `Session.drainAvailable` (src/debug/dap.zig) only decoded frames already in `Session.buf` — bytes a previous blocking read happened to over-read — and never read the pipe itself. A `stopped` event sitting unread in the OS pipe was invisible until the next request's response wait swallowed it, so `continue` to a breakpoint essentially never reported its own stop.

## Reproduction

Pinned by the delayed-stop adapter tests in src/debug/dap.zig: a fake stdio DAP server (python) that sends `stopped` 150ms after the `continue` response. Before the fix, the `continue` result's `events` array was empty and the event appeared on the next call.

## Root cause

Two gaps: (1) the drain path had no non-blocking read, so arrived-but-unread bytes were never decoded; (2) resuming ops returned immediately after their response, leaving no window for the stop event they usually cause.

## Resolution

PR 349 (merged 2026-08-23). `Session.fillAvailable` pulls whatever the adapter already wrote without blocking (zero-timeout poll(2) via the new `Registry.stdoutReadable`, src/agent/subprocess.zig); resuming ops (`continue`, `step_in`, `step_out`, `next`, `pause`) wait up to `HandleOpts.stop_wait_ms` (default 1000, 0 disables) for a stop-shaped event (`stopped`/`terminated`/`exited`). Expiry is not an error and never touches the adapter, unlike the `request_timeout_ms` bound.

## Verification

Strengthened fake-adapter flow test (continue result must contain `stopped`, the following stack_trace must not) plus two new real-subprocess tests: in-window stop attaches to `continue`; an expired window keeps the adapter alive and a bare `takeEvents` still drains the late event. Gate green: 339/339 steps, 1945/1956 passed (11 skipped).

## Follow-up

## References

- Investigation: none yet
