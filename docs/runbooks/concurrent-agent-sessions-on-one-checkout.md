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

A session is not the only thing that writes this tree. `clanker improve-self`
commits its promotions straight onto `main` and keeps a candidate staged while
it gates, so unexplained `imp-` commits and a staged file that undoes them are
usually one live loop mid-iteration, not a decision anyone made. Read the lock
for the holder:

```bash
cat state/improve.lock
```

```bash
ps -p "$(cat state/improve.lock)" -o pid,etime,cmd
```

Use the lock, not `pgrep`. The lock names the holder and is still true when you
read it; `pgrep -af improve-self` is a snapshot that also matches the shell
running the guard, and on 2026-08-16 it produced a process id that did not
exist and an instruction that was not the one running — twice, in two
different sessions, each time cited as evidence for a conclusion about who
owned the tree.

**Do not wait for the holder to exit.** `--iters` bounds one `improve-self`
invocation, but `scripts/imp-autorecover-loop/loop.py` respawns it, so on a
machine running that loop the tree never goes quiet and "wait for a still
tree" waits forever. Three sessions lost an hour to that advice on
2026-08-16. Work around the loop instead of against it: pushing and creating
branches only read refs and objects, so they are safe at any moment, and the
loop's own promotions are already gated before it commits them.

What the loop owns is the **working tree and index**, so treat its staged
candidate as transient rather than as anyone's decision. Preserve before you
discard — this writes a commit object and modifies neither tree nor index:

```bash
git stash create
```

```bash
git branch preserve/<what>-<date> <sha-from-stash-create>
```

Then push that branch. A dangling commit no ref points at is one `git gc`
from being unrecoverable, which is the failure this avoids.

"Everything is pushed" is an instant on such a machine, never a state: the
loop commits every few minutes, so a sweep is true when it runs and stale
by the next one. Report it with its timestamp and the tip you verified
against, not as a standing claim.

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

**`git commit --amend` commits the whole index, including everything another
session staged.** It reads as "edit my last commit" and behaves as "commit
with no pathspec", so amending in the shared checkout while a peer holds
staged work silently folds their slice into your commit under your message —
observed 2026-08-17, 8 files and 207 insertions belonging to another session
swallowed by a two-file documentation amend. The pathspec form is not an
escape either: `--amend -- <paths>` still carries whatever the index already
had. Amend only in a throwaway worktree, or not at all. If the commit is
already pushed, amending needs a force-push on top, which is a second reason
not to.

Recovering from it, before pushing: `git reset --soft <your-commit>` puts
HEAD back and leaves everything staged, then `git restore --staged <your
paths>` hands the index back to its owner with their entries exactly as they
were. Re-commit yours with the pathspec form, which takes the worktree copy
and never consults the index. Then tell the owner to verify against their own
expectation rather than your account of it.

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

`clanker commit` honors that narrowed index: in its default `staged` scope it
builds each group's commit from the staged content, so the other sessions'
lines stay unstaged in the working tree. Before that fix it ran `git add` and
committed by pathspec, and both take the working-tree copy, so it would have
committed the whole file. By hand, commit the index itself with a bare
`clanker git commit -m "…"` — a pathspec `git commit -- <path>` takes the
working-tree copy too.

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

Two mechanisms produce this, and they take different halves of your work:

- **A concurrent rebase.** `git rebase` needs a clean tree, so a session
  starting one clears what you had uncommitted. On 2026-08-17 a rebase in this
  checkout discarded four tracked-file edits while leaving the new *untracked*
  files (a test and a record) in place — which reads as "most of my work is
  still here" and hides the loss. `git status` naming a rebase in progress
  (`interactive rebase in progress; onto <sha>`) is the tell.
- **A concurrent `clanker commit` before fcf193a5.** Its apply path staged its
  own group and then ran a bare `git commit`, which commits the *whole* index,
  so anything you had staged went into their commit. That is fixed — each
  group is committed with a pathspec now — but any release before it behaves
  the old way, and the symptom is a commit of yours that lands with fewer
  files than you staged. Look for your content with
  `git log -S '<a string you wrote>' -- <path>`: it is usually in their commit
  rather than lost.

Write down what you changed as you go, or keep an idempotent restore script
outside the tree. Reconstructing four edits from a transcript is quick; a
second sweep while you reconstruct is not, and a script makes the retry free.

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

**"My work is pushed" is not "nothing is disk-only."** On 2026-08-16 three
sessions each verified their own state as clean, each truthfully, while
eleven branches of Aug 11–14 work, a stash, and a dangling commit sat on the
disk — every one of us had answered "is *my* work pushed" rather than "is
this repository's work safe". Ask the second question with one command:

```bash
git log --branches --tags --not --remotes --oneline
```

```bash
git stash list
```

Empty output from the first means no commit on any branch or tag is missing
upstream — and unlike a per-branch loop it also catches loose and dangling
commits that no ref points at. A stash is a separate store again: it is a
commit, but no branch points at it, so a branch enumeration misses it
entirely. Preserve either with the `git stash create` recipe above rather
than pushing the stash in place.

Distinguish **missing ref** from **lost work** before acting on the count.
A branch absent from origin whose commits are all upstream by content is a
stale pointer, not a risk; pushing it adds a ref and no bytes. Compare by
patch id or `git rev-list --count origin/main..<branch>`, not by name.

**Check the branch still exists on the remote before analysing it.** A clone
accumulates remote-tracking refs for branches the remote deleted after merging
their PRs — this one had 124 tracking refs against 27 real ones. Those refs
look like unmerged work and are not:

```bash
git ls-remote --heads origin <name>
```

They read as unmerged because a **squash merge rewrites the commit**, so its
patch id no longer matches anything on `main` even though every line landed.
Confirm by finding the squash commit's subject on `main`, not by patch id.
This is the same failure as grepping for code across an API rename: a
mechanical identity check reports **absent** for content that is present in a
different form, and "absent" is the answer that makes you re-land work that
already exists. On 2026-08-16 it turned twelve real branches into a
thirty-one-branch panic.

### Closing out a branch whose content already landed

A branch that is superseded, obsolete, or salvaged still shows as unmerged
forever, and the next sweep re-investigates it. Close it instead of leaving
the signal:

```bash
git merge -s ours -m "merge: close out <branch>" origin/<branch>
```

`-s ours` records the merge while keeping **the current tree byte for byte** —
verify with `git rev-parse <merge>^{tree}` against `<merge>^1^{tree}`, which
must be equal. So it cannot revert anything, and the branch's snapshot stays
permanently reachable as the merge's second parent (`git show <merge>^2`),
surviving `gc` and the deletion of the branch ref — which a bare unmerged
branch does not. Once merged, the remote ref can be deleted without losing
the content.

Only do this when the content is genuinely accounted for, per-commit and not
per-branch: a feature landing does not prove every commit riding along was
part of it. And unique content is necessary but not sufficient — a commit
whose own message says `wip` or `build error` should not be cherry-picked
on uniqueness alone.

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
## A green gate does not survive a rebase

`clanker gate` certifies the tree it ran on. The push flow under concurrency
is usually gate → commit → `pull --rebase` → push, and the rebase splices in
commits the gate never saw — so a passing gate before the rebase says nothing
about what gets pushed after it. This happened on 2026-08-17: 2ff411c9 was
gated green, rebased onto 6cddda0e (which did not compile), and pushed;
origin/main stayed broken until 395f912d.

After any `pull --rebase` that actually pulled commits, re-verify before
pushing — `zig build` at minimum, the full gate when the pulled commits touch
what yours do:

```bash
clanker git pull --rebase --autostash origin main
```

```bash
zig build
```

```bash
clanker git push origin main
```
## An interrupted `pull --rebase --autostash` leaves a stash behind

`--autostash` stashes the dirty tree, rebases, and pops it back. If the rebase
does not reach `rebase (finish)` — interrupted, aborted, or retried — the pop
never happens and the stash is orphaned. Nothing reports this: the retry
succeeds, the tree looks right, and the stash sits in a store that
`git log --branches --tags --not --remotes` does not cover.

Seen on 2026-08-17 in this checkout. The reflog is what shows it:

```bash
git reflog --date=format:"%H:%M:%S"
```

```
07:57:12  commit f88b3fe9
07:57:19  pull --rebase --autostash (start)   <- stash created
07:58:56  commit 31a98a6f  same subject       <- first rebase never finished
08:02:14  pull --rebase --autostash (start)   <- second attempt
08:02:49  rebase (finish) -> 82033d43
```

A `(start)` with no matching `rebase (finish)` before the next `(start)` is the
tell. The orphan also shows as a stash whose base commit is not an ancestor of
`origin/main` while that commit's *subject* is — the rebase replayed it under a
new sha:

```bash
git merge-base --is-ancestor "stash@{0}^" origin/main
```

**Do not pop it.** The word "autostash" reads as transient housekeeping, which
is exactly what invites a `stash pop`, and its base is old by then:
`git diff HEAD stash@{0}` here was 142 files, 1284 insertions and **8804
deletions**. Popping would have reverted a large amount of landed work to
restore 8 files that were already present.

Whether its content still matters is a per-line question, not a per-file one.
Compare the stash against its own parent — not against HEAD, which mixes in
every commit since — and check each added line against the current file:

```bash
git diff "stash@{0}^" "stash@{0}" -- <path>
```

Here 118 of 124 added lines were already present verbatim, and the 6 that were
not were a single comment block superseded by a later rewrite; the work had been
redone and committed as `d44669f9` and `fcf193a5`. Two checks that look
authoritative and are not: `git apply --reverse --check` fails on context drift
alone, and a matching commit *subject* is not evidence the patch landed — use
`git cherry origin/main <branch>` for commits.

Dropping is the right disposal once the content is accounted for, but record the
sha first. A dropped stash stays in the object database for the gc grace window
and `git show <sha>` still reads it, so the sha in a note is enough; a recovery
tag is worse, because it comes back as a ref that reads as unpushed work.

```bash
git rev-parse "stash@{0}"
```

```bash
git stash drop "stash@{0}"
```

Ownership first, always. A stash carries the checkout's git identity, not the
session's, so every agent's stash is authored by the same person and the
metadata cannot say whose it is. Creation time against session start times is
what rules sessions out. Ask the live sessions and get the operator's decision
before dropping one you did not create.

## Enforcement since 2026-08-19: the clanker commit lock

The writing form of `clanker commit` now takes a non-blocking exclusive
flock on `state/commit.lock` for the whole plan-confirm-write window (the
same kernel-held lock `clanker schedule run-due` uses, so it is released
whenever the holder dies and is never stale). A second `clanker commit` on
the same checkout is refused with the lock named:

```
refusing to commit: another clanker commit in this checkout holds state/commit.lock; let it finish and rerun
```

That refusal is the mechanism working — wait for the other session's commit
to finish and rerun; never delete the lock file. This covers only the
clanker-mediated commit path. Sessions writing with raw `git` are outside
it, and everything else in this runbook still applies to them.