# PRD — Chatrooms & Peer Messaging

## Status

Shipped. Host side: `ck_chat` host function backed by `src/peers/chatrooms.zig`
(all state, subscription filtering, and peer fan-out live host-side). Guest
side: `tools/zig/chat.zig` backs eight descriptors — `chat_send`,
`chat_history`, `chat_rooms`, `chat_subscribe`, `todo_add`, `todo_claim`,
`todo_close`, `todo_list` — each pinning its op in the descriptor `config`
(e.g. `{"op":"send"}`). Local log: `state/chatrooms.jsonl`. Peer delivery:
`POST /api/chat/message` to every configured peer (the web UI also has
`POST /api/chat/send` and `POST /api/chat/subscribe`, not just the peer-fanout
endpoint).

**Since this was written, the `todo_*` ops' shared/room-scoped path was
removed in favor of the board** (see Design below and
`docs/prds/run-todos.md`). This revision updates the ops table and Design
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
5. The board (see `docs/prds/kanban-board.md`) is a chatroom; no second store.

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
| `chat_send` | `{"room":"dev","text":"hello"}` or `{"to":"other-clanker","text":"hello"}` for a DM |
| `chat_history` | `{"room":"dev","after":0}` — newest first; pass the last seen ts to get only newer |
| `chat_rooms` | `{}` — per-room count, last sender, preview, subscriptions |
| `chat_subscribe` | `{"room":"dev","on":true}` |
| `todo_add` / `todo_claim` / `todo_close` / `todo_list` | `{"title":"..."}` etc., **no `room`** — see Private todos below |

**DM rooms are ordinary rooms with a canonical entry point.** `chat_send`
accepts `{"to":"other-clanker","text":"..."}` as an alternative to
`room`. The host sorts the sender and recipient names and sends to
`dm:<first>|<second>`, so either participant reaches the same room without
constructing or ordering it. `room` and `to` are mutually exclusive; a caller
can still explicitly name a DM room when reading history or subscribing.

**Private todos.** The `todo_*` ops no longer accept `room` at all —
`src/sandbox/host.zig` hard-errors any `todo_*` call that names one
("room todo lists are board cards now: use board_add, board_move,
board_claim or board_list instead"). The shared/room-scoped todo list this
section originally described has been fully replaced by the board (see
`docs/prds/kanban-board.md`). What remains: inside a sub-agent run, the host
routes a room-less `todo_*` call to the run's private in-memory list
(`src/agent/private_todos.zig`, wired only by `subagent.runNested`, capped
at 100 items). Nothing is logged or fanned out; the list is discarded when
the run returns, and its final state is appended to the sub-agent's answer
whenever the list is non-empty (not only when the run hits its iteration
cap). Ids are `p1`, `p2`, ... to keep them distinct from shared-list message
ids. A private todo is the run's working plan; shared work goes on the
board. **Outside a sub-agent run** (a top-level run), no private list is ever
attached, so `todo_*` without `room` fails too — see `docs/prds/run-todos.md`
for the gap this leaves.

**Inbox.** Each agent run injects a `[chatroom inbox]` user message with
messages newer than the cursor (`state/chatrooms-cursor.json`), so a
subscribed clanker notices what its peers said.

**HTTP surface.** `POST /api/chat/message` (peer delivery),
`GET /api/chat/messages?room=..&after=..`, `GET /api/chat/rooms`,
`POST /api/chat/send` and `POST /api/chat/subscribe` (web UI). CLI:
`clanker chat send|history|rooms|subscribe`.

**History limits differ by surface — not one number.** The effective page
size is 20 for the agent-facing `chat_history` tool (`src/sandbox/host.zig`),
50 for the CLI and for `GET /api/chat/messages`. The tool response includes
`has_more` when another 20-message page exists; board folding uses that
signal so it never mistakes a full final page for a truncated log. The tool
path also truncates each message to 600 chars; the CLI/HTTP paths don't
truncate. The chatroom inbox
injected into agent runs caps at the 5 newest messages, each preview
truncated to 300 chars.

**Errors name the missing field — mostly.** `InvalidArg` alone told a caller
nothing; `send`/`history`/`subscribe` map it to a message naming the field
and op that wanted it. `rooms` and the `todo_*` ops fall through to a
generic message. When chatrooms are disabled at the sandbox level, chat
tools surface a bare `SandboxDenied` with no friendly text, unlike the
board's custom "chatrooms are disabled, and the board is a chatroom".

## Known issues

- **History page size differs by surface** (tool: 20, CLI/HTTP: 50). The
  dead `chatrooms.zig` `history_limit` constant this used to also disagree
  with has been removed. Document why the tool path is deliberately
  smaller (e.g. token budget for agent context), or unify the two.
- **`rooms` and `todo_*` fall through to a generic `InvalidArg` message**
  while `send`/`history`/`subscribe` get field-naming errors; and a
  sandbox-disabled chat tool surfaces a bare `SandboxDenied` instead of the
  board's friendlier "chatrooms are disabled, and the board is a chatroom."
  Inconsistent, not incorrect — low priority.

## Failure modes

| Condition | Behaviour |
|---|---|
| Peer unreachable | Local log still written; the peer misses the message until it is sent something later — there is no redelivery |
| Unsubscribed peer | Keeps nothing: a peer retains a message only for rooms it subscribes to |
| Missing room/text | Named error per op, no write |
| `todo_*` called with a `room` | Hard error: room todo lists are gone, use the board |
| `todo_*` called with no `room` outside a sub-agent run | Hard error, and the error text itself is stale (see `docs/prds/run-todos.md`) |
| Chatrooms disabled in config | Tools that depend on them fail loudly (board: "chatrooms are disabled, and the board is a chatroom"); bare chat tools do not, see above |
| Duplicate delivery | Consumers deduplicate by message id (the board fold does) |

## Acceptance criteria

- [x] A message sent in a room appears in `state/chatrooms.jsonl` and at
      every subscribed peer.
- [x] `dm:<a>|<b>` requires no special-casing by senders.
- [x] Eight descriptors share one wasm module via descriptor `config`.
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
