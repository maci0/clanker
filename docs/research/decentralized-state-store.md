# Research — Decentralized state store for isolated worktrees and mesh peers

## Status

Current — searched 2026-08-16. Verified against the tree on 2026-08-16; the daemon option (A) still needs the loopback spike in Open Questions.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Which backend, concurrency-control mechanism and access path should clanker use
so runs isolated in git worktrees, and peers on other hosts, can read and write
shared agent state concurrently without copying state directories?

Three constraints make the question answerable rather than open-ended:

1. **The writer is a sandboxed wasm guest.** Whatever it calls must be reachable
   through a `ck_*` host function under a manifest grant, not through an ambient
   filesystem path.
2. **The harness is Zig 0.16 with two fetched dependencies** (`zwasm`, `vaxis`)
   plus vendored TOML. A candidate's cost includes what it adds to that list.
3. **Concurrency is real, not hypothetical.** The target is tens to thousands of
   concurrent agents, across more than one host once mesh lands.

## TL;DR

- **The pain is the path, not the store.** Worktree state sharing today is two
  independent mechanisms that must agree — host-side symlinks
  (`linkCheckoutState`, `src/improve/worktree.zig:313`) and guest-side prefix
  routing (`rootForPath`, `src/sandbox/host.zig:4742`). Every sandbox hardening
  pass re-derives `safeJoinSecure` and can silently break the second half while
  the first still looks correct — `high` confidence, observed in-tree
  ([bug record](../reports/bugs/2026-08-14-worktree-state-symlink-notdir.md)).
- **clanker already has a compare-and-swap primitive, and it does not scale to
  the state files that matter.** `ck_fs_write_if` (`src/sandbox/host.zig:3117`)
  is whole-file CAS: read all, SHA-256, compare, replace, under a `.ck_cas.lock`
  sidecar. `max_fs_bytes` defaults to 1 MiB (`src/sandbox/host.zig:178`), and
  `state/token_stats.jsonl` is already 3.2 MB — CAS on the hot append-only logs
  fails `too_large` before contention is even reached — `high` confidence,
  verified in tree.
- **The cheapest credible architecture is already 80% built and needs no new
  dependency: a local state daemon over the existing HTTP surface.** `clanker
  serve` exposes 43 distinct `/api/*` routes, `ck_http` is granted per-manifest
  by `network_allow`, and `networkAllowed` (`src/sandbox/host.zig:2350`)
  glob-matches the **hostname only** — the port is never examined — so a
  `network_allow: ["127.0.0.1"]` grant admits a daemon on any port. An HTTP
  write path is immune to
  `safeJoinSecure` hardening by construction, because it is not a path —
  `high` confidence, verified in tree.
- **SQLite is not ruled out by the "no libc" rule.** `build.zig` already sets
  `link_libc = true` for the host binary (`build.zig:126`, `:406`, `:412`). The
  real objection to SQLite is its write model, not its C-ness: WAL gives many
  readers and exactly **one** writer, so N agents still serialize, and
  `SQLITE_BUSY` needs `busy_timeout` + `BEGIN IMMEDIATE` + short transactions —
  all three, or it fails under load — `high` confidence
  ([tenthousandmeters](https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/),
  [berthub](https://berthub.eu/articles/posts/a-brief-post-on-sqlite3-database-locked-despite-timeout/)).
- **CRDTs are the wrong shape for most of clanker's state.** The bulk of
  `state/` is append-only logs and single-owner records, where last-writer-wins
  on an ordered append is already correct. Text CRDTs cost 16–32 bytes of
  metadata per character and pull in a Rust/WASM runtime — `medium` confidence
  ([Loro benchmarks](https://loro.dev/docs/performance),
  [PkgPulse comparison](https://www.pkgpulse.com/guides/yjs-vs-automerge-vs-loro-crdt-libraries-2026)).
- **Turso/libSQL embedded replicas are the closest off-the-shelf match to the
  stated shape** — local reads, forwarded writes, periodic sync — but they are
  a hosted-primary product with first-to-sync-wins conflict handling, which is a
  dependency and a business relationship, not a library — `medium` confidence
  ([Turso docs](https://docs.turso.tech/features/embedded-replicas/introduction)).

## Scope and method

- **Searched:** the local tree first (`src/sandbox/host.zig`,
  `src/improve/worktree.zig`, `src/util/file_lock.zig`, `src/peers/`,
  `build.zig`, `build.zig.zon`, `docs/reports/`), then web search on six axes —
  embedded SQLite concurrency, libSQL/Turso embedded replicas, CRDT library
  comparison, NATS JetStream KV vs etcd vs FoundationDB, S3 conditional writes,
  and agent-harness worktree architectures. The `research` tool's `plan` and
  `sweep` actions were run first (see [Appendix](#appendix)).
- **Not searched:** hosted multi-tenant control planes (Temporal, Restate,
  Dapr's state building block) — they assume a scheduler clanker does not have
  and an operator willing to run a cluster. Raft-in-Zig implementations were not
  surveyed; if the daemon option is chosen, replication is a later question, not
  this one. No benchmark was run: every performance number below is quoted, not
  measured.
- **Freshness:** sweep and verification both 2026-08-16. Newest sources are the
  2026 comparison pages; the SQLite concurrency material is stable and older by
  design. Turso pricing and product shape age fastest.

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

### A. Local state daemon over the existing HTTP surface — no new dependency

- **What it is:** promote `clanker serve` to the owner of `state/`. Guests reach
  it through `ck_http` to `127.0.0.1:<port>` under a `network_allow` grant in
  their manifest; the daemon does every `state/` write natively, on the machine
  where `state/` actually lives. A worktree needs no symlink and no
  `shared_root` special case, because it never names a path outside itself.
- **Maturity:** in-tree. 43 distinct `/api/*` routes exist today, including
  `/api/goals`, `/api/sessions`, `/api/runs`, `/api/stats`, `/api/board`,
  `/api/chat/*`, `/api/events` (SSE). `src/peers/chatrooms.zig:790` already
  fans a write out to peers over HTTP with per-peer backoff. Read 2026-08-16 in
  tree.
- **Fit:** exact. It is the only candidate that removes the fragile mechanism
  rather than adding a second one beside it. `networkAllowed` already handles
  `127.0.0.1` (`src/sandbox/host.zig:525`), and a network grant is declared per
  tool in the manifest — the same plugin boundary everything else uses.
- **Pros:**
  - Kills the `shared_root` special case in the path checker. A hardening pass
    on `safeJoinSecure` can no longer break state access, because state access
    stops being a path.
  - Concurrency control moves into one native process that can hold real locks,
    coalesce appends, and batch — instead of N guests racing on a filesystem.
  - It is the same API a mesh peer on another host already has to speak, so the
    local and remote cases stop being different code.
  - Failure is legible: an HTTP status, not a silent write into a worktree-local
    `state/` nobody reads.
- **Cons:**
  - A run now depends on a daemon being up. Needs a defined behaviour when it is
    not — refuse, or fall back to direct filesystem writes (and a fallback
    reintroduces the divergence the daemon exists to prevent).
  - Loopback HTTP is an authorization surface. Any process on the host can hit
    it unless there is a token; `ck_http` grants are per-manifest but the socket
    is not.
  - Latency per state write goes from a syscall to a request. Matters for the
    hot append logs, which is an argument for batching them.
- **Unknowns:** whether `ck_http` currently permits a port on loopback without
  additional policy; whether the existing routes cover enough of `state/` to
  avoid a large new API surface; what the per-write latency actually is.
- **Evidence:** `src/sandbox/host.zig:508-525` (loopback in `networkAllowed`),
  `src/cli.zig` route table, `src/peers/chatrooms.zig:790` (HTTP fan-out
  precedent).

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

### D. libSQL / Turso embedded replicas — local reads, forwarded writes

- **What it is:** a local SQLite file kept in sync from a remote primary. Reads
  are served locally at file speed; writes are forwarded to the primary; an
  offline mode accepts local writes and pushes the WAL when connectivity
  returns.
- **Maturity:** commercial product with public docs and an examples repo; offline
  sync reached public beta. Exact version and licence not read in this pass —
  `unverified`.
- **Fit:** this is the closest published architecture to the shape the question
  describes, and it maps onto the mesh roadmap almost directly: every host holds
  a replica, one primary owns the writes.
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
- **Maturity:** established, widely deployed, Apache-2.0. Version not read —
  `unverified`.
- **Fit:** genuinely good for the *coordination* subset — which agent owns which
  task, goal status, lease/claim records — and its `watch` would replace polling
  in the web UI. Poor for the bulk: session transcripts and token logs are not
  KV-shaped and would bloat a stream.
- **Pros:** revision-based CAS is exactly the primitive row 2 needs, at key
  granularity rather than file granularity; multi-host by construction, so the
  mesh case is free; watch eliminates polling loops.
- **Cons:** a server to run, which for a single-developer local harness is a
  large step up in operational weight; no Zig client found in this pass, so the
  wire protocol would be implemented or a C client linked; it answers
  coordination but leaves the document and blob state unsolved, so it is an
  addition rather than a replacement.
- **Unknowns:** Zig client availability; storage cost of history at clanker's
  write rates.
- **Evidence:**
  [NATS KV docs](https://docs.nats.io/nats-concepts/jetstream/key-value-store),
  [ADR-8](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-8.md),
  [state-store patterns write-up](https://timderzhavets.com/blog/building-distributed-state-stores-with-nats-jetstream/),
  read 2026-08-16.

### F. etcd / FoundationDB — strongly consistent cluster stores

- **What it is:** etcd is a Raft-backed KV store for cluster metadata, with
  leases, watches, and compare-and-swap on key revision. FoundationDB is a
  distributed transactional KV store with optimistic concurrency control and
  serializable multi-key transactions.
- **Maturity:** both are heavily used in production; both are Apache-2.0.
- **Fit:** poor, for a reason that is about clanker rather than about them. Both
  presuppose a cluster an operator runs and monitors. clanker's deployment unit
  is a checkout on a laptop; requiring a quorum to start an agent inverts that.
  FoundationDB's transaction model is the best technical match to row 2 of the
  table, and the worst operational match to how clanker ships.
- **Pros:** correct by construction; FoundationDB's OCC is the reference design
  for the concurrency the question asks about; etcd's lease primitive is exactly
  right for agent liveness at scale.
- **Cons:** operational weight; no Zig client for either found in this pass;
  etcd is not designed for the data volume `state/sessions/` represents (it is a
  metadata store with a value-size limit).
- **Unknowns:** none that would change the verdict at clanker's deployment shape.
- **Evidence:**
  [db-engines comparison](https://db-engines.com/en/system/FoundationDB;etcd),
  read 2026-08-16. Note that the comparison summary calling etcd "eventually
  consistent" is wrong — etcd is linearizable for reads through Raft — so this
  source is low quality and the claim is marked `low` in the evidence log.

### G. CRDTs — Automerge, Yjs, Loro

- **What it is:** replicated data types that merge concurrent edits without
  coordination, so every replica converges regardless of write order.
- **Maturity:** Yjs is the production default (~920 K weekly downloads, ~17 K
  stars); Automerge has `automerge-repo` for sync; Loro is newest, Rust+WASM,
  and leads the benchmark suite on size and speed. Read 2026-08-16, from
  secondary comparison pages — `medium` confidence on the numbers.
- **Fit:** poor for clanker's actual state, good for one narrow slice. The
  append-only logs need ordering, not merging. The single-owner directories have
  no concurrent writers by construction. The small documents have a natural
  owner. The one place a CRDT would genuinely earn its keep is collaborative
  editing of a shared artifact — a Kanban card, a goal description — edited by
  two agents at once.
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
- **Fit:** interesting and directly on point for the multi-host case, irrelevant
  for the single-laptop case. The task-claiming pattern — try to `PutObject` a
  claim key with `If-None-Match`, and you own the task if it succeeds — is
  precisely the primitive a 10⁴-agent fleet needs, and it needs no server.
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

- **Already in the tree.** Three things, and this is the most important section
  of the note. (1) `clanker serve`'s HTTP API is a state service that is not yet
  used as one — option A is mostly wiring, not building. (2) `ck_fs_write_if` is
  a working CAS primitive that is under-generalized rather than missing. (3)
  `src/peers/chatrooms.zig` already does durable append + HTTP fan-out to peers
  with per-peer backoff, which is a working prototype of replicated state that
  nobody has named as one.
- **Standard library / OS primitive.** Two are underused. `O_APPEND` writes below
  `PIPE_BUF` are atomic on local filesystems, which is the correct and nearly
  free answer for row 1 of the table — no CAS, no lock, no daemon. And a **unix
  domain socket** is the natural transport for option A on one host: it needs no
  port, no loopback authorization problem, and filesystem permissions are the
  access control. The catch is that a worktree cannot reach a socket outside its
  sandbox for the same reason it cannot reach `state/` — so the socket must be
  passed as an inherited file descriptor, or the transport falls back to
  loopback HTTP. Worth a spike.
- **Do nothing.** The current symlink + `shared_root` pair works when both halves
  agree. The cost is a recurring class of breakage — two records in
  `docs/reports/`, one hardening rollback in `git log` (`44071710`), and a live
  refusal observed during this session — plus the fact that it has no cross-host
  answer at all, so mesh would have to solve this problem anyway. Doing nothing
  is viable until mesh, and not after.
- **Narrow the requirement.** The strongest option on the list. The table above
  shows only ~16 KB of `state/` — the small mutable documents — actually needs
  compare-and-swap. Everything else needs atomic append or has a single owner.
  Solving *only* the coordination subset (goals, cards, claims, leases) through
  a shared store, and leaving sessions and logs as local files replicated
  lazily, cuts the problem by an order of magnitude and is compatible with every
  option above.
- **Adjacent domain.** Two transfer well. Build systems solved "many workers, one
  cache, no coordinator" with content-addressed storage plus atomic rename —
  clanker's `sessions/` and `runs/` are content-addressed in all but name.
  Distributed version control solved "everyone has a full replica, merges are
  explicit" — and clanker already has git in the loop, which raises the
  unexplored question of whether `state/` should be a git repository with
  branches per agent.
- **Buy, host, or delegate.** Options D, E, F, and H are all this. The
  consistent finding is that they solve the multi-host problem at the cost of an
  operator running something. That trade is wrong today and may be right once
  mesh has real users, which is what makes option A attractive: it is the only
  candidate whose local and hosted forms are the same code.

## Comparison

| Option | Maturity | Licence | Fit | Main risk |
|---|---|---|---|---|
| A. Local state daemon over existing HTTP | In-tree | own | **Best** — removes the fragile mechanism, same code path as mesh | Daemon becomes a hard dependency; loopback authz |
| B. Generalize `ck_fs_write_if` | In-tree | own | Partial — small docs only | Does not address the sandbox-path fragility at all |
| C. SQLite / WAL | Very high | Public domain | Good engine, needs A in front | One writer at a time; `SQLITE_BUSY` under load |
| D. libSQL / Turso embedded replicas | Medium-high | unverified | Closest published match to the shape | Vendor dependency; first-to-sync-wins loses writes |
| E. NATS JetStream KV | High | Apache-2.0 | Good for coordination subset only | A server to run; no Zig client found |
| F. etcd / FoundationDB | Very high | Apache-2.0 | Technically right, operationally wrong | Requires a cluster to start an agent |
| G. CRDTs (Yjs / Automerge / Loro) | High (Yjs) | MIT-ish | Poor — clanker's state is not merge-shaped | Per-char metadata; nested wasm runtime; convergence ≠ correctness |
| H. S3-style conditional writes | High | n/a (service) | Good for multi-host claims, wrong for hot local state | Round-trip per op; needs cloud credentials |

## Evidence log

| Claim | Source | Read on | Confidence |
|---|---|---|---|
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
| "etcd is eventually consistent" | [db-engines](https://db-engines.com/en/system/FoundationDB;etcd) | 2026-08-16 | **low — believed wrong**; etcd is linearizable via Raft. Recorded to mark the source unreliable |
| No pure-Zig embedded KV store found; Zig options are C bindings | one search only, `lmdb-zig` / `lmdbx-zig` | 2026-08-16 | low — under-searched |

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

1. **Does `ck_http` reach a loopback port today, end to end?** The *policy* half
   is settled: `networkAllowed` glob-matches the hostname and ignores the port,
   so a `["127.0.0.1"]` grant passes. What was read but not run is the
   *client* half — whether `httpImpl` connects to a plaintext loopback origin
   without TLS assumptions. One spike settles it: a throwaway guest with
   `network_allow: ["127.0.0.1"]` that POSTs to a running `clanker serve`.
   Decides whether option A is wiring or building.
2. **What is the per-write latency of the daemon path versus a direct write?**
   Decides whether the hot append logs need batching or can go through the same
   route as everything else.
3. **Can the unix-socket variant work at all under the sandbox,** or does the
   descriptor of a socket outside the worktree hit the same wall as a path
   outside it? If an inherited fd works, it is strictly better than loopback:
   no port, no authorization problem.
4. **Would a hand-written LWW-register plus OR-set cover goals and Kanban
   cards** at a small fraction of a full CRDT library's cost? This is the
   cheapest unexplored option in the note.
5. **Should `state/` be a git repository?** git is already a hard dependency, the
   worktree machinery already exists, and per-agent branches with an explicit
   merge is a well-understood model. Not searched at all; noted because it is the
   kind of answer the "adjacent domain" prompt exists to surface.
6. **What is the actual concurrency ceiling needed?** The question posits 10⁴
   agents. The measured contention today is single digits. The gap between those
   numbers changes which options are viable, and nothing in this note establishes
   which one to design for.

## What would change the answer

- **Mesh shipping.** Every option's ranking assumes single-host is the common
  case. Once state must cross hosts routinely, D, E, and H rise sharply and B
  becomes untenable.
- **A measured contention problem.** If lost updates start appearing at the
  current agent counts, C moves from "engine behind A" to "urgent".
- **A pure-Zig embedded transactional store reaching maturity.** Would remove
  the only real objection to C.
- **Turso's licence or hosting model changing.** D is the option most exposed to
  a vendor decision.
- **A sandbox hardening pass that removes `shared_root`.** Would convert the
  recurring breakage into a permanent one and force this decision immediately.

## References

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
- [db-engines: etcd vs FoundationDB](https://db-engines.com/en/system/FoundationDB;etcd) — low quality, see evidence log

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

**Events** — append-only, no CAS, ordering per stream only:

```
event(stream, seq, ts_unix_ms, host, agent_id, kind, payload_json)
```

Covers `token_stats.jsonl`, `improvements.jsonl`, `autolearn.jsonl`,
`reasoning.jsonl`, `chatrooms.jsonl`. `stream` is the file name today.

**Documents** — CAS on `revision`, the only shape that needs it:

```
doc(key, revision, ts_unix_ms, owner, body_json)
```

Covers `goals.json`, `worktrees.json`, `tool_usage.json`, `webui_plugins.json`,
and Kanban cards. `revision` is what `ck_fs_write_if`'s SHA-256 stands in for
today, at file granularity instead of key granularity.

**Blobs** — single-owner, write-once, content-addressed:

```
blob(id, ts_unix_ms, owner, bytes)
```

Covers `sessions/`, `runs/`, `history/`, `arena/`. These need replication, not
concurrency control — nothing else writes them.

**Claims** — leases, the primitive a 10⁴-agent fleet needs and clanker has no
form of today:

```
claim(resource, holder, acquired_ts, expires_ts, fence_token)
```

Create-if-absent is the whole protocol; `expires_ts` handles a dead holder, and
`fence_token` is what stops a resumed-from-pause agent acting on a lease it has
already lost.
