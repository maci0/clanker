# Research — Decentralized state store for isolated worktrees and mesh peers

## Status

Current — searched 2026-08-16. Revised after reading PRD 0011 (clanker mesh): the multi-host half is already decided by the home-instance rule, so the open problem is single-host process concurrency.

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
   concurrent agents. The next section establishes that this is a *single-host*
   figure — many short-lived processes sharing one `state/` — because mesh caps
   membership at 32.

## Constraints locked by PRD 0011 (clanker mesh)

Read after the first draft of this note and it changed several conclusions, so
it goes before the evidence rather than in a footnote.
[PRD 0011](../prds/0011-clanker-mesh.md) is marked *design locked*, Phase 1
partly built. Five of its decisions bound this question:

1. **Loopback HTTP to serve is already the house pattern.** Locked decision 1:
   *"Serve owns sockets. Everyone else is a loopback HTTP client."* `clanker
   mesh`, `ck_mesh` inside `clanker run` and the REPL, and `chatrooms.fanOut` in
   any process all reach the mesh by POSTing to the local serve. Option A below
   is therefore not a new architecture — it is the existing one, extended from
   mesh control to state.
2. **The door is a named host channel, not a guest network grant.** `ck_mesh` is
   registered next to `ck_chat` and gated on `tool_self_name`; *"the host
   function is the sandbox door; the I/O is not raw TCP."* The guest never holds
   the socket and never needs `network_allow`. This is a better answer than the
   one the first draft reached, and it removes the loopback-authorization
   objection to option A.
3. **No second daemon.** An explicit non-goal. Whatever owns state must be
   `clanker serve`, not a new process.
4. **No CRDT, no merge — explicitly.** Non-goal: *"Automatic conflict resolution
   beyond the home-instance rule. No CRDT, no merge."* Concurrency across hosts
   is resolved by **ownership**: the member that first shares a session is its
   *home*, home writes the canonical record, everyone else holds a read-only
   replica under `state/mesh/<home-id>/`, and continuing a session whose home is
   unreachable is **refused** (`home_unreachable`) rather than forked.
5. **Mesh is 32 members, not 10⁴.** `max_members = 32`, full mesh, *"32·31/2 =
   496 connections, which is the point of the cap."* So the thousands-of-agents
   figure in the question is **within one host** — many short-lived `clanker
   run` processes against one serve — and *not* across mesh peers. The two
   scales need different mechanisms, and conflating them was the first draft's
   main error.

The net effect: the multi-host half of the question is already decided, and
decided *against* a shared store. What remains genuinely open is the local half —
how many processes on one machine safely share one `state/`.

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
- **The answer is already the house pattern: a `ck_state` host channel that
  talks loopback HTTP to `clanker serve`.** PRD 0011 locks *"serve owns sockets,
  everyone else is a loopback HTTP client"* and routes `ck_mesh` exactly this
  way; `clanker serve` already exposes 43 distinct `/api/*` routes. An HTTP
  write path is immune to `safeJoinSecure` hardening by construction, because it
  is not a path — `high` confidence, verified in tree and against
  [PRD 0011](../prds/0011-clanker-mesh.md).
- **Route it through a name-gated channel, not a guest `network_allow` grant.**
  `networkAllowed` (`src/sandbox/host.zig:2350`) glob-matches the hostname and
  never examines the port, so a `["127.0.0.1"]` grant would admit *any* local
  port — including other services on the box. `ck_mesh`'s design avoids this by
  making the host do the I/O behind a `tool_self_name` gate. State should copy
  that, not `ck_http` — `high` confidence.
- **SQLite is not ruled out by the "no libc" rule.** `build.zig` already sets
  `link_libc = true` for the host binary (`build.zig:126`, `:406`, `:412`). The
  real objection to SQLite is its write model, not its C-ness: WAL gives many
  readers and exactly **one** writer, so N agents still serialize, and
  `SQLITE_BUSY` needs `busy_timeout` + `BEGIN IMMEDIATE` + short transactions —
  all three, or it fails under load — `high` confidence
  ([tenthousandmeters](https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/),
  [berthub](https://berthub.eu/articles/posts/a-brief-post-on-sqlite3-database-locked-despite-timeout/)).
- **CRDTs are ruled out by decision, not just by fit.** PRD 0011 lists
  *"No CRDT, no merge"* as a non-goal and resolves cross-host concurrency by
  home-instance ownership instead. The technical case agrees — the bulk of
  `state/` is append-only logs and single-owner records, and text CRDTs cost
  16–32 bytes of metadata per character — but the decision is already made —
  `high` confidence on the decision, `medium` on the numbers
  ([Loro benchmarks](https://loro.dev/docs/performance)).
- **The cross-host store candidates are off-model.** Turso, NATS KV, etcd,
  FoundationDB and S3 conditional writes all assume many writers converging on
  one store. PRD 0011 instead gives every shared entity a single owning host and
  **refuses** the write when that host is unreachable. They are surveyed below
  because the survey has value if that decision is ever revisited, not because
  any of them is a live candidate — `high` confidence.
- **The real open problem is local, not distributed.** Mesh caps at 32 members;
  the 10³–10⁴ agent figure is short-lived processes on *one* machine sharing one
  `state/`. That is a single-host concurrency problem, and it is the half no
  locked decision covers — `high` confidence.

## Scope and method

- **Searched:** the local tree first (`src/sandbox/host.zig`,
  `src/improve/worktree.zig`, `src/util/file_lock.zig`, `src/peers/`,
  `build.zig`, `build.zig.zon`, `docs/reports/`), then
  [PRD 0011](../prds/0011-clanker-mesh.md) in full, then web search on six axes —
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
  design. Turso pricing and product shape age fastest. The PRD is the fastest-
  moving input of all: it is marked *in progress*, so a Phase 1 landing or a
  revised non-goal dates this note before any external source does.
- **Revision:** the first draft was written without PRD 0011 and reached the
  right candidate for the wrong reasons — it treated the loopback-to-serve
  design as a new proposal and the 10⁴ figure as a cross-host requirement. Both
  are corrected above. The option survey itself did not change.

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

**Options D through H are surveyed against a decision already taken.** Each is a
shared multi-writer store for the cross-host case, and PRD 0011 resolves that
case by single-owner ("home instance") writes with an explicit refusal when the
owner is unreachable. They are recorded in full because a survey that omits the
rejected candidates cannot be re-audited, and because the home-instance rule is
a v1 choice that a later phase could revisit — not because any of them is a live
candidate today.

### D. libSQL / Turso embedded replicas — local reads, forwarded writes

- **What it is:** a local SQLite file kept in sync from a remote primary. Reads
  are served locally at file speed; writes are forwarded to the primary; an
  offline mode accepts local writes and pushes the WAL when connectivity
  returns.
- **Maturity:** commercial product with public docs and an examples repo; offline
  sync reached public beta. Exact version and licence not read in this pass —
  `unverified`.
- **Fit:** the closest published architecture to the shape the *question*
  describes — every host holds a replica, one primary owns the writes. But PRD
  0011 already implements that idea without the dependency: "home instance" is
  a per-entity primary, and `state/mesh/<home-id>/` is the read-only replica.
  Turso would centralize the primary for the whole mesh instead of per session,
  which is a different and larger commitment.
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
- **Fit:** **excluded by decision.** PRD 0011 lists *"Automatic conflict
  resolution beyond the home-instance rule. No CRDT, no merge"* among its
  non-goals. Reversing that is an ADR, not a research finding.

  The independent technical case reaches the same place, which is worth
  recording because it means the non-goal is not merely a scoping convenience:
  the append-only logs need ordering, not merging; the single-owner directories
  have no concurrent writers by construction; the small documents have a natural
  owner. The one slice where a CRDT would genuinely earn its keep is
  collaborative editing of a shared artifact — a Kanban card, a goal description
  — edited by two agents at once, which is exactly the case PRD 0011 chose to
  refuse rather than merge.
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

- **Already in the tree.** Four things, and this is the most important section of
  the note. (1) `clanker serve`'s HTTP API is a state service that is not yet
  used as one. (2) `ck_fs_write_if` is a working CAS primitive that is
  under-generalized rather than missing. (3) `src/peers/chatrooms.zig` already
  does durable append + HTTP fan-out with per-peer backoff — a working prototype
  of replicated state that nobody has named as one. (4) **PRD 0011 has already
  designed the access path**: `ck_mesh` as a name-gated host channel whose host
  side speaks loopback HTTP to serve. Option A is that design applied to a
  second noun. The out-of-the-box answer here was not a library at all; it was a
  decision already written down in another document.
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
  refusal observed during this session. Note that PRD 0011 does *not* force the
  issue: mesh replicates into `state/mesh/<peer-id>/` from serve, which already
  runs outside any worktree, so mesh can ship without this being solved. Doing
  nothing stays viable longer than the first draft of this note assumed — the
  forcing function is local agent count, not mesh.
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

| Option | Maturity | Licence | Fit vs PRD 0011 | Main risk |
|---|---|---|---|---|
| A. `ck_state` channel → serve over loopback | In-tree | own | **Best** — is locked decision 1, extended from mesh to state | Serve becomes a hard dependency of every run |
| B. Generalize `ck_fs_write_if` | In-tree | own | Compatible, but partial — small docs only | Does not address the sandbox-path fragility at all |
| C. SQLite / WAL | Very high | Public domain | Compatible — an engine *behind* A, not a rival to it | One writer at a time; `SQLITE_BUSY` under load |
| D. libSQL / Turso embedded replicas | Medium-high | unverified | Off-model — duplicates the home-instance rule with a vendor | Vendor dependency; first-to-sync-wins loses writes |
| E. NATS JetStream KV | High | Apache-2.0 | Off-model — good for claims, but a shared multi-writer store | A server to run (0011 non-goal); no Zig client found |
| F. etcd / FoundationDB | Very high | Apache-2.0 | Off-model — requires a cluster to start an agent | Operationally inverts how clanker ships |
| G. CRDTs (Yjs / Automerge / Loro) | High (Yjs) | MIT-ish | **Excluded** — explicit 0011 non-goal | Reversing it is an ADR; also per-char metadata, nested wasm |
| H. S3-style conditional writes | High | n/a (service) | Off-model for state; the *claim/lease* idea survives | Round-trip per op; needs cloud credentials |

## Evidence log

| Claim | Source | Read on | Confidence |
|---|---|---|---|
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

Ordered by what blocks a decision, most blocking first.

1. **What happens to `clanker run` when serve is not running?** This is option
   A's central question and nothing in the tree or PRD 0011 answers it. Mesh
   could refuse (*"start `clanker serve`"*) because mesh is optional; state is
   not. Refuse, auto-start, or fall back to direct writes — each is a different
   product, and a fallback reintroduces the divergence the channel exists to
   prevent.
2. **What is the per-write latency of the channel path versus a direct write?**
   Decides whether the hot append logs need batching behind `ck_state` or can go
   through the same route as everything else.
3. **Is the transport loopback HTTP or a unix socket?** PRD 0011 says loopback
   HTTP for mesh, but mesh is inherently networked and state is not. A socket
   needs no port and no authorization story — if a sandboxed process can reach
   one at all, which is the same wall a path outside the worktree hits unless
   the descriptor is inherited. Worth a spike before copying the mesh answer by
   default.
4. **Does the mesh cap of 32 members hold as the fleet grows?** The question
   posits 10³–10⁴ agents; PRD 0011 caps mesh at 32 and calls the cap deliberate.
   If those agents are all local processes the cap is irrelevant, and option A
   is sufficient. If they are meant to be hosts, `max_members` is the binding
   constraint and D/E/F re-enter — so this question decides whether half this
   note is live or archival.
5. **Should `state/` be a git repository?** git is already a hard dependency, the
   worktree machinery already exists, and per-agent branches with an explicit
   merge is a well-understood model. Not searched at all; noted because it is the
   kind of answer the "adjacent domain" prompt exists to surface.
6. **Is there a claim/lease primitive worth taking from option H** even though
   the store is off-model? PRD 0011 has no notion of an agent claiming a
   resource with a timeout and a fence token, and at any fleet size above a
   handful that gap shows up as two agents doing the same work.
7. **Would a hand-written LWW-register plus OR-set cover goals and Kanban
   cards** at a fraction of a CRDT library's cost? Parked, not open: PRD 0011's
   "no merge" non-goal makes this an ADR question rather than a research one.

## What would change the answer

- **PRD 0011's `max_members = 32` being raised, or the home-instance rule being
  revisited.** These are the two decisions that keep options D through H
  archival. Either one moving makes them live again.
- **A measured contention problem on one host.** If lost updates start appearing
  at current agent counts, C moves from "engine behind A" to urgent.
- **`clanker serve` becoming a required process.** Would remove option A's only
  serious objection and make it nearly free.
- **A pure-Zig embedded transactional store reaching maturity.** Would remove
  the only real objection to C.
- **A sandbox hardening pass that removes `shared_root`.** Would convert the
  recurring breakage into a permanent one and force this decision immediately.

## References

**Locked design**

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
