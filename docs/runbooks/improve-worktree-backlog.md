# Runbook — Leftover improve-self worktrees pile up under .clanker-worktrees/

## TL;DR

- **Use when:** A checkout driven by a repeated improve-self loop accumulates worktrees and clanker/* branches that janitor will not reclaim. Sort them by whether the branch holds commits the base lacks: an empty branch is safe to delete outright, and a branch with commits needs its content checked against the base before the worktree goes.
- **Recover by:** Determine the current verified procedure.
- **Verify with:** The linked report's verification steps.

## Scope and preconditions

Applies to a checkout where improve-self has been run repeatedly, typically by
a driver loop. Needs a clean main working tree and no live improve-self run
you intend to keep — check first, because a running run's worktree must not be
touched:

```bash
pgrep -af improve-self
```

Since the fix in
[the merge-bound-to-promotion bug](../reports/bugs/2026-08-16-improve-worktree-merge-bound-to-promotion.md),
runs reclaim their own worktrees. This runbook is for a backlog that predates
that, or for one left by a run that ended on a red gate.

## Diagnose

`clanker janitor` reports the pile without deleting any of it. Worktrees it
calls "unrecognised in .clanker-worktrees/" are never removed automatically,
because a live improve-self run may be in one:

```bash
clanker janitor
```

The one question that sorts them is whether a branch holds commits its base
does not. Per worktree:

```bash
git rev-list --count main..clanker/improve-self-<id>
```

A count of 0 means the run promoted nothing and never committed: the branch is
byte-identical to main and the worktree holds no work. A non-zero count means
something committed inside the worktree without going through promotion, and
that content has to be checked before anything is deleted.

## Recover

Confirm a branch with commits is not already upstream in content. `git cherry`
marks a patch-identical commit with `-`; a `+` only means the patch-id
differs, which a different base or a renamed local variable is enough to cause,
so read the diff rather than trusting the sign:

```bash
git cherry -v main clanker/improve-self-<id>
```

Preserve anything genuinely unique before it goes. Uncommitted work needs both
halves — the tracked diff and the untracked files:

```bash
git -C .clanker-worktrees/<id> diff > .local/salvage/<id>.patch
git -C .clanker-worktrees/<id> status --porcelain
```

Remove a clean worktree:

```bash
git worktree remove .clanker-worktrees/<id>
```

Remove one whose dirt you have already salvaged or dismissed:

```bash
git worktree remove --force .clanker-worktrees/<id>
```

Then the branches. `-d` refuses anything not merged, so it is the safe sweep
to run first and it needs no per-branch judgement:

```bash
git branch --list 'clanker/*' --merged main | tr -d ' ' | xargs git branch -d
```

What survives that is the list to audit by hand with `git cherry`, deleting
with `-D` only what you have confirmed is upstream or worthless.

## Verify

```bash
git worktree list
```

```bash
clanker janitor
```

Only live runs should remain. Stale administrative entries clear with:

```bash
git worktree prune
```

## Escalate or follow up

A worktree kept after the fix means its run ended on a failing gate, so the
branch may hold commits that never passed one. Read the diff before landing
it; do not merge it just to clear the directory.

Deleting a worktree does not delete its branch, and deleting a branch does not
remove its worktree. Doing only one leaves `git worktree list` and
`git branch` disagreeing, which is what makes a backlog hard to read.

## References

- Report: [improve-self worktrees are never reclaimed when a run promotes nothing](../reports/bugs/2026-08-16-improve-worktree-merge-bound-to-promotion.md)
