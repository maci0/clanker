# Bug — Every guest read and write under a symlinked state/ was refused

## TL;DR

- **What failed:** safeJoinSecure refuses any path component that is a symlink, so a checkout whose state/ is a symlink into external storage had every guest call under state/ denied: clanker schedule list and add failed outright and run graphs were never persisted. Fixed by ADR 0017's agent.sandbox_follow_symlinks opt-in; the flag then did not work because applyAgentFields never copied it into the merged config.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-16. Re-resolved 2026-08-17: follow_symlinks now also copied into the parallel ToolWorker sandbox literal (src/agent/loop.zig); verified with a 4-call file_ops/list_files probe on .local

## Status

Resolved on 2026-08-16. Re-resolved 2026-08-17: follow_symlinks now also copied into the parallel ToolWorker sandbox literal (src/agent/loop.zig); verified with a 4-call file_ops/list_files probe on .local

## Symptom and impact

Every guest call under `state/` was refused with the tool's generic sandbox
message:

    refused by this tool's sandbox policy — its manifest has to allow the path
    (fs_prefixes), the command (exec_allow) or the host (network_allow)

`clanker schedule list` and `clanker schedule add` failed outright. Run
graphs were never written: `state/runs/` had not gained a file since
2026-08-13, and the agent loop's own write is best-effort, so it only logged a
warning and the loss went unnoticed for three days. Spills would fail the same
way. The message names `fs_prefixes` even though the manifest grants were
correct, which is what made this hard to read.

## Reproduction

Make the checkout's `state` a symlink to a directory outside the repo, then:

    clanker schedule list

## Root cause

Two defects, one behind the other.

1. `safeJoinSecure` (src/sandbox/host.zig) walks every component of an
   already-granted path with `follow_symlinks = false` and returns
   `PathOutsideSandbox` when any component is a link. A `state/` symlinked
   into external storage — the layout `scripts/backup-state.sh` is built
   around — therefore failed every call, read and write alike.

2. After `agent.sandbox_follow_symlinks` was added per ADR 0017, setting it
   in `config.local.toml` still had no effect. `Agent` is field-merged:
   `applyAgentFields` copies only the keys a file actually set, and the new
   key was parsed into the local `Agent`, recorded in `AgentFields`, and
   then never copied to the merged config. Nothing warned, because the key was
   known — it was read and silently dropped. Flipping the struct default to
   `true` made the refusal disappear, which is what separated "the code path
   is wrong" from "the value never arrives".

## Resolution

`safeJoinSecure` returns early when `Sandbox.follow_symlinks` is set, which
`host.sandboxFor` fills from `agent.sandbox_follow_symlinks`. The prefix
grant from `safeJoin` is untouched, so the flag only decides whether a
component of an already-granted path may be a link. It is off by default; see
[ADR 0017](../../adrs/0017-sandbox-symlink-traversal-is-opt-in.md) for why that
is a security risk worth an explicit opt-in.

`applyAgentFields` now copies the key.

## Verification

With `sandbox_follow_symlinks = true` in `config.local.toml` on a checkout
whose `state/` is a symlink: `clanker schedule list` prints the table,
`schedule add` then `remove` round-trips an entry, and a `clanker run`
persists its graph (`state/runs/` went from 193 to 194 files) with no
`graph write` warning.

Three unit tests pin it: `safeJoinSecure` refuses a symlinked component by
default, allows it when opted in, and still refuses a path outside every
prefix either way; a config test asserts the key survives the local-file merge
alongside an unrelated base key; and another asserts it defaults to false.

## Follow-up

## References

- Investigation: none yet
## Follow-up 2026-08-17: flag was ignored on the parallel tool path

The resolution was incomplete. `agent.sandbox_follow_symlinks` was wired into `host.sandboxFor` (src/sandbox/host.zig:337) but the parallel-path `ToolWorker` in src/agent/loop.zig builds its own `Sandbox` literal and omitted `.follow_symlinks`, so it defaulted to false — the same omission class the literal's own comments record for `exec_allow`/`env_allow`. Any turn issuing 2+ tool calls ran on that path and still refused symlinked granted paths (`.local`, `state/`).

Evidence: with the flag set since 18:57 on 2026-08-16, a 4-call probe run (`clanker run` with file_ops stat / list_files on .local) was refused at 22:42; state/autolearn.jsonl records .local refusals at 21:50, after the config change.

Fix: `.follow_symlinks = self.cfg.agent.sandbox_follow_symlinks` added to the ToolWorker sandbox literal. Verified by re-running the same 4-call probe: .local stat and listing now succeed. Separately, `file_ops` gained a narrow `zig-out/gate-failure.txt` fs_prefixes entry — that refusal was a genuine manifest gap, not the symlink defect.