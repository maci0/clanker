# PRD - Clanker Mesh (TCP peer-to-peer clustering)

## Status

In progress. Design is locked. Phase 1 codec, admission, leave-vs-unreachable,
simultaneous-open, CHAT id-dedup, and the Fleet lamp map (`GET /api/mesh/map`)
live in `src/peers/mesh.zig` (host tests, no NIC). Serve listener, `ck_mesh`,
CLI, and chat fan-out are still open.

Single source of truth once built: `src/peers/mesh.zig` (host-side, the
same "thin guest, honest host" shape as `src/peers/chatrooms.zig`) plus
`ck_mesh` and the `mesh_*` guest tools. This PRD extends, and where noted
**replaces the transport half of**, the static-peer HTTP plumbing in
[`0001-chatrooms.md`](0001-chatrooms.md). Chatroom, board, and goal
*shapes* stay; only the pipe a `send` travels over changes for members.

## Problem

Today "peers" means a static, hand-configured list (`config.toml
[[peers]]`, `Peer{name, url}` in `src/config.zig`) that each process
pushes to over one HTTP request per message. `sendMessage` in
`src/peers/chatrooms.zig` POSTs `/api/chat/message` to every configured
URL; `phonebook` fetches each URL's `/.well-known/agent.json`. There is
no persistent connection, no membership protocol, and no way to add a
peer without editing config and restarting.

That is enough for a handful of instances the operator knows about in
advance. It breaks down for a cluster of clanker instances, possibly on
different machines, that should find each other, join and leave at
runtime, and share more than chat: workspaces (`Session.workspace` in
`src/agent/session.zig`) and an explicit, bounded set of files.

Three constraints the design has to survive, not just satisfy as goals:

1. **The sandbox must be able to enforce it.** A guest never holds a
   socket. Mesh is a named host channel, the same privilege class as
   `ck_chat` / `ck_subagent` (import existing is not a grant;
   `tool_self_name` is).
2. **There is no second notion of "peer".** `[[peers]]` and the A2A
   card stay the identity documents. Mesh does not invent a competing
   id space.
3. **Only `clanker serve` is long-lived.** `clanker run`, the REPL, and
   `clanker mesh …` are short-lived processes. A TCP membership table
   cannot live in them. The previous draft ignored this and described
   `mesh.zig` as if every process owned sockets.

The mechanism has to be the transport chatrooms (and everything that
rides them: the board per ADR 0001, goal mirroring, Arena Phase 3's
room-backed log) eventually use instead of one-off HTTP posts.

## Goals

1. Persistent TCP connections between mesh members. A mesh-aware `send`
   (chat, and therefore the board) travels over the long-lived link,
   not a new HTTP request per message.
2. Dynamic membership: an instance can join a mesh after startup and
   leave (voluntarily or by going unreachable) without any other member
   restarting or needing a config edit.
3. Shared workspaces: a workspace can be exposed explicitly so a
   conversation started on one instance is visible, and continuable,
   from another member.
4. Shared files: an explicit, bounded set of paths (never the sandbox
   root) can be replicated to members that request them, under the same
   declared-reach model (`fs_prefixes`) every other file-touching tool
   already uses.
5. Chatrooms keep working unchanged from a caller's point of view
   (`chat_send` / `chat_history` / `chat_rooms` / `chat_subscribe` keep
   their shapes). Mesh membership is another pipe for `send`, not a
   second chat system.
6. Every mesh operation is a host function. No guest holds a mesh
   socket or a file descriptor.
7. The mesh listener lives in `clanker serve`. CLI, REPL, and
   `clanker run` never open a mesh socket; they ask the local serve
   process over loopback HTTP.

## Non-goals

- Byzantine fault tolerance, or defending against a malicious member
  already inside the mesh. Trust is established at admission. Once a
  peer is a member it is trusted the way a configured chatroom peer is
  trusted today.
- Automatic conflict resolution beyond the home-instance rule (Design,
  Shared workspaces). No CRDT, no merge.
- NAT traversal, hole punching, or a rendezvous/relay. Members are
  assumed mutually reachable (same LAN, VPN, or public IP with an open
  port) at the address they advertise.
- End-to-end encryption beyond TLS-on-the-socket. v1 is plain TCP for
  loopback / RFC1918; TLS+pinning is Phase 2.
- A UI that browses the whole mesh's files and workspaces as one tree.
  Surfaces show per-member rows (whose workspace, whose file).
- Replacing `/.well-known/agent.json` / A2A. Mesh admission reuses the
  card as a label, it does not invent a competing identity document.
- A named `mesh_id` / cluster isolation beyond admission. Two open
  meshes that JOIN each other merge. Admission is the cluster
  boundary; use `allowlist` if that is not wanted.
- Fanning out `react` / `edit` / `delete` / `topic` / `pin`. Today only
  `sendMessage` calls `fanOut`. Mesh carries the same `send` body, not
  a larger chat op set. Growing HTTP fan-out is a 0001 change.
- A second daemon (`clanker mesh listen`). Serve is the process that
  already stays up.
- Generating `instance.id` when it is empty. The field is operator-set
  (`[instance] id` in `config.toml`; stock file uses `id = "main"`).
  Mesh refuses to start without one. The previous draft claimed a
  generated stable default; `parseInstance` does not create one.

## Design

**Why this stays native.** AGENTS.md says anything that can be a WASM
tool must be one. The reason mesh cannot: it owns TCP sockets, a
process-lifetime membership table, and (Phase 2) a pin store, and it
attaches to the serve accept path. That is the same class of reason
`chatrooms.zig` is native (`ck_chat` is the guest door; the host owns
the log and the fan-out). Handing sockets to a guest inverts the
sandbox.

**Not ACP, not A2A-as-the-wire.** Three protocols, three jobs. Using
either of the others as the mesh framing would invert them.

| Protocol | Job | Shape in clanker | What it is not |
|---|---|---|---|
| **ACP** ([PRD 0030](0030-acp-server.md), [Agent Client Protocol](https://agentclientprotocol.com)) | An editor drives one coding agent | Draft `clanker acp`: stdio JSON-RPC, `session/new` / `session/prompt`. Explicitly no socket. | Not peer-to-peer. Client/server, one way, one process spawned by Zed (or similar). No membership, no gossip, no file offer, no chatroom fan-out. |
| **A2A** (shipped `modules.a2a`) | One agent delegates a *task* to another | `GET /.well-known/agent.json` + `POST /api/a2a/message` runs `Agent.run` on the text and returns the answer. JSON-RPC over HTTP. | Not a cluster. No JOIN/LEAVE, no liveness, no multiplexed CHAT/FILE/SESSION frames, no persistent link. Linux Foundation A2A v1.0 is still task+card over HTTP (SSE/push exist for *task* updates, not for a membership table). |
| **Mesh** (this PRD) | Equal instances share a long-lived pipe | Serve-owned TCP, admission, `CHAT` / `CHAT_SYNC`, later workspace/file | Not "ask the other clanker to do a turn." |

IBM's older "Agent Communication Protocol" (also abbreviated ACP) was
folded into A2A in 2025. That is a different ACP than 0030. Neither
expansion of the letters is a clustering protocol.

Reuse, do not replace:

- **A2A agent card** is the identity *label* on `JOIN` (already locked).
  Adding `id` to the card is future work, not a reason to speak A2A
  JSON-RPC on the mesh port.
- **A2A `message/send`** stays the "please run a turn for me" HTTP
  path. A later revision may *relay* that over a live mesh link the
  same way `chat_send` does, still as an A2A body inside a mesh frame,
  not by making mesh *be* A2A.
- **ACP** stays the editor embedding surface. Unrelated.

A foreign A2A agent on the LAN is a phonebook row and an HTTP
fallback, never a mesh member. Mesh membership is clanker-to-clanker.

**Serve owns the mesh.** `cmdServe` starts the mesh listener when
`modules.mesh` is on. The table, the sockets, and `state/mesh/` live
in that process. Every other local entry point is a client of it:

| Caller | How it reaches the mesh |
|---|---|
| `clanker serve` | Owns sockets. HTTP `/api/mesh/*` is the local control plane. |
| `clanker mesh …` | `POST`/`GET` `http://<serve.host>:<webui_port>/api/mesh/…` on loopback. Refuses if serve is not up, naming `clanker serve` and `modules.mesh`. |
| `ck_mesh` in `clanker run` / REPL | Same loopback HTTP. The host function is the sandbox door; the I/O is not raw TCP. |
| `chatrooms.fanOut` in any process | If the target is a mesh member, `POST /api/mesh/relay` on the local serve (serve writes the `CHAT` frame). Else existing `POST {peer.url}/api/chat/message`. |

Serve's mesh port is a distinct TCP protocol, not HTTP. It does not
share Host / CSRF with `/api/*`. Default mesh bind is loopback so an
unattended `modules.mesh = true` does not open a LAN socket.

**Node identity.** A member is addressed by `Instance.id`
(`src/config.zig`), not by `name` (stock name is `"clanker"`; names
collide) and not by IP:port (addresses change). `/.well-known/agent.json`
today has `name`, `url`, `skills`, `version`, `capabilities` and **no
`id`**. JOIN therefore carries `id` as its own field plus the existing
card as a label. Phase 1 does not require changing the card document.

Empty `instance.id` is a startup error for mesh: the listener does not
bind, `mesh status` / `ck_mesh` name the `[instance] id` key to set.
`clanker doctor` says the same.

**Admission is receiver-only.** A dials B. B decides. A's own
`[[peers]]` does not have to name B (that is the dynamic-membership
point). After accept, A gets B's membership view and dials those
addresses; each of those receivers applies *its* admission. Membership
is each node's admitted set, gossiped as a dial hint, never a globally
forced set. C can refuse A even though B accepted A.

`mesh.admission` (default `allowlist`):

| Mode | JOIN from unknown id |
|---|---|
| `allowlist` | Auto-admit only when the JOIN `id` equals a `[[peers]]` entry's optional `id`, or (no `id` on the entry) the JOIN `name` equals that entry's `name`. Else refuse. |
| `prompt` | Queue for the operator (see Pending JOIN). Timeout = refuse. |
| `open` | Accept any well-formed JOIN whose `id` is non-empty and not ours. |

`open` and `prompt` are explicit opt-in. An open mesh is never the
surprise default.

The JOIN card is **self-asserted**. v1 does not HTTP-fetch
`/.well-known/agent.json` to "verify" it. There is nothing to verify
against on plain TCP; a fetch would be a second channel that can
disagree with the socket. Phase 2 binds identity to the TLS pin.

`[[peers]]` grows an optional `id` field so allowlist can match the
real key. Matching by name alone is kept for entries that have not
set `id`, and is weak (every stock instance is named `clanker`).
Doctor warns when `admission = "allowlist"` and every `[[peers]]` row
is missing `id`.

**No HTTP-rewrite of `[[peers]]`.** Join/leave never edits config.
`[[peers]]` stays the allowlist seed and the HTTP fallback path for
non-members. Phonebook lists both, labeled `mesh` or `http`.

**Topology is a full mesh.** One TCP connection per admitted pair.
Gossip is how you learn who to dial, not how messages route. A `CHAT`
or `FILE_*` frame travels only on the direct link to the intended
peer (or, for a room `send`, on the direct link to each member).
`max_members = 32` caps each node's degree, so the worst case is
32·31/2 = 496 connections, which is the point of the cap: small
enough that a hub-and-spoke (and its single point of failure) is not
worth it.

Simultaneous open (A and B dial each other): keep the connection on
which the lexicographically smaller `id` is the dialer; close the
other. Self-JOIN (`id` equals ours) is refused. A second JOIN from an
id we already have a `reachable` connection to is closed as a
duplicate (unless it is the simultaneous-open loser).

There is no `mesh_id`. The connected component of admitted members
*is* the mesh.

**Membership is persisted.** `state/mesh/members.json` holds `{id,
name, address, state}` for every admitted member. Serve start redials
that list (plus allowlist seeds that have an address). Explicit
`LEAVE` removes the row. `unreachable` stays so it can come back.
Serve hot-reload drops live sockets and redials from the file; that
is acceptable (same class as a restart).

**Transport framing.** One long-lived TCP connection per pair.
Frames are **4-byte big-endian length + UTF-8 JSON** (not newline
JSON: `FILE_CHUNK` is binary-hostile as raw JSON already, and a
length prefix stays binary-safe if a later phase drops base64).
`mesh.max_frame_bytes` (default 1 MiB) is the cap; a larger length
is a protocol error (connection closed, member `unreachable`).

Every frame:

```
{ "version": "1.0", "kind": "…", "id": "<frame-id>", "from": "<instance.id>", "to": "<instance.id>"?, "ts": <unix-ms>, "payload": {…} }
```

`from` on the wire is ignored by the receiver and overwritten with
the `id` bound at JOIN. A member cannot spoof another member on a
connection we already admitted. Chat's existing `from` field (the
**name**, because `sendMessage` writes `cfg.instance.name` and the
board fold keys on it) is filled by the receiving host from the
JOIN-bound name, not from the payload.

Major version mismatch: refuse with a clear error, no subset
negotiation. Minor version may add optional fields; unknown optional
fields are ignored; unknown required `kind` is a protocol error.

First frame on a connection must be `JOIN`. Anything else before
`JOIN_ACK` closes the socket.

| Kind | Payload | Phase |
|---|---|---|
| `JOIN` | `id`, `name`, `card` (A2A shape), `listen` (`host:port` or `[v6]:port`), `share.workspaces[]`, `share.rooms[]` | 1 |
| `JOIN_ACK` | `accepted`, `reason?`, `members[]` (`{id,name,address,state}`), `share` echoed | 1 |
| `LEAVE` | `reason?` | 1 |
| `PING` / `PONG` | `nonce` (echoed) | 1 |
| `CHAT` | body identical to today's `POST /api/chat/message` (`room`, `text`, `id`, `from`, `ts`, `thread_ts?`) | 1 |
| `CHAT_SYNC` | `room`, `after_id?` (empty = "from the start, subject to the sender's `max_history`") | 1 |
| `WORKSPACE_SYNC` | `workspace`, `home`, `cursor`, `sessions[]` (id / title / updated; transcript only on pull) | 3 |
| `SESSION_APPEND` | `workspace`, `session`, `messages[]` | 3 |
| `SESSION_PULL` | `session` | 3 |
| `FILE_OFFER` | `path`, `size`, `sha256`, `offer_id` | 3 |
| `FILE_REQUEST` | `path`, `offer_id`, `offset?` | 3 |
| `FILE_CHUNK` | `offer_id`, `offset`, `data` (base64), `last` | 3 |
| `FILE_NAK` | `offer_id`, `reason` (`disk_full` / `too_large` / `bad_path` / `unknown_offer`) | 3 |

**Liveness, leave, unreachable (one rule).** These used to contradict
each other. The rule is:

- Three missed `PONG`s, a dropped TCP connection, or a protocol error
  → state becomes `unreachable`. The membership row is **kept**. The
  host redials with the same exponential backoff `chatrooms.zig`
  already uses for HTTP cooldown (5s base, cap 5 min).
- An explicit `LEAVE` (ours or theirs) → row **removed**, connection
  closed, no redial.
- `mesh leave` with no id is a self-leave: we send `LEAVE` to every
  member, clear the table, close every socket. The listener stays up.

`unreachable` is how "was offline, came back" stays first-class.
Treating a drop as an implicit `LEAVE` would delete the cursor and
make backfill impossible.

**Chat migrates onto mesh, not into a second system.**
`chatrooms.fanOut` becomes: for each target, if that peer is a
`reachable` mesh member, `POST /api/mesh/relay` on local serve;
otherwise the existing HTTP POST. Local `append` still happens first,
exactly as today. Callers of `chat_send` see no shape change.

Receivers already dedupe by message `id` (`chatrooms.zig`: "receive
ignores a redelivered message id"). Live `CHAT` plus `CHAT_SYNC`
replay is a no-op on a known id. That is also how reconnect backfill
works: after `JOIN_ACK`, each side sends `CHAT_SYNC` for rooms it
subscribes to, with `after_id` from `state/mesh/cursors.json`
(per-`(peer-id, room)`). This is the redelivery gap 0001 left open;
mesh membership is what makes "offline, then back" a state rather
than "peer unreachable, oh well".

Board and goal mirroring need no new frame. A card action is already
a `send` (ADR 0001). Arena Phase 3's `arena-<id>` room rides the same
pipe.

**`ck_mesh` is a privileged channel.** Registered next to `ck_chat`.
Allowed `tool_self_name` values: `mesh_join`, `mesh_leave`,
`mesh_status`, `mesh_pending`, `workspace_share`, `file_share` (and
the internal multiplexed `mesh` name if the web UI wants one
descriptor). Import existing is not a grant.

One WASM module (`tools/zig/mesh.zig`), one op per descriptor in
`config`, sequential, the `chat.zig` shape.

**Guest `mesh_join` cannot widen the world.** A model-initiated join
to an arbitrary `host:port` is SSRF plus "join a hostile mesh".
`ck_mesh` `join` may only dial:

- a host:port that matches a `[[peers]]` URL's host (and port, if the
  URL has one; otherwise the configured `listen_port`), or
- a current member's advertised `listen`.

A never-seen address is CLI / web UI only (operator intent). Those
paths hit `/api/mesh/join` without going through the guest
restriction.

**Pending JOIN is not `ask_user`.** `ask_user` is per-run and dies
with the run. A JOIN can arrive with no agent in flight. Pending
entries live on serve:

- `GET /api/mesh/pending`
- `POST /api/mesh/pending` `{"id":"…","allow":true|false}`
- CLI: `clanker mesh pending` / `admit <id>` / `deny <id>`

Queue depth `mesh.max_pending_joins` (default 8); further JOINs
refused with `reason="pending_full"`. Each entry times out after
`mesh.prompt_timeout_seconds` (default 120, same number as
`agent.ask_timeout_seconds`) and is a refuse. Web UI shows a banner
on the existing Fleet / status surface; no dedicated tree browser.

**Shared workspaces (Phase 3).** Sharing is explicit
(`workspace_share {"workspace":"research","share":true}`), never
implied by JOIN. The member that first shares a session is its
**home**. Home writes the canonical `state/sessions/<id>.json`.
Other members hold a read-only replica under
`state/mesh/<home-id>/sessions/<id>.json`. Continuing the
conversation is `SESSION_APPEND` to home; home assigns order and
broadcasts metadata. If home is `unreachable`, continue is refused
(`reason="home_unreachable"`), not forked locally. Last-writer-wins
applies only to session metadata (title, workspace rename) and is
decided **by home**, so two members' clocks cannot split the
document. Metadata-only catalog on share; full transcript on
`SESSION_PULL`.

**Shared files (Phase 3).** Never the sandbox root. The offering
host checks the `file_share` tool's `fs_prefixes` (and refuses a
path outside them). The receiver does **not** trust any
self-asserted `prefix_ok`. Incoming bytes land under
`state/mesh/<peer-id>/files/<sanitized-relative-path>`. The path
may not be absolute, may not contain `..`, and is subject to the
same `safeJoin` rules that already refuse `.env`. An incoming file
cannot overwrite a local path of the same name.

Defaults (locked, not open questions):

| Knob | Default |
|---|---|
| `file_chunk_bytes` | 32768 raw, before base64 |
| `max_file_bytes` | 32 MiB |
| in-flight transfers per connection | 1 (control frames still interleave) |
| disk full / write error | receiver `FILE_NAK`, offerer stops |

Anyone who has seen the `FILE_OFFER` may `FILE_REQUEST`. Offers are
mesh-visible, not directed, unless a later revision adds `to`.

**Local HTTP control plane** (serve, `modules.mesh` on; 404 naming
the flag when off, except `/api/mesh/map`):

| Method | Path | Role |
|---|---|---|
| `GET` | `/api/mesh/map` | Fleet lamp map: self + `[[peers]]` + chat wires + recent talk pulses. Served even when `modules.mesh` is off so HTTP peers still show. Chat `last_ts` is unix seconds. |
| `GET` | `/api/mesh/status` | members + listen + admission + bind warnings |
| `POST` | `/api/mesh/join` | `{"address":"host:port"}` (operator; no guest host restriction) |
| `POST` | `/api/mesh/leave` | `{"peer_id":"…"}` or `{}` for self-leave |
| `GET` | `/api/mesh/pending` | prompt-mode queue |
| `POST` | `/api/mesh/pending` | `{"id","allow"}` |
| `POST` | `/api/mesh/relay` | local `fanOut` only; not a public peer route. Same Host / CSRF as other `/api/*`. |

**Config.** `modules.mesh` (default **false**) is the feature flag.
No second `enabled` key. Settings:

```toml
[modules]
mesh = false

[mesh]
listen_host = "127.0.0.1"   # not serve's --host; independent on purpose
listen_port = 7420
ping_interval_seconds = 15
admission = "allowlist"     # allowlist | prompt | open
max_members = 32
max_pending_joins = 8
prompt_timeout_seconds = 120
max_frame_bytes = 1048576
max_file_bytes = 33554432
file_chunk_bytes = 32768
```

`listen_host` defaults to loopback so turning the module on is not a
LAN bind. A LAN mesh sets `listen_host` to the reachable address
(and, in v1, stays on RFC1918 or accepts the doctor warning). Mesh
bind is independent of `[serve].host` because the web UI can stay
loopback while the mesh listens on the LAN, or the reverse.

`[[peers]]` keeps `name` + `url` and gains optional `id`.

**CLI**, under the existing `.peers` group, talking to local serve:

```
clanker mesh join <host:port>
clanker mesh leave [<peer-id>]
clanker mesh status
clanker mesh pending
clanker mesh admit <peer-id>
clanker mesh deny <peer-id>
```

**Guest tools** (op pinned in the descriptor):

```
mesh_join:        {"address":"10.0.0.4:7420"}   # host must already be a peer or member
mesh_leave:       {"peer_id":"a1b2c3"}          # omit = self-leave
mesh_status:      {}
mesh_pending:     {} | {"id":"…","allow":true}
workspace_share:  {"workspace":"research","share":true}
file_share:       {"path":"reports/summary.md"}
```

**Doctor** (Phase 1): warn when `modules.mesh` is on and `instance.id`
is empty; when `listen_host` is not loopback / RFC1918 / ULA and TLS
is off; when `admission = "allowlist"` and no `[[peers]]` row has
`id`; when `modules.mesh` is on but serve is the only process that
can listen (informational on `clanker doctor`, not an error).

**Tests, host-side, no real NIC.** Frame codec, admission, the
leave/unreachable state machine, simultaneous-open tie-break, and
cursor backfill are pure functions in `src/peers/mesh.zig` with
`test` blocks. A loopback integration test binds two in-process
endpoints (the `llm/mock_server.zig` shape) and walks JOIN → CHAT →
drop → redial → `CHAT_SYNC`. Add the file to the `comptime` block in
`src/main.zig` or those tests never run. `zig build e2e` grows a
two-process case once Phase 1 lands; it is not a Phase 1 blocker.

**Design decisions (locked).**

1. Serve owns sockets. Everyone else is a loopback HTTP client.
2. `admission` default = `allowlist`. `prompt` / `open` are opt-in.
3. v1 is plain TCP. Non-private bind without TLS is operator risk,
   surfaced by doctor / `mesh status`. TLS+pinning is Phase 2.
4. Protocol version is `major.minor` on every frame. Major mismatch
   refuses; no subset negotiation.
5. `[[peers]]` HTTP and mesh membership stay independent. Optional
   `Peer.id` is the allowlist key. Join/leave does not rewrite
   config.
6. Drop / timeout = `unreachable` + keep row + redial. `LEAVE` =
   remove + do not redial. Never treat a drop as implicit leave.
7. Full mesh, gossip for discovery only, smaller-id-as-dialer on
   simultaneous open. No `mesh_id`.
8. JOIN card is self-asserted. No HTTP fetch to "verify".
9. Pending JOIN is a serve queue, not `ask_user`.
10. Guest `mesh_join` may not dial a never-seen address.
11. Phase 1 includes `CHAT` + `CHAT_SYNC`. Workspace and file share
    wait for Phase 3. Home-instance is the workspace consistency
    rule.
12. `instance.id` is required and operator-set. Mesh does not mint
    one.
13. Only `send` rides the mesh, matching today's `fanOut`.
14. Mesh framing is native, not ACP and not A2A JSON-RPC. A2A
    contributes the card-as-label (and, later, an optional relayed
    `message/send`). ACP is the editor surface and does not touch
    this port.

**Dependencies.**

Hard:

- [PRD 0001](0001-chatrooms.md): message shape, `append` then fan-out,
  id-dedup, `ck_chat` precedent.
- `[[peers]]` + `Instance{name,id}` (`src/config.zig`).
- `clanker serve` accept loop (`src/cli.zig` `cmdServe` /
  `handleConnection`) for the listener and `/api/mesh/*`.
- Sandbox host-function registration (`src/sandbox/host.zig` /
  `runtime.zig`) and `tool_self_name` gates.

Soft:

- [ADR 0001](../adrs/0001-board-is-a-chatroom.md) / [PRD 0002](0002-kanban-board.md):
  board is a `send`; it rides for free.
- [PRD 0008](0008-arena.md) Phase 3: room-backed matches get catch-up
  once `CHAT_SYNC` exists; they do not need a new Arena transport.
- [PRD 0006](0006-webui.md): Fleet / `GET /api/peers` grows mesh rows.
- Phase 2 TLS: new pin store under `state/mesh/pins.json`. No existing
  TLS peer stack to reuse.

**Implementation.** Phased, file-level, independently checkable.

1. **Phase 1: serve-owned LAN TCP + chat pipe.**
   Create `src/peers/mesh.zig` (codec, membership table, persist,
   ping/liveness, JOIN/LEAVE, `CHAT`/`CHAT_SYNC`, loopback tests).
   Edit `src/config.zig` (`modules.mesh`, `Mesh`, optional `Peer.id`).
   Edit `src/cli.zig` (`cmdServe` starts the listener; `cmdMesh`;
   `/api/mesh/*`; replay flags on hot reload via `buildServeArgvTail`).
   Edit `src/sandbox/host.zig` + `runtime.zig` (`ck_mesh` + name gate).
   Edit `tools/zig/lib.zig`, create `tools/zig/mesh.zig` + manifests
   `mesh_join` / `mesh_leave` / `mesh_status` / `mesh_pending`.
   Edit `src/peers/chatrooms.zig` (`fanOut` prefers `/api/mesh/relay`).
   Edit `tools/zig/peers.zig` / `src/peers/phonebook.zig` (path label).
   Edit `src/doctor.zig` (the three warnings).
   Edit `src/main.zig` (comptime import).
   Thin Fleet / status rows + pending banner in `ui/app/` (then
   `zig build tools` + serve restart). No TLS. No workspace/file
   frames.

2. **Phase 2: TLS + pinning.** TLS wrapper on the same framing; pin
   store `state/mesh/pins.json` (id → pin). Doctor warning for
   non-private bind without TLS remains from Phase 1 and clears when
   TLS is on. Identity is the pin; the card stays a label.

3. **Phase 3: workspace home + file share.** `WORKSPACE_SYNC` /
   `SESSION_*` / `FILE_*`, guests `workspace_share` / `file_share`,
   replica root `state/mesh/<peer-id>/`, home-unreachable refuse.

## Usage sketch (once built)

Illustrative. Nothing below exists yet.

Two laptops on a LAN, allowlist:

```toml
# A
[instance]
name = "clanker-a"
id = "a1b2c3"

[modules]
mesh = true

[mesh]
listen_host = "10.0.0.4"
listen_port = 7420
admission = "allowlist"

[[peers]]
name = "clanker-b"
id = "d4e5f6"
url = "http://10.0.0.5:17921"

# B mirrors this with its own id and A's row in [[peers]].
```

```
# both
clanker serve

# either side
clanker mesh join 10.0.0.5:7420
clanker mesh status
```

A chat `send` on A to a room B subscribes to goes out as a `CHAT`
frame on the TCP link, not as `POST http://10.0.0.5:17921/api/chat/message`.
The dummy-down HTTP peer in stock config is unaffected: it is not a
member, so it still gets the HTTP path (and still fails, on purpose).

Under default `allowlist`, two instances with **no** `[[peers]]` row
for each other cannot join. That is the default working. `open` or
`prompt` (plus `admit`) is how a no-prior-config join happens.

## Failure modes

| Condition | Behaviour |
|---|---|
| Serve not running, CLI / `ck_mesh` / `fanOut` wants the mesh | Actionable error: start `clanker serve` with `modules.mesh = true`. Chat `fanOut` falls back to HTTP for configured peers. |
| `instance.id` empty | Listener does not bind. Status / doctor / tools name `[instance] id`. Process otherwise continues. |
| Listen bind failure (port in use / permission) | Mesh stays down for this process. Status / tools report the bind error and the `listen_host` / `listen_port` keys. Serve otherwise continues. |
| Peer unreachable at JOIN | JOIN times out. Caller is told the address did not answer. No membership row. |
| Peer goes unreachable mid-membership | Marked `unreachable` after three missed pongs or a TCP drop. Row kept. Redial with backoff. Cursors kept for `CHAT_SYNC`. |
| Peer sends `LEAVE` | Connection closed. Row removed. No redial. |
| Two members send in the same room | Both appends are messages with distinct ids. No merge. Same as today's two HTTP sends. |
| Duplicate `CHAT` (live + sync, or retry) | Receiver drops the second by `id`. Local log unchanged. |
| `LEAVE` arrives mid-`CHAT` / mid-`FILE_CHUNK` | In-flight frame dropped. Sender sees deliver failure. No partial chat line is appended. |
| Unrecognized JOIN (`allowlist`) | `JOIN_ACK accepted=false reason="not_allowlisted"`. No row. |
| Unrecognized JOIN (`prompt`) | Queued. Timeout or `deny` = refuse. `pending_full` refuses extras. |
| Unrecognized JOIN (`open`) | Accepted if `id` is non-empty and not ours. |
| Membership at `max_members` | Further JOINs refused `reason="max_members"`. |
| Frame major `version` mismatch | Connection closed with both versions named. No membership change if JOIN never completed; else `unreachable`. |
| Frame larger than `max_frame_bytes` | Protocol error: close, `unreachable`, redial (backoff). |
| Non-`JOIN` as first frame | Close. No row. |
| Self-JOIN or JOIN `id` empty | `JOIN_ACK` refuse. |
| Simultaneous open | Keep the connection where the smaller id is the dialer; close the other. One row. |
| Guest `mesh_join` to a never-seen address | `ck_mesh` refuses. CLI / web UI still can. |
| File offered outside offerer's `fs_prefixes` | Offering host refuses. Receiver never sees an offer. |
| Incoming file path absolute or contains `..` | `FILE_NAK reason="bad_path"`. Nothing written. |
| Incoming file would exceed `max_file_bytes` or disk | `FILE_NAK`. Partial file under the mesh root is deleted. |
| Incoming file name collides with a local path | Written under `state/mesh/<peer-id>/files/…`, never over the local file. |
| Continue a shared session whose home is unreachable | Refused `home_unreachable`. Replica stays read-only. |
| Mesh module off | Join/leave/status/relay 404 naming `modules.mesh`. `GET /api/mesh/map` still answers so Fleet can draw HTTP peers. Tools / `ck_mesh` refuse with the same key and "restart serve". Board-style actionable text, not a bare `SandboxDenied`. |
| Bind address is public and TLS is off (v1) | Allowed. Doctor and `mesh status` warn. |
| Serve hot-reload | Sockets drop. Members go `unreachable` and are redialed from `members.json`. |

## Acceptance criteria

Phase 1 (Goals 1, 2, 5, 6, 7):

- [ ] `clanker serve` with `modules.mesh = true` and a non-empty
      `instance.id` listens on `listen_host:listen_port`. `clanker run`
      and `clanker mesh status` do not open that port; they talk to
      serve over loopback. (G7)
- [ ] Two instances whose `[[peers]]` name each other by `id` can
      `clanker mesh join` at runtime (no restart, no config edit after
      start) and both show the other as `reachable`. (G2)
- [ ] Under `admission = "allowlist"`, a JOIN from an id in nobody's
      `[[peers]]` is refused. Under `open`, the same JOIN is accepted.
      Under `prompt`, it sits in `clanker mesh pending` until
      `admit` / `deny` / timeout. (G2)
- [ ] A member that sends `LEAVE` disappears from `mesh status` on
      every other member. A member whose process is killed becomes
      `unreachable` (not absent) within one liveness interval, and is
      `reachable` again after it redials, with `CHAT_SYNC` replaying
      missed `send`s by id. (G2, G5)
- [ ] A `chat_send` while the target is a `reachable` member does not
      open a new HTTP request to that peer's `/api/chat/message`. The
      same `chat_send` to a configured non-member still does. Tool
      shapes are unchanged. (G1, G5)
- [ ] No guest tool holds a mesh socket. `ck_mesh` is name-gated.
      `mesh_join` from a guest to a never-seen address is refused. (G6)
- [x] Frame codec, admission, leave-vs-unreachable, simultaneous-open,
      and id-dedup backfill have host unit tests in `src/peers/mesh.zig`,
      wired from `src/main.zig`. (G1, G2)

Phase 3 (Goals 3, 4):

- [ ] A workspace shared from A is visible as metadata on B without B
      polling. Continuing it from B appends on A (same session id),
      and is refused while A is `unreachable`. (G3)
- [ ] A `file_share` outside the offering tool's `fs_prefixes` is
      refused. A successful share lands under
      `state/mesh/<peer-id>/files/…` and does not overwrite a local
      path of the same name. (G4)

## Open questions / future work

- **NAT / relay.** Out of scope above. Two members both behind NAT
  with no port-forward cannot mesh. Same-LAN / VPN is the v1
  deployment. A relay member would be a new role (and a new trust
  story), not a flag on this design.
- **Per-session exclude.** Sharing is whole-workspace. Excluding one
  session would need a field on `Session` beyond `workspace`. Not
  needed to start Phase 3.
- **Directed file offers.** v1 offers are visible to every member.
  A `to` on `FILE_OFFER` is a small additive frame change if a later
  caller needs it.
- **`id` on `/.well-known/agent.json`.** Additive and useful for
  phonebook. Not required for JOIN (JOIN already carries `id`).
- **Fanning out react/edit/delete.** A 0001 change that mesh would
  then carry for free. Not this PRD's job.
- **Named `mesh_id`.** Only worth it if operators need two open
  meshes on one LAN that must not merge. `allowlist` is the v1
  answer.
