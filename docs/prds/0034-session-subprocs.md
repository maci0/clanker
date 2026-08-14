# PRD — Session subprocess inspector

## Status

Draft. Not built. Proposed: a `subprocs` WASM tool (or a `clanker doctor`
section) that lists the 0016 registry: session id, kind (`python` / `dap` /
…), pid, and age. Read-only. Sources once built: `src/agent/subprocess.zig`
plus a guest at `tools/zig/subprocs.zig`.

## Problem

Kernels and DAP adapters are now long-lived processes keyed by session.
When one sticks around after a turn, the operator has no way to see it
without `ps`. `clanker doctor` talks about config and credentials, not
about which unsandboxed children this process still owns. That gap will
get worse as 0016/0017/0032 (MCP client) share the same registry.

## Goals

1. List every registered subprocess for the current process: session, kind,
   pid. Empty list when none.
2. Optionally SIGTERM one key (`session` + `kind`) or every process for
   one session, using the existing registry (no second lifecycle).
3. Surface the list from `clanker doctor` and a guest the model can call,
   both reading the same registry.

## Non-goals

- Not a process manager for arbitrary host PIDs. Only registry rows.
- Not resource stats (CPU/RSS). `ps` already does that; this is identity.
- Not a TUI dashboard. A table on stdout / JSON for the tool is enough.

## Design

**Dependencies.** Hard: the 0016 `Registry` (`src/agent/subprocess.zig`).
Soft: 0017 DAP and 0032 MCP client become extra `kind` values.

**Implementation.**

1. Add `Registry.snapshot` that copies (session, kind, pid) under the lock.
2. `clanker doctor` prints a "session subprocesses" section when the
   list is non-empty.
3. Guest `subprocs` with ops `list` / `kill`, gated by the same
   `confirm: true` posture as kernel/debug because `kill` is destructive.
4. Tests: register two fakes, snapshot names them, kill drops one.

## Failure modes

| Condition | Behaviour |
|---|---|
| Registry empty | `list` returns `[]`; doctor omits the section |
| `kill` on an unknown key | `{"ok": true}` no-op, same as `terminate` today |
| Guest called with no Agent | Process-global registry, same as kernel/debug |

## Acceptance criteria

- [ ] `subprocs list` / doctor shows every live registry row.
- [ ] `subprocs kill` with session+kind SIGTERMs that row only.
- [ ] Empty registry is silent, not an error.
- [ ] Unit tests drive `Registry.snapshot` and `terminate`, not a mock.

## Open questions / future work

- Whether MCP client subprocesses (0032) reuse this `kind` space or get
  a namespaced prefix. Decide when 0032 lands, not here.
