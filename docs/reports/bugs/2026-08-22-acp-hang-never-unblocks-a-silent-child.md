# Bug — ACP hang never unblocks a silent vendor child

## TL;DR

- **What failed:** ChildTransport.readLine blocked forever in Registry.readStdoutLine (one readStreaming), so Client.timeout_ms between reads never fired. A silent ACP child hung the run; hang then cancel then headless could not run. Watchdog now SIGTERMs the child when the budget elapses. Pinned by driver.run against sleep 30.
- **Impact:** `--backend` (and a goal-loop work turn that uses it) never returned when the vendor child stopped writing ACP JSON-RPC. `backend_timeout_ms` was a no-op on a live silent process; the operator had to kill clanker.
- **Resolution:** Resolved on 2026-08-22. ChildTransport.readLine watchdog SIGTERMs the silent child so hang then headless runs; zig build test -Dtest-filter=driver.run hangs exit 0 against sleep 30.

## Status

Resolved on 2026-08-22. ChildTransport.readLine watchdog SIGTERMs the silent child so hang then headless runs; zig build test -Dtest-filter=driver.run hangs exit 0 against sleep 30.

## Symptom and impact

`clanker run --backend grok` (or `goal --backend`) against a vendor that accepts stdio and then writes nothing hangs until the process is killed. `Client.waitResponse` checks `timeout_ms` only *between* `readLine` returns; `Registry.readStdoutLine` blocks inside one `readStreaming` until the pipe closes, so the deadline is never reached on a live silent child.

## Reproduction

`driver.run` with `acp_argv = { "sleep", "30" }`, `timeout_ms = 200`, and a headless `printf`. Before the fix the test waited out the 30s sleep (or forever, if the child never exited). After: ACP outcome `hang` in ~200ms, then the headless answer. Test name: `driver.run hangs a blocking child, persists a failed ACP node, then headless` in `src/acp/driver.zig`.

## Root cause

The same class as the DAP post-launch hang (`docs/reports/bugs/2026-08-22-dap-post-launch-ops-block-unbounded.md`): a time bound that does not reach a blocked `readStreaming` is not a time bound. `transport.cancel` (SIGTERM) only ran *after* `readLine` returned.

## Resolution

`ChildTransport.readLine` starts a watchdog thread that SIGTERMs the adopted child when `timeout_ms` elapses. Killing the child closes the pipe and unblocks `readStreaming`; the read then returns `Error.Hang`. `afterAcp(.hang)` still takes headless. Tests pass a local `subprocess.Registry` via `RunOpts.acp_reg` so they do not leak the process-global table.

## Verification

`zig build test -Dtest-filter="driver.run hangs"`: log shows `acp-client: spawning sleep` then `backend-headless: spawning printf` ~200ms later; answer `recovered-from-hang`; first graph node `ok=false` detail `hang`. Exit 0, no leak.

## Follow-up

Goal-loop work turns also ignored `--backend` (CLI, TUI `/goal`, goal-loop `POST /api/run` still called `Agent.run`): docs/reports/bugs/2026-08-22-goal-loop-ignores-backend.md.

## References

- DAP analogue: docs/reports/bugs/2026-08-22-dap-post-launch-ops-block-unbounded.md
- ADR 0032 / PRD 0043 / RFC 0020
