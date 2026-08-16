# RFC 0008 — How an agent claims a shared resource before writing it

## Status

Discussion — 2026-08-16. options, drivers and a recommendation are written; circulated to the sessions that hit the incident

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Five sessions sharing one checkout corrupted each other's work because
nothing arbitrates the git working tree and index. clanker has exactly one
claim mechanism today — the flock around `schedule run-due` — and it does not
generalise to a resource that is not a file. Decide what backs a
`claim(resource, holder, acquired_ts, expires_ts, fence_token)` lease, or
whether the answer is to stop sharing a checkout at all.

**Decision to make.** What backs a claim on a shared resource in clanker —
and is a claim mechanism the right answer at all, or should concurrent agents
be kept off shared resources by construction instead?

**Why now.** It stopped being hypothetical on 2026-08-16. Five agent sessions
shared one checkout and corrupted each other: a commit swept up another
session unfinished work, a stash briefly held three sessions changes at once,
a file was deleted by the session that owned it because its index view
predated another session commit, and `git rebase --continue` refused a
conflict that `git ls-files -u` said did not exist, because a third party was
writing the index between the two reads
([report](../reports/bugs/2026-08-16-concurrent-sessions-commit-each-others-work.md)).
Nothing was lost, and only because every affected session still had its work
on disk or in an out-of-repo backup. The fleet is growing; the next collision
does not get to rely on that.

**Drivers.** Any acceptable option has to satisfy all of these.

1. **Cover resources that are not files in `state/`.** The contended resource
   in the incident was the git working tree and index. A goal, a worktree, a
   branch, and a board card are the same shape. A design that only guards
   `state/*.json` does not address the failure that prompted it.
2. **No always-on process.** [ADR 0008](../adrs/0008-the-scheduler-is-cron-driven-not-a-daemon.md)
   settles that clanker ships no daemon and no scheduling thread. Lease expiry
   therefore cannot depend on a timer clanker runs: it has to be evaluated
   when a claim is next examined, or by something already running.
3. **Survive a dead holder.** A killed agent must not park a resource forever.
   That is what `expires_ts` is for, and it is why a bare lock file is not
   enough.
4. **Fence a resumed holder.** An agent that paused, lost its lease, and
   resumed must be refused. The incident has exactly this shape: the owning
   session acted on an index view that predated another session commit. This
   is what `fence_token` is for and it is the field most likely to be dropped
   as an optimisation.
5. **Work in-process, cross-process, and cross-host.** Two sessions on one
   machine is the case that broke. Two `clanker serve` instances meshed is the
   case PRD 0011 cares about. One mechanism should cover both or the second
   gets bolted on later.
6. **Stay inside the sandbox model.** A guest touches only what its descriptor
   grants. A claim a guest takes has to be one the host can enforce, which
   rules out an honour-system field a tool sets on itself.
7. **Dependency budget.** clanker is one static musl binary with providers as
   a native vtable and everything else a WASM guest. A new server process is
   not automatically disqualified, but it has to earn a place no in-tree
   primitive can fill.

**Out of scope.** Which store holds bulk state — sessions, runs, knowledge —
is [the state-store research note](../research/decentralized-state-store.md)
and PRD 0011, not this RFC; this decides coordination only, and deliberately
asks whether coordination should live with the bulk store or apart from it.
Also out of scope: the recovery procedure for a checkout that is already
tangled, which is
[its runbook](../runbooks/concurrent-agent-sessions-on-one-checkout.md).

## Current state

clanker has five partial answers and no general one.

**An advisory flock, twice.** `clanker schedule run-due` takes a non-blocking
exclusive flock for its duration, so a minute-by-minute cron cannot stack
sweeps ([ADR 0008](../adrs/0008-the-scheduler-is-cron-driven-not-a-daemon.md)).
`state/improve.lock` serializes improve-self runs
(`src/improve/worktree.zig`). Both are single-resource, single-host, and
untimed: the lock lives exactly as long as the process holds the descriptor,
which is a real advantage — a killed process releases it — and a real limit,
because a claim that must outlive one process cannot be expressed at all.

**Compare-and-swap on content, per file.** `ck_fs_write_if` refuses a write
whose expected hash no longer matches, which is what makes the record stores
safe to write concurrently. It is optimistic and stateless: it detects a
collision after the fact rather than reserving anything, and it has no notion
of who is working on the file. Two sessions can both be mid-edit; the second
writer is simply told to retry.

**A convention with no enforcement.** `.local/TODO.md` marks a claimed task
`[-]` with an owner and a session id (`.agents/agent-rules/todo.md`). It is
the mechanism that should have prevented the incident and did not, because
nothing reads it at the moment of a write. A board that is only consulted when
picking up work does not arbitrate anything.

**Application-level card claims.** `kanban_*` claims are chat messages folded
out of a room log ([ADR 0001](../adrs/0001-board-is-a-chatroom.md)). They
coordinate people and agents at task granularity, not writers at resource
granularity, and they are replicated with the room rather than enforced.

**An explicit decision not to lock, which this RFC reopens.**
[RFC 0001](0001-workspace-room-board-hierarchy.md) item 4 states: "No
cross-instance file lock. `state/improve.lock` serializes improve-self runs
only. Ordinary agent runs have no lock and do not get one over the mesh: a
mesh-wide file lock would reintroduce a home dependency for file writes, which
is exactly what worktrees + CAS merge-back avoid." That reasoning still holds
for bulk `state/` writes. It did not consider a resource outside `state/`, and
the git index is one.

**And nothing at all for the git working tree and index**, which is what
broke. Peer messaging resolved the incident — an ownership split, a hold, a
release — and nothing in the checkout communicates any of it, which is why the
collision happened before the messaging started rather than after.

## Options considered

All five are scored against the seven drivers above. The row every option is
trying to express is the same one:

```
claim(resource, holder, acquired_ts, expires_ts, fence_token)
```

`resource` is an opaque string, not a path — `git:index@/home/y/code/clanker`,
`goal:g-0042`, `worktree:imp-17` — which is what lets one mechanism cover a
resource that is not a file.

### Option A — CAS claim records in `state/claims/`, taken through a guest

- **What it is:** one file per claimed resource under `state/claims/<hash>.json`
  holding the row above, written with `ck_fs_write_if` create-if-absent. A
  `claim` guest offers `acquire`, `renew`, `release` and `holder`. Expiry is
  evaluated on read: an `acquire` that finds an expired record overwrites it
  and increments `fence_token`.
- **Maturity:** nothing new to mature. `ck_fs_write_if` is the primitive the
  three record stores already rely on for concurrent writes.
- **How it would fit:** a new guest plus manifest, `fs_prefixes` scoped to
  `state/claims/`; the mesh replicates the directory like any other state; the
  host checks a claim in the few native paths that write a shared resource —
  the staging path in `cmdCommit`, `worktree.createOn`, `goal_update`.
- **Pros:** no new dependency, no new process, and it is the plugin shape the
  project reaches for by default. Works unchanged for two processes on one
  host. `fence_token` is trivial when the record is a file you already
  rewrite. Expiry needs no timer, satisfying driver 2 exactly.
- **Cons:** expiry-on-read means a resource can look claimed long after its
  holder died, until someone tries to take it — acceptable for coordination,
  wrong for anything latency-sensitive. Cross-host correctness is only as good
  as the mesh replication underneath it, and a partition lets two members both
  believe they hold the claim. A guest cannot enforce the claim on a host-side
  writer; that enforcement is native code the RFC has to name file by file.
- **Cost to adopt:** one guest, one manifest, three or four host call sites.
  Days, not weeks.
- **Cost to leave:** delete the guest and the call sites. The records are
  ephemeral by construction, so there is no migration.
- **Evidence:** `ck_fs_write_if` in `src/sandbox/`, and the three record
  stores using it for exactly this class of race.

### Option B — etcd as a coordination sidecar

- **What it is:** run etcd alongside clanker and express claims as etcd leases:
  a TTL attached to a key, renewed by keepalive, and the server deletes the
  attached keys when renewal stops.
- **Maturity:** CNCF graduated, Apache-2.0, the coordination layer under
  Kubernetes. The most conservative choice on this list by adoption.
- **How it would fit:** a new process to run, a native client in `src/` (a
  guest cannot hold a keepalive stream), and a hard dependency for any
  deployment that wants claims.
- **Pros:** the only option that expresses the row natively rather than
  emulating it. Server-side expiry means a dead holder is cleaned up by
  something that is definitely running, which is the cleanest possible answer
  to drivers 2 and 3. Correct across hosts, with a real consensus story under
  a partition.
- **Cons:** an always-on server, which is the thing clanker has consistently
  refused to require. Its 1.5 MiB request limit rules it out as the bulk
  store, so adopting it means running a second system for coordination alone.
  Keepalive is a long-lived connection, which is a poor fit for short-lived
  CLI invocations — `clanker commit` would connect, claim, and disconnect
  within a second.
- **Cost to adopt:** a native client module, deployment docs, and an answer
  for every user who does not want to run a server.
- **Cost to leave:** moderate. The claim API can be kept and re-backed, but
  anything that came to depend on strict cross-host correctness would regress.
- **Evidence:** [the state-store note](../research/decentralized-state-store.md),
  section F1, which surveyed etcd for this and concluded it is the best lease
  primitive on the wrong data.

### Option C — a `claims` table in whichever store wins, `SKIP LOCKED` + `expires_ts`

- **What it is:** if PRD 0011 lands a real database, claims become a table:
  `SELECT ... FOR UPDATE SKIP LOCKED` plus an `expires_ts` column.
- **Maturity:** Postgres. Not in question.
- **How it would fit:** no new system beyond the one already chosen, and the
  claim row sits next to the data it guards.
- **Pros:** one store, one connection, one backup. Transactional: claiming and
  the write it guards can be atomic, which no other option here offers.
- **Cons:** conditional on a decision that has not been made, so this RFC
  cannot recommend it today without pre-empting the state-store decision it
  declared out of scope. A resource outside the database — the git index —
  is still guarded by a row that nothing forces a writer to consult, so the
  enforcement problem is unchanged.
- **Cost to adopt:** zero if that store arrives; unbounded if it does not.
- **Cost to leave:** a table drop.
- **Evidence:** the same note, section J.

### Option D — isolation instead of arbitration (out-of-the-box)

- **What it is:** stop sharing the contended resource. One agent, one
  worktree: every session that intends to write gets its own `git worktree`,
  and the shared checkout becomes read-only by convention and then by check.
  The claim is implicit in owning a directory nobody else has.
- **Maturity:** `git worktree` is git. The machinery is already in the tree
  (`src/improve/worktree.zig`), and two sessions independently arrived at the
  temp-worktree push during the incident itself.
- **How it would fit:** no new record, no new guest, no new dependency. What
  changes is where an agent works, plus a cheap guard that refuses to stage in
  a checkout whose `.git` is shared with a live session.
- **Pros:** removes the failure rather than mediating it — there is no lease
  to expire, no fence token to check, and no partition to reason about. It is
  the only option that costs nothing to be wrong about, and it is already
  proven on the exact incident: the pushes that worked used it.
- **Cons:** does not generalise past resources that can be copied. Two agents
  claiming the same goal, the same card, or the same remote branch cannot each
  have their own; the merge back to a shared branch is still contended; and
  disk cost is real for a large checkout. The sharpest counterexample is
  already observed: two sessions writing inventory rows into the same
  `docs/*/README.md` collided at merge time *despite* working in separate
  worktrees, because the contended thing is a list under one pair of markers,
  not a file either of them could own.
- **Cost to adopt:** small. Mostly documentation and one guard.
- **Cost to leave:** nothing to leave.
- **Evidence:** the incident report and
  [its runbook](../runbooks/concurrent-agent-sessions-on-one-checkout.md);
  the two temp-worktree pushes that succeeded while rebase and stash failed.

### Option E — status quo

- **What it is:** keep the flocks where they are, keep `.local/TODO.md` as a
  convention, and rely on cross-session messaging when sessions collide.
- **Pros:** zero cost. It also demonstrably works once a collision is
  detected: the incident was resolved in about twenty minutes by messaging,
  with no work lost.
- **Cons:** it is detection-and-recovery, not prevention, and it only fires
  after damage. It scales with the square of the number of sessions and with
  how attentive each one is. Recovery depended on every affected session still
  having its work on disk or in a backup, which is luck, not design.
- **Cost to adopt:** zero now. Later cost is one lost file on the day the luck
  runs out.
- **Evidence:** the incident is the status quo being exercised — both its
  failure and its recovery.

## Implications by horizon

The options do not differ much in the short term — every one of them stops
the incident recurring, including doing nothing plus more careful messaging.
They differ in what happens as the fleet grows and as the contended resources
stop being copyable. That is the deciding axis.

### Short term (this release / 0-3 months)

- **If A:** a `claim` guest and three or four host call sites. The git index
  is guarded at the staging path; everything else is unguarded but claimable.
- **If B:** nothing ships for weeks. A native etcd client and a deployment
  story come first, and every developer who does not run etcd needs a
  fallback, which is Option A built anyway.
- **If C:** nothing happens; the state-store decision has not been made.
- **If D:** documentation and one guard. Sessions move into their own
  worktrees and the incident class disappears for the git case.
- **If status quo:** nothing changes. The next collision is handled the way
  the last one was, by noticing and messaging.

### Medium term (3-12 months)

- **If A:** the interesting cases arrive — two agents on one goal, one card,
  one branch — and A covers them because `resource` is an opaque string. The
  cost surfaces as enforcement drift: every new native writer is a place
  someone forgot to check a claim.
- **If B:** correct, and running a second server for coordination alone looks
  expensive unless the fleet is genuinely multi-host by then.
- **If C:** becomes the obvious answer if a database landed, and stays
  unavailable if one did not.
- **If D:** holds for anything copyable and starts failing visibly for
  anything shared. Worktree sprawl becomes a maintenance item — which
  `clanker janitor` already reclaims.
- **If status quo:** collisions scale with the fleet, and the expensive ones
  are the quiet ones: two agents doing the same work, or one overwriting the
  other with nobody noticing for a day.

### Long term (12+ months)

- **If A:** either it has been enough, or its partition behaviour has become
  the problem and it is re-backed by B or C behind the same API. The API is
  the durable artefact; the file format is not.
- **If B:** clanker has a hard runtime dependency on a distributed system,
  which changes what the project is.
- **If C:** coordination and bulk state share a store, which is the simplest
  end state if the dependency is acceptable.
- **If D:** an operating discipline rather than a mechanism. It will still be
  right, and it will still not cover a shared branch.
- **If status quo:** unusable above a handful of agents, which is the fleet
  size the mesh is designed for.

## Recommendation

**Recommended option:** Phased — **D now, A next**, and neither B nor C until
measurement forces it. Adopt one worktree per writing session as the default
posture immediately, since it needs no code. Then add the CAS claim record in
`state/claims/` for the resources isolation cannot copy: a goal, a card, a
shared branch.

**Confidence:** 6/10

**Why this confidence.** 6, not higher, because the D half rests on one day of
evidence from one incident and the A half has never been built here — the
partition behaviour is reasoned about rather than measured, and the
enforcement story is the weakest part of it: a claim only guards a resource at
the call sites someone remembered to check, and this RFC names four without
having audited for a fifth. What would raise it: an audit of every native
writer to a shared resource, so the enforcement surface is a known list rather
than an estimate; and a week of the fleet running one-worktree-per-session
with no collision, which would confirm D carries most of the benefit on its
own. What would sink it: finding that most contended resources in practice are
*not* copyable — if goals and cards collide more often than checkouts do, then
D is a footnote and the decision is really about which lease backend to run,
which is a different RFC with B and C as the finalists.

**Held at 6 after the first round of comment.** A second day of evidence
(open questions 1 and 2) confirmed D holds for the working tree and produced
the first observed resource it cannot cover — inventory rows under shared
markers, which collided between two separate worktrees. That sharpens where A
is needed first without changing what is recommended, and it is still one
project over two days, which is not enough to move the number in either
direction.

**Rationale.** D is the only option that removes the failure instead of
mediating it, costs nothing to be wrong about, and is already proven on the
incident that prompted this RFC — the two pushes that succeeded used a
temporary worktree while rebase and stash failed. It is not sufficient, which
is why A follows: a resource that cannot be copied still needs a lease, and A
expresses one with no new dependency, no daemon, and expiry evaluated on read
rather than on a timer clanker does not run.

B is the only option that expresses the row natively, and that is not worth an
always-on server for coordination alone at this fleet size. C cannot be chosen
without pre-empting the state-store decision this RFC declared out of scope.

The trade-off accepted is A's weak partition behaviour: two meshed members can
both believe they hold a claim. That is tolerable for coordination between
cooperating agents, and would not be tolerable for anything where a double
write is unrecoverable — which is a limit on what a claim may guard, and
belongs in the ADR.

**Reversibility.** Both halves are cheap to undo and neither is a one-way
door. D is an operating posture: stop doing it and nothing has to be migrated.
A writes records that are ephemeral by construction — every one of them
expires — so backing it out is deleting a guest and its call sites, with no
data to convert.

The point of no return is not the storage, it is the API. Once tools, the web
UI, and the mesh call `claim`/`renew`/`release`, that contract is what is
expensive to change; the file format behind it can be re-backed by B or C
without a caller noticing. So design the API as if it will be re-backed, and
do not let `state/claims/*.json` become something a consumer reads directly.

## Open questions

1. **Which native writers must check a claim?** Four are named above
   (`cmdCommit` staging, `worktree.createOn`, `goal_update`, and the board).
   Nobody has audited for the rest. Answerable by a sweep of `src/` for writes
   to a resource another session could hold — and until it is done, the
   enforcement surface is an estimate.

   **One class already found, and it is not native.** Each record store keeps a
   second copy of a record status in a `README.md` inventory and writes it
   with a compare-and-swap over the whole file. That is six index writers
   across five guests — `reports` maintains two, `docs/reports/README.md` and
   `docs/runbooks/README.md`, and a single session landed a row in both on the
   day this was written. Per-file CAS is not a claim: it refuses a lost update
   but gives the loser nothing to wait on, so two sessions creating records in
   the same store in the same second serialize by retry. Those are guest
   writers rather than native ones, which widens the question — if the
   enforcement surface includes guests, then `claim` cannot be only a
   host-side check at a handful of call sites, and those six index writers are
   its first real consumers.
2. **Is the contended resource usually copyable?** The whole D-first shape
   depends on yes. **Partially answered, from a second day of evidence.** A
   session that did all its git work in a throwaway worktree off `origin/main`
   never wrote the shared index, and three other sessions uncommitted work
   survived untouched — so D holds for the working tree. But the two things
   that actually contended were *not* copyable: the git index, which is one
   per checkout by construction, and the `docs/*/README.md` inventory rows,
   where two sessions append to the same list under the same markers. Two RFC
   rows written in different worktrees still collided at merge time. That
   sharpens rather than settles the question: isolation covers the resource
   that broke first, and the claim mechanism is most needed exactly where
   isolation cannot reach. Still worth counting collisions over a few weeks.
3. **Who is the holder?** A session id, an instance id, or a run id. They have
   different lifetimes, and the fence token means nothing until this is
   pinned. `.local/TODO.md` already uses a session id, the mesh uses
   `instance.id`, and a claim that outlives a run needs the third.
4. **Does the shared-branch case need anything beyond a claim?** Two agents
   merging into one branch is contention that a lease serializes but does not
   resolve. Possibly out of scope; possibly the case that matters most once
   worktrees are the norm.
5. **Does [RFC 0001](0001-workspace-room-board-hierarchy.md) item 4 need
   amending?** It decided against a mesh-wide file lock for ordinary agent
   runs, and its reasoning — no home dependency for file writes — still holds
   for bulk `state/`. A claim on a resource outside `state/` is arguably not
   what it ruled out, but that should be stated rather than assumed.
6. **What happens on a partition?** Option A lets two members both hold the
   same claim. Whether that is acceptable depends on what a claim is allowed
   to guard, which is a policy question this RFC should answer before A is
   built, not after.
7. **Is invisibility the larger problem, and does it belong here at all?**
   Recorded because it was found while answering this RFC, and because no
   option above addresses it. On the day this was written the checkout held
   74 local branches; 11 carried commits that existed on no remote, the
   oldest five days old, including `fix/option-specific-help`,
   `fix/worktree-shared-state` and `local/gitignore-local-dir`. Three
   sessions had each reported their own state as clean, and each was telling
   the truth: every one had answered "is *my* work pushed" rather than "is
   this repository work safe". Nothing was contending, so a claim would have
   caught none of it — a lease arbitrates writers who collide, and unpushed
   work collides with nobody. Counting is what caught it, and the useful
   distinction the count produced is **missing ref** versus **lost work**:
   of the branches with no matching ref upstream, 11 held content and the
   rest were stale pointers at commits already there. Two sessions counted
   the missing refs on the same disk minutes apart and got 43 and 57; the
   cause was not established. The 11 are the number that matters and two
   independent methods agree on it — a patch-id sweep and an ahead-count —
   but that a simple census of one repository disagrees with itself between
   two readers is the open question restating itself. If this is worth
   solving it is a different mechanism — something that answers "what here
   exists nowhere else", periodically and without being asked. It may
   deserve its own RFC rather than an option in this one.

## Next steps / action items

- [ ] Document one-worktree-per-writing-session as the default in AGENTS.md and
      the concurrent-sessions runbook, since that half needs no code.
- [ ] Audit `src/` for native writers to a shared resource (open question 1).
      This is the spike that most changes the shape of Option A, and it is
      cheap.
- [ ] Count real collisions for two weeks (open question 2) before building
      anything. If they are all checkout collisions, D may be the whole answer.
- [ ] Pin what a holder is (open question 3) — session, instance, or run.
      Nothing else can be specified until this is decided.
- [ ] Circulate to the sessions that hit the incident; they have the only
      first-hand evidence. No deadline set — this is not blocking work today,
      which is itself a reason not to rush to a mechanism.
- [ ] Write the ADR once the decision is made, and amend or explicitly
      reaffirm RFC 0001 item 4 in it (open question 5).

## References



- Report: [Five agent sessions on one checkout committed and stashed each
  other work](../reports/bugs/2026-08-16-concurrent-sessions-commit-each-others-work.md)
  — the incident, its root cause, and the open design question this RFC exists
  to answer.
- Runbook: [Several agent sessions share one checkout](../runbooks/concurrent-agent-sessions-on-one-checkout.md)
  — recovery today, and the temp-worktree pattern Option D generalises.
- Research: [Decentralized state management](../research/decentralized-state-store.md)
  — the `claim(resource, holder, acquired_ts, expires_ts, fence_token)` row,
  its open question 9, and the surveys of etcd (F1), Postgres (J) and object
  storage (H) that this RFC scores rather than re-derives. The candidate set
  came from there; nothing in it was re-verified for this RFC.
- [RFC 0001](0001-workspace-room-board-hierarchy.md) item 4 — the standing
  decision against a cross-instance file lock, and why it did not settle this.
- [ADR 0008](../adrs/0008-the-scheduler-is-cron-driven-not-a-daemon.md) — no
  daemon, which is driver 2 and the reason server-side expiry is a cost rather
  than a free feature.
- [ADR 0001](../adrs/0001-board-is-a-chatroom.md) — card claims as chat
  messages, the closest thing to a claim clanker already ships.
- [ADR 0002](../adrs/0002-private-todos-vs-shared-board.md) — private run
  todos versus the shared board, the same private/shared split one layer up.
- `.agents/agent-rules/todo.md` — the `[-]` claim convention that exists and
  was not consulted at the moment of the write.

## Appendix

The incident timeline, kept because the ordering is what makes the failure
mode legible rather than just unlucky. All times 2026-08-16.

| Time | Event |
|---|---|
| ~19:05 | A commit stages another session in-flight guests by explicit path |
| ~19:10 | That session `Edit` returns *File does not exist*; the file is now tracked, and its index view predates the commit |
| ~19:12 | It deletes its newer copy to clear what it believes is a rebase collision; the change exists in no commit and no stash |
| ~19:20 | A rebase onto `origin/main` stops on a conflict; `git rebase --continue` refuses while `git ls-files -u` reports nothing unmerged |
| ~19:25 | The rebase is aborted and replaced with a plain merge, which succeeds |
| ~19:30 | Cross-session messaging establishes one owner and a hold; the merge is pushed |
| ~19:35 | Each session recovers its own work from the tree, the stash, or an out-of-repo backup |

Two details generalise past this incident:

- **`git status` is not evidence when your index view is stale.** A file that
  is tracked can look untracked, which is what turned a recoverable situation
  into a deleted file.
- **A stash can hold several sessions work at once.** The check that made it
  safe to restore from was `git diff HEAD stash@{0} --stat` on only the files
  being recovered, requiring zero deletions: insertions-only proves the stash
  differs from HEAD by your additions alone.
