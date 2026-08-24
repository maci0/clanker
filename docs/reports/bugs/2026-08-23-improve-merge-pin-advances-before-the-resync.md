# Bug — the merge-base pin advances before the branch resync it depends on, and the resync failure is only a warning

## TL;DR

- **What failed:** src/improve/worktree.zig calls advanceCreatedFrom(commit) and only then resyncLocalBranch, which swallows both a spawn error and a non-zero git exit into a warn log. created_from is the 3-way merge base for the next promotion, so if the reset does not land the pin claims the branch is at the landed commit while the ref is still at its pre-merge tip; the next merge-tree reads that as a deletion of everything the merge folded in, and CASes it onto the base branch.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-24. Fixed in 17115abb; verified by clanker gate. Both mergeBack call sites go through afterLanded, which resyncs the branch first and advances created_from only when the reset reports success; resyncLocalBranch returns bool. Fault-injection test in worktree.zig fails the reset and asserts the pin did not move, with a control that it does move when the reset lands.

## Status

Resolved on 2026-08-24. Fixed in 17115abb; verified by clanker gate. Both mergeBack call sites go through afterLanded, which resyncs the branch first and advances created_from only when the reset reports success; resyncLocalBranch returns bool. Fault-injection test in worktree.zig fails the reset and asserts the pin did not move, with a control that it does move when the reset lands.

## Symptom and impact

`src/improve/worktree.zig`'s merge path runs, in order:
`advanceCreatedFrom(gpa, commit)`, then `resyncLocalBranch(gpa, io, commit)`,
then `resyncBaseCheckout`, then `self.merged = true`.

`resyncLocalBranch` swallows both the spawn error and a non-zero git exit into a
`log.log(.warn, …)` and returns `void`. `created_from` is the merge base the
*next* promotion passes to `mergeTree(gpa, io, self.created_from, base_sha,
branch_sha)`. So if the `git reset --hard` does not land, the pin claims the
branch is at the merge commit while the branch ref is still at its pre-merge
tip, and the next `merge-tree` computes the branch side as a diff *from* the
landed commit — which reads as a deletion of everything that merge folded in
from the other side. That deletion is then CAS'd onto the base branch.

`advanceCreatedFrom`'s own docstring states the invariant it is violating:

> the branch ref is fast-forwarded to the landed commit (`resyncLocalBranch`
> below), so the branch's next delta starts there too.

The neighbouring `resyncBaseCheckout` comment cites a commit for this exact
class of bug already having deleted promoted work from origin once.

## Reproduction

Not reproduced: it needs `resyncLocalBranch`'s `git reset --hard` to fail, which
in practice means a locked index, a read-only worktree, or a concurrent git
operation. Established by reading the ordering against
`advanceCreatedFrom`'s documented precondition.

## Root cause

A state pin advanced before the operation it asserts, with that operation's
failure demoted to a warning.

## Resolution

Fixed in 17115abb. `resyncLocalBranch` returns `bool`, and both merge paths
now go through one `afterLanded`, which resyncs first and calls
`advanceCreatedFrom` only when the reset reported success. One helper rather
than two ordered pairs, because the report describes one call site and there
were two: the fast-forward path and the merge-commit path, and an ordering
fixed in one of them is not fixed.

Leaving the pin where it was is the safe direction: the next `merge-tree`
recomputes from the older base, which over-reports the branch delta (at worst
a conflict a human resolves) rather than under-reporting it.

The two `gate_invariants` needles that pinned the old call sites
(`self.resyncLocalBranch(gpa, io, commit);` and the `branch_sha` twin) were
replaced by the `afterLanded` call sites plus the ordering itself
(`if (self.resyncLocalBranch(gpa, io, landed)) {`), so a proposal cannot
restore the old shape and keep every needle matching.

## Verification

`zig build test`: "a failed branch resync leaves the pinned merge base where it
was" in `src/improve/worktree.zig`. The fault is a worktree path that does not
exist, so `git -C <path> reset --hard` exits non-zero -- the same failure
`createOn`'s own comment records observing live ("`git -C
'.clanker-worktrees/<id>'` failing with No such file or directory ... silently
skipping the post-merge resync"). A plain directory does NOT work as the
injection: a directory inside the repository still resets it, because git
discovers the repo from the parent. The control half asserts the pin DOES
advance when the reset lands, or the test would pass on a pin that never moves.

## Follow-up

`resyncBaseCheckout` was reviewed as this asked. It keeps its
warn-and-continue shape deliberately and is not the same defect: nothing
downstream asserts that it succeeded, and its refusal path (a checkout with
local changes) is the behaviour that report
2026-08-19-improve-self-merge-leaves-worktree-reverted asked for. There is no
pin to advance past it.

## References

- Code: `src/improve/worktree.zig` (`mergeBack`, `advanceCreatedFrom`,
  `resyncLocalBranch`, `resyncBaseCheckout`, `mergeTree`)
- Related: `docs/reports/bugs/2026-08-19-improve-self-merge-leaves-worktree-reverted.md`
