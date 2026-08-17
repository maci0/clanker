# Bug — clanker commit writes one commit and reports the whole multi-commit plan as written

## TL;DR

- **What failed:** The apply path runs git add per group then a bare git commit, which commits the entire index: anything staged before the verb ran lands in the first group's commit and every later group finds nothing to commit. gitRun discarded lib.exec's reply, where the process status lives, so those empty commits were still counted in the committed N commit(s) line.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. The apply path commits with a pathspec so a group cannot sweep the rest of the index, and gitRun now reads lib.exec's exit code so a refused git commit is a refusal rather than a reported commit. e2e case in tests/e2e/commit_apply_test.zig; gate green.

## Status

Resolved on 2026-08-17. The apply path commits with a pathspec so a group cannot sweep the rest of the index, and gitRun now reads lib.exec's exit code so a refused git commit is a refusal rather than a reported commit. e2e case in tests/e2e/commit_apply_test.zig; gate green.

## Symptom and impact

`clanker commit --yes` printed a two-commit plan and said it had written both:

```
committed 2 commit(s):

  docs: document SSE logging and subscriber slot fixes
      AGENTS.md
      CHANGELOG.md
      docs/reports/README.md
      ...

  fix: report SSE subscription status and release slots on client hangup
      src/cli.zig
      src/serve/live.zig
      ...
```

`git log` had one new commit, carrying the first group message and all nine
files. `git show --stat HEAD` on 7ac67346 in this repository is that commit.

The report is the damage, not just the grouping: an operator is told two atomic
commits exist, and the history has one mixed one. The condition is having
staged before running the verb — which is what
[the concurrent-sessions runbook](../../runbooks/concurrent-agent-sessions-on-one-checkout.md)
tells a session to do so it commits only its own paths. `clanker commit --all`
on a clean index is unaffected, which is why this survived.

## Reproduction

`tests/e2e/commit_apply_test.zig` is the reproduction: a fixture repo, two
unrelated files staged up front, a scripted two-group plan, `clanker commit
--yes`. Before the fix it wrote one commit while reporting two.

## Root cause

Two defects in `tools/zig/smart_commit.zig`, compounding:

1. The apply loop ran `git add -- <group files>` and then a bare
   `git commit -m <message>`. `git commit` commits the whole index, not the
   paths just added, so group 1 swept every staged path — including the later
   groups' files.
2. `gitRun` was `_ = try lib.exec("git", args);`. `lib.exec` reports the
   process's exit status inside its `{"ok","code","stdout","stderr"}` reply
   rather than as a Zig error, so the discarded result meant group 2's
   `git commit`, which had nothing left to commit and exited non-zero, was
   still counted as written.

## Resolution

- The commit is scoped to its group: `git commit -m <message> -- <files>`.
  That is safe because the `git add` immediately before has made index and
  worktree agree on exactly those paths, and it leaves anything else staged
  for the next group or the operator.
- `gitRun` takes a `detail` out-parameter, parses `code` from the reply, and
  puts git's stderr there on a non-zero exit. The caller turns a non-empty
  `detail` into a refusal, so the verb can no longer report a commit that git
  declined to make.

## Verification

`tests/e2e/commit_apply_test.zig` (failing first: `expected 3, found 2` new
commits) asserts the report and the repository agree — two commits, one file
each, neither group's file left uncommitted. `zig build e2e` is 18/18 and
`clanker gate` passes.

`tests/e2e/mock_llm.zig` gained `jsonTurn`: a guest's `ck_llm` goes through
`client.chat`, not `chatStream`, so the existing SSE `textTurn` reaches it as
`SyntaxError` and the guest takes its "llm call failed" fallback instead of the
path under test.

## Follow-up

The sibling bug
[2026-08-17-smart-commit-readds-worktree-files.md](2026-08-17-smart-commit-readds-worktree-files.md)
is unchanged by this: the `git add` still stages each group's files whole, so
an index narrowed to one session's hunks is still widened. Committing a
hunk-narrowed index with `clanker git commit` directly remains the advice.

## References

- Investigation: none. Reproduced directly from the report of a `clanker
  commit` run in this repository (commit 7ac67346).
- `tools/zig/smart_commit.zig`, `tests/e2e/commit_apply_test.zig`,
  `tests/e2e/mock_llm.zig`
