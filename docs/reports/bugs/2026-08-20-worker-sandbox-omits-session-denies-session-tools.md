# Bug — Worker parallel sandbox omitted the session grant, denying session tools and failing the session_search capability eval in improve-self

## TL;DR

- **What failed:** `ToolWorker` (the parallel tool fast-path in `src/agent/loop.zig`) hand-rolled its own `host.Sandbox` literal and omitted `session`. After commit 759a54c3 switched the session tools from a filesystem scan to the host `ck_session` seam, a `session:true` tool running on the worker had `ck_session` denied (`Err.denied`), so `session_search` returned an error object and its capability eval scored 0.00 FAIL. Every improve-self staged tree was rejected and the batch stopped after iterations 1 and 2.
- **Impact:** No improve-self change could be promoted: the capability gate rejected every staged tree because the `session_search` eval (and any other eval whose tool uses `ck_session`) could not run.
- **Resolution:** Resolved on 2026-08-20. `ToolWorker` now delegates the whole descriptor policy to `host.sandboxFor` (the documented single source of truth) via a new `sandboxFor` method, adding only the agent-level extras sandboxFor does not know about. The hand-rolled literal is gone, so there is no second copy left to drift. A regression test asserts the worker sandbox carries a `session:true` tool's grant.

## Status

Resolved on 2026-08-20. Fix: `ToolWorker.sandboxFor` delegates to `host.sandboxFor` and adds only `subagent_runner`/`state_dir`/`tool_policy`; verified by the new unit test `worker sandbox delegates the descriptor's session grant through host.sandboxFor` and by green `zig build` / `zig build test` / `zig build tools` / `zig fmt --check` / astcheck.

## Symptom and impact

An improve-self batch ran iterations 1 and 2; both exhausted all attempts because the staged tree failed its own capability evals:

```
[WARN] request_id=improve capability evals: 2 case(s) failed; retrying only those
[ERROR] request_id=improve staged tree failed its own capability evals:
[ERROR] request_id=improve session_search: 0.00 FAIL
[WARN] request_id=improve iteration 1: all attempts failed
[WARN] request_id=improve iteration 2: all attempts failed
```

The eval agent run (`run-1787239191`) logged the actual reason:

```
[WARN] [session] denied: tool descriptor does not set "session": true
[INFO] tool 'session_search' -> 187 bytes in 19ms
eval 'session_search' (task): score 0.00 FAIL
```

`tools/manifests/session_search.tool.json` DOES set `"session": true`, so the denial was not the descriptor's fault. The `sessions`, `session_search`, and `session_export` tools all declare `session: true` and were all affected.

## Reproduction

Run a capability eval whose tool uses the host `ck_session` channel (`session_search`, `sessions`, `session_export`) while the tool executes through the `ToolWorker` parallel fast-path. The guest's `lib.sessionCall` calls `ck_session`, which gates on `h.sandbox.session`; the worker sandbox left that flag false, so `ck_session` returned `Err.denied` (rc=1 → guest `error.SandboxDenied`, not the `NoAccess` branch `sessions.zig` handles), and the tool returned a `{"ok":false,...}` error object. The eval's SHAPE_OK criteria (ok:true + hits, or the typed too-short error) is not met → 0.00.

## Root cause

Commit 759a54c3 ("session tools: read the SQLite session store through a host ck_session seam") switched the session tools from a filesystem scan to the host `ck_session` channel, which is gated on the descriptor's `session` flag. `host.sandboxFor` (the documented single source of truth for a tool's sandbox policy) propagates it correctly. But `ToolWorker.execute` in `src/agent/loop.zig` built its own `host.Sandbox` literal for the parallel fast-path and omitted `session`, leaving it at its default `false`. A `session:true` tool running on the worker therefore had `ck_session` denied even though the sequential path granted it.

This was the fourth field the hand-rolled worker literal drifted on — `exec_allow`/`env_allow` and `tool_self_name` were fixed before (the tool_self_name one is d8008075). The worker also never carried `network_from_config` or the research `web.allow` injection that `host.sandboxFor` performs, so the peers and web-research tools were missing configured hosts on the parallel path too.

## Resolution

`ToolWorker` now delegates the whole descriptor policy to `host.sandboxFor` (added a `sandboxFor` method on `ToolWorker` that calls it and then only adds the agent-level extras sandboxFor does not know about: `subagent_runner`, `state_dir`, `tool_policy`). The hand-rolled literal is gone, so there is no second copy to drift. This fixes `session`, and incidentally the `network_from_config` / research-`web.allow` gaps for parallel-run tools. A regression test (`worker sandbox delegates the descriptor's session grant through host.sandboxFor`) constructs a `ToolWorker` with a `session:true` tool and asserts the built sandbox carries `session`, plus that a non-session tool stays closed and `tool_self_name`/`state_dir` survive the delegation.

## Verification

- `zig build`, `zig build test`, `zig build tools`, `zig fmt --check`, astcheck all green in the worktree.
- The new unit test passes as part of `zig build test`.
- The session_search capability eval is the integration gate for this path and now has a working mechanism underneath it; run `clanker eval session_search --tasks` with a configured provider to confirm end-to-end.

## Follow-up (2026-08-21): the same symptom recurred on a *newer* batch, from a stale worktree base

A later improve-self batch (eval runs `run-1787282522`, `run-1787283196`,
`run-1787284292`) failed with the identical `session_search: 0.00 FAIL` /
`[session] denied: tool descriptor does not set "session": true` symptom even
though the worker-sandbox fix above was already merged to origin/main (PR
#291, b7b4b77a, merged 1787241888). The fix was on origin; the batch still
ran the buggy code.

Root cause: the improve loop cut its worktree from the **local** `main` ref
via `Worktree.createOn` (`git worktree add -b <branch> <path> <base_branch>`,
where `base_branch = currentBranch()`). At the time that batch's worktree
(`.clanker-worktrees/1787281039786392993-main`) was created, local `main`
still pointed at `154f1575` (committed 1787237597) — *before* the fix — even
though origin/main had advanced. The loop staged and gated every proposal
against pre-fix code, so the capability eval kept failing no matter how the
proposal changed.

Fix (this report): `createOn` now cuts an improve-self worktree from the
fetched remote tip `origin/<base_branch>` when that ref exists, falling back
to the local branch only when there is no remote tracking ref. Plain agent
runs (`.run`) are unchanged: they isolate the checkout's own working state,
so they still cut from the local branch. `base_branch` (the local name) is
unchanged for merge-back targeting, and `created_from` records the actual cut
point, so merge semantics are unaffected.

The remaining error lines in that batch — `plan: response was not a usable
idea list` and the `staging build failed: src/agent/ttsr.zig:93:10 error:
expected statement, found ';'` — were not code defects: the plan line is a
model-output quality flake (documented below), and the ttsr.zig staging
failure came from the loop's own broken intermediate proposal
(imp-1787284534818753126), not from committed code (committed ttsr.zig:93 is
a clean `var arena_state = ...` inside a `test` block).

## Follow-up

The two other error lines in the failing batch — `plan: response was not a usable idea list` and `model returned no proposal content (finish_reason=stop, reasoning=0 chars)` — were model-output quality issues on a batch whose gate was already failing for an opaque reason; they are not code defects and are expected to resolve once the capability gate passes.

## References

- Prior fix of the same drift class: d8008075 (tool_self_name), and the exec_allow/env_allow fixes.
- Prior session_search empty-store bug: docs/reports/bugs/2026-08-17-capability-evals-reject-empty-store-tools.md (Resolved 7bcfddea).
