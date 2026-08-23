# Bug — clanker commit --all silently omits every new file

## TL;DR

- **What failed:** `clanker commit --all` builds its file list from `git diff --name-only` (worktree vs index), which lists no new file: an untracked one is not in the diff at all, and a `git add`ed one is identical in index and worktree. The plan never mentions it, the commit does not contain it, and the command reports success. Observed on b59814fe's branch: a new runbook was left behind by two `--all` runs and needed a separate `git commit`.
- **Impact:** Silent loss from the commit, not from the tree. The file stays in the working tree, so nothing is destroyed, but the branch and any PR built from it are missing it and the command exits 0. The `staged` scope is unaffected.
- **Resolution:** Resolved on 2026-08-23. Fixed by 5a6adecc: scope all unions worktree diff, staged diff, and untracked ls-files, plus a post-write git status --porcelain -uall check that every planned path reached a commit. Verified by the e2e test 'clanker commit --all includes new files, tracked or not' and a live dry-run on e41987de showing an untracked file in the plan.

## Status

Resolved on 2026-08-23. Fixed by 5a6adecc: scope all unions worktree diff, staged diff, and untracked ls-files, plus a post-write git status --porcelain -uall check that every planned path reached a commit. Verified by the e2e test 'clanker commit --all includes new files, tracked or not' and a live dry-run on e41987de showing an untracked file in the plan.

## Symptom and impact

`clanker commit --all` reports success and writes commits that contain none of
the files being added. Nothing warns, and the exit code is 0. The file is still
in the working tree, so this is a loss from the commit rather than from the
tree, and it stays invisible until someone notices the branch is short a file.

Observed while landing the doctor worktree-links change: a newly created
runbook survived two `clanker commit --all` runs and had to be committed
separately with `clanker git commit`.

The `staged` scope does not have this defect.

## Reproduction

The mechanism is a plain `git` fact and needs no model call to show. In a
scratch repository with one tracked file modified, one untracked file, and one
new file added to the index:

```
git diff --name-only
tracked.txt

git diff --name-only --staged
staged-new.txt
```

The first command is what `scope: "all"` runs. It lists neither new file:
`untracked.txt` is not in the diff at all, and `staged-new.txt` is byte
identical in index and worktree, so worktree-vs-index has nothing to report.

## Root cause

`tools/zig/smart_commit.zig:32`. The guest picks the file list by scope:

```
const names = (if (std.mem.eql(u8, scope, "all"))
    gitOut(&.{ "diff", "--name-only" })
else
    gitOut(&.{ "diff", "--name-only", "--staged" })) catch
```

`git diff --name-only` is worktree against index, which by definition reports
only files git already tracks and whose content differs between the two. The
`--staged` form is index against HEAD, and an added file does differ from HEAD,
which is why only the `all` scope is affected.

Everything downstream is consistent with an empty list: the grouping model is
asked to group the files it was given, the plan shown for confirmation lists
those files, and the write commits those files. Nothing anywhere compares the
plan against what git would consider committable, so there is no place the
omission could be noticed.

## Resolution

Open. The `all` scope needs a file list that includes new files. The narrow fix
is to union `git diff --name-only` with `git ls-files --others --exclude-standard`
(untracked, honouring `.gitignore`) and `git diff --name-only --staged`
(already added). The wider question is whether `--all` should mean
`git add -A` semantics outright, which is what its help text implies to an
operator; that is a behaviour decision and is not settled here.

Either way the guest must not report success on a plan that silently drops
files, so a check that every intended path reached a commit belongs with the
fix.

## Verification

Not fixed, so nothing to verify yet. What is checked, and how:

- The scope-to-git-command mapping was read at `tools/zig/smart_commit.zig:32`,
  not inferred from behaviour.
- The git behaviour was reproduced directly in a scratch repository, shown
  above; it does not depend on clanker at all.
- That the `staged` scope is unaffected follows from the same reproduction:
  `--staged` lists `staged-new.txt`.
- The live occurrence (a runbook left behind by two `--all` runs) was observed
  on this branch while landing the doctor change.

## Follow-up

## References

- Investigation: none. The mechanism was clear from the source, so no tracing record was needed.
- `tools/zig/smart_commit.zig` — the guest that owns the scope-to-git-command choice.
- PRD 0021 (docs/prds/0021-smart-commit.md) — what `clanker commit` is meant to be.
## Resolution verification (2026-08-23)

Fixed on main by 5a6adecc ("fix: stop commit --all from silently dropping new files"). Scope "all" now unions `git diff --name-only`, `git diff --name-only --staged`, and `git ls-files --others --exclude-standard` in tools/zig/smart_commit.zig, and after writing it verifies with `git status --porcelain -uall` that every planned path reached a commit, failing loudly when one did not — both halves the Resolution section above asked for. Pinned by the e2e test "clanker commit --all includes new files, tracked or not" (tests/e2e/commit_apply_test.zig). Verified live on e41987de: with one untracked file in a fresh worktree, `clanker commit --all --dry-run` produced a plan naming that file (live DeepSeek grouping call); the pre-fix listing could not see it at all.