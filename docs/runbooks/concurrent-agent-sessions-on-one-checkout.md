# Runbook — Several agent sessions share one checkout

## TL;DR

- **Use when:** More than one agent session has the same working tree open, and either you are about to commit, or the tree is already tangled — files you did not write showing as modified, your own edits gone, a rebase refusing a conflict that no longer exists.
- **Recover by:** Committing from a throwaway worktree instead of the shared index, and — when the tree is already tangled — agreeing one owner for the git operation while every other session holds all `.git`-writing commands.
- **Verify with:** `git push` lands as a fast-forward, every pre-existing commit hash is still in the log, and each session confirms its own files by name.

## Scope and preconditions

Applies to any checkout with more than one agent session live in it. It is
about the shared working tree and index, not about the mesh: two `clanker
serve` processes with separate `state/` directories are not this problem.

You need to be able to message the other sessions. If you cannot, you cannot
do this safely — stop and hand the tree back to the operator.

## Diagnose

Before staging anything, find out whether the path is yours.

Read the board:

```bash
cat .local/TODO.md
```

A `[-]` line names an owner and a session id. A path covered by someone
else claim is not yours to stage, even by explicit path.

Check whether a file is being written right now:

```bash
git status --porcelain
ls -la --time-style=+%H:%M:%S <path>
date +%H:%M:%S
```

An mtime seconds old means a session is mid-edit. Committing it captures a
half-written file.

Check whether a git operation is already in progress before starting your own:

```bash
git status -sb
ls .git | grep -E "MERGE_HEAD|rebase|CHERRY_PICK_HEAD"
```

An `interactive rebase in progress` line, or a `rebase-merge` directory,
means someone else owns the index. Do not touch it.

## Recover

**Committing while others are live — the default.** Do not stage in the
shared index at all. Cherry-pick onto a fresh worktree and push from there,
which leaves everyone unstaged work untouched:

```bash
git worktree add --detach /tmp/push-$USER origin/main
git -C /tmp/push-$USER cherry-pick <sha>
git -C /tmp/push-$USER push origin HEAD:main
git worktree remove /tmp/push-$USER
```

Rebasing in the shared checkout is impossible with unstaged changes present,
and stashing is what loses other sessions work. Neither is the answer.

**A shared inventory file with several sessions hunks in it** — stage only
your own hunk and leave the rest for its owner. `git add -p` cannot do this
from an agent session: it is interactive, and this harness refuses
interactive git flags outright. Two non-interactive routes cover it.

When your change is one or more whole hunks, dump the diff, cut it down to
your hunks, and apply that to the index alone:

```bash
git diff docs/reports/README.md > /tmp/mine.patch
```

```bash
git apply --cached /tmp/mine.patch
```

When your change is a single line inside a hunk another session also
touched, no patch can separate the two. Rebuild the file from HEAD carrying
only your edit, then write that blob straight into the index:

```bash
git show HEAD:docs/reports/README.md > /tmp/mine.md
```

```bash
git update-index --cacheinfo 100644,$(git hash-object -w /tmp/mine.md),docs/reports/README.md
```

Either way the working tree keeps every session changes untouched; only the
index is narrowed to yours. Verify before committing:

```bash
git diff --cached docs/reports/README.md
```

**The tree is already tangled.** Message every session and ask three
questions: do you own the in-progress git operation, will you hold every
`.git`-writing command until I say done, and do you have edits not yet
written to disk. Wait for all of them to answer. Then:

1. Agree exactly one owner for the integration. Everyone else holds.
2. If a rebase is stuck — `git rebase --continue` refusing with "You must
   edit all merge conflicts" while `git ls-files -u` is empty and no conflict
   markers exist — abort it and merge instead. Another session is rewriting
   the index between your two reads. A merge is one atomic step and does not
   rewrite history, so no other session hashes move.
3. Never `git stash` a tree holding other sessions work, and never drop a
   stash you did not create. If one already exists, treat it as the only copy
   until each owner confirms otherwise.
4. Recover a file that vanished from under a session by asking git first —
   `git show <sha>:<path>` — then the session own out-of-repo backup. A file
   deleted while the session believed it untracked, when it had in fact just
   been committed by someone else, is only in git if it was committed.

## Recovering work that was swept into someone else's commit or stash

Symptom: a file you were editing is gone, or an `Edit` returns *File does not
exist* for a path you wrote minutes ago.

**First, copy anything you can still see to a path outside the working tree.**

```bash
mkdir -p /tmp/rescue-$USER && cp --parents <your files> /tmp/rescue-$USER/
```

Do this before any other step, and before deleting anything to unblock a
rebase. Your view of the index can predate another session's commit, so a file
that `git status` shows as untracked may already be tracked — and a file it
shows as tracked may hold *their* version rather than yours. Neither state is
evidence about what git actually holds for your content.

**Then find which half survived where.** A `git stash` taken without `-u`
keeps your tracked edits and drops your untracked files on the floor; a sweep
commit does the opposite. Check both:

```bash
git stash list
```

```bash
git stash show --include-untracked --name-only stash@{0}
```

**Before restoring from a stash, prove it only adds.** Diff the stash against
HEAD for exactly the files you intend to take back:

```bash
git diff HEAD stash@{0} --stat -- <your files>
```

A report of insertions and **zero deletions** means the stash differs from HEAD
only by your additions: no other session has competing changes in those files,
and restoring them wholesale is safe. Any deletion count means someone else's
work is in there too — restore by hand, hunk by hunk, or you will revert them
silently while recovering yourself.

With that confirmed, write each file back individually rather than popping the
stash, which would restore every session's work at once:

```bash
git show stash@{0}:<path> > <path>
```

`git show` is read-only and touches no `.git` state, so this is safe to run
while another session holds a rebase or merge in progress.

## Verify

```bash
git push origin main
git status -sb
git log --oneline -12
```

The push should be a fast-forward, `git status -sb` should show `main` in
sync with `origin/main`, and every commit hash from before the operation
should still be in the log — if a hash moved, history was rewritten and the
other sessions references are stale.

Then confirm ownership rather than assuming it: ask each session to name its
own files and say whether they are present. "Nothing was lost" is only true
when each owner has said so about their own work.

## Escalate or follow up

Tell every session when the hold is lifted. A session that is still holding
is a session doing nothing.

If a file cannot be recovered from git or a backup, say so to the operator
immediately and name the path. Do not reconstruct it from memory and present
it as the original.

## References

- Report: [Five agent sessions on one checkout committed and stashed each other work](../reports/bugs/2026-08-16-concurrent-sessions-commit-each-others-work.md)
- `.agents/agent-rules/maci0-clanker.md` — the explicit-path staging rule this
  runbook extends.
- `.agents/agent-rules/todo.md` — the board, its claim markers and session ids.
