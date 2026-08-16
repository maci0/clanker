# Bug — smart_commit's apply path re-adds whole worktree files, widening a hunk-narrowed index

## TL;DR

- **What failed:** With scope:staged and dry_run:false, smart_commit runs git add -- <files> per group before committing, staging the worktree version of each file. An index narrowed to one session's hunks (the concurrent-sessions runbook's route for shared inventory files) is silently widened with other sessions' unstaged edits. Staged scope should commit the staged content as-is.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

A `clanker commit` run on a shared checkout can commit another session's half-finished edits. The dry-run preview shows the staged diff, but the apply path stages more than it previewed, so what lands differs from what was confirmed.

## Reproduction

Observed 2026-08-17 while landing the resolveExecPath leak fix: docs/reports/README.md held two sessions' hunks, the index was narrowed to one session's hunk via `git apply --cached`, and the smart_commit apply path would have staged the whole worktree file (not run to completion — worked around by committing the narrowed index with `git commit` directly). Deterministic from the code: partially stage one hunk of a file that also has unstaged edits, run the tool with dry_run:false, and the commit contains the unstaged edits too.

## Root cause

`tool_main` in tools/zig/smart_commit.zig runs `gitRun(prepend("add", "--", g.files))` for each group before `git commit -m`. `git add <file>` stages the file's current worktree content, so in scope:staged it does not merely re-affirm the staged content — it replaces it with the worktree version. The grouping itself was computed from `git diff --staged`, so the committed content can diverge from the content the groups were derived from.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
