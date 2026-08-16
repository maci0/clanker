# Bug — improve-self worktrees are never reclaimed when a run promotes nothing

## TL;DR

- **What failed:** Worktree.merged is set only by mergeBack, whose sole caller is the promotion block in engine.zig, so a run that promotes nothing never attempts a merge and cleanup keeps the worktree and branch 'for manual recovery' even when the branch is byte-identical to the base. Commits made inside the worktree outside the promotion path strand for the same reason. 51 worktrees accumulated over four days; 38 had an empty branch and 13 held stranded commits, all of which had been landed on main by hand.
- **Impact:** 51 leftover worktrees and 93 branches in four days, each a full source tree plus its own .zig-cache; janitor cannot reclaim any of them.
- **Resolution:** Resolved. cleanup asks git whether the branch holds commits the base lacks; Engine.run folds stranded commits back when the final gate is fully green.

## Status

Resolved on 2026-08-16. cleanup asks git for stranded commits instead of reading the promotion-only merged flag; Engine.run merges unpromoted commits back behind a green gate. Covered by a new hasStrandedCommits unit test against a real repository.

## Symptom and impact

Every improve-self run that promotes nothing leaves its worktree and branch
behind, logging:

```
improve-self: worktree <path> was not merged; keeping it and branch <branch> for manual recovery
```

Nothing reclaims them afterwards. `clanker janitor` counts them but never
deletes them: they are "unrecognised in .clanker-worktrees/", which it leaves
alone because a live improve-self run may be using one. A checkout driven by
a repair loop accumulated 51 worktrees and 93 `clanker/*` branches in four
days, each worktree carrying a full source tree and its own `.zig-cache`.

## Reproduction

1. Run `clanker improve-self` on a task where no proposal passes the gate,
   or where the request budget is exhausted first. The log ends with
   `no changes were promoted`.
2. `git worktree list` still shows `.clanker-worktrees/<id>`.
3. `git rev-list --count main..clanker/improve-self-<id>` reports 0 — the
   branch is byte-identical to the base it was cut from.

## Root cause

`Worktree.merged` is written in exactly one function, `mergeBack`, and
`mergeBack` has exactly one caller: the promotion block in
`src/improve/engine.zig`, guarded by `agent.git_commit`. So `merged`
answers "did a promotion land?" while `cleanup` reads it as "is there
anything here to lose?". Those come apart in both directions:

- A run that promotes nothing never commits either, because the commit is
  made inside that same promotion block. The branch equals its base, and
  `cleanup` keeps it anyway. 38 of the 51 leftovers were this.
- An agent that commits inside the worktree outside the promotion path — its
  own git tool, or a repair step driving the loop — strands real work that
  `merged` knows nothing about. 13 of the 51 were this, and every one had
  since been re-landed on the base branch by hand.

`mergeBack` had a matching latent bug: its `already even` early return left
`merged` false, so even an unconditional end-of-run merge attempt could not
have reclaimed an empty worktree.

## Resolution

Three changes, in `src/improve/worktree.zig` and `src/improve/engine.zig`:

1. `Worktree.hasStrandedCommits` asks git (`rev-list --count base..branch`,
   pinned with `-C` to the worktree) instead of inferring from `merged`. It
   fails safe: an unreadable repository answers "stranded", because keeping a
   worktree costs disk and deleting one can cost work.
2. `cleanup` keeps a worktree only when it is both unmerged and actually
   holds commits the base lacks. The branch delete stays `-d`, so a commit
   racing in between the check and the delete is still refused.
3. The end of `Engine.run` folds stranded commits back, conditioned on a
   fully passing final gate — the same bar promotion clears — and on
   `agent.git_commit`. A failing tree keeps its worktree, which is what
   "manual recovery" was always supposed to mean. This matters: two of the
   stranded branches were titled `broken`, and merging those unconditionally
   would publish a broken base branch.

## Verification

- New unit test in `src/improve/worktree.zig`, driving `hasStrandedCommits`
  against a real git repository through all three states: a freshly cut
  branch (not stranded), a branch one commit ahead (stranded), and the same
  branch after the base is moved onto it (not stranded).
- `zig build test`: 1423/1429 passing. The one failure,
  `cli.test.built-in command help stays within 80 columns`, is unrelated
  in-flight `adr`/`prd` CLI work from a concurrent session and is not
  touched by this change.

## Follow-up

- `clanker janitor` still refuses to reclaim anything under
  `.clanker-worktrees/` it cannot tie to a retired goal. This fix stops new
  ones accumulating; it does not give janitor a way to clear a backlog that
  predates it.
- `state/worktrees.json` only ever registered a subset of live worktrees
  (10 rows against 51 directories), so it cannot be used as the inventory.

## References

- Runbook: [Leftover improve-self worktrees pile up under .clanker-worktrees/](../../runbooks/improve-worktree-backlog.md)
