# Bug — Worker parallel sandbox omitted tool_self_name, failing capability evals in improve-self

## TL;DR

- **What failed:** ToolWorker parallel fast-path builds its own Sandbox literal and left tool_self_name empty, so named channels (ck_harness_config, ck_std_api) denied parallel-run tools and capability evals peers_phonebook/std_api/git_deny scored 0.00 FAIL, rejecting every improve-self staged tree.
- **Impact:** A self-improvement batch could never promote a staged change: every attempt failed the capability evals, so iterations 1 and 2 each exhausted all attempts and the loop stopped.
- **Resolution:** Set `.tool_self_name = self.tool.name` in the worker Sandbox literal (mirroring host.sandboxFor); resolve `rg` via resolveExecPath in ckStdApi; make the git_deny eval config-independent by testing `reset` (always denied) instead of `checkout` (lifted by git_remote_ops).

## Status

Resolved.

## Symptom and impact

An improve-self batch ran iterations 1 and 2; both exhausted all attempts because the staged tree failed its own capability evals:

- `peers_phonebook: 0.00 FAIL`
- `std_api: 0.00 FAIL`
- `git_deny: 0.00 FAIL` (in a config where `agent.git_remote_ops` is enabled)

The run log showed `[sandbox] ck_harness_config denied for tool ''` — the tool name is empty, not the real tool. peers and std_api returned small (42/57 byte) results with ok:false.

## Reproduction

Run a capability eval whose tool depends on a named host channel while the tool executes through the ToolWorker parallel fast-path. With an empty `tool_self_name`:
- `peers` reads its config via `ck_harness_config` → denied (host.zig line ~1027), so `harnessConfigAccess("")` returns null.
- `std_api` calls `ckStdApi` which returns `Err.denied` because `tool_self_name != "std_api"` (host.zig line ~3572).

Both evals assert the tool's `ok` field is true, so they fail.

## Root cause

`host.sandboxFor` (sequential path) sets `tool_self_name` from the tool descriptor. The `ToolWorker` in `src/agent/loop.zig` builds its own `host.Sandbox` literal for the parallel fast-path and omitted `tool_self_name` (and, earlier, `exec_allow`/`env_allow`), leaving it `""`. The named host channels gate on the name and treated every parallel tool as unnamed, denying the channels that tool legitimately needs.

The `std_api` eval additionally failed even after the name was granted because `ckStdApi` invoked `rg` by bare name; the sandbox host inherits a minimal environment where `rg` is not on PATH. `git_deny` was config-dependent: it asserted `checkout` is denied, but `agent.git_remote_ops` legitimately lifts `checkout` (and `push`/`merge`), so the eval was red in this config even though the sandbox was behaving correctly.

## Resolution

- `src/agent/loop.zig` (ToolWorker.execute): `.tool_self_name = self.tool.name` in the worker Sandbox literal, with a comment explaining the named channels gate on it. The parallel path then matches the sequential path.
- `src/sandbox/host.zig` (ckStdApi): resolve `rg` via `resolveExecPath` before `std.process.run` so the search works under the sandbox's minimal environment.
- `evals/git_deny.task.json`: test `git reset --hard` (always on the deny list) instead of `checkout` so the eval is config-independent.

## Verification

- `zig build`, `zig build tools`, `zig build test` all pass (gate ok).
- Confirmed `harnessConfigAccess("peers")` returns `.peers` and `ckStdApi`'s grant checks `tool_self_name == "std_api"`, both now satisfied because the worker sets the real tool name.
- Capability evals require a live LLM and were not re-run here; the mechanism the evals assert (tool `ok:true`) is verified at the channel-grant level.

## Follow-up

- The `[WARN] improve plan: response was not a usable idea list` line is a separate, non-fatal symptom (loose plan parsing already landed in f1c0ab53). Not part of this defect.

## Follow-up (2026-08-21)

The same drift class recurred: the worker's hand-rolled Sandbox literal omitted
`session` after the `ck_session` seam, denying `session_search` on the parallel
path and stalling another improve-self batch. Rather than add the one missing
field again, the worker now builds its sandbox through `host.sandboxFor` (the
documented single source of truth), removing the class. See
`2026-08-21-worker-sandbox-missing-session-grant.md`.

## References

- Investigation: none yet
- Related: reports on improve-self staging (2026-08-14 improve-staging-*) and build failures (2026-04-15 improve-self-gate-build).
