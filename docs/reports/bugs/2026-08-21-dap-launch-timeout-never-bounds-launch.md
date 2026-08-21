# Bug — debug.launch_timeout_ms is stored but never bounds a launch

## TL;DR

- **What failed:** Config parses the knob and host.zig copies it onto the DAP Session, but launch() waits on a fixed spin count over readFrame and nothing reads Session.launch_timeout_ms, so a silent adapter blocks past any configured cap. Found while fixing the sibling disconnect_timeout_ms dead knob (PR 305).
- **Impact:** A guest debug launch against a silent or wedged adapter never returned, wedging the calling run; the configured cap was a no-op.
- **Resolution:** Resolved on 2026-08-21. launchBounded bounds the launch handshake with debug.launch_timeout_ms via io.concurrent + Event.waitTimeout; silent adapter is SIGTERM/SIGKILLed and reaped; pinned by a silent-adapter test

## Status

Resolved on 2026-08-21. launchBounded bounds the launch handshake with debug.launch_timeout_ms via io.concurrent + Event.waitTimeout; silent adapter is SIGTERM/SIGKILLed and reaped; pinned by a silent-adapter test

## Symptom and impact

## Reproduction

## Root cause

The spin counts in launch()/waitResponse() bound the number of frames read, not time: a silent adapter leaves the caller blocked inside one readStreaming on the stdout pipe, which never returns. A fully silent adapter blocks in initialize() before launch()'s loop even runs, so a per-loop deadline would not have covered the launch op either.

## Resolution

launchBounded (src/debug/dap.zig) runs the whole launch handshake (initialize + launch/attach) on an io.concurrent worker and bounds it with Event.waitTimeout at debug.launch_timeout_ms, the same pattern as subprocess.waitChildWithin. On expiry the adapter is SIGTERMed (its exit closing the pipe is what unblocks the worker's read), escalated to SIGKILL after a 2s grace, then awaited and reaped; the guest gets error.LaunchTimeout, mapped to 'launch timed out (debug.launch_timeout_ms); adapter terminated' in ckDebug. launch_timeout_ms = 0 disables the bound. The dead HandleOpts copies are wired instead of deleted: handle() is now the one writer of both Session timeout fields, and host.zig's direct session writes are gone, so tests can inject timeouts through opts.

## Verification

New test 'silent adapter: launch is bounded by launch_timeout_ms and reaped' (src/debug/dap.zig): a python adapter that reads requests but never answers, launch_timeout_ms=300, asserts error.LaunchTimeout and that the registry row is gone. Full suite green: 333/333 steps, 1815/1826 passed (11 expected worktree skips).

## Follow-up

The post-launch ops were fixed separately: [Post-launch DAP ops block unbounded on a silent adapter](2026-08-22-dap-post-launch-ops-block-unbounded.md), bounded by the new debug.request_timeout_ms.

## References

- Investigation: none yet
## Evidence

Grep for readers: `launch_timeout_ms` appears in src/config.zig (parse + default 15000), src/sandbox/host.zig:1987 (copied onto the live Session), and src/debug/dap.zig:94/:343 (field declarations). No line reads the Session field. `launch()` in src/debug/dap.zig bounds its wait with `spins < 64` over `readFrame`, not a clock.

Also dead: `HandleOpts.launch_timeout_ms` and `HandleOpts.disconnect_timeout_ms` (src/debug/dap.zig:343-344) — `handle()` never copies them onto the session; host.zig sets the Session fields directly, so the HandleOpts copies mislead a reader into thinking tests can inject timeouts through opts.

## Fix shape

Bound the launch wait with the same io.concurrent + Event.waitTimeout pattern `Registry.terminateWithin` (PR 305) and `pingWithTimeout` use, or a deadline check inside the spin loop; delete the dead HandleOpts fields or wire them.