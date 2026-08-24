# RFC 0006 — Where ck_cas lock sidecars live

## Status

Decided — 2026-08-17. Decided as Option A in ADR 0031 (docs/adrs/0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md): the lock moved to state/locks/<sha256-of-target>.lock. The deciding fact the recommendation named — whether anyone minds the sidecars in practice — was answered on 2026-08-17 when the operator reported 46 of them as uncleaned litter.

## Overview

Every ck_fs_write_if compare-and-swap creates a permanent zero-byte <target>.ck_cas.lock beside its target. The lock file is correct and must never be unlinked while held, but when the target is a repo document the sidecar lands in the source tree: 34 were found across the checkout, 20 of them copied into .clanker-worktrees. They are gitignored and inert, so this is a placement question, not a correctness one, and it is open because the alternative changes the sandbox's lock path convention.

**Decision to make.** Where does the compare-and-swap lock file live — beside
its target as `<target>.ck_cas.lock`, or somewhere outside the source tree?

**Why now.** The sidecars are visible litter and growing: 34 on 2026-08-16, 46
by 2026-08-17, one per record ever CAS-written and a copy of each in every
improve worktree.

**Drivers.** Mutual exclusion must not weaken — a lock file may never be
unlinked while it is held. No new dependency. It has to work where `state` is
a symlink to the checkout's, which is what an isolated run has.

**Out of scope.** Whether `ck_fs_write_if` should lock at all. The measured
lost-update result in `src/util/file_lock.zig` settles that.

## Current state

`fsWriteIfImpl` in `src/sandbox/host.zig` creates `<target>.ck_cas.lock`,
holds an exclusive advisory lock on it for the read-compare-write, and closes
it. Closing releases the lock; nothing ever unlinks the file, and nothing
should. `src/util/file_lock.zig` is deliberately identical. There is no
workaround in place — the files are simply left where they fall.

## Options considered

### Option A — lock under state/locks/, keyed by a hash of the target path

- **What it is:** `fsWriteIfImpl` builds its lock path as
  `state/locks/<hash-of-full-path>.lock` instead of `<target>.ck_cas.lock`.
  One lock inode per target path, as today, but none of them in the source tree.
- **Maturity:** no new dependency; `std.crypto.hash` and `ensureDir` are
  already used here. `file_lock.acquire` already locks by `{dir}/{name}.lock`
  rather than beside the target, so this is the convention the rest of the
  codebase already follows.
- **How it would fit:** one lock-path expression in `src/sandbox/host.zig`,
  plus `ensureDir` on `state/locks/` — which is the one sanctioned way to
  create `state/` when it may be a `--worktree` symlink.
- **Pros:** the working tree stays clean; worktree copies stop inheriting
  sidecars; `state/` is already the place machine state lives.
- **Cons:** a lock is no longer visibly adjacent to what it guards, so a stuck
  lock is harder to spot by eye. Two different repo checkouts sharing one
  `state/` would share lock names; that is already true of the rest of
  `state/`, and AGENTS.md already says sharing one `state/` is not a mesh.
- **Cost to adopt:** small — one expression, one directory, plus a test that a
  CAS still serialises. Existing stray sidecars are deleted once by
  `clanker janitor` or by hand.
- **Cost to leave:** trivial; revert the expression. Old sidecars are inert
  either way.
- **Evidence:** `src/util/file_lock.zig` `acquire` (the existing
  `{dir}/{name}.lock` convention); `src/util/ensureDir` per AGENTS.md.

### Option B — keep the sidecar beside the target, and have janitor sweep it

- **What it is:** leave the lock path alone and teach `clanker janitor` to
  delete `*.ck_cas.lock` files that no process holds.
- **Maturity:** `janitor` already exists and already reports before deleting.
- **How it would fit:** one more sweep rule in the janitor guest.
- **Pros:** no change to the sandbox's locking at all; the sweep is opt-in and
  already has the report-then-`--yes` shape operators expect.
- **Cons:** it does not stop the litter, it periodically clears it, so a fresh
  checkout still grows sidecars between sweeps. Worse, deciding "no process
  holds it" is exactly the unlink-while-locked race the sidecar design exists
  to avoid; doing it safely means taking the lock first and unlinking under it,
  which is still unsafe for a process that already opened the old inode.
- **Cost to adopt:** small to write, but it buys a recurring hazard.
- **Cost to leave:** trivial.
- **Evidence:** `docs/reports/investigations/2026-08-16-ck-cas-lock-sidecars.md`
  (why unlinking a held lock breaks mutual exclusion).

### Option C — status quo

- **What it is:** keep the sidecar beside its target and let the files
  accumulate. They are zero bytes, gitignored (`.gitignore:67`), and inert.
- **Pros:** zero work and zero risk; the lock is visibly adjacent to what it
  guards, which is the easiest thing to reason about when a write hangs.
- **Cons:** `docs/reports/`, `docs/runbooks/` and `docs/research/` collect
  one sidecar per record ever CAS-written, every worktree inherits a copy, and
  directory listings carry noise that reads as leftover garbage to anyone who
  does not know the mechanism — which is what prompted this RFC.
- **Cost to adopt:** zero now. Later it is one `find -delete` whenever the
  noise becomes annoying, repeated forever.
- **Evidence:** 34 sidecars found in this checkout on 2026-08-16, 20 of them
  inside `.clanker-worktrees/`.

### Option D — out of the box: stop needing a sidecar at all

- **What it is:** replace the read-compare-write under an advisory lock with an
  atomic rename: write the new contents to a temp file in the same directory
  and `rename` it over the target only if the target still hashes to
  `expected`. POSIX `rename` is atomic, so no lock file is involved.
- **Maturity:** an OS primitive, not a dependency.
- **How it would fit:** rewrites the body of `fsWriteIfImpl`; the sandbox's
  path checks apply to the temp name too.
- **Pros:** no lock file anywhere, so the placement question disappears rather
  than moving.
- **Cons:** it does not actually close the window — hashing and renaming are
  still two steps, so two writers can both observe the expected hash and the
  second rename silently wins. That is precisely the lost-update failure
  `file_lock.zig` documents (six writers, ten messages each, twelve of sixty
  kept). Closing it needs a lock again, which is where we started. It also
  leaves temp files behind on a crash, trading one kind of litter for another.
- **Cost to adopt:** medium, and it would need the concurrency test to prove
  the very property it weakens.
- **Cost to leave:** high once callers depend on the new failure modes.
- **Evidence:** `src/util/file_lock.zig` module doc (the measured lost-update
  result that motivated locking in the first place).

## Implications by horizon

The options differ in exactly one horizon — the long one. Nothing distinguishes
them this week, which is why this sat open.

### Short term (this release / 0–3 months)

- **If A:** one expression changes; the existing sidecars are deleted once.
- **If B:** the sidecars come back between sweeps, and each sweep runs the
  unlink-while-held race.
- **If status quo:** nothing happens, which is the honest appeal of it.

### Medium term (3–12 months)

- **If A:** `state/locks/` grows one file per distinct target path. That
  plateaus for repo documents and does not for ephemeral ones, so it needs a
  retention rule of its own.
- **If B:** unchanged — a recurring sweep of a hazard that recurs.
- **If status quo:** `docs/` accumulates one sidecar per record and every new
  worktree inherits the whole set.

### Long term (12+ months)

- **If A:** the source tree stays clean permanently and the lock convention
  matches `file_lock.acquire`'s `{dir}/{name}.lock`.
- **If B:** the litter is bounded by sweep frequency and never goes away.
- **If status quo:** the sidecars become part of what the tree looks like, and
  the cost is paid by every reader who has to learn they are inert.

## Recommendation

**Recommended option:** Option A — move the sidecar to state/locks/ keyed by a hash of the target path

**Confidence:** 6/10

**Why this confidence.** A 6 because the status quo is genuinely tolerable and the litter is cosmetic — the mechanism is not at risk either way. What would raise it is the operator saying the sidecars are a problem in practice; what would sink it is a finding that the lock has to be adjacent to its target to be diagnosable. Neither was known when this was written. The first arrived on 2026-08-17, and the second was answered rather than found: the lock file now carries a holder record naming the run and the moment, which is more diagnosable than adjacency was.

**Rationale.** It is the only option that removes the litter without weakening the lock. Option B periodically deletes files whose safe deletion is the exact race the sidecar design avoids; Option D drops the lock and reintroduces the measured lost-update failure; the status quo is genuinely tolerable, which is why this is a 6 and not higher. What would move it: a second checkout deliberately sharing one state/ directory would need the hash to include the repo root, and if nobody minds the sidecars in practice, the status quo wins on zero risk.

**Reversibility.** Easy, and there is no point of no return. Reverting the lock
path expression restores the old behaviour; locks left in `state/locks/` are
inert once nothing looks there, exactly as the old sidecars are now.

## Open questions

- **Does `state/locks/` need a retention rule?** Answered while implementing:
  yes. The lock is keyed by target path, so an ephemeral target — a test's tmp
  tree, an improve staging copy — leaves a lock nothing will reuse.
  `clanker janitor` now sweeps lock files whose recorded acquisition is over
  12 hours old.
- **Does a lock need a heartbeat so a crashed run's lock can be reclaimed?**
  Answered: no, and it would be wrong. The lock is an `flock`, which the
  kernel releases when the holding descriptor closes, crash included. A held
  lock is never stale. This is the opposite of `src/util/run_lock.zig`, which
  is a pid file and does need reclaiming — by probing the owner, not by a clock.

## Next steps / action items

- [x] Decide the placement. Decided as Option A on 2026-08-17.
- [x] Write the ADR — [ADR 0031](../adrs/0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md).
- [x] Move the lock path in `fsWriteIfImpl` and delete the existing sidecars once.
- [x] Give `state/locks/` a retention rule in `clanker janitor`.

## References

- [ADR 0031](../adrs/0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md)
  — the decision this RFC produced.
- [Investigation 2026-08-16](../reports/investigations/2026-08-16-ck-cas-lock-sidecars.md)
  — why unlinking a held lock breaks mutual exclusion.
- `src/util/file_lock.zig` — the measured lost-update result that motivates
  locking at all, and the `{dir}/{name}.lock` convention Option A adopts.
