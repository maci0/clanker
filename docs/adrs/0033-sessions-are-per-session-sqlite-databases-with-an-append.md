# ADR 0033 — Sessions are per-session SQLite databases with an append-only event stream; mesh peers replicate streams at cursor+1

## Status

Accepted — 2026-08-20.

## Context

The session store was per-session JSON files (rewritten whole per save) plus a separate append-only events database. The operator directed a full port to SQLite with append-only semantics and mesh replication, with no backward compatibility for the JSON format.

## Decision

One SQLite database per conversation at state/sessions/<id>.db holds three tables: meta (the session record), messages (the mutable transcript projection, rewritten on save) and events (the append-only trace of what the model saw, INSERT-only by trigger). Sandboxed WASM guests never link SQLite: sessions/search/export read through a new host channel ck_session gated by a session:true descriptor key, mirroring ck_llm. Mesh peers replicate a session's event stream over HTTP (GET /api/sessions/<id>/events?after= for backfill, POST /api/sessions/<id>/events for appends), accepting a record only at cursor+1 and reporting gaps, per RFC 0019 option T's stage-1 spike. The JSON transcript format and the separate .events.db are gone.

## Consequences

Costs, honestly: a vendored C dependency (SQLite amalgamation) in a single-binary musl build, and a host seam (ck_session) the guest ABI now carries. Sessions are no longer plain-text JSON on disk, so debugging by reading a file needs a sqlite3 client. The shipped cross-session index is one global FTS5 database (state/session_fts.db, trigram tokenizer, maintained on save, fail-open to the linear scan), not per-session DB queries. Automatic fan-out (pushTail after every session save) and serve-start backfill (backfill at cmdServe start, then per-gap resend) are wired at the session-save sites, consistent with ADR 0008: nothing fires on its own — the fan-out runs when a save happens, not from a background thread. Replicas store the event stream under state/mesh/<owner>/sessions/; backfill also pulls the transcript projection (pullTranscript) so a replica can resume a session, not only audit its events.
