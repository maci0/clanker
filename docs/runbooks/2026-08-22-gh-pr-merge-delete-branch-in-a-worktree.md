# Runbook — gh pr merge --delete-branch reports failure after the merge landed, when run from a worktree

## TL;DR

- **Use when:** Run from a git worktree, gh pr merge --delete-branch prints 'failed to run git: fatal: main is already used by worktree at <path>' and exits nonzero — but the PR is already merged on GitHub. The failure is the local post-merge checkout switch, not the merge. Check gh pr view <n> --json state before retrying anything.
- **Recover by:** Confirm the merge with `gh pr view <n> --json state,mergedAt`, then delete the remote branch and remove the worktree by hand. Do not re-run the merge.
- **Verify with:** `gh pr view <n> --json state` reads `MERGED`, and `git worktree list` no longer names the removed worktree.

## Scope and preconditions

The maci0/clanker workflow does every unit of work in its own worktree while
the main checkout stays on `main` (`.agents/agent-rules/maci0-clanker.md`).
`gh pr merge --delete-branch` was run with the shell inside that worktree.

## Diagnose

The command prints, and exits nonzero on:

```
failed to run git: fatal: 'main' is already used by worktree at '/home/yannick/code/maci0/clanker'
```

That is `gh`'s local cleanup, not the API call. After merging, `--delete-branch`
switches the current checkout off the merged branch and onto the base branch
before deleting it; git refuses because `main` is checked out in the *other*
worktree. The merge itself already happened server-side, so the nonzero exit
reads as "merge failed" when it is not.

Ask GitHub, not the exit code:

```bash
gh pr view <n> --json state,mergedAt
```

`{"state":"MERGED","mergedAt":"..."}` means the merge landed and only the
cleanup failed.

## Recover

Delete the remote branch from the main checkout:

```bash
git push origin --delete <branch>
```

Remove the worktree:

```bash
git worktree remove <path>
```

Do not re-run `gh pr merge`: on an already-merged PR it fails with a different
message and nothing to act on.

## Verify

```bash
gh pr view <n> --json state
```

```bash
git worktree list
```

The first reads `MERGED`; the second no longer names the removed worktree.

## Escalate or follow up

Avoid the cleanup entirely by merging without it and deleting the branch
yourself:

```bash
gh pr merge <n> --squash
```

Observed on PR #319 (2026-08-22, gh from a `clanker-wt-*` worktree): the merge
landed at 02:05:56Z and the same invocation exited nonzero.

## References

- Report: none yet
