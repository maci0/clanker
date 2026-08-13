# ADR 0011 — `ck_kernel` is a named host channel, not a `ck_exec` grant

## Status

Accepted.

## Context

Persistent eval kernels (PRD 0016) need to spawn `python3` / `bun`. `ck_exec`
deliberately does not allow those verbs: `uv` is pinned to one OpenCV script,
and a general `python3 -c` grant is a sandbox bypass (network + exec of
arbitrary code). The kernel is already a named unsandboxed class (ADR 0010);
widening `ck_exec` would give every exec-capable guest that same power.

## Decision

Add `ck_kernel(json) -> json`, callable only when `tool_self_name == "kernel"`
and `kernel.enabled` is true. Import existing is not a grant. The host owns
spawn, cwd under `state/kernels/`, and (later) the session subprocess
registry. `ck_exec` stays closed to `python3`/`bun`.

## Consequences

- ABI growth is one privileged channel, same shape as `ck_docker`.
- A guest that imports `ck_kernel` without being named `kernel` is denied.
- Persistent supervisors can reuse this function without a second ABI.
