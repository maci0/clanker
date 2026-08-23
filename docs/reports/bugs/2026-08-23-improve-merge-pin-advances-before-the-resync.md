# Bug — the merge-base pin advances before the branch resync it depends on, and the resync failure is only a warning

## TL;DR

- **What failed:** src/improve/worktree.zig calls advanceCreatedFrom(commit) and only then resyncLocalBranch, which swallows both a spawn error and a non-zero git exit into a warn log. created_from is the 3-way merge base for the next promotion, so if the reset does not land the pin claims the branch is at the landed commit while the ref is still at its pre-merge tip; the next merge-tree reads that as a deletion of everything the merge folded in, and CASes it onto the base branch.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

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

Open. `resyncLocalBranch` should report success (`!void` or `bool`), and
`advanceCreatedFrom` should run only after it reports success. Leaving the pin
where it was is the safe direction: the next `merge-tree` then recomputes from
the older base, which over-reports the branch delta rather than under-reporting
it.

## Verification

Needs a test that fails the reset and asserts `created_from` did not move.

## Follow-up

`resyncBaseCheckout` has the same warn-and-continue shape and wants the same
review.

## References

- Code: `src/improve/worktree.zig` (`mergeBack`, `advanceCreatedFrom`,
  `resyncLocalBranch`, `resyncBaseCheckout`, `mergeTree`)
- Related: `docs/reports/bugs/2026-08-19-improve-self-merge-leaves-worktree-reverted.md`

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
