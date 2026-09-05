# ADR 0038 — Live sessions get advisory file-touch notify from a host read-set

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0026 — How live sessions are notified when a file they read is edited](../rfcs/0026-file-shift-notify.md). Not yet implemented. Tracked as [PRD 0049](../prds/0049-file-touch-notify-for-live-sessions.md).

## Context

When two sessions share a checkout, a write is invisible to a peer that already read the file. The 2026-08-16 incident recovered via a runbook. RFC 0008 is git claims, still open. ck_swarm members cannot see each other. RFC 0026 compared a host read-set notify, waiting on claims, the status quo, and worktrees.

## Decision

Record paths a session successfully read. On write, notify other live sessions that have that path in their read-set, advisory, fail-open, no lock. whoToNotify is a pure helper. Not a ck_swarm rewrite. Not RFC 0008.

> The RFC recommended: **Recommended option:** Option A: host read-set plus advisory file-touch notify; not a lock and not a ck_swarm rewrite


## Consequences

Agents can notice code shifting under them. The honest downside: every write to a previously-read path is a notification, including unrelated edits; noise is the cost of no locks. In-process first; cross-process needs serve later. Worktrees remain the isolation option for writers who do not share a tree.
