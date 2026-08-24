# PRD — File-touch notify for live sessions

## Status

Draft. Later phases, not implement-now this round. Decision: [ADR 0038](../adrs/0038-live-sessions-get-advisory-file-touch-notify-from-a-host.md). RFC: [0026](../rfcs/0026-file-shift-notify.md).

## Problem

When session A writes a file session B has read, B does not hear about it. Concurrent sessions recover after damage via a runbook rather than during the write.

## Goals

1. whoToNotify is a pure function over read-sets, path, and writer id.  2. Live sessions record successful reads.  3. A write notifies other live sessions that hold the path, advisory, fail-open.  4. No lock and no ck_swarm rewrite.

## Non-goals

Git claims (RFC 0008). Locks. ck_swarm rewrite. Mesh file replication (PRD 0011 Phase 3). Blocking the writer.

## Design

**whoToNotify.** Pure: given map session_id -> read path set, a written path, and writer id, return other session ids whose set contains the path. Host-tested.

**Record.** ck_fs_read success adds the resolved path to the session read-set (bounded, LRU).

**Notify.** On write, inject a short advisory into those sessions at a safe point (next tool result or turn), fail-open.

**Dependencies.** Hard: ADR 0038, src/sandbox/host.zig, src/agent/session.zig. Soft: RFC 0008, the concurrent-sessions runbook.

**Implementation.** later, not implement-now this round.

1. whoToNotify helper + tests. Files: src/sandbox/file_shift.zig (create), src/main.zig comptime.
2. Record reads and notify on write in-process. Files: src/sandbox/host.zig.
3. Cross-process via serve. Files: src/serve/, src/peers/.

## Failure modes

| Condition | Behaviour |
|---|---|
| No other reader | No notify |
| Read-set full | Drop oldest path |
| Notify inject fails | Log, writer succeeds |

## Acceptance criteria

1. [ ] whoToNotify returns the other reader, not the writer (Goal 1)
2. [ ] A successful read is in the set (Goal 2)
3. [ ] A write notifies that reader (Goal 3)
4. [ ] No lock file is taken on the target (Goal 4)

## Open questions / future work

Safe-point injection vs a chat DM. Cross-process (phase 3).
