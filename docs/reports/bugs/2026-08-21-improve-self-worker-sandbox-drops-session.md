# Bug — ToolWorker parallel sandbox drops session:true, failing the session_search capability eval and stopping improve-self

## TL;DR

- **What failed:** The parallel tool worker (ToolWorker in src/agent/loop.zig) builds its own host.Sandbox literal and never set .session, so session-capable tools (session_search, sessions) ran with the struct default session:false on the worker pool, every ck_session call was denied, the session_search capability eval scored 0.00, and every staged improve-self tree failed — the batch stopped after iterations 1 and 2.
- **Impact:** Every improve-self attempt in the batch failed because the capability gate rejects any staged tree whose evals fail; the batch stopped after iterations 1 and 2 with `session_search: 0.00 FAIL` blocking all proposals.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

From the failed improve-self batch (ts_ms=1787278..., runs `run-1787278211`,
`run-1787278780`, `run-1787279393`, `run-1787280003`):

```
[WARN] request_id=improve capability evals: 2 case(s) failed; retrying only those
[ERROR] request_id=improve staged tree failed its own capability evals:
[ERROR] request_id=improve session_search: 0.00 FAIL
[WARN] request_id=improve iteration 1: all attempts failed
[WARN] request_id=improve iteration 2: all attempts failed
```

Each retry showed the same deterministic deny right before the `session_search`
eval call:

```
[WARN] [session] denied: tool descriptor does not set "session": true
[INFO] tool 'session_search' -> 187 bytes in 17ms
[INFO] eval 'session_search' (task): score 0.00 FAIL
```

Because the capability gate rejects any staged tree whose evals fail, every
improve-self attempt failed regardless of the proposal, and the batch stopped
after iterations 1 and 2. A second eval, `reasoning`, scored 0.50 in the same
batch; that is the known model-compliance flake (the model answered something
containing neither `SHAPE_OK` nor `SHAPE_BAD`), not this defect — it is a
satisfied-fraction score and passes on re-run.

## Reproduction

On a checkout whose `state/` has no `state/sessions/` yet (state/ is
gitignored), run an agent task that calls `session_search {"q":"the"}`. The
tool runs on the parallel worker pool (it is not `llm`/`sequential`/
`live_publish`, and a single tool call still takes `executeToolOnWorker`).
On the worker path the sandbox was built without `session`, so the guest's
`ck_session` call returned `Err.denied`; the guest mapped that to
`error.SandboxDenied` (not `NoAccess`), so `searchSessions` returned a
`failErr` instead of the empty `{"ok":true,"hits":[]}` shape, and the eval
scored 0.00.

The deterministic host check is the `session_search` and `sessions` capability
evals (`evals/session_search.task.json`).

## Root cause

`host.sandboxFor` (src/sandbox/host.zig) copies `tool.session` into the
`Sandbox`, and the sequential path uses it. But the parallel path's
`ToolWorker.execute` (src/agent/loop.zig) hand-builds a `Sandbox` literal and
enumerates the policy fields it copies. The `session` flag was never copied,
so it fell back to the struct default `false`. This is the same omission class
previously fixed for `tool_self_name`, `exec_allow`, `env_allow` and
`config_json` — the worker silently runs a *narrower* policy than the
sequential path, and the divergence bit `session_search` after the SQLite
session port (759a54c3) moved the guest behind `ck_session`.

The reachable set is exactly `session_search` and `sessions`: every
`tool_call:true` tool (chain, run_plan, bugreport, goal_write) is also
`sequential`, and `llm`/`live_publish` tools are excluded from the worker by
`executeToolOnWorker`, so `session` was the only remaining gated channel a
parallel tool could need.

## Resolution

Added `.session = self.tool.session,` to the `ToolWorker.execute` `Sandbox`
literal in src/agent/loop.zig, with a comment naming the omission class. The
worker now carries the descriptor's `session` grant exactly like
`host.sandboxFor` does on the sequential path, so `session_search`/`sessions`
work on the worker pool and the `session_search` capability eval passes.

## Verification

- `zig build`, `zig build test`, `zig build tools` all green after the fix
  (the `gate` tool reports `build ok; tools ok; test ok`).
- The failing `session_search` capability eval is the regression test: it
  exercises `session_search` on the agent parallel path, which previously
  produced the `[session] denied` + 187-byte `failErr` that scored 0.00.
- Diff shows only the intended `+6/-1` hunk in `src/agent/loop.zig`.

## Follow-up

## References

- Investigation: none yet
