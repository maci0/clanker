# PRD — Per-session SQLite store with an append-only event stream and mesh replication

## Status

Shipped — 2026-08-20. src/agent/session.zig, src/agent/session_events.zig, src/util/sqlite.zig, src/peers/session_sync.zig, src/sandbox/host.zig ck_session, src/cli.zig /api/sessions/<id>/events
per-session store: meta + messages + events tables in `state/sessions/<id>.db`),
`src/agent/session_events.zig` (the append-only writer), `src/util/sqlite.zig`
(the vendored binding), `src/peers/session_sync.zig` (replica store + cursor
semantics), `ck_session` in `src/sandbox/host.zig` (the guest seam), and the
HTTP handlers in `src/cli.zig` (`GET|POST /api/sessions/<id>/events`). The
JSON transcript format and the separate `.events.db` are gone; no migration
is provided or planned. Decision: [ADR 0033](../adrs/0033-sessions-are-per-session-sqlite-databases-with-an-append.md).

## Problem

Per-session JSON transcripts were rewritten whole on every save (atomic but
not append-only), the traceable record of what the model saw lived in a
separate append-only file per session, and sandboxed guests read the JSON
files directly. The operator directed a full port: one SQLite database per
conversation holding the record, the transcript and the append-only event
stream, with no backward compatibility, and with the event streams
replicating to mesh peers.

## Goals

1. One SQLite database per session holds meta, the transcript and the
   append-only events, so a conversation and its trace are one file.
2. The events table is INSERT-only (UPDATE/DELETE refused by trigger).
3. Sandboxed guests read sessions only through a host channel; no guest
   links SQLite or sees the database path.
4. Mesh peers replicate a session's event stream with dense per-stream seq
   cursors: appends accepted only at cursor+1, duplicates dropped, gaps
   reported for backfill.

## Non-goals

- Backward compatibility with the JSON transcript format (deliberate).
- Cross-session query/index (SQLite FTS) until the linear scan is measured
  slow (ROADMAP gate).
- Automatic fan-out on append and serve-start backfill: the wire and cursor
  semantics are in place; a push/pull driver is a follow-up, consistent
  with ADR 0008 (nothing fires on its own).
- Replicating the transcript projection to peers — only the event stream
  replicates.

## Design

**Store.** One SQLite database per conversation at `state/sessions/<id>.db`
(`src/agent/session.zig`), three tables: `meta` (id/title/created/updated/
workspace/archived/system_prompt), `messages` (the mutable transcript
projection, deleted+reinserted in one transaction on save) and `events`
(seq, ts_ms, kind, payload; INSERT-only by trigger). The event recorder
(`session_events.zig`) appends into the same database.

**Guest seam.** WASM guests cannot link SQLite. `ck_session`
(`src/sandbox/host.zig`) serves list/get/search from the host-side store,
gated by a `session: true` descriptor key (mirroring `llm`). The
`sessions`/`session_search`/`session_export` tools call it
(`lib.sessionCall` in `tools/zig/lib.zig`).

**Mesh.** A session's event stream is owned by its home instance (RFC 0019
option T). `GET /api/sessions/<id>/events?after=<seq>` serves the owner's
tail for backfill; `POST /api/sessions/<id>/events` accepts appends into
`state/mesh/<owner>/sessions/<id>.db`, taking a record only at cursor+1,
dropping duplicates, and answering `{"gap":true,"have":N,"need":N+1}` on a
hole (`src/peers/session_sync.zig`).

## Failure modes

| Condition | Behaviour |
|---|---|
| Session DB missing on load | `error.FileNotFound`; resume treats it as absent |
| Events UPDATE/DELETE attempted | Trigger aborts (`StepFailed`) |
| Append arrives ahead of the cursor | 409 `gap:true` (caller backfills) |
| Append at/below the cursor | Dropped silently, cursor unchanged |
| Replica dir missing | Created on receive (`createDirPath`) |
| Guest without `session: true` calls ck_session | Denied, logged |

## Acceptance criteria

- [x] One `<id>.db` per session with meta + messages + events (G1).
- [x] UPDATE/DELETE on events are refused by trigger; tested (G2).
- [x] `clanker sessions` / `session export` / `session search` work through
      ck_session with no guest SQLite (G3).
- [x] POST accepts at cursor+1, drops duplicates, reports gaps; tested in
      `session_sync.zig` and live over two serve instances (G4).

## Open questions / future work

All four items named here have shipped (see the committed code and the
ROADMAP entry):

- Automatic fan-out on append and serve-start backfill —
  `session_sync.pushTail` runs after every session save (REPL persist,
  `cmdRun` save, serve save sites), gated on `modules.session_events`;
  `session_sync.backfill` runs at serve start and per gap (409) resend.
- Cross-session FTS index — `session_fts.zig`: one global FTS5 trigram
  index over message content, maintained on `saveSession`, read through
  `searchSessions` candidates with a linear-scan fallback when the index
  is missing or corrupt.
- Replicating the transcript projection — `session_sync.pullTranscript`
  fetches a peer's session meta + messages after event sync so a replica
  can resume the conversation, not only audit its events.
