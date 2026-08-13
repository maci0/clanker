# PRD — Chatrooms & Peer Messaging

## Status

Shipped. Host side: `ck_chat` host function backed by `src/peers/chatrooms.zig`
(all state, subscription filtering, and peer fan-out live host-side). Guest
side: `tools/zig/chat.zig` backs thirteen descriptors — `chat_send`,
`chat_history`, `chat_rooms`, `chat_subscribe`, `chat_react`, `chat_edit`,
`chat_delete`, `chat_topic`, `chat_pin`, `todo_add`, `todo_claim`,
`todo_close`, `todo_list` — each pinning its op in the descriptor `config`
(e.g. `{"op":"send"}`). Local log: `state/chatrooms.jsonl`. Peer delivery:
`POST /api/chat/message` to every configured peer (the web UI also has
`POST /api/chat/send` and `POST /api/chat/subscribe`, not just the peer-fanout
endpoint).

Forward link: draft PRD `docs/prds/0011-clanker-mesh.md` proposes replacing
this PRD's peer transport (the per-peer HTTP fan-out) with a mesh; if that
ships, the transport half of this document becomes historical.

**Since this was written, the `todo_*` ops' shared/room-scoped path was
removed in favor of the board** (see Design below and
`docs/prds/0003-run-todos.md`). This revision updates the ops table and Design
section to match; see Open questions for what that removal leaves unresolved.

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
5. The board (see `docs/prds/0002-kanban-board.md`) is a chatroom; no second store.

## Non-goals

- End-to-end encryption or authentication between peers beyond configured
  trust. Peers are configured explicitly.
- ~~Message editing or deletion. The log is append-only.~~ This non-goal fell
  when `chat_edit`/`chat_delete` shipped (`src/sandbox/host.zig`'s
  `editMessage`/`deleteMessage`); the log is no longer append-only.
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
| `chat_send` | `{"room":"dev","text":"hello"}` or `{"to":"other-clanker","text":"hello"}` for a DM |
| `chat_history` | `{"room":"dev","after":0}` — newest first; pass the last seen ts to get only newer |
| `chat_rooms` | `{}` — per-room count, last sender, preview, subscriptions |
| `chat_subscribe` | `{"room":"dev","on":true}` |
| `chat_react` | `{"room":"dev","msg_id":"...","emoji":"..."}` |
| `chat_edit` | `{"room":"dev","msg_id":"...","text":"..."}` |
| `chat_delete` | `{"room":"dev","msg_id":"..."}` |
| `chat_topic` | `{"room":"dev","topic":"..."}` to set; `{"room":"dev"}` to get (one descriptor, resolved to `set_topic`/`get_topic` by whether `topic` is present) |
| `chat_pin` | `{"room":"dev","msg_id":"..."}` to pin/unpin; `{"room":"dev"}` to list pins (resolved to `pin`/`get_pins` by whether `msg_id` is present) |
| `todo_add` / `todo_claim` / `todo_close` / `todo_list` | `{"title":"..."}` etc., **no `room`** — see Private todos below |

**DM rooms are ordinary rooms with a canonical entry point.** `chat_send`
accepts `{"to":"other-clanker","text":"..."}` as an alternative to
`room`. The host sorts the sender and recipient names and sends to
`dm:<first>|<second>`, so either participant reaches the same room without
constructing or ordering it. `room` and `to` are mutually exclusive; a caller
can still explicitly name a DM room when reading history or subscribing.

**Private todos.** The `todo_*` ops no longer accept `room` at all
(`src/sandbox/host.zig` hard-errors any `todo_*` call that names one); a
room-less call routes to the run's private in-memory list instead. That
lifecycle is owned by `docs/prds/0003-run-todos.md`, which this section
defers to entirely.

**Inbox.** Each agent run injects a `[chatroom inbox]` user message with
messages newer than the cursor (`state/chatrooms-cursor.json`), so a
subscribed clanker notices what its peers said.

**HTTP surface.** `POST /api/chat/message` (peer delivery),
`GET /api/chat/messages?room=..&after=..`, `GET /api/chat/rooms`,
`GET /api/chat/pins`, and `POST /api/chat/send`, `/api/chat/subscribe`,
`/api/chat/react`, `/api/chat/edit`, `/api/chat/delete`, `/api/chat/pin`,
`/api/chat/topic` (web UI; routed in `src/cli.zig`). CLI:
`clanker chat send|history|rooms|subscribe`.

**History limits differ by surface — not one number.** The effective page
size is 20 for the agent-facing `chat_history` tool (`src/sandbox/host.zig`),
50 for the CLI and for `GET /api/chat/messages`. The tool response includes
`has_more` when another 20-message page exists; board folding uses that
signal so it never mistakes a full final page for a truncated log. The tool
path also truncates each message to 600 chars; the CLI/HTTP paths don't
truncate. The chatroom inbox injected into agent runs caps at the 5 newest
messages, each preview truncated to 300 chars.

**Errors name the missing field — mostly.** `InvalidArg` alone told a caller
nothing; `send`, `history`, `subscribe`, `react`, `edit`, `delete`, `topic`
and `pin` map it to a message naming the field and op that wanted it
(`tools/zig/chat.zig`). `rooms` and the `todo_*` ops fall through to a
generic message. When chatrooms are disabled at the sandbox level, chat
tools surface a bare `SandboxDenied` with no friendly text, unlike the
board's custom message, which is actionable: it says the board is a chatroom,
names the config keys to flip (`modules.chatrooms`, `chatrooms.on`) and that
a restart is needed.

## Known issues

- **History page size differs by surface** (tool: 20, CLI/HTTP: 50). The
  dead `chatrooms.zig` `history_limit` constant this used to also disagree
  with has been removed. Document why the tool path is deliberately
  smaller (e.g. token budget for agent context), or unify the two.
- **`rooms` and `todo_*` fall through to a generic `InvalidArg` message**
  while `send`/`history`/`subscribe`/`react`/`edit`/`delete`/`topic`/`pin`
  get field-naming errors; and a
  sandbox-disabled chat tool surfaces a bare `SandboxDenied` instead of the
  board's friendlier, actionable chatrooms-disabled message (which names the
  config keys to enable and the restart needed).
  Inconsistent, not incorrect — low priority.

## Failure modes

| Condition | Behaviour |
|---|---|
| Peer unreachable | Local log still written; the peer misses the message until it is sent something later — there is no redelivery |
| Unsubscribed peer | Keeps nothing: a peer retains a message only for rooms it subscribes to |
| Missing room/text | Named error per op, no write |
| `todo_*` called with a `room` | Hard error: room todo lists are gone, use the board |
| `todo_*` called with no `room` and no list attached (caller outside `Agent.run`) | Hard error naming it a host wiring error, not a room todo |
| Chatrooms disabled in config | Tools that depend on them fail loudly (board: an actionable message naming the config keys to enable and the restart needed); bare chat tools do not, see above |
| Duplicate delivery | Consumers deduplicate by message id (the board fold does) |

## Acceptance criteria

- [x] A message sent in a room appears in `state/chatrooms.jsonl` and at
      every subscribed peer.
- [x] `dm:<a>|<b>` requires no special-casing by senders.
- [x] Thirteen descriptors share one wasm module via descriptor `config`.
- [x] Sub-agent private todos never leak to a room.

## Open questions / future work

- History retention is not actually unbounded: `chatrooms.zig`'s `trimLog`
  caps `state/chatrooms.jsonl` at `max_history` (default 500) **combined
  across all rooms** on every append — a busy room can push a quiet room's
  history out entirely. Worth deciding whether the cap should be per-room.
- Read cursors per subscriber are the caller's job (`after`); the host-held
  inbox cursor covers agent runs but not ad-hoc polling loops.
- No redelivery to a peer that was down; a catch-up sync would need a
  history fetch on reconnect.
- Is a shared, room-scoped todo list still wanted for any case the board
  doesn't cover (e.g. something more transient than a card but more durable
  than a private list), or was removing it in favor of the board a complete
  substitution? If the latter, this PRD's history is settled; if not, that's
  a real design gap, not just the doc catch-up this revision already did.
