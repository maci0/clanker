# Bug — Parallel worker sandbox omitted the session grant, failing the session_search capability eval and stalling improve-self

## TL;DR

- **What failed:** `ToolWorker` built its own `Sandbox` literal and omitted the `session` field added by the `ck_session` seam, so session_search/sessions/session_export were denied `ck_session` on the parallel path only, scored 0.00 in the improve-self capability eval, and every staged tree was rejected.
- **Impact:** improve-self stopped the batch after iterations 1 and 2 because every staged tree failed the session_search capability eval, so no improvement could land.
- **Resolution:** Resolved on 2026-08-21. ToolWorker now delegates to `host.sandboxFor` (the documented single source of truth for a tool's sandbox policy), granting the session channel on the parallel path and removing the whole hand-rolled-literal drift class; full gate green.

## Status

Resolved on 2026-08-21. ToolWorker now builds its sandbox through
`host.sandboxFor` instead of a hand-rolled `Sandbox` literal, so the `session`
grant from the descriptor reaches the parallel path. `zig build`,
`zig build tools`, `zig build test` and `zig fmt --check` are green.

## Symptom and impact

An improve-self batch ran iterations 1 and 2; both exhausted all attempts
because the staged tree failed its own capability evals:

```
[WARN] improve capability evals: 1 case(s) failed; retrying only those
[ERROR] improve staged tree failed its own capability evals:
[ERROR] improve session_search: 0.00 FAIL
[WARN] [session] denied: tool descriptor does not set "session": true
[INFO] tool 'session_search' -> 187 bytes in 19ms
[WARN] improve iteration 1: all attempts failed
[WARN] improve iteration 2: all attempts failed
```

The `[session] denied` warning is the load-bearing line: `ck_session` refused
because `h.sandbox.session` was false. The 187-byte result is the tool's error
response, so the eval saw `ok:false` instead of `ok:true` with a `hits` array
and scored 0.00.

## Root cause

The session store was ported to SQLite (`154abb72`) and the sessions guests now
read it through the host `ck_session` channel (`759a54c3`), gated by the tool
descriptor's `session: true`. The committed `session_search` descriptor sets
`"session": true`, and the sequential execution path (`Agent.sandboxFor` →
`host.sandboxFor`) grants it correctly.

But the parallel fast-path `ToolWorker` in `src/agent/loop.zig` builds its own
`host.Sandbox` literal and omitted `session`. This is the same drift class as
the prior `tool_self_name` bug: `host.sandboxFor` is documented as "the single
place a tool's sandbox policy is assembled", yet the worker hand-rolled a copy,
so every field added to `Sandbox` after that copy was written is silently
missing on the parallel path only. `session_search` is a plain tool (no `llm`/
`sequential`/`live_publish`), so it runs on the worker pool, got `session =
false`, and `ck_session` denied its own channel. The eval's `requires_tool`
was satisfied (the tool was invoked), but the result was `ok:false`, so the
model answered `SHAPE_BAD` → 0.00.

The guests' `NoAccess` fallback (rc=7) does not cover this: a descriptor-gate
denial returns `Err.denied` (rc=1), which the guest maps to `SandboxDenied`,
not the `NoAccess` it degrades on, so the tool hard-fails.

## Reproduction

Run a capability eval whose tool depends on `ck_session` while it executes
through the worker parallel fast-path, in a tree where the descriptor grants
`session: true`:

- `clanker eval session_search --tasks --provider deepseek --model deepseek-v4-flash`

Before the fix the eval logs `[session] denied` and scores 0.00. The sandbox
test (`runtime.zig` "sessions and graph report empty...") passed because it
builds its own sandbox with `session = true` and never exercised the worker's
literal.

## Resolution

`src/agent/loop.zig` `ToolWorker.execute`: replace the hand-rolled `Sandbox`
literal with

```zig
var sb = try host.sandboxFor(self.ctx.gpa, io, arena_state.allocator(),
    self.ctx.environ_map, self.cfg, self.tool, self.ctx);
sb.subagent_runner = self.subagent_runner;
sb.tool_policy = self.tool_policy;
sb.state_dir = self.cfg.agent.state_dir;
```

`host.sandboxFor` sets every policy field from the descriptor (`session`,
`llm`, `live_publish`, `tool_call`, `tool_allow`, `config_json`, ...), so the
parallel path matches the sequential path by construction and cannot drift
again. The three lines after the call are the agent-only extras that
`host.sandboxFor` deliberately does not set. `llm`/`sequential`/`live_publish`
tools never reach the worker (loop.zig `tool.llm or tool.sequential or
tool.live_publish` gates the parallel pass), so passing `self.ctx` as the
`llm_ctx` is safe.

A search-path regression test was added to the existing `runtime.zig` sessions
test: it loads `zig-out/tools/sessions.wasm`, executes `{"q":"the"}` and
asserts `ok:true` plus a `hits` array and no `ok:false` — the exact shape the
`session_search` eval's `SHAPE_OK` criterion checks.

## Verification

- `zig build`, `zig build tools`, `zig build test`, `zig fmt --check` all pass.
- The new sessions search test passes with `session` granted.
- Capability evals require a live LLM and were not re-run here; the mechanism
  the eval asserts (tool returns `ok:true` with `hits`) is verified at the
  channel-grant and guest-output level.

## Follow-up

Same bug class as `2026-08-16-worker-sandbox-missing-tool-self-name.md` (the
worker hand-rolling its sandbox). The delegation to `host.sandboxFor` removes
the entire class instead of adding the one missing field.

## References

- Related bug: `docs/reports/bugs/2026-08-16-worker-sandbox-missing-tool-self-name.md`
- Related bug: `docs/reports/bugs/2026-08-17-capability-evals-reject-empty-store-tools.md`
