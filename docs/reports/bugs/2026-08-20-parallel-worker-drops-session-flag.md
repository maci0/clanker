# Bug — Parallel tool worker omits descriptor `session: true`, denying session tools

## TL;DR

- **What failed:** The `session_search` capability eval scores 0.00, failing every improve-self iteration. The parallel tool-execution path (`ToolWorker.execute` in src/agent/loop.zig) builds its own `host.Sandbox` literal that omits `.session` (defaults false), so the session tools are denied their `ck_session` gate on every parallel run. Fixed by copying `.session = self.tool.session` into the worker sandbox.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-20. Fixed by copying `.session = self.tool.session` into the parallel ToolWorker sandbox literal in src/agent/loop.zig; `zig build`/`tools`/`test` pass.

## Status

Resolved on 2026-08-20. Fixed by copying `.session = self.tool.session` into the parallel ToolWorker sandbox literal in src/agent/loop.zig; `zig build`/`tools`/`test` pass.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Symptom and impact

An `clanker improve-self` batch stopped after iterations 1 and 2, each exhausting all
attempts. Every iteration's capability gate failed on the `session_search` eval (score
0.00 FAIL), so the staged tree never passed its own evals and no proposal could be
promoted. The log lines:

```
[WARN] [session] denied: tool descriptor does not set "session": true
[INFO] tool 'session_search' -> 187 bytes in 19ms
[INFO] eval 'session_search' (task): score 0.00 FAIL
[ERROR] staged tree failed its own capability evals:
```

The denial fired even though `tools/manifests/session_search.tool.json` sets
`"session": true`.

## Root cause

The agent loop executes independent tool calls on a worker pool for parallelism
(`src/agent/loop.zig`, `executeCalls` → `ToolWorker.execute`). The worker builds its own
`host.Sandbox` literal instead of calling `host.sandboxFor`, copying the descriptor's
policy fields by hand. `session` was not among the copied fields, so it stayed at the
struct default of `false` (`src/sandbox/host.zig` line 298).

`session_search`, `sessions` and `session_export` are parallel-eligible: none sets
`llm`, `sequential` or `live_publish`, the three flags that route a tool onto the
sequential pass. So every agent run executes them on a worker, and `ck_session`'s gate
(`host.zig` `ckSession`, `if (!h.sandbox.session) return Err.denied`) denied the call —
returning a 187-byte denial that the eval scored as a failure.

The `session: true` capability was introduced in `154abb72` (session store ported to
SQLite, `ck_session` host channel); that change updated `host.sandboxFor` and the
sequential path but not the parallel worker's sandbox literal. It is the same omission
class previously fixed for `tool_self_name`, `exec_allow`, `env_allow` and `config_json`
(the worker's comments document those), just a field that landed later.

## Resolution

`src/agent/loop.zig`, `ToolWorker.execute`: added `.session = self.tool.session,` to the
worker's `host.Sandbox` literal, matching the existing copy of `tool_self_name` /
`exec_allow` / `env_allow`. This restores parity with the sequential `host.sandboxFor`
path, which already set `.session = tool.session`.

The other fields the worker omits (`llm`, `live_publish`, `tool_call`, `tool_allow`) are
deliberately not copied because every tool that sets any of them also sets `llm` or
`sequential` (or `live_publish`) and so never runs on the worker pool.

## Verification

- `zig build`, `zig build tools`, `zig build test` all pass after the change.
- Root-cause reasoning is airtight: the denial is emitted only when `h.sandbox.session`
  is false, and the worker literal is the only construction path for a parallel tool that
  leaves it unset; `host.sandboxFor` (sequential) sets it from the descriptor.
- End-to-end confirmation requires an LLM-backed `clanker eval session_search`, which
  needs a configured provider; the code path fix is direct.
