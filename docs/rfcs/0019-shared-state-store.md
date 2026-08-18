# RFC 0019 — Shared state store for worktree-isolated runs and mesh peers

## Status

Draft — opened 2026-08-18.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Decide which backend, concurrency-control mechanism and access path clanker should use so that runs isolated in git worktrees, and instances running on different servers in a network, can read and write shared agent state concurrently without copying state directories. The research note in docs/research/decentralized-state-store.md surveys 17 candidates across two independent axes — an access path (tier 1: how a sandboxed guest reaches state at all) and a topology/consistency choice (tier 2: where state lives and who resolves concurrency across N servers) — and records evidence for each without picking. This RFC is the decision that follows.

**Decision to make.** Which backend, concurrency-control mechanism and access path do we adopt so worktree-isolated runs and mesh peers on different servers read and write shared agent state concurrently without copying state directories?

**Why now.** Four things force the choice.

- The fleet is growing, and the mesh (PRD 0011) leaves most of `state/` per-host: `token_stats.jsonl`, `improvements.jsonl`, `autolearn.jsonl`, `reasoning.jsonl`, knowledge and `learnings.md` have no replication story, so a fleet does not pool what it learns.
- Worktree state sharing is a recurring breakage: the `shared_root` special case inside `safeJoinSecure` has produced a bug report and an investigation, one hardening rollback (`44071710`), and a live refusal observed during research.
- The in-tree CAS (`ck_fs_write_if`) was defective until 2026-08-17 — two writers could hold two locks on one file — so "already works" was not true when the research began.
- The research note is complete enough to decide from; it surveys the field and deliberately leaves the choice to this RFC.

**Drivers.** Any acceptable option must satisfy all of these (the note's four constraints plus the two named axes):

1. Reachable by a sandboxed wasm guest through a `ck_*` host function under a manifest grant, not an ambient filesystem path.
2. Zig 0.16 harness with two fetched deps (`zwasm`, `vaxis`) plus vendored TOML; a candidate's cost includes what it adds and whether a Zig client exists.
3. Many servers, tens to thousands of concurrent agents, each of which may fail independently.
4. No agent may be blocked by another agent's host being down.
5. Topology: central store vs full replication per host. "One host dies, the rest still know everything" is full replication.
6. Partition behaviour: CP (refuse writes without a quorum) vs AP (accept everywhere, converge). Whether an isolated agent should stall or keep working is the product question that selects the row.

**Out of scope.** This RFC does not decide the claim/lease mechanism for shared resources — RFC 0008 covers that and explicitly defers "which store holds bulk state" here. It does not decide the tier-1 transport (loopback HTTP vs unix socket) beyond defaulting to the PRD 0011 loopback pattern (open question 7). It does not decide the exact schema; the note's appendix sketches a candidate.

**Who decides, and by when.** The operator. Tier 1 (option A) is decidable now and blocks the first next step, so this RFC should leave discussion before tier-1 implementation starts; the tier-2 backend is not locked until the operator answers open questions 1 and 2, which the next steps put to them via ask_user.

## Current state

`state/` is a tree of JSON/JSONL files under the checkout, and it is four access patterns, not one:

| Shape | Files | Bytes (2026-08-16) | Concurrency need |
|---|---|---|---|
| Append-only event logs | `token_stats.jsonl`, `improvements.jsonl`, `autolearn.jsonl`, `reasoning.jsonl`, `chatrooms.jsonl` | 3.2 M / 1.7 M / 1.3 M / 348 K / 236 K | Atomic append; order need not be global |
| Small mutable documents | `goals.json`, `tool_usage.json`, `worktrees.json`, `webui_plugins.json` | 4 K each | Read-modify-write, must not lose a record |
| Per-entity directories | `sessions/`, `runs/`, `history/`, `arena/` | 9.5 M / 4.4 M / 1.1 M / 12 K | Single-owner writes; concurrent readers |
| Coordination sidecars | `*.lock` | 0 | Mutual exclusion |

Only the second row genuinely needs compare-and-swap; the first needs atomic append, a weaker and cheaper guarantee. Conflating them is why the current CAS primitive does not fit the files that grow.

Worktree isolation rests on two mechanisms that must agree: host-side symlinks (`linkCheckoutState`, `src/improve/worktree.zig:313`) and guest-side prefix routing (`rootForPath`, `src/sandbox/host.zig:4742`); `shared_root` is a special case inside `safeJoinSecure`. Guests write through `ck_fs_*` and the CAS primitive `ck_fs_write_if` (`src/sandbox/host.zig:3282`), which as of 2026-08-17 is correct for small documents but still whole-file, capped at `max_fs_bytes` (1 MiB), and still routed through `safeJoinSecure` — so it is exactly as exposed to sandbox hardening as a plain write.

Cross-host, PRD 0011 gives sessions a per-entity "home" with read-only replicas under `state/mesh/<home-id>/`, and board/goals a deduped message log resolved by fold order (last-writer-wins without saying so). Everything else in `state/` stays per-host.

## Options considered

The note's 17 candidates split into two tiers that are independent decisions. Options A and B are tier 1 (the access path); the rest are tier 2 (where state lives), placed on the topology × partition grid the note names. The status quo and one out-of-the-box option ("narrow the requirement") are added explicitly. Several candidates are ruled out on measured numbers; those verdicts are carried over with their evidence.

### Tier 1 — the access path

### A. `ck_state` host channel to serve, over loopback — the house pattern extended

- **What it is:** make `clanker serve` the owner of `state/`. A guest calls `ck_state`, a name-gated privileged channel registered next to `ck_chat`/`ck_mesh`; the host turns that into a loopback HTTP request to the local serve, which writes natively where `state/` lives. A worktree needs no symlink and no `shared_root` special case.
- **Maturity:** in-tree pattern; PRD 0011 already commits to it for mesh (locked decision 1: "Serve owns sockets. Everyone else is a loopback HTTP client."). 43 `/api/*` routes exist today; `src/peers/chatrooms.zig:790` already fans writes out over HTTP.
- **How it would fit:** a new host channel plus API surface; concurrency control moves into one native process that can hold locks and coalesce appends.
- **Pros:** kills the `shared_root` special case (state access stops being a path); makes tier 2 swappable behind serve; the name-gated channel avoids the `network_allow` hole (`networkAllowed` glob-matches hostname and never examines port, so `127.0.0.1` admits any local service); one door for local and mesh; failure is a status code, not a silent write.
- **Cons:** a run now depends on serve being up, and state is not optional the way mesh is; per-write latency goes from syscall to request (argues for batching the append logs); a new channel + API is real work.
- **Cost to adopt:** the new channel, the host-side loopback client, and the serve-side routes; moderate.
- **Cost to leave:** low, because it is the access path, not the store — but once guests call `ck_state` instead of writing paths, that is the committed seam.
- **Evidence:** PRD 0011 locked decisions; `src/cli.zig` route table; `src/peers/chatrooms.zig:790`; `src/sandbox/host.zig:2350` (why a channel beats a network grant).

### B. Harden and generalize the existing `ck_fs_write_if` CAS — smallest change

- **What it is:** keep the filesystem as the store and give guests real concurrency primitives through host functions instead of raw writes.
- **Maturity:** in-tree, and correct for small documents as of 2026-08-17 (three defects fixed: the lock name hashed the joined path string; the lock dir resolved against cwd; aged locks were never swept). The fix moved it from "claimed to work" to "actually works" at the scope it already had.
- **How it would fit:** extends the existing primitive rather than adding a channel.
- **Pros:** no new dependency, daemon or protocol.
- **Cons:** does not solve the stated problem — the CAS still routes through `safeJoinSecure` and `rootForPath`, so it is exactly as exposed to hardening as a plain write; whole-file CAS under contention degrades quadratically (every loser re-reads and retries — livelock at 10³ agents on one `goals.json`); no cross-host story. Neither missing primitive it suggests (`ck_state_append`; key-level granularity) exists.
- **Cost to adopt:** near zero.
- **Cost to leave:** near zero.
- **Evidence:** `src/sandbox/host.zig:3110-3175`; `src/util/file_lock.zig:1-13` ("six writers posting ten messages each kept twelve of sixty"); the 2026-08-17 bug and ADR 0031.

### Tier 2 — where state lives

The note places the candidates on two axes: topology (central store vs full replication on every host) and partition behaviour (CP vs AP). Full replication is what "one host dies, the rest still know everything" requires; CP means a minority partition stops writing.

### J. PostgreSQL — one dependency, all four data shapes (central, CP)

- **What it is:** a shared relational server; every instance connects over the network; serve becomes a client, not the owner of truth.
- **How it expresses the four shapes:** append logs = `INSERT` (MVCC, writers never block); documents = `UPDATE ... WHERE revision = $2` (row count 0 = lost the race); blobs = `bytea`/large objects/path into object storage; claims = `SELECT FOR UPDATE SKIP LOCKED` + `pg_advisory_xact_lock`.
- **Maturity:** highest on the list; `pg.zig` is a native Zig driver for Zig 0.16.0 (MIT), with pooling, prepared statements, `LISTEN/NOTIFY`, JSONB; TLS via OpenSSL is explicitly experimental (repo re-read 2026-08-18 — the README makes no no-libc/no-libpq claim; "native" implies no libpq, and the TLS path links OpenSSL).
- **Pros:** removes the `max_members` ceiling (no O(n²)); a host going down strands nothing (constraint 4 met directly); covers the state PRD 0011 leaves out; `SKIP LOCKED` gives the missing claim primitive; `psql` inspectability for a self-modifying system.
- **Cons:** a server an operator must run (deployment becomes "a checkout plus a database"); for reliability it is a cluster, not a server (streaming replication + Patroni/repmgr), the strongest argument against J relative to the full-replication row and to option O; connection count needs PgBouncer or routing through serve (tier 1 does that); TLS experimental.
- **Cost to adopt:** one server + HA tooling for any reliability-sensitive deployment; migration off JSONL.
- **Cost to leave:** the migrated data format is the expensive part.
- **Evidence:** [pg.zig](https://github.com/karlseguin/pg.zig), PG explicit-locking docs, SKIP LOCKED write-ups (all fetched 2026-08-16).

### O. Distributed SQL — CockroachDB, YugabyteDB (central, CP, resilient)

- **What it is:** horizontally scalable, strongly consistent SQL, multi-node by design; YugabyteDB is PostgreSQL wire-compatible.
- **Pros:** no separate HA tooling — availability from resilience, not failover; YSQL "reuses the PostgreSQL query layer" per its own README (confirmed verbatim 2026-08-18), so `pg.zig` may work against it unchanged — running that experiment is still the note's cheapest high-value test and has not been done.
- **Cons:** heavier per node; a cluster to operate; CockroachDB is source-available under the CockroachDB Software License, requiring a licence key outside limited non-production use, while YugabyteDB's core is Apache 2.0 — both confirmed at their LICENSE files 2026-08-18.
- **Evidence:** [YugabyteDB resiliency vs PostgreSQL HA](https://www.yugabyte.com/blog/yugabytedb-resiliency-vs-postgresql-ha-solutions/) (vendor source), comparison read 2026-08-16.

### D. libSQL / Turso embedded replicas — local reads, forwarded writes (central primary + replicas, AP-ish)

- **What it is:** a local SQLite file synced from a remote primary; reads local at file speed, writes forwarded, offline mode accepts local writes and pushes the WAL later.
- **Pros:** local-speed reads; the write path is the centralized backend; sync is a supported feature.
- **Cons:** conflict resolution is first-to-sync-wins (a lost update, no merge); hosted product with unverified self-host story; same guest problem as C (needs A in front); vendor dependency.
- **Evidence:** Turso embedded-replica and offline-sync docs (read 2026-08-16).

### F1. etcd — best CAS and lease primitives, on the wrong data (full per host, CP)

- **What it is:** Raft-backed strongly consistent KV for cluster metadata (Kubernetes' store).
- **Access:** no Zig client needed — the gRPC-gateway exposes the v3 API as JSON over HTTP (base64 values); clanker's HTTP client reaches it today.
- **Pros:** `Txn` on `mod_revision` is the document-CAS shape; TTL leases are the claim shape (server-side expiry); watch replay is PRD 0011's `CHAT_SYNC` cursor.
- **Cons (measured):** 1.5 MiB max request, ~8 GB suggested store, "designed to handle small key value pairs typical for metadata" (limit page, verbatim 2026-08-18; the "not a general-purpose database" phrasing could not be found at source and is dropped). Against this checkout's sessions — 38 at the note's measurement, 56 on the 2026-08-18 re-measurement, max 1.75 MB unchanged, base64 inflating ~33% — sessions and logs do not belong in etcd today. Operational cost (quorum loss stops writes; <10 ms fsync; periodic defrag; odd-numbered cluster) is the highest after FoundationDB.
- **Verdict from the note:** wrong as the backend, attractive as a coordination sidecar next to a bulk store — a two-store architecture.
- **Evidence:** etcd gateway/limits/API docs; local `find state/sessions -printf '%s'` (read 2026-08-16).

### N. Consul — gossip membership plus a Raft-replicated KV (full per host, CP)

- **What it is:** HashiCorp service discovery; Serf/memberlist gossip for membership, KV on Raft; multi-datacenter is first-class.
- **Fit:** functionally close to etcd for our purposes, better multi-site story, heavier; the bulk-data objection is unchanged.
- **Cons:** BSL 1.1, confirmed at the LICENSE file 2026-08-18 — licensor now IBM after the acquisition, and each release reverts to MPL 2.0 four years after publication.
- **Evidence:** HashiCorp gossip/Serf/Raft resource (read 2026-08-16).

### K. rqlite / dqlite — Raft-replicated SQLite, full copy on every node (full per host, CP)

- **What they are:** SQLite plus Raft. rqlite is a standalone process with an HTTP API; dqlite (Canonical) embeds as a library — no external database process.
- **Pros:** SQL/SQLite semantics (the schema sketch maps over); no etcd-style size limits; dqlite keeps the "one binary" property.
- **Cons:** single-writer through the Raft leader (solves replication/availability, not write concurrency); quorum required (same minority stall as etcd); dqlite is a C library coupled to Canonical's needs.
- **Evidence:** rqlite/dqlite repos and comparisons (read 2026-08-16).

### L. Corrosion + cr-sqlite — gossip-replicated SQLite with multi-writer CRDTs (full per host, AP)

- **What it is:** the note's "closest published match to a mesh where every host knows the full state." A daemon propagating SQLite state via the `cr-sqlite` CRDT extension; RESTful HTTP API, SQL subscriptions, QUIC transport, SWIM gossip. Every node accepts writes, always; conflicts resolve by CRDT semantics.
- **Maturity:** Apache-2.0, ~1.8k stars; Fly.io runs it across its fleet — the blog says "thousands of high-powered servers", converging "in seconds" (re-read 2026-08-18; the 800+/p99 ~1 s figures trace only to the QCon talk, which was not reopened); docs marked WIP; Rust daemon.
- **Pros:** exactly the requirement — lose any host, survivors still have everything and keep accepting writes; HTTP API needs no client; proven at Fly's fleet scale; the empirical answer to "we outgrew a central store".
- **Cons:** a Rust daemon (second runtime; PRD 0011's "no second daemon" argues against it); docs WIP; CRDT convergence is not correctness (two agents moving one card to different lanes converge on *a* lane); 2.5× insert cost; blobs gossip badly.
- **Cost to adopt:** deploy and operate a daemon; map the schema onto CRDT tables.
- **Evidence:** [Corrosion repo](https://github.com/superfly/corrosion), [Fly blog](https://fly.io/blog/corrosion/), [cr-sqlite](https://github.com/vlcn-io/cr-sqlite) (read 2026-08-16).

### M. Marmot — leaderless multi-master SQLite with HLC last-write-wins (full per host, AP, tunable)

- **What it is:** leaderless SQLite replication; any node accepts writes; row-level CDC + two-phase commit over gRPC; MySQL wire interface.
- **Pros:** tunable write consistency (ONE / QUORUM / ALL) — the only candidate where CP/AP is a per-write knob, not a property; HLC LWW is more principled than fold-order (PRD 0011) and weaker than CRDT convergence (L); SQLite semantics.
- **Cons (the project's own limitations):** all tables replicated (no selective table watching); rows may sync out of order (bad for append-only logs where order is the meaning); eventual consistency + avoid concurrent DDL (bad for a self-modifying harness); gRPC on the wire, not reachable from the existing HTTP client; no Zig client searched.
- **Evidence:** [Marmot repo](https://github.com/maxpert/marmot) (fetched 2026-08-16); HN/Lobsters threads are about the older v1 and now out of date.

### G. CRDTs — Automerge, Yjs, Loro (full per host, AP; a library, not a store)

- **What it is:** replicated data types that merge concurrent edits without coordination.
- **Fit:** poor on the merits — the append logs need ordering, not merging; per-entity dirs have no concurrent writers; a shared backend removes the problem CRDTs solve. The one slice where one would earn its keep (two agents editing one card/goal) is resolved as LWW by every option here.
- **Cons:** per-character metadata overhead plus full editing history retained per document (the 16–32 B/char figure is unverified at source — loro.dev returned 403 to the verification pass, and the note's evidence log says to reopen it before quoting); no Zig implementation; convergence ≠ correctness; at least one production migration away.
- **Evidence:** Loro perf, crdt-benchmarks, Cinapse migration (read 2026-08-16).

### I. PRD 0011's full mesh — peer-to-peer, per-entity ownership (full per host, CP-ish; native)

- **What it is:** no backend; each instance connects to every other; each shared entity has one owning "home" that serializes its writes; board/goals replicate as a deduped message log; sessions as read-only replicas under `state/mesh/<home-id>/`.
- **Maturity:** Phase 1 (codec, admission, liveness, Fleet map) built with host tests; listener, `ck_mesh`, CLI and fan-out open; Phase 3 unstarted.
- **Pros:** no server to run — the only candidate with that property; already designed and consistent with the sandbox model; failure is local.
- **Cons:** `max_members = 32` (O(n²)); per-entity SPOF (`home_unreachable` refuses the write); no replication at all for improvement logs, token stats, learnings, knowledge; LWW fold-order conflict resolution.
- **Evidence:** PRD 0011, whole document.

### E. NATS JetStream KV — distributed KV with watch, built on a log (per-stream replicas, tunable)

- **What it is:** a KV store layered on JetStream streams, with revisions, history and `watch`.
- **Maturity:** established, Apache-2.0; `nats-io/nats.zig` is the official Zig 0.16 client but explicitly pre-1.0 with a changing API; Object Store and client mTLS not built, though server-authenticated TLS is supported (re-verified 2026-08-18).
- **Pros:** multi-host with no `max_members` and no per-entity SPOF; `watch` gives push updates; streams give replay/history (good for `improvements.jsonl`/`autolearn.jsonl`); covers 3 of 4 shapes.
- **Cons:** a server to run; pre-1.0 client in a project that pins two deps deliberately; no Object Store in the Zig client (blobs need a second mechanism); no ad-hoc queries/joins/`psql`.
- **Evidence:** [nats.zig](https://github.com/nats-io/nats.zig), NATS KV docs, ADR-8 (read 2026-08-16).

### F2. FoundationDB — the most correct concurrency model, on the worst-fitting shape (sharded, CP)

- **Ruled out by a measured number.** Values ≤ 100 KB, transactions ≤ 5 s. 19 of this checkout's 38 session transcripts already exceeded 100 KB at the note's measurement (median 95 KB, max 1.75 MB); re-measured 2026-08-18: 19 of 56 still exceed it, max 1,753,954 bytes unchanged. Access is the heaviest (libfdb_c + FFI, no Zig binding). Not a candidate.

### C. SQLite / WAL — single host, not a cross-host answer

- **What it is:** replace JSON/JSONL with one embedded WAL-mode relational store per host.
- **Fit:** good on the host, poor from a guest (a wasm guest cannot open a DB file through `ck_fs_*`; it needs `ck_sql` or option A in front). It is a storage engine *behind* A, not a replacement for it, and it is not a cross-host answer at all.

### H. Object storage with conditional writes (S3 `If-Match` / `If-None-Match`)

- **What it is:** S3 create-if-absent and ETag CAS — enough for leases, leader election and task claiming with no coordinator.
- **Fit:** a complement, not a primary — covers blobs (where 9.5 MB of sessions doesn't belong in a KV) and claims, not documents or hot logs.

### P. The Zig-native landscape — TigerBeetle and what does not exist

- **What it is:** TigerBeetle is the flagship Zig database, operationally the simplest distributed store here — and its schema is fixed to double-entry accounts, so it cannot hold `state/`. It is the proof a Zig-native replicated store is achievable, and the VSR reference if clanker ever builds its own. No general-purpose Zig store exists.

### Q. NATS alternatives for the event-shaped half

- Redpanda/Kafka are better at streaming and cover one shape; Redis Streams covers documents + events but persistence/clustering unverified. None displaces NATS for the combination (streams + KV CAS + TTLs + watch + one server + one Zig client).

### Status quo — do nothing

- **What it is:** keep the JSON/JSONL files, the symlink + `shared_root` pair for worktrees, and per-host `state/` with no cross-host pooling.
- **Pros:** zero work now; works for a single host and small meshes.
- **Cons:** the recurring tier-1 breakage continues; every server keeps a private `state/`, so agents re-derive the same learnings, token accounting is per-host, and `improvements.jsonl` fragments N ways. Survivability at two hosts; the thing the question exists to prevent at a hundred.
- **Cost to adopt:** zero now; the cost is the breakage and non-pooling later.

### Out-of-the-box — narrow the requirement (staged adoption)

- **What it is:** only ~16 KB of `state/` (the small mutable documents) genuinely needs compare-and-swap; everything else needs atomic append or has a single owner. Adopt in stages: put the coordination subset (goals, cards, claims, leases) in a shared backend first, keep sessions and blobs local with lazy replication, and move the append-only logs when the fleet is large enough that pooling them matters.
- **Why it leads:** the note calls it "the strongest move on the list", and it survives the reframing into tiers. Every tier-2 candidate supports being adopted in that order, and tier 1 is what makes the staging invisible to guests.

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** worktree breakage is removed at the cost of serve being required for state writes; the "what does `clanker run` do without serve" question must be answered. Tier 2 becomes swappable — the optionality everything else depends on.
- **If B:** the smallest change lands immediately, but it does not fix the `shared_root` breakage or cross-host sharing, so the stated problem stays open.
- **If J/O:** a server and (for J) HA tooling must be stood up and a migration started; the two experiments (pg.zig vs YugabyteDB, unix-socket transport) are cheap and settle the central-store column.
- **If L/M:** a daemon (Rust for L, or Marmot) must be deployed and operated; schema mapping onto CRDT/HLC tables starts.
- **If status quo:** nothing changes; the worktree breakage recurs and the fleet keeps not pooling.

### Medium term (3–12 months)

- **If A + narrow-the-requirement:** the coordination subset is in one shared backend; sessions/blobs stay local; append logs move when pooling matters. The tier-2 choice is postponed until the product question (stall vs keep working) is answered.
- **If J:** bulk state, claims and logs consolidate on one store; the open questions are `pg.zig` at thousands of connections, TLS maturity, and the migration path off JSONL.
- **If the AP row (L/M):** every host holds full state and keeps writing through partitions; the costs are the daemon (L), out-of-order rows (M), and CRDT "converge, not correct" semantics on card/goal edits.
- **If status quo:** at a handful of hosts the mesh's 32-member ceiling and per-entity SPOF begin to bind; above it, `home_unreachable` strands work and the unreplicated logs fragment.

### Long term (12+ months)

- **If A + one store (J or O):** a self-modifying fleet with inspectable, queried state and collective learning; the dependency is an operator-run database, and the point of no return is the migrated data format.
- **If full-replication AP (L/M):** the fleet meets "no agent blocked by a host being down" directly, at the cost of owning a daemon and CRDT/HLC conflict semantics, with blob state living elsewhere.
- **If status quo:** survivable at two hosts; at a hundred the question this RFC exists to prevent becomes the daily failure mode.

## Recommendation

**Recommended option:** Phased. Tier 1 now: option A — a `ck_state` host channel to the local serve (the house pattern applied to state). Tier 2: do not lock a backend yet. Adopt the "narrow the requirement" staging — coordination subset first (goals, cards, claims/leases), sessions and blobs local with lazy replication, append-only logs later — and default that first shared backend to PostgreSQL unless the product answer to "should an isolated agent keep working" selects the AP row, in which case verify Corrosion first.

**Confidence:** 6/10

**Why this confidence.** Raises: `pg.zig` working against YugabyteDB unchanged (natively-distributed SQL with no failover machinery); the operator's answer to "stall vs keep working" (selects the CP vs AP row); `nats.zig` reaching 1.0 or `pg.zig`'s TLS leaving experimental (removes the two named maturity gaps on the leaders). Sinks: an operator who will not run a server (collapses tier 2 to option I or do-nothing); a decision that the mesh stays small (option I becomes sufficient); a measured contention problem on one host (makes tier 1 urgent and could force B as a stopgap before A lands).

**Rationale.** Tier 1 has no real competition: A beats B because B neither fixes the breakage (it still routes through `safeJoinSecure`) nor has any cross-host story, while A removes the fragile mechanism, makes tier 2 swappable behind serve, and is already PRD 0011's locked pattern for a neighbouring problem. Tier 2 is staged rather than picked because the note found no single winner — its two blocking open questions (stall vs keep working; whether the mesh is meant to reach fleet scale) are product decisions that select the row, not the candidate. "Narrow the requirement" is the note's strongest move and makes one-store-by-default safe to start; PostgreSQL is that default because it is the only single candidate covering all four data shapes with a native Zig client (`pg.zig`) and the missing claim primitive (`SKIP LOCKED`), and its one real cost — single-node SPOF — is already answered by HA tooling or by option O.

**Reversibility.** Tier 1 (A) is a seam, not a store: once guests call `ck_state` instead of writing paths, that access path is committed — but that is exactly what makes tier 2 swappable, since the backend behind serve can change without touching a guest. Tier 2 is the reversible part: starting with PostgreSQL and later moving to a full-replication AP store (Corrosion/Marmot) is a migration, not a rewrite, because tier 1 decouples them. The point of no return is the migrated data format: once data leaves the JSON/JSONL files into tables, backing out is the expensive step, so the staging order (coordination subset first) should be followed before any bulk migration.

## Open questions

Ordered by what blocks a decision, most blocking first.

1. **Should an isolated agent stall or keep working?** The CP/AP question; a product decision that selects the row rather than a candidate.
2. **Is PRD 0011's mesh meant to reach fleet scale, or is it a small-cluster feature?** If "a handful of instances", option I stands and a backend is a separate additional decision.
3. **Does `pg.zig` work against YugabyteDB?** The cheapest high-value experiment; if yes, one afternoon buys natively-distributed SQL with a native Zig client.
4. **Is clanker's state record-shaped or event-shaped?** Decides J versus E.
5. **What happens to `clanker run` when serve is not running?** Option A's central question: refuse, auto-start, or fall back (a fallback reintroduces divergence).
6. **Is a pre-1.0 client API acceptable?** If not, E drops and J leads by default.
7. **Tier-1 transport: loopback HTTP or a unix socket?** A socket needs no port/authorization but must be inherited to reach a sandbox.
8. **Per-write latency of the channel vs a direct write?** Decides whether hot append logs batch behind `ck_state`.
9. **Claims/leases worth a second store?** etcd expresses it natively but only as a sidecar; the default is one store until measurement says otherwise.
10. **Should `state/` be a git repository?** Not searched; per-agent branches with explicit merges is a well-understood model.
11. **Hand-written LWW-register + OR-set for goal/card edits?** A refinement on whichever backend wins.
12. **Could `cr-sqlite` be used without Corrosion?** The extension plus clanker's own gossip — no second daemon, no Rust; entirely unexplored.
13. **Is Marmot production-ready?** Its repo was fetched 2026-08-16 (v2 architecture, HLC conflict model and stated limitations verified there — the discussion-thread description of v1 was corrected then), but v2 is a young rewrite: 2PC write-path behaviour at the stated agent counts, out-of-order sync on ordered logs, and the missing Zig/gRPC client are unassessed.

## Next steps / action items

- [ ] Accept tier 1: implement `ck_state` and answer "what does `clanker run` do without serve" (open question 5).
- [ ] Run the two cheap experiments: pg.zig against YugabyteDB (question 3) and the unix-socket transport spike (question 7).
- [ ] Put the two product questions (1 and 2) to the operator via ask_user; the answers select the tier-2 row.
- [ ] Adopt "narrow the requirement" staging regardless of which tier-2 backend wins.
- [ ] Write the ADR once the decision is made.

## References

- Research: [Research — Decentralized state store for isolated worktrees and mesh peers](../research/decentralized-state-store.md) — read 2026-08-18; the source for every claim here.
- [RFC 0008 — How an agent claims a shared resource before writing it](../rfcs/0008-claims-on-shared-resources.md) — defers "which store holds bulk state" here.
- [PRD 0011 — clanker mesh](../prds/0011-clanker-mesh.md) — the in-tree mesh candidate and tier-1 precedent.
- External sources are cited per option above (pg.zig, etcd, NATS, Corrosion, cr-sqlite, Marmot, FoundationDB, TigerBeetle).

## Appendix

- The note's tier-2 comparison table (topology × partition grid) and its candidate schema sketch live in the research note and are the reference for the migration once a backend is chosen.

## Verification log — 2026-08-18

Every load-bearing claim above was reopened at its original source in this pass — the repository, documentation page, or blog post each option cites — independently of the research note, and the local measurement was re-run. Confirmed verbatim at source: etcd 1.5 MiB / 2 GB / 8 GB limits, the JSON gRPC-gateway at /v3/* with base64 keys and values, Txn as an atomic If/Then/Else on version/create/mod/value, lease-TTL key deletion, and watch replay from a start revision; FoundationDB 10,000 B keys / 100,000 B values / 10,000,000 B transactions / 5 s duration; S3 If-None-Match create and If-Match ETag CAS; cr-sqlite MIT, crsql_as_crr, crsql_changes, 2.5x insert cost, build-against-a-release-tag advice; Marmot leaderless 2PC with ONE/QUORUM/ALL, HLC last-write-wins, anti-entropy, and its three stated limitations; rqlite Raft with an HTTP API; dqlite as an embeddable Raft C library used by LXD; Corrosion Apache-2.0 with cr-sqlite, SWIM (Foca), QUIC (Quinn), SQL subscriptions, docs WIP; pg.zig for Zig 0.16.0, MIT, pooling, LISTEN/NOTIFY, experimental OpenSSL TLS; nats.zig official, Zig 0.16+, Apache-2.0, JetStream and KV, pre-1.0; Consul BSL 1.1 with IBM as licensor; the CockroachDB Software License; YugabyteDB Apache 2.0 core reusing the PostgreSQL query layer; TigerBeetle Zig, VSR, static allocation, accounts-and-transfers schema.

Corrected in place above after this pass: pg.zig no-libc/no-libpq (not stated at source), the etcd "not a general-purpose database" quote (not found at source), and Corrosion 800+ nodes / p99 ~1 s (the Fly blog says "thousands of high-powered servers" and "in seconds"; the numbers trace only to the QCon talk, which was not reopened).

Not reopened in this pass, so still note-sourced: the Turso embedded-replica docs (option D), the NATS-alternatives comparison pages (option Q), and the SQLite-concurrency write-ups (option C). Still unverified: loro.dev/docs/performance (HTTP 403 again), and the pg.zig-against-YugabyteDB experiment (not run).