# Bug — smart_commit's apply path re-adds whole worktree files, widening a hunk-narrowed index

## TL;DR

- **What failed:** With scope:staged and dry_run:false, smart_commit runs git add -- <files> per group before committing, staging the worktree version of each file. An index narrowed to one session's hunks (the concurrent-sessions runbook's route for shared inventory files) is silently widened with other sessions' unstaged edits. Staged scope should commit the staged content as-is.
- **Impact:** A shared checkout could commit another session's half-finished edits, and the operator confirmed a narrower preview.
- **Resolution:** Resolved on 2026-08-17. Scope staged builds each group commit in the index (git write-tree, per-group read-tree + restore --staged, bare commit, read-tree back), so a hunk-narrowed index commits as staged; verified by the new scope-staged case in tests/e2e/commit_apply_test.zig (19/19 e2e) and clanker gate.

## Status

Resolved on 2026-08-17. Scope staged builds each group commit in the index (git write-tree, per-group read-tree + restore --staged, bare commit, read-tree back), so a hunk-narrowed index commits as staged; verified by the new scope-staged case in tests/e2e/commit_apply_test.zig (19/19 e2e) and clanker gate.

## Symptom and impact

A `clanker commit` run on a shared checkout can commit another session's half-finished edits. The dry-run preview shows the staged diff, but the apply path stages more than it previewed, so what lands differs from what was confirmed.

## Reproduction

Observed 2026-08-17 while landing the resolveExecPath leak fix: docs/reports/README.md held two sessions' hunks, the index was narrowed to one session's hunk via `git apply --cached`, and the smart_commit apply path would have staged the whole worktree file (not run to completion — worked around by committing the narrowed index with `git commit` directly). Deterministic from the code: partially stage one hunk of a file that also has unstaged edits, run the tool with dry_run:false, and the commit contains the unstaged edits too.

## Root cause

`tool_main` in tools/zig/smart_commit.zig runs `gitRun(prepend("add", "--", g.files))` for each group before `git commit -m`. `git add <file>` stages the file's current worktree content, so in scope:staged it does not merely re-affirm the staged content — it replaces it with the worktree version. The grouping itself was computed from `git diff --staged`, so the committed content can diverge from the content the groups were derived from.

Removing the `git add` would not have been enough: `git commit -- <files>` is a
second, independent cause of the same widening. A pathspec commit takes the
*working-tree* copy of the named paths, which is what the previous fix in
`fcf193a5` switched to (for the unrelated reason that a bare `git commit`
commits the whole index). Checked directly, git 2.55.0, on a file with one
staged hunk and one unstaged hunk:

```bash
git commit -m "test: pathspec commit" -- a.txt
git show HEAD:a.txt
```

The committed blob held the unstaged hunk's line as well as the staged one.

## Resolution

Scope `staged` no longer stages or commits from the working tree. `git add` and
a pathspec `git commit` are both worktree-copy operations, so the fix is to
build each group's commit in the index:

1. `git write-tree` saves the whole staged state as a tree.
2. Per group: `git read-tree HEAD` (`--empty` when the repository has no
   commit yet), `git restore --source=<tree> --staged -- <files>`, then a bare
   `git commit -m "<message>"`. The index at that point holds that group and
   nothing else, so the bare commit cannot sweep anything --- the condition the
   sibling bug (2026-08-17-smart-commit-sweeps-the-whole-index.md) fixed.
3. `git read-tree <tree>` restores the index, on the failure path as well: a
   half-built index reads as lost work.

No step writes the working tree, so unstaged edits are still unstaged when the
verb returns. Scope `all` keeps `git add` + pathspec commit, which is what that
scope means.

The three verbs are new to the sandbox's git allowlist, granted only in the
forms that cannot write the working tree: `write-tree`, `read-tree` without
`-u`/`--update`, and `restore` only with `--staged` and never `--worktree`. A
bare `git restore <path>` discards uncommitted work exactly as `checkout` does,
and `checkout` is on `exec_deny_tokens`.

Changed: `tools/zig/smart_commit.zig` (`commitGroupsFromIndex`,
`commitEachFromIndex`, `restoreArgs`), `src/sandbox/host.zig`
(`gitIndexVerbAllowed`, called from `gitVerbAllowed`).

## Verification

`tests/e2e/commit_apply_test.zig` gained "clanker commit in scope staged
commits the index, not the worktree": `shared.md` is staged holding `mine`,
then the working-tree copy grows a `theirs-unfinished` line that is left out of
the index, and a two-group plan is applied with `clanker commit --yes`. It
asserts the committed blob holds `mine` and not `theirs-unfinished`, and that
the working-tree line survives as an unstaged change.

Against the unfixed tool the test failed with the commit widened to the
worktree copy:

```
commit widened to the worktree copy:
mine
theirs-unfinished
```

After the fix `zig build e2e` reports 19/19 tests passed, and `clanker gate`
passes every gate (build, tests, tools, fmt, lint, provider-kind,
tools-ts-toolchain, release-contract). The allowlist forms are covered by "git
index verbs are allowed only in the forms that cannot touch the worktree" in
`src/sandbox/host.zig`.

## Follow-up

## References

- Investigation: none yet
