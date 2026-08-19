# Research — Decentralized state store for isolated worktrees and mesh peers

## Status

Current — searched 2026-08-16, option B and its evidence rows corrected 2026-08-17, distributed-ledger family added as option R 2026-08-19 (Draft 5). Draft 4: names the topology axis (central store vs full replication per host) and the CP/AP axis, and surveys 17 candidates across both. No recommendation -- the choice belongs in an RFC. The 2026-08-17 pass changed no verdict: it records that the in-tree CAS the note measures against was itself defective until then, so "already works" under option B now means what the note assumed it meant.

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
- **"Every host knows the full state" is full replication, and it is a different
  requirement from "a centralized backend".** Naming that axis reorganises the
  field: the central-store options (Postgres, CockroachDB, Turso) and the
  full-replication options (etcd, Consul, rqlite/dqlite, Corrosion, Marmot, PRD
  0011) answer different questions. Both are surveyed; neither is selected here.
- **The second axis is what happens under partition.** CP options (etcd, Consul,
  rqlite, PRD 0011) refuse writes without a quorum — a minority host stops
  recording entirely. AP options (Corrosion/cr-sqlite, Marmot, CRDTs) keep
  accepting writes everywhere and converge. For an agent fleet, whether an
  isolated worker should stall or keep working is a product question that selects
  the row — `high` confidence.
- **Corrosion is the closest published match to the mesh requirement.** Fly.io
  built it *after* outgrowing a central Consul state database: gossip-replicated
  SQLite with multi-writer CRDTs (`cr-sqlite`), an HTTP API, SQL subscriptions,
  SWIM membership and QUIC transport, running across **800+ nodes at p99 ~1 s**.
  Apache-2.0, ~1.8k stars, docs marked WIP; it is a Rust daemon, and its CRDT
  basis is what PRD 0011's non-goal rules out — `high` confidence
  ([repo](https://github.com/superfly/corrosion), [Fly blog](https://fly.io/blog/corrosion/)).
- **PostgreSQL needs a cluster for reliability, which weakens it against the
  natively-distributed options.** Single-node Postgres is a single point of
  failure; HA means Patroni or repmgr, i.e. failover-and-recovery machinery.
  YugabyteDB is PostgreSQL wire-compatible and resilient by construction, so
  `pg.zig` may work against it unchanged — the cheapest high-value experiment
  this note suggests, and unverified — `medium` confidence.
- **No general-purpose Zig-native store exists.** TigerBeetle is Zig, distributed
  by VSR, and operationally the simplest thing here — and its schema is fixed to
  debits and credits, so it cannot hold `state/`. It is the proof that a
  Zig-native replicated store is achievable and the reference if clanker ever
  builds one — `high` confidence.
- **PostgreSQL was missing from the first two drafts and covers all four shapes
  with one dependency.** It expresses all four of clanker's data shapes with one
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
- **The distributed-ledger family (option R, added 2026-08-19) decomposes
  into parts clanker mostly has or can add cheaply.** A ledger is a
  replicated log + consensus total order + deterministic fold + tamper
  evidence (+ BFT in the blockchain variants). The board/chatroom design is
  already the log and the fold; total order is available from the surveyed
  Raft rows without BFT's cost; tamper evidence is a hash chain addable to
  any backend for one hash per record — and it is the one part with a
  clanker-specific argument, because the improve ledger's prefix has already
  been silently rewritten once. BFT itself buys nothing here: every node runs
  the same self-modifying code under one operator, so the realistic bad
  writer is a correlated fault BFT cannot absorb — `high` confidence on the
  decomposition, `medium` on the per-candidate verdicts.
- **The standalone ledger-database market is consolidating away from itself.**
  Amazon retired QLDB on 2025-07-31 pointing users at Aurora PostgreSQL and
  conceding the migration loses cryptographic verifiability; Google's
  Trillian is in maintenance mode naming Tessera as successor; immudb — the
  strongest survivor — is **BUSL 1.1, not open source**, and its replication
  is read-only replicas pulling from a primary with no documented failover —
  `medium` for QLDB (press), `high` for the rest (read at source 2026-08-19).

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
- **Freshness:** all verification 2026-08-16, option R's sources fetched
  2026-08-19. The PRD is the fastest-moving input
  — marked *in progress*, so a Phase 1 landing or a revised non-goal dates this
  note before any external source does. `nats.zig` is pre-1.0 and its API is
  declared unstable.
- **Revision history.** Draft 1 was written without PRD 0011. Draft 2 read it and
  over-corrected, treating an in-progress design as settled ground and archiving
  the cross-host candidates. Draft 3 separated the two tiers, restored those
  candidates, added PostgreSQL, and corrected two wrong "no Zig client" claims.
  Draft 4 (this one) names the topology axis — central store versus full
  replication on every host — which is what the question was actually about, and
  adds the seven candidates that axis surfaces (rqlite/dqlite, Corrosion +
  cr-sqlite, Marmot, Consul, CockroachDB/YugabyteDB, TigerBeetle, and the NATS
  alternatives). It also drops the recommendation language earlier drafts had
  drifted into: the field is laid out for an RFC to choose from, per this
  directory's own convention. The tier-1 finding is the only one that has
  survived unchanged throughout. Draft 5 (2026-08-19) adds option R, the
  distributed-ledger family, decomposed into its parts rather than adopted or
  rejected whole; no earlier verdict changed. Its leads were gathered by
  direct web search and verified with fetches, because the sweep web backend
  failed again (see rejected leads).
- **Known gaps, stated so the next reader does not mistake breadth for depth.**
  Licences for Consul, CockroachDB, YugabyteDB and Turso are unverified, as is
  the Loro per-character figure (its source 403s). No candidate was compiled, deployed or
  benchmarked. `pg.zig` against YugabyteDB is a guess. Every performance figure
  is quoted.

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

The tier-1 option that removes the fragile mechanism rather than adding a second
beside it, and the one PRD 0011 has already committed to for a neighbouring
problem. Tier 1 has no real competition, which is why this half of the note is
short.

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
  that is one function, `ck_fs_write_if` (`src/sandbox/host.zig:3282`).
- **Maturity:** in-tree, and correct for small documents **as of 2026-08-17** — it was not when this note was written. See the update below before relying on the "already tested" claim under Pros.
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

**Update 2026-08-17 — the primitive was hardened; option B was not taken.**
Read this before treating the row above as closed. Three defects were found
and fixed in the CAS itself, all of them in what this note assumed already
worked:

1. The lock name hashed the joined path *string*, so one file had a lock per
   spelling — `./state/goals.json` under the default `agent.sandbox_root` and
   `/abs/checkout/state/goals.json` under an isolated run worktree
   `shared_root`. Two writers took two lock inodes on one file, so neither
   excluded the other and the earlier write was lost: exactly the failure the
   `file_lock.zig` quote above measures, reintroduced by the lock relocation
   that [ADR 0031](../adrs/0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md)
   decided. The name is now the hash of the resolved target.
2. The lock *directory* resolved against the process cwd while the target
   resolved against the sandbox root, so a sandbox rooted in a test tmp tree
   or an improve worktree wrote its locks into whichever `state/` the process
   happened to sit in. Both now resolve against the run own root.
3. Aged lock files were only ever removed by an operator typing `clanker
   janitor --yes`, which the ADR read as though it were automatic.
   `ck_fs_write_if` now sweeps them itself.

Record: [bug](../reports/bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md),
decision it implements: [ADR 0031](../adrs/0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md).
Code: `resolvedLockKey`, `casLockPath` and `sweepAgedLocks` in
`src/sandbox/host.zig:3391-3600`, retention shared with the `janitor` guest via
`tools/zig/cas_lock_record.zig`.

**What this does not change: every Con above still stands.** The CAS still goes
through `safeJoinSecure` (`src/sandbox/host.zig:3294`) and `rootForPath`, so it
is exactly as exposed to sandbox hardening as before; it is still whole-file and
still capped at `max_fs_bytes` (`src/sandbox/host.zig:194`), so it still cannot
cover row 1; contention still degrades quadratically; and there is still no
cross-host story. Neither missing primitive was added — `ck_state_append` does
not exist, and granularity is still per file. The fix moved this option from
*claimed to work* to *actually works* at the scope it already had. It did not
widen that scope, and it is not an argument for choosing B.

---

### Tier 2 — where state lives

Which store holds the truth across N servers, and who resolves concurrency. This
is the open half. Options C through I are all tier-2 answers; A is orthogonal to
every one of them and composes with all of them.

#### Tier 2 has two axes, and the first one was never named

"Where state lives" is really two questions, and separating them explains why
etcd, Postgres and PRD 0011 felt incomparable in earlier drafts:

- **Topology** — is there one store everyone talks to, or does **every host hold
  the full state**?
- **Consistency under partition** — does the system **refuse writes** without a
  quorum (CP), or **accept them everywhere and converge** later (AP)?

|  | **CP** — quorum required, refuses on partition | **AP** — always writable, converges later |
|---|---|---|
| **Central store** | J. PostgreSQL (+ Patroni/repmgr for HA), O. CockroachDB / YugabyteDB | D. Turso (first-to-sync-wins) |
| **Full replication on every host** | **F1. etcd**, N. Consul, K. rqlite / dqlite | **L. Corrosion + cr-sqlite**, M. Marmot, G. CRDTs, I. PRD 0011 mesh |
| **External / neither** | H. S3 conditional writes | E. NATS JetStream (per-stream replicas) |

**The requirement "if one host fails, the others still know the full state" is
the bottom-left and bottom-right cells** — full replication — and it is a
different requirement from "a centralized backend that handles concurrency".
Earlier drafts answered the second while the question was really the first.

**So: yes, etcd does exactly this.** Every member holds the entire keyspace,
replicated by Raft; any member serves reads; losing one host loses nothing. The
caveat is what CP means in practice: etcd needs a **majority alive**, so a
3-node cluster tolerates 1 failure and a 5-node cluster tolerates 2. A host in
the minority side of a partition stops accepting writes entirely. That is
correct behaviour and it is also the opposite of what an agent fleet usually
wants, where an isolated worker continuing to record its own token usage and
learnings is strictly better than it stalling.

The AP row is where the genuinely mesh-shaped answers live, and the previous
drafts missed all of them.

Two candidates lead on data shape, and both now have native Zig clients on the
current compiler — which was the objection that ruled them out in the previous
draft, wrongly. But on *topology*, neither is the best fit for a mesh; see
options K through N.

### J. PostgreSQL — one dependency, all four data shapes

Listed out of alphabetical order because it was absent from the first two
drafts. It is the reference *central-store* candidate; the full-replication
candidates are K, L, M, N and I.

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
  - **It is a server an operator must run.** This changes clanker's deployment
    shape from "a checkout on a machine" to "a checkout plus a database". A
    single-laptop user should not need one, which argues for Postgres being one
    backend behind `ck_state`, not the only one.
  - **For reliability it is a *cluster*, not a server.** One Postgres is a single
    point of failure, so any deployment that cares about a host dying needs
    streaming replication plus Patroni or repmgr — failover-and-recovery
    machinery that is itself a thing to operate and to test. This is the
    strongest argument against J relative to the full-replication row, and
    relative to option O, whose availability comes from resilience rather than
    from failover.
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
The better fit if clanker's state is judged event-shaped rather than
record-shaped, and the transport option M builds on.

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

### K. rqlite / dqlite — Raft-replicated SQLite, full copy on every node

- **What they are:** SQLite plus Raft. **rqlite** is a standalone process
  fronting SQLite with an HTTP API and configurable read consistency (strong,
  eventual, none), automatic failover, and sub-second elections. **dqlite**
  (Canonical) is a *library* that embeds the same idea into your own binary — no
  external database process at all — and is what Canonical ships inside LXD and
  MicroK8s.
- **Topology / consistency:** full replication, CP. Every node has the complete
  database on local disk.
- **Fit:** dqlite is architecturally the closest thing in this note to "clanker
  serve grows a replicated state store", because it is a library rather than a
  server — which would preserve the "no second daemon" property that PRD 0011
  cares about while giving every host the full state. rqlite is the same idea as
  a separate process with an HTTP API clanker could call today.
- **Pros:** SQL and SQLite semantics, so the schema sketch maps over unchanged;
  no size limits of the etcd kind; rqlite's HTTP API needs no client library;
  dqlite embeds, so the deployment stays one binary.
- **Cons:** single-writer through the Raft leader — every write is forwarded, so
  this does not solve write concurrency, only availability and replication;
  quorum required, same minority-partition stall as etcd; dqlite is a C library
  (Zig can bind it, but it is C) and is heavily coupled to Canonical's needs;
  rqlite's HTTP hop adds latency.
- **Unknowns:** dqlite's viability outside Canonical's stack; whether write
  forwarding through a leader is acceptable at clanker's agent counts; Zig
  bindings for dqlite (not searched).
- **Evidence:** [rqlite](https://github.com/rqlite/rqlite),
  [dqlite](https://dqlite.io/),
  [VPS comparison of the SQLite replication options](https://onidel.com/blog/sqlite-replication-vps-2025),
  [mvsqlite's comparison with dqlite and rqlite](https://github.com/losfair/mvsqlite/wiki/Comparison-with-dqlite-and-rqlite),
  read 2026-08-16.

### L. Corrosion + cr-sqlite — gossip-replicated SQLite with multi-writer CRDTs

**The closest published match to a mesh where every host knows the full state.**
It is what Fly.io built after finding a central Consul state database
insufficient, which is very nearly the transition this question is asking about.

- **What it is:** a daemon that propagates SQLite state across a cluster with
  **multi-writer support via CRDTs** (the `cr-sqlite` extension), eventual
  consistency, a **RESTful HTTP API**, **SQL query subscriptions**, QUIC
  peer-to-peer transport, and SWIM gossip for cluster formation. Every node holds
  the full state in a local SQLite file and answers SQL queries against it.
- **Topology / consistency:** full replication, **AP**. Every node accepts
  writes, always; conflicts resolve by CRDT semantics rather than by refusing.
- **Maturity:** Apache-2.0, ~1.8k stars, 1,130 commits, actively developed. Fly.io
  runs it across **800+ nodes** with **p99 propagation around one second**. The
  documentation is marked WIP, which is the main maturity caveat. Rust.
  Read 2026-08-16.
- **`cr-sqlite` separately:** MIT, ~3.8k stars, 2,168 commits, a run-time loadable
  SQLite/libSQL extension. `SELECT crsql_as_crr('table')` upgrades a table to a
  "conflict-free replicated relation"; changes flow through a `crsql_changes`
  virtual table. Supports last-write-wins registers, fractional indices,
  observe-remove sets and multi-value registers; distributed counters and
  rich-text are in progress. **Inserts are 2.5× slower than plain SQLite; reads
  are the same speed.** The project advises building against a release tag as
  main may not be stable.
- **Fit:** on topology, the best in the note for the stated requirement. On
  clanker's data shapes it is good for documents and coordination, and the
  append-only logs are naturally an OR-set or a grow-only table. Blobs would
  gossip badly and should live elsewhere.
- **Pros:**
  - Exactly the requirement: any host can be lost, every survivor still has
    everything, and every survivor keeps accepting writes.
  - HTTP API plus SQL subscriptions means clanker's existing HTTP client reaches
    it, and the web UI's live views get push updates without polling.
  - Proven at a scale (800+ nodes) far beyond PRD 0011's 32-member ceiling.
  - It is the empirical answer to "we tried a central store and outgrew it".
- **Cons:**
  - A Rust daemon — a second runtime in the deployment, and the "no second
    daemon" non-goal in PRD 0011 argues against it.
  - Documentation WIP; built for one company's use case, and general-purpose use
    is plausible but not demonstrated.
  - CRDT semantics mean convergence, not correctness: two agents moving one card
    to different lanes still converge on *a* lane. PRD 0011's "no CRDT, no merge"
    non-goal is a direct objection.
  - 2.5× insert cost on CRDT tables.
- **Unknowns:** whether cr-sqlite could be used **without** Corrosion — the
  extension plus clanker's own gossip over the mesh transport it is already
  building. That is the most interesting unexplored combination in this note.
- **Evidence:** [Corrosion repo](https://github.com/superfly/corrosion) (fetched:
  licence, stars, API, transport, WIP status),
  [Fly blog: Corrosion](https://fly.io/blog/corrosion/),
  [Corrosion docs](https://superfly.github.io/corrosion/),
  [Corrosion CRDT docs](https://superfly.github.io/corrosion/crdts.html),
  [cr-sqlite](https://github.com/vlcn-io/cr-sqlite) (fetched: licence, stars,
  CRDT types, 2.5× insert cost, stability warning),
  [QCon talk](https://qconlondon.com/presentation/apr2025/fast-eventual-consistency-inside-corrosion-distributed-system-powering-flyio),
  read 2026-08-16.

### M. Marmot — leaderless multi-master SQLite with HLC last-write-wins

**Corrected on verification.** Earlier drafts described Marmot as replicating
over NATS JetStream and recorded it as `unverified` from discussion threads. The
repo says otherwise: **v2 does not use NATS at all.** The "composes with option
E" argument the previous draft made for it was wrong and is withdrawn.

- **What it is:** a *leaderless, distributed SQLite replication system* — any
  node accepts writes. Replication is row-level Change Data Capture encoded with
  msgpack, coordinated by **two-phase commit**, with the transaction log streamed
  over **gRPC** (delta sync plus snapshot transfer) and a **gossip protocol** for
  cluster communication. It also presents a MySQL wire-compatible interface.
- **Topology / consistency:** full replication, AP with **tunable write
  consistency — ONE, QUORUM or ALL** — which makes it the only candidate in this
  note where the CP/AP choice is a per-write knob rather than a property of the
  system. Conflicts resolve **last-write-wins on Hybrid Logical Clock
  timestamps**, and split brain is repaired by anti-entropy.
- **Maturity:** MIT, ~2.8k stars, 737 commits. Positions itself as production
  ready and ships a SQL parser and WordPress support, but v2 is a young rewrite.
  Fetched 2026-08-16.
- **Fit:** on topology and on the stated requirement, strong — leaderless full
  replication with per-write consistency covers both the "keep working when
  isolated" and "do not diverge on this particular write" cases from one system.
  HLC-based LWW is a more principled conflict story than fold-order over a
  message log (PRD 0011) and a weaker one than CRDT convergence (option L).
- **Pros:** any node writes; tunable consistency per write; SQLite semantics, so
  the schema sketch maps over; automatic split-brain recovery; no separate
  message broker to run, contrary to what the previous draft claimed.
- **Cons — the project's own stated limitations:**
  - **All tables in a database are replicated**; there is no selective table
    watching. clanker would need a separate database for anything host-local,
    which cuts against putting all of `state/` in one place.
  - **Rows may sync out of order.** For the append-only logs, where order is the
    only thing that matters, this needs thought.
  - Eventually consistent; concurrent DDL on the same database should be avoided,
    which interacts badly with a self-modifying harness that might migrate its
    own schema.
  - gRPC on the wire, so unlike etcd and Corrosion it is not reachable from
    clanker's existing HTTP client.
- **Unknowns:** whether "rows may sync out of order" is acceptable for the event
  logs; how the 2PC write path behaves at the agent counts in question; Zig
  client availability (none searched — the MySQL wire interface may be the
  practical answer).
- **Evidence:** [Marmot repo](https://github.com/maxpert/marmot), fetched
  2026-08-16 for licence, stars, architecture, consistency model and the stated
  limitations; [HN](https://news.ycombinator.com/item?id=38600743) and
  [Lobsters](https://lobste.rs/s/f9slcf/marmot_distributed_sqlite_replication)
  discuss the older v1 design and are now out of date.

### N. Consul — gossip membership plus a Raft-replicated KV

- **What it is:** HashiCorp's service-discovery system. Serf/`memberlist` gossip
  maintains agent-level cluster membership and failure detection; the KV store
  and service catalog sit on Raft across the server nodes.
- **Topology / consistency:** full replication among servers, CP. Multi-datacenter
  is a first-class concept, using WAN gossip between DCs — the one candidate that
  designs explicitly for "clanker instances in several networks".
- **Fit:** functionally very close to etcd for clanker's purposes, with a better
  story for multi-site and a worse one for being lightweight. Same
  metadata-store size posture; the same reasons that rule etcd out as the primary
  store apply.
- **Pros:** HTTP API, so no client library; mature; multi-datacenter federation;
  gossip-based failure detection is exactly the liveness mechanism PRD 0011
  hand-rolls with PING/PONG.
- **Cons:** heavier than etcd for the same job; BSL licence since 2023 (not
  verified in this pass); a KV store, so the bulk-data objection is unchanged.
- **Unknowns:** current licence terms — **`unverified`, and it matters**; whether
  the WAN-federation model maps onto clanker's mesh.
- **Evidence:**
  [HashiCorp on gossip, Serf, memberlist, Raft and SWIM](https://www.hashicorp.com/en/resources/everybody-talks-gossip-serf-memberlist-raft-swim-hashicorp-consul),
  read 2026-08-16. Note that several comparison pages returned for this query
  (StackShare-derived) describe etcd as gossip-based and eventually consistent,
  which is wrong on both counts; that whole family of sources is unreliable.

### O. Distributed SQL — CockroachDB, YugabyteDB

- **What they are:** horizontally scalable, strongly consistent SQL databases
  that are multi-node by design. YugabyteDB is PostgreSQL wire-compatible and
  reuses the Postgres query layer.
- **Topology / consistency:** sharded and replicated across nodes, CP.
- **Fit:** the direct answer to the objection raised against option J — that
  Postgres needs Patroni or repmgr for HA. As one comparison puts it,
  YugabyteDB's availability *"is based on resilience, unlike PostgreSQL HA which
  is based on failover and recovery techniques."* If clanker is going to depend
  on a SQL store across servers anyway, a natively distributed one removes the
  failover machinery rather than automating it.
- **Pros:** no separate HA tooling; survives node loss natively; YugabyteDB's
  Postgres compatibility means `pg.zig` may work unchanged — which, if true, is a
  significant finding, because it would give a natively-distributed backend with
  a native Zig client;
  CockroachDB is strong for geo-distribution.
- **Cons:** heavier per node than Postgres; single-region performance trails
  Postgres by roughly 20–30% for CockroachDB; both are a cluster to operate;
  licences are not the plain OSS story Postgres has (CockroachDB in particular)
  and were **not verified** in this pass.
- **Unknowns:** whether `pg.zig` actually works against YugabyteDB — the highest
  value/lowest cost experiment suggested anywhere in this note; current licence
  terms for both.
- **Evidence:**
  [YugabyteDB resiliency vs PostgreSQL HA](https://www.yugabyte.com/blog/yugabytedb-resiliency-vs-postgresql-ha-solutions/)
  (vendor source, read critically),
  [three-way comparison](https://www.index.dev/skill-vs-skill/cockroachdb-vs-postgresql-vs-yugabytedb),
  read 2026-08-16.

### P. The Zig-native landscape — TigerBeetle and what does not exist

Asked explicitly because a Zig-native store would fit this codebase better than
anything else. The honest answer is that it does not exist for this use case.

- **TigerBeetle** is the flagship Zig database: a financial-accounting DBMS,
  distributed by default via Viewstamped Replication, with all memory allocated
  upfront, no dynamic allocation, single-core deterministic execution, and direct
  I/O bypassing the page cache. Deployment is "install the binary on however many
  machines you want" with no ZooKeeper and no async replication — operationally
  the simplest distributed store in this note by a wide margin.

  **And it cannot be used here.** It is not a general-purpose store: its schema
  is fixed to double-entry accounts and transfers. Nothing in `state/` is a
  debit or a credit. It is listed because it is the strongest evidence that a
  Zig-native replicated store is *achievable*, and because its VSR implementation
  is the best available reference if clanker ever built its own replication over
  the mesh transport.
- **`pg.zig` and `nats.zig`** are Zig *clients*, covered above, and remain the
  only native-Zig path to a mature store.
- **Not found:** any general-purpose embedded or distributed key-value store
  written in Zig. `lmdb-zig` / `lmdbx-zig` are C bindings; "Axion" appeared in one
  result as a Zig storage engine and was **not investigated** — a lead, not a
  finding.
- **What this implies:** the build-it-ourselves option is a real one — cr-sqlite
  or a hand-written LWW/OR-set layer, gossiped over the mesh transport PRD 0011
  is already building — and it is the only option that keeps everything in-tree.
  Its cost is that clanker would own a distributed-systems problem, which is the
  category of work most likely to be subtly wrong.
- **Evidence:** [TigerBeetle architecture](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md),
  [TigerBeetle on dbdb.io](https://dbdb.io/db/tigerbeetle),
  [awesome-zig](https://github.com/zigcc/awesome-zig), read 2026-08-16.

### Q. NATS alternatives for the event-shaped half

Asked explicitly. The short answer is that the alternatives are better at
streaming and worse at everything else NATS was attractive for.

- **Redpanda** — Kafka-compatible, written in C++, no JVM and no ZooKeeper, lower
  latency and simpler operations than Kafka. Strong for durable long-retention
  streaming. **No KV store and no watch**, so it covers one of clanker's four
  shapes.
- **Apache Kafka** — the reference. Highest durability and ecosystem, heaviest
  operations, JVM. Same one-shape limitation.
- **Redis Streams** — simplest of the three, consumer groups, adequate below
  ~10K messages/second, which is comfortably above clanker's write rate. Redis
  also has a KV store and keyspace notifications, so it is the only alternative
  here that covers documents *and* events. Persistence and clustering
  semantics were **not verified** in this pass.
- **Why none displaces NATS for this question:** what made JetStream attractive
  was the *combination* — streams for the logs, KV with revision CAS for
  documents, TTLs for claims, `watch` for push updates, one server, one official
  Zig client. Redpanda and Kafka give a better version of one quarter of that.
- **Unknowns:** Fluvio and Iggy (Rust streaming systems) returned nothing usable
  in this search and were **not evaluated**; Redis as a full state store was not
  assessed.
- **Evidence:**
  [Redpanda vs NATS vs Kafka 2026](https://www.pkgpulse.com/blog/redpanda-vs-nats-vs-apache-kafka-event-streaming-platforms-2026),
  [message broker comparison 2026](https://dev.to/mahdi0shamlou/message-brokers-comparison-2026-kafka-rabbitmq-nats-redis-streams-which-one-should-you-3ea8),
  [NATS alternatives roundup](https://www.modern-datatools.com/alternatives/nats),
  read 2026-08-16 — all secondary comparison pages, so `medium` at best.

### R. Distributed ledgers — the family decomposed, and which parts apply

Asked explicitly (2026-08-19 pass). "Distributed ledger" is not one candidate
but a bundle of properties, and the honest way to weigh it is to take the
bundle apart: (1) a replicated append-only log, (2) a total order over that
log agreed by consensus, (3) a deterministic state machine folded from the
log, (4) cryptographic tamper evidence — hash chaining and Merkle proofs —
and, in the blockchain variants, (5) Byzantine fault tolerance among mutually
distrusting parties. Clanker already has (1) and (3) in-tree: [ADR
0001](../adrs/0001-board-is-a-chatroom.md)'s board is a chatroom log folded
deterministically into cards, and PRD 0011 replicates per-owner logs with
id-dedup. The in-tree design is ledger-shaped already, minus consensus and
crypto — so this section prices (2), (4) and (5) separately instead of
adopting or rejecting the bundle whole.

- **CometBFT (the maintained successor to Tendermint Core) + an ABCI app** —
  the general-purpose form of (2)+(3)+(5): a Go consensus engine that takes a
  deterministic state machine written in any language over the ABCI interface
  and replicates it across nodes, tolerating fewer than one-third faulty or
  malicious members; the README claims up to 10k TPS. Apache-2.0. Fit: this is
  the strongest ordering guarantee in the whole note — a BFT-agreed total
  order over exactly the append-then-fold shape clanker's logs and board
  already have, and the state machine could in principle be clanker-native
  Zig behind ABCI. Cost: a Go daemon and a validator set per deployment, BFT
  quorum (a minority partition stalls — CP), and consensus latency on every
  write for a fault class the fleet does not contain (the closing verdict
  below).
  Evidence: [CometBFT repo](https://github.com/cometbft/cometbft), fetched
  2026-08-19.
- **Hyperledger Fabric — the permissioned-blockchain form.** Ordering is Raft
  (crash fault tolerant, the recommended default) or SmartBFT since v3.0
  (tolerates fewer than one-third malicious); a deployment runs ordering
  nodes, peers, *and* certificate authorities with per-organization MSP
  identity. That identity machinery is the point of Fabric: it exists so
  organizations that do not trust each other can share a ledger. A fleet of
  one operator's instances has no such boundary to enforce, so Fabric's
  distinguishing cost buys nothing here, and with Raft ordering its guarantee
  collapses to what rqlite/dqlite (option K) already offer without the PKI.
  Evidence:
  [ordering service docs](https://hyperledger-fabric.readthedocs.io/en/latest/orderer/ordering_service.html),
  fetched 2026-08-19.
- **immudb — the ledger database without the "distributed".** "Immutable
  database based on zero trust, SQL/Key-Value/Document model, tamperproof,
  data change history" (its own description): every transaction extends a
  cryptographically verifiable chain, clients can verify inclusion and
  consistency, and the APIs are gRPC, PostgreSQL wire v3, and REST through
  the separate immugw — plus embedded use, but only from Go. Two findings
  gate it. **Licence: BUSL 1.1**, not an OSI licence. And replication is
  asynchronous primary→replica pull (gRPC `ExportTx`) where **replicas
  reject writes**, with no automatic failover documented — topologically it
  is option J's central store with hash chains and a weaker HA story, giving
  property (4) while failing the "no agent blocked by a down host" constraint
  the same way single-node Postgres does. Evidence:
  [repo](https://github.com/codenotary/immudb),
  [replication docs](https://docs.immudb.io/master/production/replication.html),
  both fetched 2026-08-19.
- **Hypercore/Autobase and OrbitDB — the peer-to-peer log family.** The AP
  corner of the ledger space, and structurally the closest to PRD 0011:
  per-writer append-only logs with Merkle integrity, replicated peer-to-peer,
  folded into a view. Autobase (Holepunch/Pears) linearizes multiple writers'
  Hypercores into one eventually consistent view through an `apply` handler
  that must be a pure deterministic reducer — and its docs state it **can
  reorder previously seen nodes when new causal information arrives**, so the
  fold must tolerate retroactive reordering or peers diverge. OrbitDB is
  Merkle-CRDTs over Helia/libp2p (MIT, 8.8k stars; JS, with a Go
  implementation by Berty) offering event-log, document and KV types — the
  applied form of option G on a p2p transport, sharing its verdict. Both are
  JavaScript runtimes, so each host would run a Node daemon beside clanker;
  no Zig path exists. What the family demonstrates is that PRD 0011's
  own shape — single-owner logs, deterministic fold — extends to multi-writer
  with Merkle integrity, which is an argument for the build-it-ourselves row
  in option P, not for adopting a JS stack. Evidence:
  [Autobase docs](https://docs.pears.com/building-blocks/autobase),
  [OrbitDB repo](https://github.com/orbitdb/orbitdb), fetched 2026-08-19.
- **The category's own trajectory is the strongest signal in this section.**
  Amazon retired QLDB — the flagship managed ledger database — on
  2025-07-31, recommending migration to Aurora PostgreSQL and conceding the
  migration loses cryptographic verifiability (press coverage; AWS's own page
  not fetched, so `medium`). Google's Trillian, the Merkle-log service behind
  Certificate Transparency (Apache-2.0, MySQL/MariaDB-backed, centrally
  operated), declares itself in maintenance mode and points new operators at
  Tessera. The standalone verifiable-ledger market is consolidating into
  "ordinary database plus audit machinery" — which is evidence for taking the
  useful ledger properties à la carte rather than adopting a ledger product.
  Evidence: [InfoQ on QLDB's retirement](https://www.infoq.com/news/2024/07/aws-kill-qldb),
  [Trillian repo](https://github.com/google/trillian), fetched 2026-08-19.

**What survives the decomposition.** Two parts. *Total order* (2) is real —
observation 5 in the comparison already names ordering as the axis the
append-only logs care about and almost nothing guarantees — but the surveyed
Raft rows (rqlite, etcd, Consul) provide agreed total order without BFT's
quorum economics, so a ledger product is not needed to get it. *Tamper
evidence* (4) is the one part with a clanker-specific argument: it is a hash
chain over an append log — addable to any backend in this note, including
today's flat files, for one hash per record, no consensus and no daemon — and
the improve ledger has already had its prefix silently rewritten once
(three `accepted` entries flipped in worktree copies while the shared file
froze,
[bug](../reports/bugs/2026-08-17-improve-ledger-written-to-a-worktree-copy.md));
a chained log makes a rewritten prefix detectable at read time, though it
prevents nothing. A self-modifying harness is unusually exposed to its own
defective writers, and that is an integrity argument, not a consensus one.

**What does not survive.** *BFT* (5): every clanker node runs the same
self-improving binary under one operator, so the realistic bad writer is a
defect replicated to every node — a correlated fault, which is precisely the
class BFT consensus cannot absorb (it protects a correct majority from a
faulty minority, and here there is no independent majority). Paying BFT's
latency and quorum cost to defend against a minority-node threat model the
deployment does not have is the wrong trade — `high` confidence on the
reasoning, with the caveat that it rests on the single-operator premise
(see "What would change the answer"). Fabric's identity machinery falls with
it, and the public-chain variants add token economics on top (rejected leads).

## Out-of-the-box options

Each prompt answered explicitly, including the ones that do not apply.

- **Already in the tree.** Four things, and this is the most important section of
  the note. (1) `clanker serve`'s HTTP API is a state service that is not yet
  used as one. (2) `ck_fs_write_if` is a working CAS primitive that is
  under-generalized rather than missing — it became one on 2026-08-17, when
  three defects that let two writers hold two locks on one file were fixed
  ([bug](../reports/bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md));
  the under-generalization is unchanged. (3) `src/peers/chatrooms.zig` already
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

The note's job is to lay the field out, not to pick. Two tables, because the two
tiers are independent decisions.

**Tier 1 — access path.** Composes with every tier-2 option.

| Option | Maturity | Fit | Main risk |
|---|---|---|---|
| A. `ck_state` channel → local serve | In-tree pattern (`ck_mesh`) | Removes the worktree fragility; makes tier 2 swappable | Serve becomes a hard dependency of every run |
| B. Generalize `ck_fs_write_if` | In-tree, primitive fixed 2026-08-17 | Small documents only | Still goes through `safeJoinSecure`, so it does not fix the break |

**Tier 2 — where state lives.** `Topology` and `Partition` are the two axes;
"Full state per host" is the column that answers "one host dies, the rest still
know everything".

| Option | Topology | Partition | Zig client | To operate | All 4 shapes | Notes |
|---|---|---|---|---|---|---|
| J. PostgreSQL | Central | CP | `pg.zig`, native, 0.16 | 1 server **+ Patroni/repmgr for HA** | Yes | Only single-node without HA tooling |
| O. CockroachDB / YugabyteDB | Central, sharded | CP | maybe `pg.zig` (Yugabyte is PG-compatible) | Cluster | Yes | Resilience instead of failover; licences unverified |
| D. Turso / libSQL | Central primary + replicas | AP-ish | unverified | Hosted or self-host | Yes | First-to-sync-wins loses writes |
| **F1. etcd** | **Full per host** | CP | **none needed** (JSON/HTTP) | Quorum, 3 or 5 | No — 1.5 MiB / 8 GB | Best CAS + lease primitives here |
| N. Consul | **Full per host** | CP | none needed (HTTP) | Quorum | No — KV store | Multi-datacenter is first-class; licence unverified |
| K. rqlite / dqlite | **Full per host** | CP | rqlite: none (HTTP); dqlite: C lib | 1 process, or embedded | Yes | dqlite embeds — no second daemon |
| **L. Corrosion + cr-sqlite** | **Full per host** | **AP** | none needed (HTTP) | 1 Rust daemon | Mostly — blobs poorly | Proven at 800+ nodes; docs WIP |
| M. Marmot | **Full per host** | **AP, tunable per write** | none found (gRPC; MySQL wire) | 1 daemon | Yes | Leaderless; all tables replicated; rows may sync out of order |
| I. PRD 0011 mesh | **Full per host** | CP-ish (refuses) | n/a, native | **Nothing** | No — logs unreplicated | `max_members = 32`; per-entity SPOF |
| E. NATS JetStream | Per-stream replicas | Tunable | `nats.zig`, official, 0.16 | 1 server | No — blobs missing | Client pre-1.0, API unstable |
| F2. FoundationDB | Sharded cluster | CP | none; `libfdb_c` + FFI | Process cluster | **No — 100 KB values** | Half of existing sessions exceed it |
| C. SQLite / WAL | Single host | n/a | via C | Nothing | Yes, locally | Not a cross-host answer |
| H. S3 conditional writes | External | CP-ish | none needed (HTTP) | A bucket | Blobs + claims only | Complement, not a primary |
| G. CRDTs (Yjs/Automerge/Loro) | **Full per host** | **AP** | none | Nothing | n/a | Library, not a store; see L for the applied form |
| P. TigerBeetle | Full per host (VSR) | CP | native Zig | Binary per node | **No — fixed schema** | Unusable here; best Zig reference |
| R. CometBFT + ABCI app | **Full per host** | CP (BFT, >2/3 quorum) | n/a — the ABCI app is the store | Go daemon per node + the app | App-defined | Strongest total order in the note; consensus on every write |
| R. Hyperledger Fabric | Full per org | CP | none (SDKs: Go/Node/Java) | Orderers + peers + CAs/MSP | No | Inter-org identity machinery the fleet does not have |
| R. immudb | Central + read replicas | n/a — primary is SPOF | none found (gRPC / pg wire / REST gw) | 1 server | KV+SQL+docs | **BUSL 1.1**; replicas reject writes; ledger without the "distributed" |
| R. Hypercore/Autobase, OrbitDB | **Full per host** | **AP** | none (JS runtime) | Node daemon per host | Logs + docs + KV | Eventual total order that may retroactively reorder |

Five observations for whoever writes the RFC, none of them a recommendation:

1. **Full replication and "no server to run" are not exclusive.** dqlite embeds
   as a library, and PRD 0011 needs nothing. Both keep clanker a single binary.
2. **CP versus AP is not always a property of the system — sometimes it is a
   knob.** Most of the CP options stall a minority partition: etcd, Consul,
   rqlite and PRD 0011 all refuse writes when cut off. But Marmot makes write
   consistency tunable per write (ONE / QUORUM / ALL), so "converge quietly" and
   "do not diverge on *this* record" can coexist in one system. Whether an
   isolated agent should stop recording or keep working is still the product
   question that selects the row — Marmot just means the row need not be chosen
   once for everything.
3. **Two candidates need no client library at all** — etcd and Corrosion both
   speak HTTP — and two have native Zig clients. Client availability, which the
   earlier drafts treated as decisive, separates the field much less than
   expected. Note the inverse for Marmot: no Zig client and gRPC on the wire,
   which is a real cost against otherwise strong fundamentals.
4. **Composition beats selection in several places.** etcd for claims plus
   Postgres for bulk; anything plus S3 for blobs. The survey is not obliged to
   produce a single winner.
5. **Ordering is the axis the append-only logs care about, and almost nothing
   guarantees it.** Marmot states outright that rows may sync out of order;
   CRDT convergence says nothing about order either; PRD 0011's board and goals
   resolve by fold order over a deduped log. Since the largest part of `state/`
   by volume is append-only logs where order *is* the meaning, an RFC should
   test each candidate against that specifically rather than against
   compare-and-swap, which is what the small documents need and they are 16 KB.

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
| `ck_fs_write_if` is whole-file SHA-256 CAS under a lock file | `src/sandbox/host.zig:3292-3389` | 2026-08-17 | high |
| The lock is `state/locks/<sha256-of-resolved-target>.lock`, not a `<target>.ck_cas.lock` sidecar | [ADR 0031](../adrs/0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md) | 2026-08-17 | high |
| The CAS lost updates across path spellings until 2026-08-17 | [bug](../reports/bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md) | 2026-08-17 | high |
| CAS cannot cover the hot logs (1 MiB cap vs 3.2 MB file) | `src/sandbox/host.zig:194`; `du -sh state/*` | 2026-08-17 | high |
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
| Text CRDT metadata costs 16–32 bytes per character | search-result summary attributed to [Loro performance](https://loro.dev/docs/performance) / [PkgPulse](https://www.pkgpulse.com/guides/yjs-vs-automerge-vs-loro-crdt-libraries-2026) | 2026-08-16 | **low — not verified at source.** A 2026-08-16 verification pass could not open loro.dev/docs/performance (HTTP 403 to both curl and the fetch tool), so this number and the Loro star/benchmark figures rest on a search summary. Do not quote them in an RFC without reopening the source |
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
| Corrosion: gossip + cr-sqlite CRDTs + HTTP API + SQL subscriptions + QUIC + SWIM; Apache-2.0, ~1.8k stars, docs WIP | [repo](https://github.com/superfly/corrosion), fetched | 2026-08-16 | high |
| Fly.io runs Corrosion across 800+ nodes at p99 ~1 s, after replacing a central Consul state database | [Fly blog](https://fly.io/blog/corrosion/), [QCon](https://qconlondon.com/presentation/apr2025/fast-eventual-consistency-inside-corrosion-distributed-system-powering-flyio) | 2026-08-16 | medium |
| cr-sqlite: MIT, ~3.8k stars; LWW registers, fractional indices, OR-sets, multi-value registers; inserts 2.5x slower than plain SQLite, reads unchanged; build against a release tag | [repo](https://github.com/vlcn-io/cr-sqlite), fetched | 2026-08-16 | high |
| rqlite is Raft SQLite with an HTTP API and tunable read consistency; dqlite is the same idea as an embeddable library | [comparison](https://onidel.com/blog/sqlite-replication-vps-2025), [mvsqlite wiki](https://github.com/losfair/mvsqlite/wiki/Comparison-with-dqlite-and-rqlite) | 2026-08-16 | medium |
| Marmot v2 is leaderless multi-master SQLite: gossip + msgpack CDC + 2PC + gRPC, HLC last-write-wins, tunable ONE/QUORUM/ALL, anti-entropy; MIT, 2.8k stars. **Does not use NATS** | [repo](https://github.com/maxpert/marmot), fetched | 2026-08-16 | high |
| Marmot replicates all tables in a database, rows may sync out of order, concurrent DDL discouraged | same, stated limitations | 2026-08-16 | high |
| Consul uses Serf gossip for membership and Raft for the KV catalog, with first-class multi-datacenter | [HashiCorp](https://www.hashicorp.com/en/resources/everybody-talks-gossip-serf-memberlist-raft-swim-hashicorp-consul) | 2026-08-16 | medium |
| Postgres HA is failover-and-recovery (Patroni/repmgr); YugabyteDB's is resilience, and it is PG wire-compatible | [Yugabyte](https://www.yugabyte.com/blog/yugabytedb-resiliency-vs-postgresql-ha-solutions/) — vendor | 2026-08-16 | medium — vendor source, direction credible |
| TigerBeetle is a Zig DBMS, VSR-replicated, upfront allocation, direct I/O, install-the-binary deployment — and its schema is fixed to accounts and transfers | [architecture](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md), [dbdb.io](https://dbdb.io/db/tigerbeetle) | 2026-08-16 | high |
| No general-purpose embedded or distributed KV store written in Zig was found | searches across awesome-zig and DB roundups | 2026-08-16 | medium |
| Redpanda/Kafka/Redis Streams cover streaming but not the KV+watch+TTL combination | secondary comparison pages | 2026-08-16 | medium |
| FDB production users: Apple (Record Layer), Snowflake metadata, Tigris metadata | [Record Layer announcement](https://www.foundationdb.org/blog/announcing-record-layer/), [Tigris](https://www.tigrisdata.com/blog/building-a-database-using-foundationdb/) | 2026-08-16 | medium |
| ~~No Zig client for NATS~~ | previous draft of this note | 2026-08-16 | **retracted** — `nats-io/nats.zig` is official and supports JetStream + KV |
| CometBFT is Apache-2.0 Go BFT state-machine replication; the ABCI app can be any language; README claims up to 10k TPS; tolerates fewer than 1/3 faulty | [repo](https://github.com/cometbft/cometbft), fetched | 2026-08-19 | high |
| Fabric ordering is Raft (CFT, recommended) or SmartBFT since v3.0 (< 1/3 malicious); a deployment runs orderers, peers, and CA/MSP identity | [ordering service docs](https://hyperledger-fabric.readthedocs.io/en/latest/orderer/ordering_service.html), fetched | 2026-08-19 | high |
| immudb is **BUSL 1.1**, Go, ~9k stars; KV + SQL + document; gRPC, PostgreSQL wire v3, REST via separate immugw; embeds in Go only | [repo](https://github.com/codenotary/immudb), fetched | 2026-08-19 | high |
| immudb replication is asynchronous primary→replica pull (gRPC `ExportTx`); replicas reject all direct writes; no automatic failover documented | [replication docs](https://docs.immudb.io/master/production/replication.html), fetched | 2026-08-19 | high |
| Amazon QLDB service ended 2025-07-31; AWS recommended migrating to Aurora PostgreSQL; the migration loses cryptographic verifiability | [InfoQ](https://www.infoq.com/news/2024/07/aws-kill-qldb) + press roundup; AWS's own page not fetched | 2026-08-19 | medium — press only |
| OrbitDB is MIT, JS (Go implementation by Berty), 8.8k stars, Merkle-CRDTs over Helia/libp2p, eventually consistent; event/document/KV types | [repo](https://github.com/orbitdb/orbitdb), fetched | 2026-08-19 | high |
| Autobase linearizes multi-writer Hypercores into an eventually consistent view; may reorder previously seen nodes as causal info arrives; `apply` must be a pure deterministic reducer; Node.js runtime | [Pears docs](https://docs.pears.com/building-blocks/autobase), fetched | 2026-08-19 | high |
| Trillian is a centrally operated Merkle-log gRPC service over MySQL/MariaDB, Apache-2.0, 3.7k stars, in maintenance mode; recommends Tessera for new logs | [repo](https://github.com/google/trillian), fetched | 2026-08-19 | high |

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
- **StackShare-derived comparison pages** (`consul vs etcd`, `etcd vs serf`).
  Returned prominently and describe etcd as gossip-based and eventually
  consistent, both wrong. Same failure mode as the db-engines page. Treat that
  whole family as unusable for consistency claims.
- **Fluvio and Iggy** (Rust streaming systems). Named in the search, returned
  nothing substantive; not evaluated.
- **"Axion", a Zig storage engine.** Appeared once in a roundup; not
  investigated. A lead, not a finding.
- **Dapr state building block.** Abstracts over the stores in options E and F;
  adds an abstraction layer without answering which store, and assumes a
  sidecar. Not pursued.
- **Temporal / Restate.** Durable-execution engines. They would replace the agent
  loop, not the state store. Out of scope for this question.
- **`research` tool `sweep`, web backend, retried 2026-08-19.** For the
  option-R pass, `distributed ledger state store` and `immutable ledger
  database` at depth standard returned nothing on-topic at all: every WEB hit
  across every query angle was an unrelated page (Chinese hardware-vendor
  sites, bird-watching forum threads, thesaurus entries for "hate"). Third
  recorded failure of this backend; option R's leads were gathered by direct
  web search and every cited claim verified with a fetch.
- **Public smart-contract chains (Ethereum and kin).** Rejected without a
  fetch, on the trust model alone: proof-of-work/stake economics, gas
  metering and token incentives exist to coordinate mutually distrusting
  strangers, which a one-operator fleet is not. If BFT ordering is ever
  actually wanted, the permissioned form (CometBFT, option R) is the
  applicable shape at a fraction of the machinery.
- **Corda.** Named in ledger roundups; not investigated in this pass. A lead,
  not a finding.
- **Tessera.** Trillian's named successor for transparency logs; not
  investigated. A lead, not a finding.

## Open questions

Ordered by what blocks a decision, most blocking first. The first two are the
only ones that block choosing a tier-2 backend.

1. **Should an isolated agent stall or keep working?** The CP/AP question, and
   the one that selects a row rather than a candidate. If an agent cut off from
   the fleet should keep recording its own runs, tokens and learnings and
   converge later, the AP options (Corrosion/cr-sqlite, Marmot) are the family.
   If divergence is worse than downtime, the CP options (etcd, Consul, rqlite,
   PRD 0011) are. **A product question, not a research one**; this note cannot
   settle it and everything else depends on it.
2. **Is PRD 0011's peer-to-peer model meant to reach fleet scale, or is it a
   small-cluster feature?** If mesh is "a handful of instances an operator knows
   about", option I stands and a backend is a separate, additional decision. If
   mesh is meant to be the fleet, `max_members = 32` and `home_unreachable` are
   load-bearing constraints that do not hold, and the PRD needs revising rather
   than extending. Also product, not research.
3. **Does `pg.zig` work against YugabyteDB?** The cheapest high-value experiment
   in this note. If it does, one afternoon buys a natively-distributed,
   node-loss-tolerant SQL backend with a native Zig client and no failover
   machinery — which would materially change the central-store column.
4. **Is clanker's state record-shaped or event-shaped?** Decides J versus E. The
   volume argues event-shaped: the append-only logs are the bulk. The read
   patterns argue record-shaped: the web UI wants queries and joins, and an
   operator debugging a self-modifying agent wants `psql`. A backend that gets
   this wrong is expensive to leave.
5. **What happens to `clanker run` when serve is not running?** Option A's
   central question, unanswered in the tree and the PRD. Mesh can refuse
   (*"start `clanker serve`"*) because mesh is optional; state is not. Refuse,
   auto-start, or fall back to direct writes — each is a different product, and a
   fallback reintroduces the divergence the channel exists to prevent.
6. **Is a pre-1.0 client API acceptable for a core dependency?** `nats.zig` is
   explicitly pre-1.0 with a changing API, in a project that pins two
   dependencies deliberately. If not, E drops and J leads by default.
7. **Is the tier-1 transport loopback HTTP or a unix socket?** PRD 0011 says
   loopback HTTP for mesh, but mesh is inherently networked and state is not. A
   socket needs no port and no authorization story — if a sandboxed process can
   reach one at all, which is the same wall a path outside the worktree hits
   unless the descriptor is inherited. Worth a spike before copying the mesh
   answer by default.
8. **What is the per-write latency of the channel path versus a direct write?**
   Decides whether the hot append logs need batching behind `ck_state`.
9. **Do agents need claims/leases, and is that worth a second store?** No longer
   hypothetical: see
   [the concurrent-sessions bug](../reports/bugs/2026-08-16-concurrent-sessions-commit-each-others-work.md),
   where the contended resource is the git working tree rather than a file in
   `state/`. That widens the question — a claim mechanism useful to clanker has
   to cover resources outside the state store, which argues for the lease living
   wherever coordination lives rather than being a column on a state table. PRD 0011
   has no notion of an agent claiming a resource with a timeout and a fence
   token; above a handful of agents that gap shows up as two agents doing the
   same work. etcd expresses it natively (TTL leases, server-side expiry) and is
   reachable with no new dependency, but only as a *sidecar* to a bulk store —
   its 1.5 MiB request limit rules it out as the primary. So the real question is
   whether coordination is worth running a second system for, or whether
   Postgres's `SKIP LOCKED` plus an `expires_ts` column is good enough. The
   default answer should be one store until measurement says otherwise.
10. **Should `state/` be a git repository?** git is already a hard dependency, the
   worktree machinery exists, and per-agent branches with explicit merges is a
   well-understood model. Not searched at all; noted because it is the kind of
   answer the "adjacent domain" prompt exists to surface.
11. **Would a hand-written LWW-register plus OR-set cover concurrent goal and card
   edits?** The one case every option currently resolves as last-writer-wins.
   Low priority: it is a refinement on whichever backend wins, not a choice
   between backends.

12. **Could `cr-sqlite` be used without Corrosion** — the extension plus
    clanker's own gossip over the mesh transport PRD 0011 is already building?
    That would give multi-writer full replication with no second daemon and no
    Rust, which is the combination nothing else in this note offers. Entirely
    unexplored, and the most interesting loose end here.
13. **Is Marmot production-ready?** Its repo, licence, architecture and conflict
    semantics were fetched 2026-08-16 (see option M, which corrected the earlier
    discussion-thread description of v1), but v2 is a young rewrite: 2PC
    write-path behaviour at the stated agent counts and out-of-order sync on
    ordered logs would need a pass of their own before it is weighed.
14. **Is a hash chain over the shared append logs worth one hash per record?**
    The only ledger property option R leaves standing with a clanker-specific
    argument. The improve ledger's prefix has been silently rewritten once
    already, and a chained log makes a rewritten prefix detectable at read
    time on any backend — including today's flat files — with no consensus
    and no daemon. Cheap to spike; entirely unexplored.

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
- **Peers stopping being one operator's.** Every BFT verdict in option R
  rests on the premise that the fleet is mutually trusting because one
  operator runs every node. A mesh that admitted other operators' instances
  would reintroduce the minority-adversary model and reopen the CometBFT row.

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

**Full-replication candidates**

- [Corrosion](https://github.com/superfly/corrosion) · [Fly blog](https://fly.io/blog/corrosion/) · [docs](https://superfly.github.io/corrosion/) · [CRDT docs](https://superfly.github.io/corrosion/crdts.html) · [QCon talk](https://qconlondon.com/presentation/apr2025/fast-eventual-consistency-inside-corrosion-distributed-system-powering-flyio)
- [cr-sqlite](https://github.com/vlcn-io/cr-sqlite) — the CRDT SQLite extension underneath it
- [rqlite](https://github.com/rqlite/rqlite) · [dqlite](https://dqlite.io/) · [SQLite replication comparison](https://onidel.com/blog/sqlite-replication-vps-2025) · [mvsqlite's dqlite/rqlite comparison](https://github.com/losfair/mvsqlite/wiki/Comparison-with-dqlite-and-rqlite)
- [Marmot](https://github.com/maxpert/marmot) — verified at source 2026-08-16; the [HN](https://news.ycombinator.com/item?id=38600743) and [Lobsters](https://lobste.rs/s/f9slcf/marmot_distributed_sqlite_replication) threads describe the older v1 and are out of date
- [HashiCorp on gossip, Serf, memberlist, Raft and SWIM](https://www.hashicorp.com/en/resources/everybody-talks-gossip-serf-memberlist-raft-swim-hashicorp-consul)

**Distributed SQL**

- [YugabyteDB resiliency vs PostgreSQL HA](https://www.yugabyte.com/blog/yugabytedb-resiliency-vs-postgresql-ha-solutions/) — vendor source
- [CockroachDB vs PostgreSQL vs YugabyteDB](https://www.index.dev/skill-vs-skill/cockroachdb-vs-postgresql-vs-yugabytedb)

**Zig-native landscape**

- [TigerBeetle architecture](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md) · [dbdb.io entry](https://dbdb.io/db/tigerbeetle)
- [awesome-zig](https://github.com/zigcc/awesome-zig)

**NATS alternatives**

- [Redpanda vs NATS vs Kafka 2026](https://www.pkgpulse.com/blog/redpanda-vs-nats-vs-apache-kafka-event-streaming-platforms-2026)
- [Message broker comparison 2026](https://dev.to/mahdi0shamlou/message-brokers-comparison-2026-kafka-rabbitmq-nats-redis-streams-which-one-should-you-3ea8)
- [NATS alternatives roundup](https://www.modern-datatools.com/alternatives/nats)

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

**Distributed ledgers (option R)**

- [CometBFT](https://github.com/cometbft/cometbft) — BFT state-machine replication over ABCI
- [Hyperledger Fabric: the ordering service](https://hyperledger-fabric.readthedocs.io/en/latest/orderer/ordering_service.html)
- [immudb](https://github.com/codenotary/immudb) · [replication docs](https://docs.immudb.io/master/production/replication.html)
- [InfoQ: AWS to retire QLDB](https://www.infoq.com/news/2024/07/aws-kill-qldb) — press, AWS's own page not fetched
- [Autobase (Pears docs)](https://docs.pears.com/building-blocks/autobase) · [OrbitDB](https://github.com/orbitdb/orbitdb)
- [Trillian](https://github.com/google/trillian) — maintenance mode, names Tessera as successor

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

**This row has a live instance in the tree.**
[Five sessions committed and stashed each other's work](../reports/bugs/2026-08-16-concurrent-sessions-commit-each-others-work.md)
records five agents sharing one checkout with no arbitration over the working
tree and index: a commit swept up another session's unfinished guests, a stash
briefly held three sessions' changes, and a rebase `--continue` refused while
`git ls-files -u` reported nothing unmerged, because another session was writing
the index between the check and the continue. The report's root cause — *"a git
working tree and index are process-global shared state, and nothing in the
harness arbitrates them"* — is this row, on a resource that is not in `state/`
at all. Its open design question, whether staging should take a claim the way
`clanker schedule run-due` takes its flock, is the same question as which
mechanism below backs `claim(...)`.

Of every option in this note, **etcd expresses this row natively and the others
emulate it**: an etcd lease carries the TTL, keepalive renews it, and the
attached keys are deleted by the server when renewal stops — so `expires_ts`
stops being something clanker enforces on a timer it has to run itself. Postgres
does it with a `expires_ts` column plus `SKIP LOCKED`, S3 with a conditional
create plus a sweeper, and PRD 0011 has no form of it at all.
