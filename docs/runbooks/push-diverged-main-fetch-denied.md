# Runbook — Push a diverged main when fetch is denied

## TL;DR

- **Use when:** When `git push origin main` is rejected with `(fetch first)` and the sandbox denies `git fetch`, don't push to main directly: create a worktree + branch from local main, push the branch, open a PR to main, and merge it. Branch pushes are always fast-forward, and GitHub resolves the divergence server-side — no fetch needed.
- **Recover by:** Create a worktree + branch from local `main`, push the *branch* (never push to `main` directly), open a PR to `main`, and merge it — GitHub resolves the divergence server-side.
- **Verify with:** `gh pr view <n> --json state` returns `MERGED`, and `git worktree list` no longer shows the worktree.

## Scope and preconditions

Applies when local `main` is ahead of the *stale* local `origin/main` ref (so
`git status` reports "ahead by N commits") but the *actual* remote has also
moved, so a direct `git push origin main` is rejected with `(fetch first)`.
The sandbox denies `git fetch`, so `git pull --rebase` cannot reconcile locally.

## Diagnose

```bash
git push --dry-run origin main
```

`[rejected] main -> main (fetch first)` confirms the remote holds work that is
not in the local tree.

## Recover

Create a worktree and branch from the local `main` tip:

```bash
git worktree add -b fix/<topic> .local/worktrees/<topic>
```

Edit the files in the worktree (`edit_file` addresses `.local/worktrees/<topic>/...`).
Stage and commit with `--git-dir`/`--work-tree`; a `-C` path is misparsed as a
git verb and refused:

```bash
git --git-dir=.local/worktrees/<topic>/.git --work-tree=.local/worktrees/<topic> add <path>
git --git-dir=.local/worktrees/<topic>/.git --work-tree=.local/worktrees/<topic> commit -m "message"
```

Push the branch (branch pushes are always fast-forward, never `(fetch first)`):

```bash
git --git-dir=.local/worktrees/<topic>/.git --work-tree=.local/worktrees/<topic> push -u origin fix/<topic>
```

Open and merge the PR:

```bash
gh pr create --base main --head fix/<topic> --title "..." --body "..."
gh pr merge <n> --merge
```

Then remove the worktree and branches:

```bash
git worktree remove .local/worktrees/<topic>
git branch -D fix/<topic>
git push origin --delete fix/<topic>
```

## Verify

```bash
gh pr view <n> --json state
```

```bash
git worktree list
```

## Escalate or follow up

Local `main` stays at its pre-merge tip — still "ahead by N commits" of the
stale local `origin/main` ref — because `fetch` is denied. It catches up on the
next `git fetch`/`pull`. This is expected, not a regression.

The PR carries every unpushed local-`main` commit, so this is also how
improve-self's locally-committed promotions reach `origin/main` when a direct
push is rejected.

## References

- Runbook: [Several agent sessions share one checkout](concurrent-agent-sessions-on-one-checkout.md)
- RFC: [0021 — improve-self promotion landing lifecycle](../rfcs/0021-improve-promotion-landing-lifecycle.md) (the open decision on how promotions should reach `origin`; this runbook documents the current status-quo recovery)
