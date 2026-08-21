# Bug — Post-launch DAP ops block unbounded on a silent adapter

## TL;DR

- **What failed:** continue/stackTrace/variables and every other post-launch op wait via waitResponse/waitEvent, whose spin counts bound frames read, not time: a silent adapter leaves the caller blocked inside one readStreaming forever. Found as the Follow-up of the launch-timeout bug; only the launch handshake was covered by a knob.
- **Impact:** Any guest debug op after launch (continue, step_*, stackTrace, scopes, variables, evaluate, set_breakpoints, and the response wait inside disconnect/terminate) against an adapter that stops answering wedged the calling run forever.
- **Resolution:** Resolved on 2026-08-21. runBounded generalizes the launch watchdog over every DAP op; post-launch ops bounded by new debug.request_timeout_ms (default 15s), expiry kills and reaps the adapter; pinned by a mute-after-launch test

## Status

Resolved on 2026-08-21. runBounded generalizes the launch watchdog over every DAP op; post-launch ops bounded by new debug.request_timeout_ms (default 15s), expiry kills and reaps the adapter; pinned by a mute-after-launch test

## Symptom and impact

A debug session whose adapter launches cleanly and then goes mute (crash without closing pipes is not required — just silence) never returns from the next op. The run holds its iteration forever; no error reaches the guest.

## Reproduction

Fake adapter that answers initialize and launch, then keeps reading and never answers again; issue {"op":"continue"}. Pinned as the test 'mute-after-launch adapter: post-launch ops are bounded by request_timeout_ms' in src/debug/dap.zig.

## Root cause

waitResponse/waitEvent bound the number of frames read (spins < 256), not time. One readStreaming on the adapter's stdout pipe is not a cancelable syscall, so a caller blocked there is stuck until the pipe closes.

## Resolution

The launch fix's bounded runner is generalized: OpSpec turns every DAP op into data, and runBounded (src/debug/dap.zig) executes any of them on an io.concurrent worker under Event.waitTimeout. Post-launch ops run under the new debug.request_timeout_ms (default 15000, 0 disables); the launch handshake keeps debug.launch_timeout_ms. Expiry SIGTERMs the adapter (pipe close is what unblocks the worker), SIGKILLs after a 2s grace, awaits, reaps, and returns error.RequestTimeout, mapped in ckDebug to 'request timed out (debug.request_timeout_ms); adapter terminated'. disconnect/terminate treat the timeout as success with a note — teardown wanted the adapter gone and the expiry path killed it.

## Verification

Test 'mute-after-launch adapter: post-launch ops are bounded by request_timeout_ms' (src/debug/dap.zig): launch succeeds against the mute adapter, continue with request_timeout_ms=300 returns error.RequestTimeout, and the registry row is gone.

## Follow-up

None.

## References

- Investigation: none yet
