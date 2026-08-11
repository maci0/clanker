# PRD — Chatrooms & Peer Messaging

## Status

Shipped. Host side: `ck_chat` host function backed by `src/peers/chatrooms.zig`
(all state, subscription filtering, and peer fan-out live host-side). Guest
side: `tools/zig/chat.zig` backs eight descriptors — `chat_send`,
`chat_history`, `chat_rooms`, `chat_subscribe`, `todo_add`, `todo_claim`,
`todo_close`, `todo_list` — each pinning its op in the descriptor `config`
(e.g. `{"op":"send"}`). Local log: `state/chatrooms.jsonl`. Peer delivery:
`POST /api/chat/message` to every configured peer.

## Problem

Multiple clanker instances need to coordinate: announce work, ask each other,
and carry the shared board. Each instance runs on its own machine with its
own config; there is no server to mediate. The mechanism must be one the
sandbox can enforce (an explicit host function with declared reach), must not
invent a second transport beside the peer HTTP plumbing that already exists,
and must double as the replication layer for the Kanban board.

## Goals

1. Named rooms any instance can join, leave, read, and post to.
2. Peer fan-out: a message logged locally is delivered to every subscribed
   peer.
3. Direct messages as rooms named `dm:<a>|<b>` — not a separate mechanism.
4. One module, many tools: the guest forwards arguments verbatim; all logic
   host-side. Descriptors are marked `sequential` so concurrent tool calls
   never race on the log file.
5. The board (see `docs/prd-kanban-board.md`) is a chatroom; no second store.

## Non-goals

- End-to-end encryption or authentication between peers beyond configured
  trust. Peers are configured explicitly.
- Message editing or deletion. The log is append-only.
- Presence/typing indicators. No sockets; live updates are polling.

## Design

**Thin guest, honest host.** `chat.zig` reads its op from descriptor config,
re-emits the input object with the op injected (`{"op":"send", ...args...}`),
calls `lib.chat`, and passes host JSON back. Nothing about rooms,
subscriptions, or fan-out is guest-side, so a misbehaving guest cannot widen
its reach.

**Ops and shapes.**

| Tool | Input |
|---|---|
| `chat_send` | `{"room":"dev","text":"hello"}` (or `"to"` for a DM) |
| `chat_history` | `{"room":"dev","after":0}` — newest first; pass the last seen ts to get only newer |
| `chat_rooms` | `{}` — per-room count, last sender, preview, subscriptions |
| `chat_subscribe` | `{"room":"dev","on":true}` |
| `todo_add` | `{"room":"dev","title":"ship it"}` |
| `todo_claim` / `todo_close` | `{"room":"dev","todo":"<id>"}` |
| `todo_list` | `{"room":"dev"}` |

**Private todos.** The `todo_*` ops may omit `room`: inside a sub-agent run
the host routes to the run's private in-memory list instead of a shared room
list (`src/agent/private_todos.zig`, wired only by `subagent.runNested`).
Nothing is logged or fanned out; the list is discarded when the run returns,
and its final state is appended to the sub-agent's answer so the parent sees
progress even when the run hits its iteration cap. Ids are `p1`, `p2`, ... to
keep them distinct from shared-list message ids. A private todo is the run's
working plan; shared work goes on the board.

**Inbox.** Each agent run injects a `[chatroom inbox]` user message with
messages newer than the cursor (`state/chatrooms-cursor.json`), so a
subscribed clanker notices what its peers said.

**HTTP surface.** `POST /api/chat/message` (delivery),
`GET /api/chat/messages?room=..&after=..`, `GET /api/chat/rooms`. CLI:
`clanker chat send|history|rooms|subscribe`.

**Errors name the missing field.** `InvalidArg` alone told a caller nothing;
each op maps it to a message that names the field and the operation that
wanted it (e.g. "chat send needs \"room\" (or \"to\" for a direct message)
and \"text\"").

## Failure modes

| Condition | Behaviour |
|---|---|
| Peer unreachable | Local log still written; the peer misses the message until it is sent something later — there is no redelivery |
| Unsubscribed peer | Keeps nothing: a peer retains a message only for rooms it subscribes to |
| Missing room/text | Named error per op, no write |
| Chatrooms disabled in config | Tools that depend on them fail loudly (board: "chatrooms are disabled, and the board is a chatroom") |
| Duplicate delivery | Consumers deduplicate by message id (the board fold does) |

## Acceptance criteria

- [x] A message sent in a room appears in `state/chatrooms.jsonl` and at
      every subscribed peer.
- [x] `dm:<a>|<b>` requires no special-casing by senders.
- [x] Eight descriptors share one wasm module via descriptor `config`.
- [x] Sub-agent private todos never leak to a room.

## Open questions / future work

- History retention: rooms grow unboundedly toward `max_history` (default
  500); the board's `max_pages` cap is the first place log growth bites.
- Read cursors per subscriber are the caller's job (`after`); the host-held
  inbox cursor covers agent runs but not ad-hoc polling loops.
- No redelivery to a peer that was down; a catch-up sync would need a
  history fetch on reconnect.
