# ADR 0038 — Live sessions get advisory file-touch notify from a host read-set

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0026 — How live sessions are notified when a file they read is edited](../rfcs/0026-file-shift-notify.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

When two sessions share a checkout, a write is invisible to a peer that already read the file. The 2026-08-16 incident recovered via a runbook. RFC 0008 is git claims, still open. ck_swarm members cannot see each other. RFC 0026 compared a host read-set notify, waiting on claims, the status quo, and worktrees.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Record paths a session successfully read. On write, notify other live sessions that have that path in their read-set, advisory, fail-open, no lock. whoToNotify is a pure helper. Not a ck_swarm rewrite. Not RFC 0008.

> The RFC recommended: **Recommended option:** Option A: host read-set plus advisory file-touch notify; not a lock and not a ck_swarm rewrite


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Agents can notice code shifting under them. The honest downside: every write to a previously-read path is a notification, including unrelated edits; noise is the cost of no locks. In-process first; cross-process needs serve later. Worktrees remain the isolation option for writers who do not share a tree.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
