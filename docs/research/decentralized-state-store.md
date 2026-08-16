# Research — Decentralized state store for isolated worktrees and mesh peers

## Status

Current — searched 2026-08-16. Draft 3: separates the access path (tier 1) from where state lives (tier 2). Loopback fixes only tier 1; PostgreSQL and NATS JetStream lead tier 2, both with native Zig 0.16 clients.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Which backend, concurrency-control mechanism and access path should clanker use
so runs isolated in git worktrees, **and instances running on different servers
in a network**, can read and write shared agent state concurrently without
copying state directories?

Four constraints make the question answerable rather than open-ended:

1. **The writer is a sandboxed wasm guest.** Whatever it calls must be reachable
   through a `ck_*` host function under a manifest grant, not through an ambient
   filesystem path.
2. **The harness is Zig 0.16** with two fetched dependencies (`zwasm`, `vaxis`)
   plus vendored TOML. A candidate's cost includes what it adds to that list —
   and whether a Zig client for it exists at all.
3. **The deployment is many servers, not one laptop.** Tens to thousands of
   concurrent agents spread across hosts on a network, each of which may fail
   independently.
4. **No agent may be blocked by another agent's host being down.** This is the
   constraint that separates the candidates, and the one the current design does
   not meet.

## Two tiers, not one

The first two drafts of this note collapsed two independent questions into one
answer, and that was their central error. They are separate axes and each needs
its own decision:

```
guest (wasm, inside a worktree)
  │
  │  TIER 1 — the access path
  │  How does a sandboxed guest reach state at all?
  │  Problem it solves: safeJoinSecure / shared_root fragility
  ▼
local clanker serve
  │
  │  TIER 2 — where state lives
  │  Which store holds the truth for N servers, and who resolves concurrency?
  │  Problem it solves: cross-host sharing, availability, scale
  ▼
shared backend  (or peer mesh, or local files)
```

**Tier 1 is a local question with a clear answer** (option A below): a name-gated
`ck_state` host channel, with the host doing the I/O. It removes the recurring
worktree breakage. It is necessary and it is nowhere near sufficient — a loopback
call reaches the *local* serve and nothing else, so tier 1 alone leaves every
server an island.

**Tier 2 is the open question** and is where every remaining option lives. Note
that tier 1 makes tier 2 *replaceable*: once guests call `ck_state` instead of
writing paths, the backend behind serve can change without touching a single
guest. That is the strongest argument for doing tier 1 first, and it is an
argument about optionality rather than about state.

## What PRD 0011 decides, and what it leaves open

[PRD 0011](../prds/0011-clanker-mesh.md) is marked *design locked, in progress*
(Phase 1 partly built). It is a **candidate for tier 2, not the frame for this
question** — an in-progress design is evidence about intent, not a constraint
research must accept. Read 2026-08-16.

**What it settles.**

- **Tier 1's shape, for a different noun.** Locked decision 1: *"Serve owns
  sockets. Everyone else is a loopback HTTP client."* `ck_mesh` is a name-gated
  host channel; the host does the I/O; the guest never holds a socket and never
  needs `network_allow`. Option A is that pattern applied to state, so tier 1 is
  not a new architecture — it is the existing one.
- **Session and workspace consistency, by ownership.** The member that first
  shares a session is its **home**; home writes the canonical
  `state/sessions/<id>.json`; other members hold a read-only replica under
  `state/mesh/<home-id>/`. This *is* a cross-server mechanism — the question is
  whether it is the right one.
- **Board and goals, as a replicated log.** A card action is a chat `send`
  (ADR 0001), fanned out and deduped by message id. Eventually consistent, with
  no conflict resolution: two agents moving one card to different lanes both
  append, and fold order decides.

**What it does not settle, and this is the larger half.**

1. **Most of `state/` is not covered at all.** `token_stats.jsonl`,
   `improvements.jsonl`, `autolearn.jsonl`, `reasoning.jsonl`, knowledge and
   `learnings.md` have no mesh frame and no replication story. On a fleet they
   stay **per-host islands**. For a system whose whole premise is collective
   self-improvement, that is the most consequential gap in this note: a hundred
   servers would produce a hundred disjoint improvement logs and a hundred
   private sets of learnings.
2. **`max_members = 32`.** Full mesh, *"32·31/2 = 496 connections, which is the
   point of the cap."* That is a property of choosing full-mesh gossip, not a
   requirement of the problem. At the stated deployment size the topology is the
   binding constraint, and a shared backend does not have it.
3. **Availability is per-entity single-point-of-failure.** *"If home is
   `unreachable`, continue is refused (`reason="home_unreachable"`), not forked
   locally."* Correct, and deliberately so — but it means every host is a SPOF
   for the sessions it owns. On one laptop that is invisible; across servers it
   means routine host maintenance strands work.
4. **"No CRDT, no merge"** is a non-goal that follows from the ownership model.
   It stays sound for tier 2 candidates that also have a single writer per
   entity, and it is not binding on a store that resolves concurrency itself.

So the PRD's own model — peer-to-peer full mesh, per-entity ownership, refuse on
owner loss — is **option I** in the survey below, ranked against the shared-store
candidates rather than above them.

## TL;DR

- **Tier 1 and tier 2 are separate decisions, and loopback only answers tier 1.**
  A `ck_state` channel to the local serve fixes the worktree breakage and leaves
  cross-server state entirely unsolved. Both halves are needed; only tier 1 is
  currently obvious — `high` confidence.
- **The pain in tier 1 is the path, not the store.** Worktree state sharing is
  two mechanisms that must agree — host-side symlinks (`linkCheckoutState`,
  `src/improve/worktree.zig:313`) and guest-side prefix routing (`rootForPath`,
  `src/sandbox/host.zig:4742`). `shared_root` is a special case *inside*
  `safeJoinSecure`, the function the improve loop exists to harden — `high`
  confidence, observed in-tree
  ([bug](../reports/bugs/2026-08-14-worktree-state-symlink-notdir.md)).
- **Route tier 1 through a name-gated channel, not a `network_allow` grant.**
  `networkAllowed` (`src/sandbox/host.zig:2350`) glob-matches the hostname and
  never examines the port, so a `["127.0.0.1"]` grant admits *any* local service.
  `ck_mesh` avoids this by gating on `tool_self_name` — `high` confidence.
- **PostgreSQL is the strongest tier-2 candidate and was missing from the first
  two drafts.** It expresses all four of clanker's data shapes with one
  dependency — append tables, row-version CAS, bytea blobs, and `FOR UPDATE SKIP
  LOCKED` plus advisory locks for claims — and `pg.zig` is a **native Zig 0.16
  driver needing no libc and no C client** (MIT, 591 stars, read 2026-08-16) —
  `high` confidence
  ([pg.zig](https://github.com/karlseguin/pg.zig),
  [PG explicit locking](https://www.postgresql.org/docs/current/explicit-locking.html)).
- **NATS JetStream is the strongest event-shaped alternative, and it has an
  official Zig client.** `nats-io/nats.zig` requires Zig 0.16+, is Apache-2.0,
  and supports JetStream and the KV store with integration tests — though it is
  explicitly pre-1.0 with an API that may change — `high` confidence
  ([nats.zig](https://github.com/nats-io/nats.zig)).
- **Correction to the previous draft: "no Zig client found" was wrong for both.**
  That claim carried a `low confidence, one search only` caveat and the caveat
  fired. Both candidates are materially more viable than the last revision said.
- **etcd needs no Zig client and has the best CAS and lease primitives here — and
  is still not the answer.** Its gRPC-gateway exposes the whole v3 API as base64
  JSON over HTTP, so clanker's existing HTTP client reaches it today. `Txn`
  compares on `mod_revision` *is* the document-CAS shape, and TTL leases *are*
  the claim shape. But a 1.5 MiB max request and an 8 GB suggested store, on a
  system its own docs call *"not intended as a general-purpose database"*, rule
  it out for sessions and logs — `high` confidence
  ([gateway](https://etcd.io/docs/v3.5/dev-guide/api_grpc_gateway/),
  [limits](https://etcd.io/docs/v3.3/dev-guide/limit/)).
- **FoundationDB is ruled out by a measured number, not a judgement.** Values
  cannot exceed 100,000 bytes and transactions cannot exceed 5 seconds. **19 of
  this checkout's 38 session transcripts already exceed the value limit**, with a
  median of 95 KB sitting on the line and a maximum of 1.75 MB — `high`
  confidence
  ([known limitations](https://apple.github.io/foundationdb/known-limitations.html),
  local measurement).
- **The PRD's full-mesh model does not reach the stated scale.** 32 members,
  per-entity SPOF, and no replication for the improvement and learning logs. It
  is a reasonable v1 for a handful of instances and is not what a fleet of
  servers needs — `high` confidence, from the PRD itself.
- **CRDTs remain rejected, now on their own merits.** With a shared backend
  resolving concurrency there is nothing for them to do; the append-only logs
  need ordering, not merging. The PRD's non-goal is no longer the reason —
  `medium` confidence.

## Scope and method

- **Searched:** the local tree first (`src/sandbox/host.zig`,
  `src/improve/worktree.zig`, `src/util/file_lock.zig`, `src/peers/`,
  `build.zig`, `build.zig.zon`, `docs/reports/`), then
  [PRD 0011](../prds/0011-clanker-mesh.md) in full, then web search on eight axes
  — embedded SQLite concurrency, libSQL/Turso embedded replicas, CRDT library
  comparison, NATS JetStream KV vs etcd vs FoundationDB, S3 conditional writes,
  agent-harness worktree architectures, PostgreSQL coordination primitives, and
  Zig client availability for the surviving candidates. The `research` tool's
  `plan` and `sweep` actions were run first (see [Appendix](#appendix)).
- **Not searched:** hosted control planes (Temporal, Restate, Dapr) — they
  replace the agent loop rather than the state store. Raft-in-Zig was not
  surveyed; if a self-hosted store wins, its own HA is a later question. No
  benchmark was run: every performance number is quoted, not measured. Neither
  Zig driver was compiled or run against a live server.
- **Freshness:** all verification 2026-08-16. The PRD is the fastest-moving input
  — marked *in progress*, so a Phase 1 landing or a revised non-goal dates this
  note before any external source does. `nats.zig` is pre-1.0 and its API is
  declared unstable.
- **Revision history.** Draft 1 was written without PRD 0011. Draft 2 read it and
  over-corrected, treating an in-progress design as settled ground and archiving
  the cross-host candidates. Draft 3 (this one) separates the two tiers, restores
  those candidates, adds PostgreSQL — absent from both earlier drafts — and
  corrects two wrong "no Zig client" claims. The tier-1 finding is the only one
  that has survived unchanged throughout.

## The problem, stated in terms of the current tree

Worth writing down precisely, because two of the candidates below only make
sense against it.

**What state is.** `state/` is not one thing. It is four access patterns:

| Shape | Files | Bytes (2026-08-16) | Concurrency need |
|---|---|---|---|
| Append-only event logs | `token_stats.jsonl`, `improvements.jsonl`, `autolearn.jsonl`, `reasoning.jsonl`, `chatrooms.jsonl` | 3.2 M / 1.7 M / 1.3 M / 348 K / 236 K | Atomic append; order need not be global |
| Small mutable documents | `goals.json`, `tool_usage.json`, `worktrees.json`, `webui_plugins.json` | 4 K each | Read-modify-write, must not lose a record |
| Per-entity directories | `sessions/`, `runs/`, `history/`, `arena/` | 9.5 M / 4.4 M / 1.1 M / 12 K | Single-owner writes; concurrent readers |
| Coordination sidecars | `*.lock` | 0 | Mutual exclusion |

Only the second row genuinely needs compare-and-swap. The first row needs
atomic append, which is a weaker and much cheaper guarantee. Conflating them is
why the current CAS primitive does not fit the files that grow.

**What the current mechanism is.** For a `--worktree` run, two halves must agree:

- **Host half:** `linkCheckoutState` (`src/improve/worktree.zig:313`) symlinks
  each entry of `host.shared_prefixes` (`state`, `.local`, `.agents`, `.claude`,
  `.env`, `config.local.toml`, `config.local.json`) from the worktree back to the
  checkout, so the ~44 hardcoded relative `state/...` paths in `src/` resolve
  correctly after the `chdir`.
- **Guest half:** `rootForPath` (`src/sandbox/host.zig:4742`) resolves those same
  prefixes against `Sandbox.shared_root` instead of `root_dir`, because
  `safeJoinSecure` (`:4691`) does a no-follow walk and refuses to cross the
  symlink the host half just made.

The comment on `linkCheckoutState` says it outright: *"Both halves are needed and
they are not redundant: without the links the host writes a worktree-local
state/ nobody reads, and without the routing every sandboxed tool is denied the
moment it touches a linked component."*

That is the fragility the question is about. `shared_root` is a **special case
inside the path-security check**, and the improve loop's job is to harden exactly
that check. The tree records the failure mode twice already
([bug](../reports/bugs/2026-08-14-worktree-state-symlink-notdir.md),
[investigation](../reports/investigations/2026-08-14-isolated-cli-worktree-notdir.md)),
and `git log` shows a hardening rollback at `44071710`. A live instance appeared
during this very research session: every `clanker run` used to drive the
`research` tool ended with

```
graph write: writing the run graph: refused by this tool's sandbox policy
```

**Why "copy in, merge back" is not the fix.** It is O(state) per agent in time
and space, it has no merge function for the append-only logs, and at the stated
target of 10³–10⁴ agents the copy alone dominates. The current design already
rejects it for plain runs, which is why `linkCheckoutState` exists at all.

## Options found

### Tier 1 — the access path

How a sandboxed guest reaches state at all. Local question, and the two options
are not rivals: B is the fallback if A is judged too large.

### A. `ck_state` host channel to serve, over loopback — the house pattern extended

**Strongest candidate.** It is the only one that removes the fragile mechanism
instead of adding a second beside it, and PRD 0011 has already committed to its
shape for a neighbouring problem.

- **What it is:** make `clanker serve` the owner of `state/`. A guest calls
  `ck_state`, a name-gated privileged channel registered next to `ck_chat` and
  `ck_mesh`; the **host** turns that into a loopback HTTP request to the local
  serve, which does the write natively on the machine where `state/` lives. The
  guest holds no socket and needs no `network_allow`. A worktree needs no
  symlink and no `shared_root` special case, because it never names a path
  outside itself.
- **Maturity:** in-tree and, for the mesh half, already specified. 43 distinct
  `/api/*` routes exist today, including `/api/goals`, `/api/sessions`,
  `/api/runs`, `/api/stats`, `/api/board`, `/api/chat/*`, `/api/events` (SSE).
  `src/peers/chatrooms.zig:790` already fans a write out over HTTP with per-peer
  backoff. PRD 0011 routes `clanker mesh`, `ck_mesh` and `fanOut` through
  loopback-to-serve as locked decision 1. Read 2026-08-16.
- **Fit:** exact, and it is the same shape three existing subsystems already
  have. It also satisfies PRD 0011's non-goal "no second daemon", because the
  owner is serve, which already stays up.
- **Pros:**
  - Kills the `shared_root` special case in the path checker. A hardening pass
    on `safeJoinSecure` can no longer break state access, because state access
    stops being a path. This is the whole point.
  - Concurrency control moves into one native process that can hold real locks,
    coalesce appends, and batch — instead of N guests racing on a filesystem.
    This is what makes the many-processes-on-one-host scale tractable.
  - The name-gated channel avoids the authorization hole a `network_allow`
    grant would open: `tool_self_name` decides, and the port never appears in a
    manifest.
  - Same door for the local and mesh cases, so `state/mesh/<peer-id>/` replicas
    and local state stop being different code paths.
  - Failure is legible: a status code, not a silent write into a worktree-local
    `state/` nobody reads.
- **Cons:**
  - A run now depends on serve being up. PRD 0011 already had to answer this for
    mesh — *"Actionable error: start `clanker serve`"* — but state is not
    optional the way mesh is, so refusing every run without a daemon is a much
    bigger behaviour change. A fallback to direct filesystem writes reintroduces
    exactly the divergence the channel exists to prevent.
  - Latency per state write goes from a syscall to a request. Matters for the
    hot append logs, which is an argument for batching them behind the channel.
  - It is a new host channel and a new API surface: real work, not just wiring.
- **Unknowns:** whether the existing routes cover enough of `state/` to avoid a
  large new API; per-write latency; what happens to `clanker run` on a machine
  where the operator never starts serve — which is the design's central
  question, not a detail.
- **Evidence:** [PRD 0011](../prds/0011-clanker-mesh.md) locked decisions 1 and
  the "Serve owns the mesh" caller table; `src/cli.zig` route table;
  `src/peers/chatrooms.zig:790`; `src/sandbox/host.zig:2350` (why the channel is
  preferable to a network grant).

### B. Harden and generalize the existing `ck_fs_write_if` CAS — smallest change

- **What it is:** keep the filesystem as the store, but give guests real
  concurrency primitives through host functions instead of raw writes. Today
  that is one function, `ck_fs_write_if` (`src/sandbox/host.zig:3117`).
- **Maturity:** in-tree and working for small documents.
- **Fit:** partial, and the gap is measurable. Whole-file CAS is O(file) per
  write and bounded by `max_fs_bytes` (1 MiB default, `:178`). Against the table
  above it covers row 2 (4 KB documents) and cannot cover row 1 at all — the
  smallest hot log is already 236 KB and the largest is 3.2 MB.
- **Pros:** no new dependency, no daemon, no protocol; the primitive already
  exists and is already tested.
- **Cons:**
  - Does not solve the stated problem. The CAS still goes through
    `safeJoinSecure` and `rootForPath`, so it is exactly as exposed to sandbox
    hardening as a plain write.
  - Whole-file CAS under contention degrades quadratically: every loser re-reads
    the whole file and retries. At 10³ agents on one `goals.json` this is a
    livelock, not a slowdown.
  - No cross-host story at all, so it does not help mesh.
- **Missing primitives it suggests:** an atomic `ck_state_append` (correct and
  cheap for row 1, where CAS is the wrong tool), and key-level rather than
  file-level granularity for row 2.
- **Evidence:** `src/sandbox/host.zig:3110-3175`; `src/util/file_lock.zig:1-13`
  records the measured lost-update rate this class of bug produces — *"six
  writers posting ten messages each kept twelve of sixty."*

---

### Tier 2 — where state lives

Which store holds the truth across N servers, and who resolves concurrency. This
is the open half. Options C through I are all tier-2 answers; A is orthogonal to
every one of them and composes with all of them.

Two candidates lead, for different data shapes, and both now have native Zig
clients on the current compiler — which was the objection that ruled them out in
the previous draft, wrongly.

### J. PostgreSQL — one dependency, all four data shapes

**Strongest tier-2 candidate.** Listed out of alphabetical order because it was
absent from the first two drafts; adding it changed the ranking.

- **What it is:** a single shared relational server that every clanker instance
  connects to over the network. `serve` becomes a client, not the owner of truth.
- **How it expresses clanker's four shapes** — the reason it leads, since no
  other single candidate covers all four:

  | Shape | Mechanism |
  |---|---|
  | Append-only logs | plain `INSERT` into an append table; MVCC means writers never block each other |
  | Documents (CAS) | `UPDATE ... WHERE key = $1 AND revision = $2`, row count 0 means lost the race |
  | Blobs | `bytea`, or large objects, or a path into object storage |
  | Claims / leases | `SELECT FOR UPDATE SKIP LOCKED` for work claiming, `pg_advisory_xact_lock` for global constraints |

- **Maturity:** the highest on the list. PostgreSQL licence.
  **`pg.zig` is a native Zig driver, not a C binding**: targets Zig 0.16.0, needs
  no libc and no `libpq`, MIT, 591 stars, 216 commits, actively maintained.
  Supports connection pooling, prepared statements, transactions, `LISTEN/NOTIFY`
  (which is the change-notification primitive the web UI wants), JSON/JSONB and
  arrays. TLS is via OpenSSL and marked experimental — the one caveat. Read
  2026-08-16.
- **Fit:** very good, with one honest cost. It solves availability (no per-entity
  SPOF — any agent can write any record from any host), scale (thousands of
  clients is ordinary for Postgres, not exotic), and concurrency (MVCC plus real
  transactions) in one move. `LISTEN/NOTIFY` even replaces the polling the mesh
  design uses SSE for.
- **Pros:**
  - Removes the `max_members` ceiling entirely: clients do not connect to each
    other, so there is no O(n²) topology.
  - A host going down strands nothing. That is constraint 4, met directly.
  - Covers the state PRD 0011 leaves out — improvement logs, token stats,
    learnings, knowledge — with no new mechanism, so the fleet can actually learn
    collectively.
  - `SKIP LOCKED` gives the claim/lease primitive that is missing everywhere else
    in this note.
  - Boring, inspectable, and an operator can query it with `psql` when an agent
    misbehaves. This is worth more than it sounds for a self-modifying system.
- **Cons:**
  - **It is a server an operator must run.** This is the real cost, and it
    changes clanker's deployment shape from "a checkout on a machine" to "a
    checkout plus a database". A single-laptop user should not need one, which
    argues for Postgres being one backend behind `ck_state`, not the only one.
  - Postgres itself becomes the SPOF unless it is made HA — a smaller and much
    better-understood problem than per-entity ownership, but not free.
  - Connection count: thousands of short-lived `clanker run` processes each
    opening a connection needs PgBouncer or routing through the local `serve`,
    which tier 1 already does.
  - TLS in `pg.zig` is experimental, which matters on a real network.
- **Unknowns:** `pg.zig` under thousands of concurrent connections; whether TLS
  maturity blocks a LAN deployment; migration path from the current JSONL files.
- **Evidence:** [pg.zig](https://github.com/karlseguin/pg.zig) (fetched
  2026-08-16 for version, licence, dependencies, features);
  [PostgreSQL explicit locking](https://www.postgresql.org/docs/current/explicit-locking.html);
  [SKIP LOCKED as a distributed lock](https://medium.com/@arkadii.osheev.official/lightweight-distributed-locks-with-postgresql-skip-locked-in-action-2461a067b491);
  [why SKIP LOCKED alone is not enough for global constraints](https://terrislinenbach.medium.com/why-for-update-skip-locked-isnt-enough-using-pg-advisory-xact-lock-to-build-a-correct-postgresql-d3eb9db46473);
  [Postgres for agentic AI](https://www.pgedge.com/blog/postgres-for-agentic-ai-your-database-is-a-compute-layer-not-a-parking-lot).

### I. PRD 0011's full mesh — peer-to-peer, per-entity ownership

The status quo candidate. Included because a survey without it cannot be
audited, and because it is the only option already partly built.

- **What it is:** no backend. Every instance holds its own `state/`, connects
  directly to every other member, and each shared entity has one owning host
  ("home") that serializes its writes. Board and goals replicate as a deduped
  message log; sessions replicate as read-only copies under
  `state/mesh/<home-id>/`.
- **Maturity:** Phase 1 codec, admission, liveness and the Fleet map are built
  with host tests; listener, `ck_mesh`, CLI and fan-out are open. Phase 3
  (workspace and file sharing) is unstarted. Read 2026-08-16.
- **Fit:** good for a handful of instances an operator knows about; poor at the
  stated scale, on three independent counts.
- **Pros:**
  - No server to run — the only candidate with that property, and it is a real
    one. A two-laptop mesh works with no infrastructure at all.
  - Already designed, partly built, and consistent with the sandbox model.
  - Failure is local: losing one host loses only that host's owned entities.
- **Cons:**
  - `max_members = 32`, by design, because full mesh is O(n²) connections. The
    stated deployment does not fit.
  - Per-entity SPOF: `home_unreachable` refuses the write outright. Routine host
    maintenance strands work.
  - Covers only sessions, workspaces, files, chat and board. The improvement
    logs, token stats, learnings and knowledge have **no replication story at
    all**, so a fleet does not pool what it learns.
  - Conflict resolution for board and goals is fold order over a deduped log,
    which is last-writer-wins without saying so.
- **Unknowns:** whether `max_members` could be raised with a different topology
  (hub, or gossip with partial connectivity) without abandoning the design — the
  PRD rejects hub-and-spoke explicitly but only at 32 members.
- **Evidence:** [PRD 0011](../prds/0011-clanker-mesh.md), whole document.

### C. SQLite (or libSQL) as the state backend

- **What it is:** replace the JSON/JSONL files with one embedded relational
  store, in WAL mode, opened by every clanker process on the host.
- **Maturity:** the most mature option on the list by a wide margin. Public
  domain. Not read for a version number in this pass.
- **Fit:** good on the *host*, poor from a *guest*. A wasm guest cannot open a
  database file through `ck_fs_*`; it would need either a new `ck_sql` host
  channel or option A's daemon in front of it. So SQLite does not replace
  option A — it is a possible storage engine *behind* it.
- **Pros:**
  - Real transactions, real indexes, real crash safety. Replaces hand-rolled
    lock sidecars and read-modify-write JSON.
  - WAL gives many concurrent readers that never block the writer, with each
    reader on a consistent snapshot — the right model for the many-readers /
    few-writers shape of `state/`.
  - Solves row 1 and row 2 of the table with one mechanism.
- **Cons:**
  - **One writer at a time.** WAL does not allow concurrent writes; a second
    writer gets `SQLITE_BUSY`. At 10³–10⁴ agents this is a queue, and its depth
    is the design question.
  - Correct use is three things together — `busy_timeout` (3–5 s), short
    transactions, and `BEGIN IMMEDIATE` for anything that will write, to avoid
    read→write upgrade deadlocks. Omitting any one produces "database is locked"
    under load.
  - Locking is unreliable on NFS and some network filesystems, which constrains
    where `state/` may live.
  - A C dependency. **Not blocked by the libc rule** — `build.zig` already sets
    `link_libc = true` — but it would be the first fetched C library in a
    two-dependency project.
- **Unknowns:** whether a Zig-native embedded store could avoid the C dependency
  at acceptable maturity. `lmdb-zig` and `lmdbx-zig` are *bindings*, so they do
  not avoid it; no pure-Zig equivalent of Rust's `redb` was found in this pass —
  `low` confidence, one search only.
- **Evidence:**
  [tenthousandmeters](https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/)
  (WAL still serializes writers),
  [berthub](https://berthub.eu/articles/posts/a-brief-post-on-sqlite3-database-locked-despite-timeout/)
  (`BEGIN IMMEDIATE`, never upgrade a transaction),
  [SkyPilot](https://blog.skypilot.co/abusing-sqlite-to-handle-concurrency/)
  (production write-up of pushing SQLite at concurrency), all read 2026-08-16.

---

**Options D through H are live tier-2 candidates.** The previous draft marked
them archival on the grounds that PRD 0011 had already decided the cross-host
question. That was wrong twice over: the PRD covers only part of `state/`, and
an in-progress design is not a constraint on research. They are ranked here on
their merits against the four constraints, alongside J and I.

### D. libSQL / Turso embedded replicas — local reads, forwarded writes

- **What it is:** a local SQLite file kept in sync from a remote primary. Reads
  are served locally at file speed; writes are forwarded to the primary; an
  offline mode accepts local writes and pushes the WAL when connectivity
  returns.
- **Maturity:** commercial product with public docs and an examples repo; offline
  sync reached public beta. Exact version and licence not read in this pass —
  `unverified`.
- **Fit:** the closest published architecture to the literal shape of the
  question — every host holds a replica, one primary owns the writes — and it is
  the middle ground between J and I. Against J it trades SQL and one server for
  local-speed reads; against I it trades "no server" for a primary that does not
  vanish with one host. The blocking issue is not architecture but ownership: a
  hosted product with an unverified self-host story is a heavier commitment than
  a Postgres or NATS server the operator already knows how to run.
- **Pros:** the read path is a local file, so per-host read latency is
  unaffected by mesh size; the write path is already the "centralized backend"
  the question asks for; sync is a solved, supported feature rather than
  something to build.
- **Cons:**
  - Conflict resolution is WAL-ordering, first-to-sync-wins by default. For
    concurrent goal edits across hosts that is a lost update with no merge.
  - It is a hosted product. Self-hosting the primary is possible but is then a
    service clanker's operator must run.
  - Same guest problem as option C: a wasm guest cannot open the replica. It
    still needs option A in front.
  - Vendor dependency in a project whose whole design pressure is toward
    drop-in, replaceable units.
- **Unknowns:** self-hosting story, licence of the server component, behaviour at
  thousands of replicas.
- **Evidence:**
  [Embedded replicas](https://docs.turso.tech/features/embedded-replicas/introduction),
  [Offline sync beta](https://turso.tech/blog/turso-offline-sync-public-beta),
  [Offline writes](https://turso.tech/blog/introducing-offline-writes-for-turso),
  read 2026-08-16.

### E. NATS JetStream KV — distributed KV with watch, built on a log

- **What it is:** a key-value store layered on JetStream streams, with revision
  numbers, history, and `watch` for change notification.
**Runner-up to J**, and the better fit if clanker's state is judged to be
event-shaped rather than record-shaped.

- **Maturity:** established, widely deployed, Apache-2.0. **Correction to the
  previous draft, which said no Zig client existed:** `nats-io/nats.zig` is the
  **official** client, requires Zig 0.16.0 or later, is Apache-2.0, 218 stars,
  and supports core pub/sub, server-authenticated TLS, JetStream (pull and push
  consumers), the KV store and Micro Services, all covered by integration tests.
  It is explicitly **pre-1.0 and under active development, with an API that may
  change**; Object Store and client mTLS are planned, not built. Fetched
  2026-08-16.
- **Fit:** strong for three of the four shapes and weak on one. Streams are the
  natural home for the append-only logs — which is the majority of `state/` by
  volume and exactly what PRD 0011 leaves unreplicated. KV with revision CAS
  covers documents, and KV TTLs give claims. The gap is blobs: Object Store is
  the right answer and is the one part the Zig client has not implemented.
- **Pros:**
  - Multi-host by construction with no `max_members` ceiling, and no per-entity
    SPOF.
  - `watch` is push-based change notification, which removes polling from the web
    UI and from any agent waiting on another's result.
  - Streams give replay and history for free — a genuinely good match for
    `improvements.jsonl` and `autolearn.jsonl`, where "what has this fleet
    learned" is a replay over a log.
  - Lighter to operate than Postgres for a pure message/KV workload.
- **Cons:**
  - A server to run, same objection as J.
  - Pre-1.0 client with a declared-unstable API, in a project that pins two
    dependencies deliberately. This is the main risk and it is not small.
  - No Object Store in the Zig client, so blobs need a second mechanism.
  - Weaker than Postgres for the read patterns the web UI has: no ad-hoc queries,
    no joins, no `psql` to inspect state by hand.
- **Unknowns:** storage cost of stream history at clanker's write rates; how the
  pre-1.0 API churn behaves in practice; whether Object Store lands.
- **Evidence:** [nats.zig](https://github.com/nats-io/nats.zig) (fetched
  2026-08-16 for official status, Zig version, feature table, pre-1.0 status),
  [NATS KV docs](https://docs.nats.io/nats-concepts/jetstream/key-value-store),
  [ADR-8](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md),
  [state-store patterns write-up](https://timderzhavets.com/blog/building-distributed-state-stores-with-nats-jetstream/).

### F1. etcd — the best CAS and lease primitives here, on the wrong data

The most interesting result of this pass. etcd is simultaneously the **best fit
in the note for two of clanker's four shapes and disqualified for the other
two**, and both halves are worth recording because they suggest a split role
rather than a yes/no.

- **What it is:** a Raft-backed, strongly consistent key-value store built for
  cluster metadata. It is what Kubernetes stores its entire cluster state in, so
  its production pedigree is not in question. Apache-2.0.
- **Access: no Zig client is required.** This retracts the previous draft's
  objection. etcd ships a **gRPC-gateway exposing the whole v3 API as plain
  JSON over HTTP** at `[CLIENT-URL]/v3/*` — `/v3/kv/put`, `/v3/kv/range`,
  `/v3/kv/txn`, `/v3/watch`. Keys and values are byte arrays and so are base64
  encoded in JSON. clanker already has an HTTP client and already speaks JSON, so
  etcd is reachable today with no new dependency at all — the only candidate in
  the note with that property. The documented gateway limitation is that it does
  not support authentication via TLS Common Name. Read 2026-08-16.
- **Why its primitives fit so well.** Two of the four shapes in the schema
  appendix map onto etcd features exactly, rather than being emulated:

  | Shape | etcd feature |
  |---|---|
  | Documents (CAS) | `Txn`: an atomic If/Then/Else comparing `version`, `create_revision`, `mod_revision` or `value` with `=`, `>`, `<`, `!=`. Guarding an update on unchanged `mod_revision` *is* the `doc(key, revision)` row |
  | Claims / leases | Leases with a TTL and keepalive: attached keys are **deleted automatically** when the client stops renewing. The `expires_ts` in the claim schema stops being something clanker has to enforce |

  A third is close: watch takes a `start_revision` and can replay "the entire
  available event history from the last compaction revision", which is precisely
  PRD 0011's `CHAT_SYNC` `after_id` cursor — implemented by the server instead of
  by `state/mesh/cursors.json`.
- **Why it is disqualified for the bulk, with measured numbers.** etcd is
  explicitly *"designed to handle small key value pairs typical for metadata"*
  and *"not intended as a general-purpose database"*. The limits:

  | Limit | Default | Flag |
  |---|---|---|
  | Max request size | 1.5 MiB | `--max-request-bytes` |
  | Storage quota | 2 GB | `--quota-backend-bytes` |
  | Suggested maximum DB size | 8 GB | warns at startup above this |

  The stated reason for the size ceiling is **MTTR**: etcd recovers 2 GB in
  about 20 seconds on good hardware and cannot do the same for a terabyte.

  Checked against this checkout's `state/sessions/` on 2026-08-16 — 38 files,
  9.8 MB total, median 95 KB, p90 535 KB, **max 1.75 MB** — one transcript
  already exceeds the 1.5 MiB request limit, and base64 encoding through the
  JSON gateway inflates every payload by ~33%, which drops the effective ceiling
  to roughly 1.1 MiB of real content. Session transcripts and the append-only
  logs do not belong in etcd, today, at 38 sessions.
- **Operational cost, which is the highest in the note after FoundationDB:**
  - **Quorum loss stops writes with no automatic recovery.** Not a degraded
    mode — the cluster goes read-only and waits for an operator.
  - **fsync latency under 10 ms is the official recommendation.** etcd persists
    every proposal to a write-ahead log, and unrelated disk activity causing long
    fsyncs makes it miss heartbeats, triggering leader elections and request
    timeouts. This is the most commonly reported production failure.
  - **Defragmentation must be run periodically and blocks the member while it
    runs.** Skipping it lets storage grow past quota into a read-only alarm
    state. Most production teams schedule it weekly.
  - It wants an odd-numbered cluster (3 or 5), so "one small server" is not the
    deployment.
- **Verdict:** wrong as *the* backend, genuinely attractive as a **coordination
  sidecar** next to a bulk store — goals, card state, agent claims and leases in
  etcd; sessions, blobs and logs in Postgres or object storage. That is a
  two-store architecture and its cost is that it is two stores, which is why it
  is not the recommendation. If clanker only ever needed the coordination subset
  — the "narrow the requirement" option — etcd would lead outright.
- **Unknowns:** whether the JSON gateway's `/v3/watch` streaming behaves well
  over a long-lived HTTP connection from clanker's client; how much the base64
  inflation costs in practice; whether the operational burden is acceptable to an
  operator who is not already running Kubernetes.
- **Evidence:**
  [gRPC-gateway](https://etcd.io/docs/v3.5/dev-guide/api_grpc_gateway/) (fetched:
  URL scheme, base64 encoding, endpoint list, CN limitation),
  [etcd v3 API learning guide](https://etcd.io/docs/v3.5/learning/api/) (fetched:
  Txn compare targets, lease TTL/keepalive, watch `start_revision`),
  [system limits](https://etcd.io/docs/v3.3/dev-guide/limit/),
  [why 8 GB](https://www.perfectscale.io/blog/etcd-8gb) (MTTR rationale),
  [five production failure patterns](https://perun.au/insights/etcd-production/),
  all read 2026-08-16; local `find state/sessions -printf '%s'` for the size
  distribution.

### F2. FoundationDB — the most correct concurrency model, on the worst-fitting shape

- **What it is:** a distributed, ordered, transactional key-value store with
  optimistic concurrency control and **serializable** multi-key transactions —
  the strongest correctness guarantee of any candidate in this note. Apple's
  Record Layer runs on it for services with hundreds of millions of users;
  Snowflake uses it for metadata; Tigris uses it for object-storage metadata.
  Apache-2.0.
- **Hard limits, from the project's own "Known Limitations" page** (fetched
  2026-08-16 — these are absolute, not tunable):

  | Limit | Value |
  |---|---|
  | Key size | 10,000 bytes |
  | **Value size** | **100,000 bytes** |
  | Transaction size | 10,000,000 bytes of affected data |
  | **Transaction duration** | **5 seconds** |
  | Tested cluster size | up to 500 processes |
  | Tested database size | up to 100 TB |

- **The value limit is disqualifying on measured data.** Of this checkout's 38
  session transcripts, **19 — exactly half — already exceed 100,000 bytes**, the
  median (95 KB) sits right on the line, and the largest is 1.75 MB, or 17× the
  limit. Every session write would become a chunked multi-key range with its own
  reassembly logic, on a dataset that is 38 sessions on one developer's machine.
  This is not a scaling concern for later; it is broken now.
- **The 5-second limit is a real architectural constraint, not a tuning knob.**
  Reads after five seconds raise `transaction_too_old` and commits with writes
  fail. The established workaround is the Record Layer's **continuations** —
  splitting one logical operation into a sequence of small independent
  transactions, each returning a token to resume from. That is a sound pattern
  and it is also a layer clanker would have to write itself, in Zig, because the
  Record Layer is Java.
- **Access is the heaviest of any candidate.** No Zig binding was found. Every
  language binding sits on `libfdb_c.so`, and linking it also requires `libm`,
  `libpthread` and `librt`. Zig's C FFI makes writing the binding
  straightforward, but the result is a runtime shared-library dependency whose
  version must track the cluster's — a categorically larger commitment than
  `pg.zig`, which is native Zig with no C at all.
- **Pros:**
  - Serializable transactions with OCC: the reference design for the concurrency
    this question asks about, and the only candidate that could make a multi-key
    state update atomic.
  - Proven at scales far beyond anything clanker will reach.
  - The layer concept is philosophically close to clanker's own "everything is a
    plugin" pressure — a thin core with structure added above it.
- **Cons:**
  - The 100 KB value limit versus measured data, above. Decisive.
  - No long-running transaction, so any operation spanning an agent turn needs
    continuations.
  - C shared library plus a binding clanker would write and maintain.
  - Heaviest operational model in the note: a multi-role process cluster, not a
    daemon. Even Apple built workarounds (QuiCK) for the transaction limits.
  - Nothing in clanker currently needs serializable multi-key transactions, so
    the one thing it is uniquely best at is unused.
- **Unknowns:** whether a Zig binding exists that this search missed; whether
  chunking sessions across keys is as bad in practice as it looks on paper.
- **Evidence:**
  [Known limitations](https://apple.github.io/foundationdb/known-limitations.html)
  (fetched: all six numbers),
  [C API](https://apple.github.io/foundationdb/api-c.html) (libfdb_c and its link
  requirements),
  [Record Layer announcement](https://www.foundationdb.org/blog/announcing-record-layer/)
  and [Record Layer paper](https://www.foundationdb.org/files/record-layer-paper.pdf)
  (Apple production use),
  [continuations as the 5s workaround](https://pierrezemb.fr/posts/understanding-fdb-record-layer-continuations/),
  [Tigris on FoundationDB](https://www.tigrisdata.com/blog/building-a-database-using-foundationdb/),
  all read 2026-08-16; local session-size measurement as above.

**Correction carried from the previous draft.** It cited a db-engines comparison
calling etcd "eventually consistent" and flagged it as probably wrong. That is
now settled: etcd's own API documentation describes `Txn` as *"an atomic
If/Then/Else construct"* over a Raft-replicated log with monotonic revisions,
which is not an eventually consistent design. The db-engines summary should not
be relied on; it stays in the references marked unreliable.

### G. CRDTs — Automerge, Yjs, Loro

- **What it is:** replicated data types that merge concurrent edits without
  coordination, so every replica converges regardless of write order.
- **Maturity:** Yjs is the production default (~920 K weekly downloads, ~17 K
  stars); Automerge has `automerge-repo` for sync; Loro is newest, Rust+WASM,
  and leads the benchmark suite on size and speed. Read 2026-08-16, from
  secondary comparison pages — `medium` confidence on the numbers.
- **Fit:** poor, on the merits. The previous draft said "excluded by decision"
  because PRD 0011 lists *"no CRDT, no merge"* as a non-goal; that is still true
  but it is no longer the reason, since the PRD is now one candidate among
  several rather than the frame.

  The independent case: the append-only logs need ordering, not merging; the
  per-entity directories have no concurrent writers by construction; the small
  documents have a natural owner. More decisively, **a shared backend removes the
  problem CRDTs solve.** CRDTs earn their keep when replicas must accept writes
  while partitioned from each other; options J and E accept writes centrally and
  resolve concurrency there. Choosing a backend makes CRDTs redundant, and
  choosing peer-to-peer (option I) is what would make them relevant again — which
  is precisely the combination PRD 0011 rejects.

  The one slice where a CRDT would still earn its keep is two agents editing one
  Kanban card or goal description simultaneously, which every option in this note
  currently resolves as last-writer-wins.
- **Pros:** removes the need for a central writer entirely; offline-first by
  construction; the strongest possible answer to "thousands of agents on
  different hosts" *if* the data is merge-shaped.
- **Cons:**
  - Metadata overhead of 16–32 bytes per character for text CRDTs, plus full
    editing history retained per document.
  - No Zig implementation; adopting one means embedding a Rust/WASM runtime or
    writing a CRDT, and clanker already runs a wasm runtime it would now be
    nesting.
  - Convergence is not correctness. Two agents concurrently moving a card to
    different lanes converge on *a* lane, not the right one.
  - At least one reported production migration *away* from CRDTs for sync.
- **Unknowns:** whether a small hand-written LWW-register / OR-set (not a text
  CRDT) would cover the goal/card case at a fraction of the cost. This is the
  most promising unexplored thread in this note.
- **Evidence:**
  [Loro performance](https://loro.dev/docs/performance),
  [PkgPulse 2026 comparison](https://www.pkgpulse.com/guides/yjs-vs-automerge-vs-loro-crdt-libraries-2026),
  [crdt-benchmarks](https://github.com/dmonad/crdt-benchmarks),
  [Cinapse moving away from CRDTs](https://powersync.com/blog/why-cinapse-moved-away-from-crdts-for-sync),
  read 2026-08-16.

### H. Object storage with conditional writes (S3 `If-Match` / `If-None-Match`)

- **What it is:** S3 gained `If-None-Match` on `PutObject` (create-if-absent) and
  `If-Match` on ETag (compare-and-swap) — the two primitives needed to build
  leases, leader election, and task claiming with no coordinator at all.
- **Maturity:** GA on S3 since late 2024; equivalents predate it on GCS and Azure
  Blob. Read 2026-08-16.
- **Fit:** partial but genuinely valuable, and best read as a *complement* to J
  or E rather than a rival. It covers exactly the two shapes the leaders are
  weakest on — blobs (where `state/sessions/` at 9.5 MB does not belong in a
  KV store) and claims (try to `PutObject` a claim key with `If-None-Match`; you
  own the task if it succeeds). It cannot cover documents or hot logs: no watch,
  and a round-trip per operation.
- **Pros:** no infrastructure to run beyond a bucket; scales to the stated agent
  count without a coordinator; the same API works across three clouds and MinIO.
- **Cons:** network round-trip per operation makes it wrong for hot local state;
  requires cloud credentials in a harness that currently needs none; no watch, so
  change notification is polling.
- **Unknowns:** whether a MinIO-on-localhost variant would be a reasonable
  self-hosted form.
- **Evidence:**
  [AWS multi-writer guide](https://aws.amazon.com/blogs/storage/building-multi-writer-applications-on-amazon-s3-using-native-controls/),
  [Morling, leader election with conditional writes](https://www.morling.dev/blog/leader-election-with-s3-conditional-writes/),
  [Piper, S3 as an agent orchestrator](https://benpiper.com/post/2026/can-s3-replace-a-central-orchestrator-for-agents/),
  read 2026-08-16.

## Out-of-the-box options

Each prompt answered explicitly, including the ones that do not apply.

- **Already in the tree.** Four things, and this is the most important section of
  the note. (1) `clanker serve`'s HTTP API is a state service that is not yet
  used as one. (2) `ck_fs_write_if` is a working CAS primitive that is
  under-generalized rather than missing. (3) `src/peers/chatrooms.zig` already
  does durable append + HTTP fan-out with per-peer backoff — a working prototype
  of replicated state that nobody has named as one. (4) **PRD 0011 has already
  designed the access path**: `ck_mesh` as a name-gated host channel whose host
  side speaks loopback HTTP to serve. Option A is that design applied to a
  second noun. The out-of-the-box answer for tier 1 was not a library at all; it
  was a decision already written down in another document. Note that none of the
  four helps with tier 2.
- **Standard library / OS primitive.** Two are underused. `O_APPEND` writes below
  `PIPE_BUF` are atomic on local filesystems, which is the correct and nearly
  free answer for row 1 of the table — no CAS, no lock, no daemon. And a **unix
  domain socket** is the natural transport for option A on one host: it needs no
  port, no loopback authorization problem, and filesystem permissions are the
  access control. The catch is that a worktree cannot reach a socket outside its
  sandbox for the same reason it cannot reach `state/` — so the socket must be
  passed as an inherited file descriptor, or the transport falls back to
  loopback HTTP. Worth a spike.
- **Do nothing.** Two different "nothings", one per tier. On tier 1 the symlink
  + `shared_root` pair works when both halves agree, at the cost of a recurring
  class of breakage — two records in `docs/reports/`, one hardening rollback in
  `git log` (`44071710`), and a live refusal observed during this session. On
  tier 2, doing nothing means every server keeps a private `state/`: the fleet
  runs, but nothing pools. Agents re-derive the same learnings independently,
  token accounting is per-host, and `improvements.jsonl` fragments N ways. That
  is survivable at two hosts and is the thing the whole question exists to
  prevent at a hundred.
- **Narrow the requirement.** Still the strongest move on the list, and it
  survives the reframing. Only ~16 KB of `state/` — the small mutable documents —
  genuinely needs compare-and-swap; everything else needs atomic append or has a
  single owner. A staged adoption follows directly: put the coordination subset
  (goals, cards, claims, leases) in a shared backend first, keep sessions and
  blobs local with lazy replication, and move the append-only logs when the
  fleet is large enough that pooling them matters. Every tier-2 candidate
  supports being adopted in that order, and tier 1 is what makes the staging
  invisible to guests.
- **Adjacent domain.** Two transfer well. Build systems solved "many workers, one
  cache, no coordinator" with content-addressed storage plus atomic rename —
  clanker's `sessions/` and `runs/` are content-addressed in all but name.
  Distributed version control solved "everyone has a full replica, merges are
  explicit" — and clanker already has git in the loop, which raises the
  unexplored question of whether `state/` should be a git repository with
  branches per agent.
- **Buy, host, or delegate.** Options D, E, F, H and J are all this, and the
  consistent finding is that they solve the cross-server problem at the cost of
  an operator running something. The judgement changed between drafts: for one
  laptop that trade is clearly wrong, and for a network of servers it is clearly
  right, because such a deployment already runs infrastructure. Option I is the
  only candidate that avoids it entirely, and it pays for that with a 32-member
  ceiling. The honest summary is that "no server to run" and "many servers" are
  close to mutually exclusive.

## Comparison

**Tier 1 — access path.** Not mutually exclusive with anything in tier 2.

| Option | Maturity | Fit | Main risk |
|---|---|---|---|
| A. `ck_state` channel → local serve | In-tree pattern (`ck_mesh`) | **Best** — removes the fragility outright and makes tier 2 swappable | Serve becomes a hard dependency of every run |
| B. Generalize `ck_fs_write_if` | In-tree | Partial — small documents only | Still goes through `safeJoinSecure`, so it does not fix the actual break |

**Tier 2 — where state lives.** Ranked against the four constraints, with
constraint 4 (no agent blocked by another host being down) doing most of the
separating.

| Option | Zig client | Server to run | Covers all 4 shapes | Scales past 32 hosts | Survives a host loss | Main risk |
|---|---|---|---|---|---|---|
| **J. PostgreSQL** | `pg.zig`, native, Zig 0.16, MIT | Yes, one | **Yes** | Yes | Yes | Operator must run a DB; `pg.zig` TLS experimental |
| **E. NATS JetStream** | `nats.zig`, official, Zig 0.16, Apache-2.0 | Yes, one | No — blobs missing | Yes | Yes | Client is pre-1.0 with a declared-unstable API |
| I. PRD 0011 full mesh | n/a (native) | **No** | No — logs/knowledge unreplicated | **No**, `max_members = 32` | **No**, `home_unreachable` refuses | Does not reach the stated deployment size |
| C. SQLite / WAL | via C | No | Yes, on one host | Single-host only | n/a | One writer at a time; wrong tier for many servers |
| D. libSQL / Turso | unverified | Hosted or self-host | Yes | Yes | Partly — first-to-sync-wins loses writes | Vendor dependency |
| **F1. etcd** | **none needed** — JSON/HTTP gateway | Yes, a quorum (3 or 5) | No — 1.5 MiB request, 8 GB store | Yes | Yes | Best CAS + lease primitives here, but metadata-only by design |
| F2. FoundationDB | none found; `libfdb_c` + FFI | Yes, a process cluster | **No — 100 KB value limit** | Yes | Yes | Half of existing session files already exceed the value limit |
| H. S3 conditional writes | n/a (HTTP) | No, a bucket | Blobs + claims only | Yes | Yes | Round-trip per op; no watch; needs credentials |
| G. CRDTs | none | No | n/a | Yes | Yes | Redundant once a backend resolves concurrency |

Reading the F rows together is the surprise of this pass: **etcd needs no client
library at all** — its gRPC-gateway is plain JSON over HTTP — and has the best
compare-and-swap and lease primitives in the note, while being disqualified as
the primary store by a 1.5 MiB request limit and an explicit "not a
general-purpose database" design stance. FoundationDB is the reverse: the
strongest correctness model, ruled out by a 100 KB value limit that half this
checkout's session transcripts already exceed.

The shape of the answer: **A for tier 1, and J or E for tier 2**, with the choice
between them turning on whether clanker's state is judged record-shaped
(Postgres) or event-shaped (NATS), and on whether a pre-1.0 client API is
acceptable.

## Evidence log

| Claim | Source | Read on | Confidence |
|---|---|---|---|
| `pg.zig` is a native Zig 0.16 PostgreSQL driver needing no libc and no libpq; MIT, 591 stars, pooling + LISTEN/NOTIFY; TLS experimental | [pg.zig](https://github.com/karlseguin/pg.zig), fetched | 2026-08-16 | high |
| `nats-io/nats.zig` is the official NATS Zig client, Zig 0.16+, Apache-2.0, 218 stars, JetStream + KV supported, **pre-1.0 with an API that may change**; Object Store not implemented | [nats.zig](https://github.com/nats-io/nats.zig), fetched | 2026-08-16 | high |
| Postgres expresses all four shapes: append INSERT, row-version CAS, bytea, `FOR UPDATE SKIP LOCKED` + advisory locks | [PG explicit locking](https://www.postgresql.org/docs/current/explicit-locking.html), [SKIP LOCKED](https://medium.com/@arkadii.osheev.official/lightweight-distributed-locks-with-postgresql-skip-locked-in-action-2461a067b491) | 2026-08-16 | high |
| `SKIP LOCKED` alone does not enforce global constraints; advisory locks are needed for "at most N concurrent" | [Linenbach](https://terrislinenbach.medium.com/why-for-update-skip-locked-isnt-enough-using-pg-advisory-xact-lock-to-build-a-correct-postgresql-d3eb9db46473) | 2026-08-16 | medium |
| PRD 0011 leaves token stats, improvements, autolearn, reasoning, knowledge and learnings with no replication story | [PRD 0011](../prds/0011-clanker-mesh.md), absence across the frame table and Phase 3 scope | 2026-08-16 | high |
| PRD 0011 refuses a write when the owning host is unreachable (`home_unreachable`) | same, Failure modes + "Shared workspaces (Phase 3)" | 2026-08-16 | high |
| Serve owns sockets; CLI, REPL, `clanker run` and `fanOut` are loopback HTTP clients of it | [PRD 0011](../prds/0011-clanker-mesh.md), "Serve owns the mesh" table + locked decision 1 | 2026-08-16 | high |
| `ck_mesh` is a name-gated host channel; the guest never holds the socket | same, "`ck_mesh` is a privileged channel" + goal 6 | 2026-08-16 | high |
| "No CRDT, no merge" is an explicit non-goal; cross-host concurrency is the home-instance rule | same, Non-goals + "Shared workspaces (Phase 3)" | 2026-08-16 | high |
| Continuing a session whose home is unreachable is refused, not forked | same, `home_unreachable` in Failure modes | 2026-08-16 | high |
| Mesh caps at `max_members = 32` (496 connections worst case), so 10³–10⁴ agents is a single-host figure | same, "Topology is a full mesh" + Config | 2026-08-16 | high |
| A second daemon is an explicit non-goal | same, Non-goals | 2026-08-16 | high |
| Worktree state sharing is two halves that must agree | `src/improve/worktree.zig:288-318`, `src/sandbox/host.zig:4714-4750` | 2026-08-16 | high |
| The pair has broken in practice | [bug](../reports/bugs/2026-08-14-worktree-state-symlink-notdir.md), [investigation](../reports/investigations/2026-08-14-isolated-cli-worktree-notdir.md), `git log 44071710` | 2026-08-16 | high |
| A sandbox refusal on a state write reproduces today | `graph write ... refused by this tool's sandbox policy`, emitted by every `clanker run` in this session | 2026-08-16 | high |
| `ck_fs_write_if` is whole-file SHA-256 CAS under a lock sidecar | `src/sandbox/host.zig:3110-3175` | 2026-08-16 | high |
| CAS cannot cover the hot logs (1 MiB cap vs 3.2 MB file) | `src/sandbox/host.zig:178`; `du -sh state/*` | 2026-08-16 | high |
| Lost updates are measured, not theoretical | `src/util/file_lock.zig:1-13` | 2026-08-16 | high |
| `networkAllowed` matches the hostname only and ignores the port, so a `["127.0.0.1"]` grant admits any local port | `src/sandbox/host.zig:2350-2368`, tests at `:508-525` | 2026-08-16 | high |
| `clanker serve` exposes 43 distinct `/api/*` routes | `src/cli.zig`, counted | 2026-08-16 | high |
| libc is already linked, so SQLite is not excluded on that ground | `build.zig:126,406,412` | 2026-08-16 | high |
| Dependency budget is two fetched packages | `build.zig.zon` | 2026-08-16 | high |
| WAL permits many readers but exactly one writer | [tenthousandmeters](https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/) | 2026-08-16 | high |
| Correct SQLite concurrency needs WAL + `busy_timeout` + short transactions, and `BEGIN IMMEDIATE` to avoid upgrade deadlock | [berthub](https://berthub.eu/articles/posts/a-brief-post-on-sqlite3-database-locked-despite-timeout/), [SkyPilot](https://blog.skypilot.co/abusing-sqlite-to-handle-concurrency/) | 2026-08-16 | high |
| SQLite locking is unreliable on NFS / network filesystems | same | 2026-08-16 | medium |
| Turso embedded replicas: local reads, forwarded writes, periodic sync | [Turso docs](https://docs.turso.tech/features/embedded-replicas/introduction) | 2026-08-16 | medium |
| Turso conflict handling is WAL-ordering, first-to-sync-wins | [Turso offline writes](https://turso.tech/blog/introducing-offline-writes-for-turso) | 2026-08-16 | medium |
| NATS KV gives revision CAS, history, and watch | [NATS docs](https://docs.nats.io/nats-concepts/jetstream/key-value-store), [ADR-8](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md) | 2026-08-16 | medium |
| Text CRDT metadata costs 16–32 bytes per character | [Loro performance](https://loro.dev/docs/performance), [PkgPulse](https://www.pkgpulse.com/guides/yjs-vs-automerge-vs-loro-crdt-libraries-2026) | 2026-08-16 | medium |
| At least one team migrated away from CRDTs for sync | [PowerSync / Cinapse](https://powersync.com/blog/why-cinapse-moved-away-from-crdts-for-sync) | 2026-08-16 | medium |
| S3 supports `If-None-Match` create and `If-Match` ETag CAS | [AWS](https://aws.amazon.com/blogs/storage/building-multi-writer-applications-on-amazon-s3-using-native-controls/), [Morling](https://www.morling.dev/blog/leader-election-with-s3-conditional-writes/) | 2026-08-16 | high |
| Task claiming via conditional create is an established agent pattern | [Piper](https://benpiper.com/post/2026/can-s3-replace-a-central-orchestrator-for-agents/) | 2026-08-16 | medium |
| Worktree-per-agent is the industry norm for parallel coding agents | [Augment Code](https://www.augmentcode.com/guides/git-worktrees-parallel-ai-agent-execution) | 2026-08-16 | medium |
| "etcd is eventually consistent" | [db-engines](https://db-engines.com/en/system/FoundationDB;etcd) | 2026-08-16 | **low — wrong, now settled**; etcd's own API doc describes an atomic If/Then/Else `Txn` over a Raft log with monotonic revisions. Source marked unreliable |
| No pure-Zig embedded KV store found; Zig options are C bindings | one search only, `lmdb-zig` / `lmdbx-zig` | 2026-08-16 | low — under-searched |
| ~~No Zig client for etcd~~ | previous draft | 2026-08-16 | **retracted** — none is needed; the gRPC-gateway is JSON over HTTP at `/v3/*` |
| etcd max request 1.5 MiB, storage quota 2 GB default, 8 GB suggested max; MTTR is the stated reason | [system limits](https://etcd.io/docs/v3.3/dev-guide/limit/), [PerfectScale](https://www.perfectscale.io/blog/etcd-8gb) | 2026-08-16 | high |
| etcd is "designed to handle small key value pairs typical for metadata" and not a general-purpose database | [system limits](https://etcd.io/docs/v3.3/dev-guide/limit/) | 2026-08-16 | high |
| etcd `Txn` compares version / create_revision / mod_revision / value; leases auto-delete keys on TTL expiry; watch resumes from `start_revision` | [etcd v3 API](https://etcd.io/docs/v3.5/learning/api/), fetched | 2026-08-16 | high |
| etcd needs fsync under 10 ms; quorum loss stops writes with no automatic recovery; defragmentation blocks the member and must be scheduled | [five failure patterns](https://perun.au/insights/etcd-production/) | 2026-08-16 | medium |
| FoundationDB: key 10,000 B, value 100,000 B, transaction 10,000,000 B, transaction duration 5 s | [known limitations](https://apple.github.io/foundationdb/known-limitations.html), fetched | 2026-08-16 | high |
| 19 of 38 session transcripts exceed FDB's 100 KB value limit; median 95 KB, p90 535 KB, max 1.75 MB; 1 exceeds etcd's 1.5 MiB | local `find state/sessions -type f -printf '%s'` | 2026-08-16 | high |
| FDB's 5 s limit is worked around with Record Layer continuations (many small transactions plus a resume token), which is Java | [Zemb](https://pierrezemb.fr/posts/understanding-fdb-record-layer-continuations/), [Record Layer paper](https://www.foundationdb.org/files/record-layer-paper.pdf) | 2026-08-16 | medium |
| FDB bindings all sit on `libfdb_c.so` and must also link libm, libpthread, librt; no Zig binding found | [C API](https://apple.github.io/foundationdb/api-c.html) | 2026-08-16 | medium — absence is one search |
| FDB production users: Apple (Record Layer), Snowflake metadata, Tigris metadata | [Record Layer announcement](https://www.foundationdb.org/blog/announcing-record-layer/), [Tigris](https://www.tigrisdata.com/blog/building-a-database-using-foundationdb/) | 2026-08-16 | medium |
| ~~No Zig client for NATS~~ | previous draft of this note | 2026-08-16 | **retracted** — `nats-io/nats.zig` is official and supports JetStream + KV |

### Rejected leads, kept deliberately

- **`research` tool `sweep`, web backend.** The generated queries are the topic
  string plus a suffix, which searches badly. Worse, the Bing fallback answered
  `embedded SQLite shared state store multi-process agent coordination` with
  Merriam-Webster and Cambridge Dictionary entries for the word "embedded" — six
  of the first results were dictionary pages. Sweep output was not usable as
  evidence for this note; every finding above was verified directly.
- **`research` tool `sweep`, result size.** The deep sweep returned 49,670 bytes
  and the agent harness delivered only the first 32,768, pruning the middle. A
  deep sweep cannot currently be read in full by the agent that requested it.
- **Dapr state building block.** Abstracts over the stores in options E and F;
  adds an abstraction layer without answering which store, and assumes a
  sidecar. Not pursued.
- **Temporal / Restate.** Durable-execution engines. They would replace the agent
  loop, not the state store. Out of scope for this question.

## Open questions

Ordered by what blocks a decision, most blocking first. The first two are the
only ones that block choosing a tier-2 backend.

1. **Is PRD 0011's peer-to-peer model meant to reach fleet scale, or is it a
   small-cluster feature?** This is the question everything else hangs on. If
   mesh is "a handful of instances an operator knows about", option I stands and
   a backend is a separate, additional decision. If mesh is meant to be the
   fleet, then `max_members = 32` and `home_unreachable` are load-bearing
   constraints that do not hold, and the PRD needs revising rather than
   extending. **This is an operator/product question, not a research one**, and
   this note cannot settle it.
2. **Is clanker's state record-shaped or event-shaped?** Decides J versus E. The
   volume argues event-shaped: the append-only logs are the bulk. The read
   patterns argue record-shaped: the web UI wants queries and joins, and an
   operator debugging a self-modifying agent wants `psql`. A backend that gets
   this wrong is expensive to leave.
3. **What happens to `clanker run` when serve is not running?** Option A's
   central question, unanswered in the tree and the PRD. Mesh can refuse
   (*"start `clanker serve`"*) because mesh is optional; state is not. Refuse,
   auto-start, or fall back to direct writes — each is a different product, and a
   fallback reintroduces the divergence the channel exists to prevent.
4. **Is a pre-1.0 client API acceptable for a core dependency?** `nats.zig` is
   explicitly pre-1.0 with a changing API, in a project that pins two
   dependencies deliberately. If not, E drops and J leads by default.
5. **Is the tier-1 transport loopback HTTP or a unix socket?** PRD 0011 says
   loopback HTTP for mesh, but mesh is inherently networked and state is not. A
   socket needs no port and no authorization story — if a sandboxed process can
   reach one at all, which is the same wall a path outside the worktree hits
   unless the descriptor is inherited. Worth a spike before copying the mesh
   answer by default.
6. **What is the per-write latency of the channel path versus a direct write?**
   Decides whether the hot append logs need batching behind `ck_state`.
7. **Do agents need claims/leases, and is that worth a second store?** PRD 0011
   has no notion of an agent claiming a resource with a timeout and a fence
   token; above a handful of agents that gap shows up as two agents doing the
   same work. etcd expresses it natively (TTL leases, server-side expiry) and is
   reachable with no new dependency, but only as a *sidecar* to a bulk store —
   its 1.5 MiB request limit rules it out as the primary. So the real question is
   whether coordination is worth running a second system for, or whether
   Postgres's `SKIP LOCKED` plus an `expires_ts` column is good enough. The
   default answer should be one store until measurement says otherwise.
8. **Should `state/` be a git repository?** git is already a hard dependency, the
   worktree machinery exists, and per-agent branches with explicit merges is a
   well-understood model. Not searched at all; noted because it is the kind of
   answer the "adjacent domain" prompt exists to surface.
9. **Would a hand-written LWW-register plus OR-set cover concurrent goal and card
   edits?** The one case every option currently resolves as last-writer-wins.
   Low priority: it is a refinement on whichever backend wins, not a choice
   between backends.

## What would change the answer

- **Session transcripts getting smaller, or moving out of the store.** The FDB
  and etcd verdicts both rest on transcript size. If sessions moved to object
  storage with only metadata in the KV store, F1 becomes a live primary
  candidate rather than a sidecar.
- **A decision that mesh stays small.** If `max_members = 32` is affirmed as the
  intended scale, option I is sufficient for the multi-host case and this note
  narrows to tier 1 plus pooling the logs.
- **`nats.zig` reaching 1.0, or `pg.zig`'s TLS leaving experimental.** These are
  the two specific maturity gaps separating the leaders from being obvious
  choices.
- **A measured contention problem on one host.** If lost updates appear at
  current agent counts, tier 1 becomes urgent independently of tier 2.
- **`clanker serve` becoming a required process.** Removes option A's only
  serious objection and makes tier 1 nearly free.
- **A sandbox hardening pass that removes `shared_root`.** Converts the recurring
  tier-1 breakage into a permanent one and forces that half immediately.
- **An operator who will not run a server.** Collapses tier 2 to option I or to
  doing nothing, regardless of what the survey says.

## References

**Zig clients for the leading candidates**

- [pg.zig — native PostgreSQL driver for Zig](https://github.com/karlseguin/pg.zig)
- [nats-io/nats.zig — official NATS Zig client](https://github.com/nats-io/nats.zig)
- [qail-zig — second Zig PostgreSQL driver](https://github.com/qail-io/qail-zig), not evaluated

**PostgreSQL coordination**

- [PostgreSQL: explicit locking](https://www.postgresql.org/docs/current/explicit-locking.html)
- [Lightweight distributed locks with SKIP LOCKED](https://medium.com/@arkadii.osheev.official/lightweight-distributed-locks-with-postgresql-skip-locked-in-action-2461a067b491)
- [Why SKIP LOCKED is not enough — advisory locks for global constraints](https://terrislinenbach.medium.com/why-for-update-skip-locked-isnt-enough-using-pg-advisory-xact-lock-to-build-a-correct-postgresql-d3eb9db46473)
- [Postgres for agentic AI](https://www.pgedge.com/blog/postgres-for-agentic-ai-your-database-is-a-compute-layer-not-a-parking-lot)

**In-tree design (candidate, not constraint)**

- [PRD 0011 — Clanker Mesh (TCP peer-to-peer clustering)](../prds/0011-clanker-mesh.md)
  — serve-owns-sockets, `ck_mesh` as a host channel, home-instance consistency,
  `max_members = 32`, and the "no CRDT, no merge" / "no second daemon" non-goals
- [PRD 0001 — chatrooms](../prds/0001-chatrooms.md) — append-then-fan-out and
  id-dedup, the precedent 0011 builds on
- [ADR 0001 — the board is a chatroom](../adrs/0001-board-is-a-chatroom.md)

**Local tree**

- `src/sandbox/host.zig` — `ckFsWriteIf` (3110), `networkAllowed` tests (508),
  `safeJoinSecure` (4691), `shared_prefixes` (4728), `rootForPath` (4742)
- `src/improve/worktree.zig` — `linkCheckoutState` (288–318)
- `src/util/file_lock.zig` — the lost-update measurement
- `src/peers/chatrooms.zig:790` — `fanOut`, the existing HTTP replication path
- `build.zig`, `build.zig.zon` — libc linkage and dependency budget
- [Bug: worktree setup rejects a symlinked state directory](../reports/bugs/2026-08-14-worktree-state-symlink-notdir.md)
- [Investigation: unexpected worktree and NotDir shared-state warning](../reports/investigations/2026-08-14-isolated-cli-worktree-notdir.md)

**SQLite concurrency**

- [SQLite concurrent writes and "database is locked" errors](https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/)
- [What to do about SQLITE_BUSY errors despite setting a timeout](https://berthub.eu/articles/posts/a-brief-post-on-sqlite3-database-locked-despite-timeout/)
- [Abusing SQLite to Handle Concurrency (SkyPilot)](https://blog.skypilot.co/abusing-sqlite-to-handle-concurrency/)

**Replicated SQLite**

- [Turso embedded replicas](https://docs.turso.tech/features/embedded-replicas/introduction)
- [Turso offline sync public beta](https://turso.tech/blog/turso-offline-sync-public-beta)
- [Introducing offline writes for Turso](https://turso.tech/blog/introducing-offline-writes-for-turso)

**Distributed KV**

- [NATS JetStream Key/Value Store](https://docs.nats.io/nats-concepts/jetstream/key-value-store)
- [NATS ADR-8: KV design](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md)
- [Building distributed state stores with NATS JetStream](https://timderzhavets.com/blog/building-distributed-state-stores-with-nats-jetstream/)
- [db-engines: etcd vs FoundationDB](https://db-engines.com/en/system/FoundationDB;etcd) — unreliable, see evidence log

**etcd**

- [gRPC-gateway: the v3 API as JSON over HTTP](https://etcd.io/docs/v3.5/dev-guide/api_grpc_gateway/)
- [etcd v3 API: Txn, leases, watch](https://etcd.io/docs/v3.5/learning/api/)
- [System limits](https://etcd.io/docs/v3.3/dev-guide/limit/)
- [Why the etcd database size should not exceed 8 GB](https://www.perfectscale.io/blog/etcd-8gb)
- [etcd in production: five failure patterns](https://perun.au/insights/etcd-production/)

**FoundationDB**

- [Known limitations](https://apple.github.io/foundationdb/known-limitations.html) — the six hard numbers
- [C API](https://apple.github.io/foundationdb/api-c.html) — libfdb_c and its link requirements
- [Announcing the Record Layer](https://www.foundationdb.org/blog/announcing-record-layer/)
- [FoundationDB Record Layer: a multi-tenant structured datastore (paper)](https://www.foundationdb.org/files/record-layer-paper.pdf)
- [Bypassing the transaction limits with continuations](https://pierrezemb.fr/posts/understanding-fdb-record-layer-continuations/)
- [Tigris: building a database on FoundationDB](https://www.tigrisdata.com/blog/building-a-database-using-foundationdb/)

**CRDTs**

- [Loro performance benchmarks](https://loro.dev/docs/performance)
- [Yjs vs Automerge vs Loro, 2026](https://www.pkgpulse.com/guides/yjs-vs-automerge-vs-loro-crdt-libraries-2026)
- [crdt-benchmarks](https://github.com/dmonad/crdt-benchmarks)
- [Why Cinapse moved away from CRDTs for sync](https://powersync.com/blog/why-cinapse-moved-away-from-crdts-for-sync)

**Object-storage coordination**

- [Building multi-writer applications on Amazon S3](https://aws.amazon.com/blogs/storage/building-multi-writer-applications-on-amazon-s3-using-native-controls/)
- [Leader election with S3 conditional writes](https://www.morling.dev/blog/leader-election-with-s3-conditional-writes/)
- [Can S3 replace a central orchestrator for agents?](https://benpiper.com/post/2026/can-s3-replace-a-central-orchestrator-for-agents/)

**Agent-harness prior art**

- [Git worktrees for parallel AI agent execution](https://www.augmentcode.com/guides/git-worktrees-parallel-ai-agent-execution)
- [AI agent harnesses explained](https://boringbot.substack.com/p/ai-agent-harnesses-explained-architecture)

## Appendix

### Sweep queries actually issued

Run through the `research` tool, `{"action":"sweep","depth":"deep",...}`, with
explicit queries rather than the generated ones:

```
embedded SQLite shared state store multi-process agent coordination
CRDT sync engine Automerge Yjs local-first comparison
libSQL Turso embedded replica write forwarding sync
NATS JetStream key value store distributed agent state
FoundationDB etcd comparison metadata store concurrency
unix domain socket state daemon broker sandboxed process
optimistic concurrency compare-and-swap document store etag
event sourcing append-only log agent session transcript schema
git worktree isolation shared state directory sandbox problem
hybrid logical clock vector clock conflict resolution replicated state
capability token scoped state API wasm guest sandbox
single writer multi reader WAL SQLite concurrency litestream
```

26 fetches, 0 duplicates dropped. See the rejected-leads section for why the
output was not usable.

### Candidate schema sketch, for whichever store wins

Recorded here as evidence of what the data actually looks like, not as a
decision. Every option above has to express these four shapes.

`home` throughout is PRD 0011's home-instance id — the member that owns the row
and is the only one allowed to write it. On a single host it is always the local
instance, which is why the local and mesh cases can share one schema.

**Events** — append-only, no CAS, ordering per stream only:

```
event(stream, seq, ts_unix_ms, host, agent_id, kind, payload_json)
```

Covers `token_stats.jsonl`, `improvements.jsonl`, `autolearn.jsonl`,
`reasoning.jsonl`, `chatrooms.jsonl`. `stream` is the file name today.

**Documents** — CAS on `revision`, the only shape that needs it:

```
doc(key, revision, ts_unix_ms, home, body_json)
```

Covers `goals.json`, `worktrees.json`, `tool_usage.json`, `webui_plugins.json`,
and Kanban cards. `revision` is what `ck_fs_write_if`'s SHA-256 stands in for
today, at file granularity instead of key granularity.

**Blobs** — single-owner, write-once, content-addressed:

```
blob(id, ts_unix_ms, home, bytes)
```

Covers `sessions/`, `runs/`, `history/`, `arena/`. These need replication, not
concurrency control — nothing else writes them. This is exactly PRD 0011's
Phase 3 shape: home writes `state/sessions/<id>.json`, every other member holds
a read-only replica under `state/mesh/<home-id>/sessions/<id>.json`.

**Claims** — leases. The one shape with no counterpart anywhere in the tree or
in PRD 0011, and the one a fleet of any real size needs:

```
claim(resource, holder, acquired_ts, expires_ts, fence_token)
```

Create-if-absent is the whole protocol; `expires_ts` handles a dead holder, and
`fence_token` is what stops a resumed-from-pause agent acting on a lease it has
already lost.

Of every option in this note, **etcd expresses this row natively and the others
emulate it**: an etcd lease carries the TTL, keepalive renews it, and the
attached keys are deleted by the server when renewal stops — so `expires_ts`
stops being something clanker enforces on a timer it has to run itself. Postgres
does it with a `expires_ts` column plus `SKIP LOCKED`, S3 with a conditional
create plus a sweeper, and PRD 0011 has no form of it at all.
