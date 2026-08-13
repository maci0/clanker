# PRD — Clanker Mesh (TCP peer-to-peer clustering)

## Status

Draft. **Do not implement until Design decisions below are locked.** Those
decisions are now locked in this revision (admission default, TLS phasing,
frame versioning, `[[peers]]` dual-path). Nothing described below is
implemented yet. Single source of truth once built: a new `src/peers/mesh.zig`
(host-side, mirroring `src/peers/chatrooms.zig`'s shape) plus a `mesh` host
function and `mesh`/`mesh_join`/`mesh_leave`-style guest tools. This PRD
extends, and where noted **replaces**, the existing static-peer HTTP plumbing
described in `docs/prds/0001-chatrooms.md`.

## Problem

Today "peers" means a static, hand-configured list (`config.toml [[peers]]`,
`Peer{name, url}`, `src/config.zig:356`) that each instance polls or pushes to
over plain HTTP request/response: `POST /api/chat/message` fans a chatroom
message out to every configured peer one request at a time; `peers` (the
`phonebook` action) fetches each configured peer's `/.well-known/agent.json`
A2A agent card and reports it up or down (`tools/zig/peers.zig`). There is no
persistent connection, no membership protocol, and no notion of a peer that
wasn't already in `config.toml` before the process started — adding or
removing a peer means editing config and restarting.

This is enough for a handful of instances the operator knows about in
advance, wired by hand. It breaks down for the case this PRD is for: a
cluster of clanker instances, possibly on different machines and different
networks, that should be able to find each other, join and leave a shared
mesh at runtime, and share more than chat messages — workspaces (the session
folders that already exist locally per instance, `Session.workspace`,
`src/agent/session.zig:18`), arbitrary files, and chatrooms — without an
operator hand-editing every instance's config every time the cluster's
membership changes.

The mechanism has to fit the same constraints `docs/prds/0001-chatrooms.md`
already established for chatrooms, because mesh **is** the transport
chatrooms (and everything built on chatrooms — the kanban board, goal
mirroring) should eventually ride instead of one-off HTTP posts: it must be
something the sandbox can enforce (an explicit host function with declared
reach, never something a guest tool dials out to on its own), and it must not
invent a second, incompatible notion of "peer" beside the one `config.toml`
and the A2A agent card already describe.

## Goals

1. Persistent TCP connections between mesh members, replacing the
   request-per-message HTTP fan-out for anything mesh-aware (chat, board,
   goal mirroring) with a long-lived link each side can push over without
   redialing.
2. Dynamic membership: an instance can join a mesh it wasn't configured with
   at startup, and leave (voluntarily or by going unreachable) without any
   other member restarting or needing a config edit.
3. Shared workspaces: a workspace (and the sessions filed under it) can be
   exposed to the mesh, so a conversation started on one instance is visible
   and continuable from another member that has joined that workspace.
4. Shared files: an explicit, bounded set of paths (never the whole sandbox
   root) can be replicated to mesh members that request them, under the same
   `fs_prefixes`-style declared-reach model every other file-touching tool
   already uses.
5. Chatrooms keep working unchanged from a caller's point of view
   (`chat_send`/`chat_history`/`chat_rooms`/`chat_subscribe` keep their
   existing shapes) — mesh membership becomes an additional way a room's
   messages fan out, not a second chat system.
6. Every mesh operation stays a host function, never a capability a guest
   tool can reach directly — matching the `ck_chat` precedent.

## Non-goals

- Byzantine fault tolerance or defending against a malicious member already
  inside the mesh. Trust is established at admission (see Design); once a
  peer is a member, it is trusted the way a configured chatroom peer is
  trusted today.
- Automatic conflict resolution beyond last-writer-wins. A file or workspace
  edited concurrently on two members picks a winner by timestamp, the same
  rule `cards.zig` already uses for card fields — it does not attempt a merge.
- NAT traversal, hole punching, or a rendezvous/relay server for members that
  cannot open a direct connection to each other. Mesh members are assumed
  mutually reachable (same LAN, VPN, or public IP with an open port) at the
  address they advertise; making unreachable members reachable is a
  deployment concern, not this PRD's.
- End-to-end encryption beyond what TLS-on-the-socket provides. v1 is plain
  TCP for LAN-only (see Design decisions); TLS+pinning is Phase 2, not a v1
  deliverable.
- A UI for browsing the whole mesh's combined file/workspace state as one
  tree. The webui gets per-member visibility (whose workspace, whose file);
  a unified cross-member view is future work if wanted at all.
- Replacing `/.well-known/agent.json` / A2A. Mesh admission reuses the agent
  card for identity, it does not invent a competing identity document.

## Design

**Node identity.** Every instance already has `Instance{name, id}`
(`src/config.zig:362`, `id` defaulting to a generated stable value). A mesh
member is addressed by that same `id`, not by `name` (names collide across
operators; ids are meant to be unique) and not by IP:port alone (an
instance's address can change; its id should not).

**Membership is a protocol, not a config list.** `config.toml` keeps
`[[peers]]` for the "instances I trust enough to auto-admit" bootstrap set
(today's static list is the mesh's seed/allowlist under the default
`admission = "allowlist"`, not its whole membership — and it remains an
independent HTTP path in v1; see Design decisions). Joining beyond that set
goes through an explicit handshake:

1. Instance A dials instance B's mesh port with a `JOIN` frame carrying A's
   agent card (reusing the existing `/.well-known/agent.json` shape, over
   the new TCP framing instead of a second HTTP round trip) and the
   workspaces/rooms it wants to share.
2. B decides: auto-accept (A is in B's `[[peers]]` allowlist, or B is
   configured to accept any A2A card it can fetch and verify), prompt an
   operator (webui/TUI surfaces a pending-join notification, mirroring how
   `ask_user` surfaces a question today), or refuse.
3. On accept, B sends back its own membership view (who else is in the mesh
   it already knows about) so A can dial them too — gossip-style discovery
   rather than every member needing every other member pre-configured.
4. Either side can send `LEAVE` at any time; the connection dropping without
   one is treated as an implicit leave after a liveness timeout (see Failure
   modes), not an error condition.

**Transport framing.** One long-lived TCP connection per member pair,
length-prefixed JSON frames (matching the JSON-everywhere convention the rest
of the host already uses for `ck_chat`/`ck_fs_*`/etc. — no new serialization
format to maintain). Frame kinds: `JOIN`, `JOIN_ACK`, `LEAVE`, `PING`/`PONG`
(liveness), `CHAT` (a chatroom message, replacing the `POST
/api/chat/message` body 1:1), `WORKSPACE_SYNC` (session metadata + new
messages for a shared workspace), `FILE_OFFER` / `FILE_REQUEST` /
`FILE_CHUNK` (bounded file transfer, chunked so one large file can't stall
liveness pings behind it on the same connection — a second logical stream, or
a cap on chunk size interleaved with control frames).

**Host function, not guest reach.** `mesh.zig` owns every socket, the
membership table, and all TCP I/O, exactly the way `chatrooms.zig` owns
`state/chatrooms.jsonl` and peer HTTP delivery today. Guest tools
(`mesh_join`, `mesh_leave`, `mesh_status`, and reusing `chat_*`/a new
`workspace_share`/`file_share`) pass arguments through and get JSON back;
none of them ever holds a socket or a file descriptor. This is the same
"thin guest, honest host" shape `docs/prds/0001-chatrooms.md` Design already
states and justifies (a misbehaving guest can't widen its reach beyond what
the descriptor declares).

**Shared workspaces.** A workspace is shared explicitly (`{"workspace":"research","share":true}`
on some new/extended tool) — not implicit in joining the mesh. Sharing a
workspace means: its sessions' metadata (id, title, updated, **not** full
transcript) replicate to every mesh member on share, and a member can pull a
specific session's full transcript on demand (mirroring how workflows send a
catalog line always and the body only on request — the same shape this
session already applied to skills and workflows, for the same reason: don't
pay the cost of the whole thing everywhere it might be looked at). Continuing
a shared conversation from a different member appends to the same session id;
last-writer-wins on the session's own metadata (title, workspace) the way a
card's edited fields already resolve.

**Shared files.** Never the sandbox root wholesale. A file (or a declared
prefix) is offered explicitly, the same way `fs_prefixes` scopes what a tool
may already reach — sharing a path outside every local tool's own
`fs_prefixes` is refused at the host, not left to the guest to avoid asking
for. A receiving member writes into its own sandbox under a mesh-scoped
subpath (e.g. `state/mesh/<peer-id>/<path>`), never directly over a local
file of the same name — an incoming file cannot silently overwrite something
the receiving instance already has.

**Chatrooms migrate onto mesh, not replaced by it.** `chat_send`'s existing
fan-out (`POST /api/chat/message` to every configured peer,
`docs/prds/0001-chatrooms.md` Design) becomes: fan out over the mesh
connection when the target peer is a mesh member, fall back to the existing
HTTP POST when it's a configured-but-not-meshed peer (or the mesh module is
off). No caller-visible change to `chat_send`/`chat_history`/etc.'s shapes;
this is purely which pipe a message travels over.

**Liveness.** Each connection exchanges `PING`/`PONG` on a fixed interval
(config: `mesh.ping_interval_seconds`, default matching the sandbox's other
timeout defaults). Three missed pongs → the member is marked `unreachable`
(not removed from membership — it can still catch up when it comes back) and
its connection is retried with backoff, not torn down and forgotten.

**Design decisions (locked).**

- **`mesh.admission` default = `allowlist`.** Auto-admit only peers named in
  `[[peers]]`. `prompt` and `open` are explicit opt-in (`admission = "prompt"`
  / `"open"` in config). An open mesh is never the surprise default.
- **TLS: v1 plain TCP for LAN-only.** Binding beyond localhost/private nets
  without TLS is operator risk and must be called out in `clanker doctor` /
  mesh status when the listen address is not loopback or RFC1918. TLS with
  per-peer pinning is Phase 2 (see Implementation), not a blocker for a
  same-LAN mesh.
- **Protocol versioning.** Every frame carries a `version` field. A mismatched
  major version is refused with a clear error (no subset negotiation). Minor
  version differences may add optional fields; unknown optional fields are
  ignored, unknown required kinds are refused.
- **`[[peers]]` dual-path.** Mesh membership and `[[peers]]` HTTP remain
  independent in v1. `[[peers]]` is still the admission allowlist seed and
  still the static HTTP fan-out path for non-meshed peers. Phonebook lists
  both (mesh members and configured HTTP peers), labeled by path. Mesh does
  not auto-rewrite `[[peers]]` on join/leave.

**Frame kinds → payload fields.** Every frame is length-prefixed JSON with
common envelope `{version, kind, from, to?, ts}` plus a `payload` object:

| Kind | Payload fields |
|---|---|
| `JOIN` | `card` (A2A agent card), `share.workspaces[]`, `share.rooms[]`, `listen` (advertised `host:port`) |
| `JOIN_ACK` | `accepted` (bool), `reason?`, `members[]` (`{id,name,address,state}`), `share` echoed |
| `LEAVE` | `reason?` |
| `PING` | `nonce` |
| `PONG` | `nonce` (echo) |
| `CHAT` | chatroom message body identical to today's `POST /api/chat/message` (`room`, `text`, `id`, `sender`, …) |
| `WORKSPACE_SYNC` | `workspace`, `cursor`, `sessions[]` (metadata: id/title/updated; full transcript only on pull) |
| `FILE_OFFER` | `path`, `size`, `sha256`, `prefix_ok` (offerer asserts local `fs_prefixes` allow) |
| `FILE_REQUEST` | `path`, `offer_id`, `offset?` |
| `FILE_CHUNK` | `offer_id`, `offset`, `data` (base64), `last` (bool) |

**Dependencies.**

- [PRD 0001 (chatrooms)](0001-chatrooms.md): message shape, HTTP fan-out fallback,
  `ck_chat` host-function precedent.
- `config.toml` `[[peers]]` + `Instance{name,id}` (`src/config.zig`),
  `/.well-known/agent.json` A2A card (`src/peers/phonebook.zig`).
- `src/peers/chatrooms.zig` delivery path (mesh becomes an alternate pipe,
  not a second chat system).
- Sandbox host-function registration pattern (`ck_chat` / thin guest tools).
- Phase 2 TLS+pinning additionally depends on a per-peer cert store under
  `state/mesh/` (new); no existing TLS peer stack to reuse.

**Implementation.** Phased, file-level:

1. **Phase 1: framing + membership (LAN TCP).** `src/peers/mesh.zig`
   (listen/dial, frame codec, membership table, ping/liveness, JOIN/LEAVE),
   config `[mesh]` in `src/config.zig`, CLI `clanker mesh …` arms in
   `src/cli.zig`, guest tools `tools/zig/mesh.zig` + manifests
   (`mesh_join`/`mesh_leave`/`mesh_status`), phonebook dual-list labeling.
   Chat fan-out prefers mesh when the target is a member (`chatrooms.zig`
   call site). No TLS.
2. **Phase 2: TLS + pinning.** TLS wrapper on the same framing; pin store
   under `state/mesh/pins.json`; doctor warning for non-private bind without
   TLS remains from Phase 1 and clears when TLS is on.
3. **Phase 3: workspace + file share.** `WORKSPACE_SYNC` /
   `FILE_OFFER`/`REQUEST`/`CHUNK` paths, `workspace_share`/`file_share`
   guests, mesh-scoped write root `state/mesh/<peer-id>/`, backfill on
   reconnect.

## Usage sketch (once built)

Illustrative only — nothing below exists yet (see Status). Shown so the
shape of Design reads as something a user would actually type, not just
mechanism.

**Config.** A new `[mesh]` table, off by default like every other optional
module (`cfg.modules.*`):

```toml
[mesh]
enabled = true
listen_port = 7420
ping_interval_seconds = 15
admission = "allowlist"   # default (locked); "prompt" | "open" are opt-in
max_members = 32
```

`[[peers]]` keeps its existing shape (`docs/prds/0001-chatrooms.md`) and
is the allowlist `admission = "allowlist"` auto-admits from. It also remains
an independent HTTP path in v1 (see Design decisions); mesh join/leave does
not rewrite it.

**CLI**, under the existing `.peers` command group alongside `chat`/`notify`/
`phonebook` (`src/cli.zig:1235-1237`), following `chat <subcommand> ...`'s own
style exactly:

```sh
clanker mesh join <host:port>     # dial a member, JOIN handshake
clanker mesh leave <peer-id>      # explicit LEAVE, or self-leave with no id
clanker mesh status               # every known member: id, address, reachable|unreachable
```

**Guest tools**, following `chat_*`'s op-in-config, thin-guest shape
(`tools/zig/chat.zig`'s own doc comment: one WASM module, op pinned by the
descriptor's `config`, all real state and I/O host-side):

```
mesh_join:   {"address":"10.0.0.4:7420"}
mesh_leave:  {"peer_id":"a1b2c3"}          # omit peer_id to leave the whole mesh
mesh_status: {}                            # -> [{"id":"a1b2c3","name":"...","address":"...","state":"reachable"}]
workspace_share: {"workspace":"research","share":true}
file_share:  {"path":"reports/summary.md","to":"a1b2c3"}
```

**Web UI / REPL.** A mesh status panel beside the existing peers/phonebook
view (`docs/prds/0006-webui.md`), a pending-`JOIN` notification when
`admission = "prompt"` (reusing the `ask_user` surface, per Design), and
`mesh_status` reachable from `/mesh` the way `/plugins` reaches
`plugins` today.

## Failure modes

| Condition | Behaviour |
|---|---|
| Peer unreachable at JOIN time | `JOIN` times out; caller told the address didn't answer, not left hanging |
| Peer goes unreachable mid-membership | Marked `unreachable` after missed pings (see Liveness); membership entry kept, not dropped, so it can resync on reconnect |
| Peer sends `LEAVE` | Connection closed cleanly, membership entry removed, no reconnect attempted |
| Connection drops with no `LEAVE` | Treated as implicit leave after the liveness timeout — same end state as an explicit `LEAVE`, just slower to detect |
| Two members edit the same shared session concurrently | Last-writer-wins by timestamp on session metadata; message-level content is append-only so there is nothing to merge there, only the metadata (title/workspace) can actually conflict |
| File offered outside every local tool's `fs_prefixes` | Refused at the host; the offering side is told why, not silently dropped |
| Incoming file collides with an existing local path | Written under the mesh-scoped subpath, never over the local file |
| Member rejoins after being offline | Gets a `WORKSPACE_SYNC`/room backfill from its last known cursor, not just new traffic going forward — this is the redelivery gap `docs/prds/0001-chatrooms.md`'s Open questions left unresolved for plain chatrooms; mesh membership is what finally needs it fixed, since "was offline, came back" is now a first-class state instead of just "peer unreachable, oh well" |
| Mesh module disabled in config | All mesh tools/host functions refuse with an actionable message (config key to flip, restart needed) — same pattern the board uses today when chatrooms are off |
| Untrusted/unrecognized `JOIN` | Refused outright, or queued for operator decision, depending on `mesh.admission` config — never silently admitted |
| Listen bind failure (port in use / permission) | Mesh module starts disabled for this process; `mesh status` and mesh tools report the bind error and the config key to fix; process otherwise continues |
| `LEAVE` arrives mid-`CHAT` / mid-`FILE_CHUNK` | In-flight frame is dropped; sender sees deliver failure for that message/chunk; membership removes the peer; no partial chat line is appended on the receiver |
| Membership at `mesh.max_members` (default 32) | Further `JOIN`s refused with `reason="max_members"`; operator must raise the cap or leave an existing member |
| Frame with mismatched major `version` | Connection refused/closed with a version-mismatch error naming both versions; no membership change |
| Bind address is public and TLS is off (v1) | Allowed, but `clanker doctor` / `mesh status` warn that this is operator risk (Design decisions) |

## Acceptance criteria

- [ ] Two instances with no shared `config.toml` peer entry can join a mesh
      at runtime given only one address, and both end up seeing each other
      as members.
- [ ] A member that leaves (explicitly or by going unreachable) is reflected
      in `mesh_status` on every other member within one liveness interval.
- [ ] A chatroom message sent while the target is a mesh member travels over
      the TCP connection, not a new HTTP request per message.
- [ ] A workspace shared from instance A is visible (metadata only) on
      instance B without B polling for it.
- [ ] A session continued from instance B after being started on instance A
      appends to the same session id, not a duplicate.
- [ ] A file share request for a path outside the offering tool's
      `fs_prefixes` is refused, not silently narrowed or ignored.
- [ ] No guest tool ever holds a mesh socket directly — every mesh op is a
      host function call.
- [ ] A member that reconnects after being offline receives backfill, not
      just messages sent after it reconnected.

## Open questions / future work

- **NAT/reachability / relay.** Explicitly out of scope above, but still
  open as product scope: two members both behind NAT with no port forwarding
  cannot mesh directly under this design. Acceptable for same-LAN/VPN, or
  does a relay/rendezvous member become necessary sooner than "future work"?
- **Large file transfer and backpressure.** `FILE_CHUNK` chunking is named
  in Design to keep pings unblocked, but the actual chunk size, concurrent
  transfer cap, and what happens when a receiving member is out of disk
  space are unresolved.
- **Per-session share granularity.** Design assumes whole-workspace sharing.
  Can specific sessions within a shared workspace be excluded? Would need
  its own field on `Session` beyond the existing `workspace` string. Still
  open.
