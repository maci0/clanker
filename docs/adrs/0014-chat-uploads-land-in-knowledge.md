# ADR 0014: Chat file uploads land in Knowledge through add_doc

## Status

Accepted. Records the choice in
[RFC 0002](../rfcs/0002-chat-upload-into-knowledge.md). Not yet
implemented (2026-08-19): no `uploads-<workspace>` / `uploads` collection is
written; chat uploads still stay on the vision / `@file` paths.

## Context

Chat can attach images (vision) and `@file` workspace-path chips (this turn
only). Knowledge ingest is a different view: paste, pick a text file, or
sync a server folder. Memory search (PRD 0007) only ranks documents already
in `state/knowledge/`. Dropping a file on Chat therefore never became
retrievable on a later turn.

RFC 0002 compared auto-ingest through `knowledge.add_doc` (A), explicit
Keep (B), status quo (C), and reuse of folder Sync (D). Keep would be
skipped. Sync is not a Chat upload. Status quo leaves a hole next to a
finished inject path.

## Decision

A text file uploaded in Chat is written with `knowledge.add_doc` into a
well-known collection: `uploads-<workspace>` when a workspace is selected,
`uploads` for the empty-id cwd. That collection is included in
`req.knowledge` for the session so `/api/run` memory search can hit it.

Images stay on the vision path. `@file` path chips stay this-turn path
hints; they do not ingest. Non-text files are refused in v1 (same 500 KB
and text accept-list as the Knowledge form). CLI/REPL upload is out of
scope.

## Consequences

Later Chat turns can retrieve a dropped file without opening the Knowledge
view. There is still one corpus, one chunker, and one untrusted retrieval
fence. The Knowledge UI remains the place to browse and delete docs.

Auto-ingest is durable: a drop is not ephemeral. A visible chip must name
the collection. Whether removing the chip deletes the doc or only drops it
from this turn's `req.knowledge` is left to the implementer; delete on the
Knowledge view always works.

Two workspaces do not share an uploads corpus. A later PDF extract can
still feed `add_doc` without a second store.
