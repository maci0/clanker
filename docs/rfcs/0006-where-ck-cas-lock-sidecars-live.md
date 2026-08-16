# RFC 0006 — Where ck_cas lock sidecars live

## Status

Discussion — 2026-08-16. Options and recommendation filled in; the placement is the operator's call, not a fix to land unilaterally.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Every ck_fs_write_if compare-and-swap creates a permanent zero-byte <target>.ck_cas.lock beside its target. The lock file is correct and must never be unlinked while held, but when the target is a repo document the sidecar lands in the source tree: 34 were found across the checkout, 20 of them copied into .clanker-worktrees. They are gitignored and inert, so this is a placement question, not a correctness one, and it is open because the alternative changes the sandbox's lock path convention.

**Decision to make.** One sentence, phrased as the question the reader must
answer — "which X do we adopt for Y", not "we should adopt X".

**Why now.** What forces the choice: a blocked implementation, a cost, a
failure, a deadline, a dependency that is going away.

**Drivers.** The constraints any acceptable option has to satisfy (language and
toolchain, sandbox model, dependency budget, licence, operational cost, who
maintains it). These are what the options are scored against below, so keep
them concrete enough to disqualify something.

**Out of scope.** What this RFC deliberately does not decide, so a reader does
not read a broader mandate into it.

## Current state

How the thing works today, including the workaround being used in place of a
decision. Name the files, tools, or config that would change. If the status quo
is viable, it belongs in the options below as a real candidate, not as a
strawman.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

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

### Option B — <name>

- **What it is:**
- **Maturity:**
- **How it would fit:**
- **Pros:**
- **Cons:**
- **Cost to adopt:**
- **Cost to leave:**
- **Evidence:**

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

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

- **If A:**
- **If B:**
- **If status quo:**

### Medium term (3–12 months)

- **If A:**
- **If B:**
- **If status quo:**

### Long term (12+ months)

- **If A:**
- **If B:**
- **If status quo:**

## Recommendation

**Recommended option:** Option A — move the sidecar to state/locks/ keyed by a hash of the target path

**Confidence:** 6/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** It is the only option that removes the litter without weakening the lock. Option B periodically deletes files whose safe deletion is the exact race the sidecar design avoids; Option D drops the lock and reintroduces the measured lost-update failure; the status quo is genuinely tolerable, which is why this is a 6 and not higher. What would move it: a second checkout deliberately sharing one state/ directory would need the hash to include the repo root, and if nobody minds the sidecars in practice, the status quo wins on zero risk.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_

## Open questions

Questions whose answers could change the recommendation, each with who or what
can answer it. Keep them here until they are answered; do not silently drop the
ones that turned out to be inconvenient.

## Next steps / action items

- [ ] What happens if this recommendation is accepted, in order.
- [ ] The experiment or spike that would settle an open question above.
- [ ] Who is being asked for comment, and by when.
- [ ] Write the ADR once the decision is made.

## References



- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
