# Bug — zig_std returns not-found: zigLibDir runs zig env without the live environment

## TL;DR

- **What failed:** `host.zigLibDir` ran `zig env` with no `.environ_map`, so the child got the Io instance's stale memoized env (no HOME) and `zig env` failed with AppDataDirUnavailable; `zigLibDir` returned empty and every `zig_std` lookup answered "not found", making the improve-self `std_api` capability eval score 0.00. Fix: pass the live `environ_map` (same fix as `ck_exec`).
- **Impact:** The improve-self batch stopped after iterations 1 and 2; no improvement could be promoted because the capability gate always failed on `std_api`.
- **Resolution:** Resolved on 2026-08-18. Fixed by passing the live environ_map to zig env in host.zigLibDir; gate (build/tools/test) green and component-level probes confirm the lib dir resolves and readSliceShort is found in std.

## Status

Resolved on 2026-08-18. Fixed by passing the live environ_map to zig env in host.zigLibDir; gate (build/tools/test) green and component-level probes confirm the lib dir resolves and readSliceShort is found in std.

## Symptom and impact

A failed improve-self batch (ts_ms=1787077…) showed the `std_api` capability eval scoring `0.00 FAIL` three times across iterations 1 and 2, so the loop stopped after both iterations exhausted all attempts. The run log line `tool 'zig_std' -> 59 bytes in 29ms` is the `zig_std` tool returning `{"ok":false,"error":"looking up the std symbol: not found"}` (the `Err.not_found` path), so the eval's prompt ("reply with the value of its ok field") got `false` and scored 0.00.

## Reproduction

Call `zig_std` with any symbol (e.g. `readSliceShort`): it answers `{"ok":false,"error":"looking up the std symbol: not found"}`. The direct cause is that `zig env`, run under `std.process.run` with no `.environ_map`, prints nothing to stdout and writes `error: unable to resolve zig cache directory: AppDataDirUnavailable` to stderr.

## Root cause

`host.zigLibDir` runs `std.process.run(gpa, io, .{ .argv = &[_][]const u8{"zig","env"} })` with no `.environ_map`. In Zig 0.16 `std.process.run` without an explicit env map spawns the child with the `std.Io` instance's memoized environment copy, which lacks `HOME` even when `HOME` is set in the live process env. `zig env` needs `HOME` (or `ZIG_GLOBAL_CACHE_DIR`) to resolve the global cache dir, so it errors with empty stdout; `zigLibDir` then finds no `.lib_dir =` line and returns empty, and `ckStdApi` sees `lib_dir.len == 0` and returns `Err.not_found`. `ck_exec` already documents and avoids exactly this with `.environ_map = &child_env`.

## Resolution

`host.zigLibDir` now takes `environ_map: *std.process.Environ.Map` and passes `.environ_map = environ_map` to `std.process.run`. Call sites updated: `ckStdApi` passes `h.sandbox.environ_map`; `Engine.stdSymbolHelp`/`stdGrep` and the engine test pass `self.ctx.environ_map`/`ctx.environ_map`. The `.lib_dir =` parser is unchanged: `zig env` still prints Zig struct syntax (`.lib_dir = "/usr/lib/zig"`) in 0.16, so the existing parse is correct.

## Verification

- `zig build`, `zig build tools`, `zig build test` all pass (gate ok).
- Probe: `zig env` run with `.environ_map` (HOME set) prints `.lib_dir = "/usr/lib/zig"`.
- Probe: `rg -n -F --max-count 40 readSliceShort /usr/lib/zig/std` finds `pub fn readSliceShort` at `/usr/lib/zig/std/Io/Reader.zig:675`, so the eval's exact lookup returns a non-empty result.
- The `std_api` capability eval itself needs a live LLM and was not re-run here; the mechanism it asserts (lib-dir resolution + rg match) is verified at the component level.

## Follow-up

- The `bugreport.zig:55` "expected 4 argument(s), found 3" line in the same batch was a transient improve-loop staging artifact: committed `tools/zig/bugreport.zig` already has 4-arg `appendSection` calls and builds clean.
- A CHANGELOG entry is pending; root-level `CHANGELOG.md` is outside this agent's editable paths.

## References

- Investigation: none yet
- Related: docs/reports/bugs/2026-08-16-worker-sandbox-missing-tool-self-name.md (tool_self_name + rg PATH — a separate std_api cause that had been masking this one)
