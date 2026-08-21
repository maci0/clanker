# Bug — debug.launch_timeout_ms is stored but never bounds a launch

## TL;DR

- **What failed:** Config parses the knob and host.zig copies it onto the DAP Session, but launch() waits on a fixed spin count over readFrame and nothing reads Session.launch_timeout_ms, so a silent adapter blocks past any configured cap. Found while fixing the sibling disconnect_timeout_ms dead knob (PR 305).
- **Impact:** To be confirmed.
- **Resolution:** Open on 2026-08-21. confirmed against main 5a4767f8: no reader of Session.launch_timeout_ms exists; not fixed yet

## Status

Open on 2026-08-21. confirmed against main 5a4767f8: no reader of Session.launch_timeout_ms exists; not fixed yet

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence

Grep for readers: `launch_timeout_ms` appears in src/config.zig (parse + default 15000), src/sandbox/host.zig:1987 (copied onto the live Session), and src/debug/dap.zig:94/:343 (field declarations). No line reads the Session field. `launch()` in src/debug/dap.zig bounds its wait with `spins < 64` over `readFrame`, not a clock.

Also dead: `HandleOpts.launch_timeout_ms` and `HandleOpts.disconnect_timeout_ms` (src/debug/dap.zig:343-344) — `handle()` never copies them onto the session; host.zig sets the Session fields directly, so the HandleOpts copies mislead a reader into thinking tests can inject timeouts through opts.

## Fix shape

Bound the launch wait with the same io.concurrent + Event.waitTimeout pattern `Registry.terminateWithin` (PR 305) and `pingWithTimeout` use, or a deadline check inside the spin loop; delete the dead HandleOpts fields or wire them.