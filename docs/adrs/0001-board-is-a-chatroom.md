# ADR 0001 — The Kanban board is a chatroom, not a separate store

## Status

Accepted. See `docs/prds/kanban-board.md` for the full design.

## Context

The board went through two prior shapes: HTTP handlers in `src/cli.zig`
that only the web UI could reach, then a tool backed by its own file,
`state/board.json`. The second shape left two stores for one idea — a
room's todo list and the board file could disagree, and neither let a
clanker read or change its own board consistently with what the web UI
showed. Chatrooms (`docs/prds/chatrooms.md`) already give every instance a
replicated, append-only, peer-fanned-out log; building a second replication
mechanism for the board specifically would duplicate that for no reason.

## Decision

There is no `state/board.json`. A card action is a chat message, encoded in
`tools/zig/cards.zig`, appended to a room (default `"board"`). Every read
and write re-derives the board by folding that room's log, oldest first,
deduplicated by message id. The host's job is transport (append, fan out);
card semantics (validation, claim races, columns) live entirely in the
sandboxed guest.

## Consequences

One board is now trivially consistent across the web UI and every
tool-calling clanker, and it replicates for free over the existing peer
mechanism. The cost: every read is a fold over the room's full history, so
board size is bounded by the same `max_pages` cap chatroom history is
(`docs/prds/kanban-board.md` § Known issues documents that the cap
currently fails open — a partial fold — instead of erroring, which this
decision makes more consequential than it would be for an ordinary chat
room, since a partial board fold can resurrect deleted cards). Deleting a
card is a tombstone, not an erasure — the log never shrinks, so archival or
compaction is future work, not something this decision left room to skip
forever.
