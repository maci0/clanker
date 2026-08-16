# Bug — improve-self worktrees are never reclaimed when a run promotes nothing

## TL;DR

- **What failed:** Worktree.merged is set only by mergeBack, whose sole caller is the promotion block in engine.zig, so a run that promotes nothing never attempts a merge and cleanup keeps the worktree and branch 'for manual recovery' even when the branch is byte-identical to the base. Commits made inside the worktree outside the promotion path strand for the same reason. 51 worktrees accumulated over four days; 38 had an empty branch and 13 held stranded commits, all of which had been landed on main by hand.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
