# ADR 0033 — Sessions are per-session SQLite databases with an append-only event stream; mesh peers replicate streams at cursor+1

## Status

Accepted — 2026-08-20.

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

The session store was per-session JSON files (rewritten whole per save) plus a separate append-only events database. The operator directed a full port to SQLite with append-only semantics and mesh replication, with no backward compatibility for the JSON format.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

One SQLite database per conversation at state/sessions/<id>.db holds three tables: meta (the session record), messages (the mutable transcript projection, rewritten on save) and events (the append-only trace of what the model saw, INSERT-only by trigger). Sandboxed WASM guests never link SQLite: sessions/search/export read through a new host channel ck_session gated by a session:true descriptor key, mirroring ck_llm. Mesh peers replicate a session's event stream over HTTP (GET /api/sessions/<id>/events?after= for backfill, POST /api/sessions/<id>/events for appends), accepting a record only at cursor+1 and reporting gaps, per RFC 0019 option T's stage-1 spike. The JSON transcript format and the separate .events.db are gone.

The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Costs, honestly: a vendored C dependency (SQLite amalgamation) in a single-binary musl build, and a host seam (ck_session) the guest ABI now carries. Sessions are no longer plain-text JSON on disk, so debugging by reading a file needs a sqlite3 client. Cross-session queries still need an index (the ROADMAP's measured-need gate); the per-session DBs do not provide them. Automatic fan-out and serve-start backfill are not yet wired: the wire (endpoints + replica store) and the cursor semantics are in place, and pushing/pulling is a manual or future cron-driven step, consistent with ADR 0008 (nothing fires on its own). Replicas store only the event stream under state/mesh/<owner>/sessions/, not the transcript projection.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
