# Bug — Five agent sessions on one checkout committed and stashed each other's work

## TL;DR

- **What failed:** Five Claude sessions shared one checkout with no lock on the working tree. Explicit-path staging was not enough, because the paths themselves belonged to other sessions: one commit swept up another session's unfinished guests, a stash briefly held three sessions' work at once, and an aborted rebase left the tree holding upstream content. Nothing was lost, but only because each session still had its edits on disk or in a backup.
- **Impact:** No work was lost, and the ten commits on origin/main are correct. The cost was three sessions blocked for roughly twenty minutes, one deleted file that had to be recovered from an out-of-repo backup, a partly-completed feature published in a state its own README advertises but the binary does not implement, and an integration that took an aborted rebase plus a merge to land.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

Five Claude sessions were live on `/home/yannick/code/maci0/clanker` at the
same time, each editing files in the shared working tree. Four distinct
failures followed within about half an hour.

**A commit swept up unfinished work.** Commit `f7995c6b` staged the `adr` and
`prd` guests, their manifests, `doc_scaffold` helpers, both TEMPLATEs and
`docs/adrs/README.md` by explicit path, from a tree where another session was
still writing that feature. Explicit-path staging was followed; it was not
enough, because the paths belonged to someone else.

**A session was left editing files it no longer owned.** The owning session
kept working from an index view that predated `f7995c6b`, so `tools/zig/adr.zig`
looked untracked to it. It deleted its own newer copy to clear the path for a
rebase. That copy existed nowhere in git.

**A published document describes a command that does not exist.**
`docs/adrs/README.md` opens with a `clanker adr` quick start. The CLI wiring
was uncommitted in the other session, so the pushed README documents a verb
that answers `error: unknown command adr`.

**The integration needed two attempts.** A rebase onto `origin/main` stopped on
a conflict in `tools/zig/model_stats_logic.zig`. `git rebase --continue` then
refused with "You must edit all merge conflicts" while `git ls-files -u`
reported no unmerged entries and no conflict markers existed anywhere in the
tree — the index was being written by another session between the check and the
continue. The rebase was aborted and replaced with a plain merge, which
succeeded. At one point a single `claude-session-wip` stash held three
sessions changes at once.

## Reproduction

Any two agent sessions working the same checkout without a shared claim will
reproduce this; nothing here is timing-exotic. The minimal shape:

```bash
git add <path-you-did-not-write>
git commit -m "..."
```

The other session then sees its own file as untracked or unexpectedly
modified, because its index view predates the commit.

## Root cause

A git working tree and index are process-global shared state, and nothing in
the harness arbitrates them. Five agents each held a private, stale model of a
tree all five could write.

The repository rule that was supposed to prevent this —
`.agents/agent-rules/maci0-clanker.md`, "preserve unrelated uncommitted work
through explicit-path staging" — is necessary but not sufficient. It rules out
`git add -A`. It says nothing about how to tell whose work a path is, which is
the question that actually matters when several sessions are live. Staging
`tools/zig/adr.zig` by name is explicit-path staging and still wrong if
someone else is mid-edit in it.

`.local/TODO.md` is the checkout coordination board and does answer that
question: two of the three affected work items were claimed on it with an
owner and a session id, including the ADR/PRD line. It was not read before
staging. A board only prevents collisions if it is consulted at the moment of
the write, not only when picking up a task.

The secondary failures follow from the same cause. An index view goes stale
the moment another process commits; `git ls-files -u` and `git
rebase --continue` are two separate reads of an index a third party is
rewriting between them, so a rebase can refuse a conflict that no longer
exists.

## Resolution

Recovered by coordinating explicitly between the sessions rather than by any
change to the repository. The procedure is written up as a runbook:
[Several agent sessions share one checkout](../../runbooks/concurrent-agent-sessions-on-one-checkout.md).

In short: every session was messaged and asked three questions — do you own
the in-progress git operation, will you hold all `.git`-writing commands, and
do you have unwritten edits. All five answered. One owner was agreed for the
integration; the other four held. The owner aborted the rebase, merged, and
the result was pushed as `4c170a41`. Each session then re-applied its own
files from the working tree, a stash, or an out-of-repo backup, and every
piece of work was accounted for.

## Verification

- `git push` landed `30691bb5..4c170a41` as a fast-forward; local `main`
  reports in sync with `origin/main`.
- Every commit hash from before the failed rebase is still in the log:
  aborting rather than forcing meant no history was rewritten.
- Each affected session confirmed its own work present, by name: the improve
  worktree changes live in the tree, the ADR/PRD CLI wiring untouched, the
  research-note correction on origin.
- Not verified: no test run stands behind the push. `zig build test` and
  `clanker gate` were deliberately not run — the operator asked that nothing
  start a long test while sessions were racing, and the tree still carries the
  uncommitted ADR/PRD wiring, which is known to fail two tests.

## Follow-up

- The `docs/adrs/README.md` mismatch closed itself: the CLI wiring landed as
  `8b885c8c`, so `clanker adr` and `clanker prd` now exist. The README was
  wrong on origin for roughly an hour.
- The research Google fallback still has no CHANGELOG entry, though it is on
  origin.
- One test was still failing at the time of writing —
  `cli.test.built-in command help stays within 80 columns`, from the adr/prd
  help table — reported from a run that predates `8b885c8c`.
- Worth deciding, and not decided here: whether an agent should take a lock
  before writing the index at all. `clanker schedule run-due` already uses a
  non-blocking exclusive flock for exactly this reason, so the harness has the
  mechanism; the commit path does not use it. A `.git/index.lock`-style claim
  around staging, or a `clanker` verb that refuses to commit paths another
  board entry claims, would turn a convention into an enforced rule.

## References

- Runbook: [Several agent sessions share one checkout](../../runbooks/concurrent-agent-sessions-on-one-checkout.md)
- `.agents/agent-rules/maci0-clanker.md` — the explicit-path staging rule.
- `.agents/agent-rules/todo.md` — the board that answers whose path it is.
- Commits: `f7995c6b` the sweep, `4c170a41` the merge that integrated it,
  `8b885c8c` the CLI wiring that closed the README mismatch.
- Investigation: none; the trace is in this record.
## The overwritten session's account

Filed by the session whose work was swept, to add the parts visible only from
that side.

**What the deletion looked like from inside.** The work was a feature in two
halves: WASM guests plus manifests, and the CLI verbs that call them. The
guests were written first and left on disk untracked while the CLI half was
being written — normal, since a helper whose only caller is a test is exactly
what `src/improve/inert_check.zig` classifies as inert, so both halves belong
in one commit. Between writing the guests and writing the CLI half, an
`Edit` to `tools/zig/adr.zig` returned *File does not exist*. That is the
first and only signal anything was wrong. The tool call did not fail because
of a permission or a path error; the file had simply stopped being there.

**Why the recovery was not obvious.** `git status` showed my remaining files
as untracked and my tracked edits as absent. `git stash list` showed a
`claude-session-wip` entry, and `git stash show --include-untracked` on it
listed my `doc_scaffold.zig`, `cli.zig` and `main.zig` — but not the guests,
because the stash had been taken without `-u` and the guests were untracked at
the time. So the tracked half of my work was recoverable from the stash and the
untracked half existed nowhere in git at all. It was recoverable only because
the sweeping commit had already captured it, which is the same commit that
caused the problem.

**The check that made the stash safe to take.** Before restoring anything I ran
`git diff HEAD stash@{0} --stat` on just the three files I wanted. It reported
426 insertions and **zero deletions**, which is what made it safe: the stash
differed from HEAD only by my additions, so no other session had competing
changes in those files and I could take them wholesale rather than merging by
hand. A non-zero deletion count would have meant the opposite, and restoring
wholesale would have silently reverted someone else's work. That diff is worth
making a required step in the runbook — it is the difference between recovering
and overwriting.

**One trap specific to this failure mode.** After the sweep, my in-memory view
of the index was stale, so a file that was by then *tracked* looked untracked
to me. I deleted my newer copy of `tools/zig/adr.zig` to unblock what I thought
was a rebase collision. Because the file was tracked, `git` held the swept
version — but not mine, which was newer by one change (a search filter
excluding `README.md` and `TEMPLATE.md` from grep hits). That change existed
in no commit and in no stash. It survived only because I had copied the file
outside the repository first. **Copy to a path outside the working tree before
deleting anything you cannot see in `git log`** — `git status` is not evidence
about a file when your index view predates another session's commit.

**Correction to the follow-up list.** The research Google Programmable Search
fallback *does* have a CHANGELOG entry, under `## [Unreleased]` → `### Added`,
beginning "Google as the research sweep's third web backend". That item can be
struck.

**Cross-session messaging worked.** The coordination that resolved this was
peer messages, not the repository: an explicit ownership split (which paths
belong to which session), an explicit hold on `.git`-writing commands while one
session finished a rebase, and an explicit release afterwards. Nothing in the
checkout communicates that, which is why the collision happened before the
messaging started rather than after.

## Pushing without stashing anyone: a temporary worktree

Recorded by a session that hit the "I need to push and the shared checkout is
dirty with three other sessions' work" case twice today and found a way through
that touches nobody else's files.

The trap: your commit is ready, `origin/main` has moved, and integrating means
`rebase` or `merge`. Both refuse or clobber when the working tree carries other
sessions' uncommitted work — `rebase` exits with "cannot rebase: You have
unstaged changes", and `merge` overwrites any dirty file its incoming commits
touch. The obvious unblock is `git stash`, and that is precisely the move this
report exists to warn against: it takes work that is not yours.

A temporary worktree has none of that surface, because it never touches the
shared working directory:

```bash
git worktree add -b push-tmp /tmp/pushwt <your-commit>
git -C /tmp/pushwt merge origin/main
git -C /tmp/pushwt push origin push-tmp:main
git worktree remove --force /tmp/pushwt
git branch -D push-tmp
```

Why each step matters. `worktree add` checks your commit out somewhere else, so
the dirty files in the shared checkout are never read or written. The merge
happens in that isolated tree, so a conflict — if any — is yours alone to
resolve and cannot leave half-merged content where another session will commit
it. `push push-tmp:main` publishes the result under the branch name the remote
expects without your local `main` ever moving. Removing the worktree and the
branch leaves no trace.

The property that makes this safe to repeat: your local `main` stays an
ancestor of what you pushed, so the shared checkout can fast-forward later
rather than facing a divergence someone has to merge.

Verified on 2026-08-16: pushed commit 115d4022 this way while
`src/cli.zig`, `src/main.zig`, `src/improve/*`, `tools/zig/adr.zig`,
`tools/zig/prd.zig` and `tools/zig/doc_scaffold.zig` were all dirty with two
other sessions' in-progress work. `git status --porcelain` was byte-identical
before and after.

Use this whenever the alternative is stashing someone else's work.
