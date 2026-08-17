# Bug — clanker commit applies a plan it computes a second time, not the one it previewed

## TL;DR

- **What failed:** cmdCommit calls smart_commit twice -- a dry run for the preview, then an independent apply -- and each call re-asks the model for a grouping. The plan that lands is therefore not the plan the operator was shown and confirmed. Observed 2026-08-17: the preview proposed fix(smart_commit): commit staged content in staged scope and the apply committed chore: update working tree, its ck_llm reply having hit the 4096-token grant exactly.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. smart_commit gained a commits input that writes a given plan as-is (refusing any file the current diff does not hold), and cmdCommit hands the previewed list to the write; verified by the two-different-plans e2e case asserting requestCount() == 1 (20/20 e2e) and by a live clanker commit whose preview and result matched on one token_stats row.

## Status

Resolved on 2026-08-17. smart_commit gained a commits input that writes a given plan as-is (refusing any file the current diff does not hold), and cmdCommit hands the previewed list to the write; verified by the two-different-plans e2e case asserting requestCount() == 1 (20/20 e2e) and by a live clanker commit whose preview and result matched on one token_stats row.

## Symptom and impact

The confirmation prompt is the point of `clanker commit`: it shows a plan and
asks whether to write it. What it writes is a second, independently computed
plan, so the messages and the file grouping can both differ from what was
confirmed. Nothing is lost --- the same staged content is committed --- but the
history gets a message the operator never saw, and a `y` answer means less than
it appears to.

It also doubles the cost of every run: two grouping calls over the same diff.

## Reproduction

Observed 2026-08-17 committing this checkout's own smart_commit fix, a ten-file
staged diff:

```bash
clanker commit --dry-run
```

reported `fix(smart_commit): commit staged content in staged scope`, and

```bash
clanker commit --yes
```

reported `committed 1 commit(s): chore: update working tree`, with the note
`llm reply held no usable grouping (possibly truncated by the max_tokens
grant)`.

The three `state/token_stats.jsonl` rows for those runs are the evidence that
the difference is a second model call, not a re-render: `completion_tokens`
1560 for the `--dry-run` call, then 1034 and 4096 for the two calls of the
single `--yes` run. The 4096 is exactly the descriptor's grant, so that reply
was truncated mid-JSON, `parseGroups` failed, and `groupViaLlm` fell back to
one generic commit --- the tail predicted in the Follow-up of
2026-08-16-smart-commit-generic-message.md.

Not verified: what the `--yes` run's own preview printed, since only the tail
of its output was kept. The two-call structure is read from the code below, not
inferred from that output.

## Root cause

`cmdCommit` in `src/cli.zig` calls `smartCommitPlan` twice, once with
`dry_run: true` for the preview and once with `dry_run: false` to write, and
`smart_commit`'s only input is `{dry_run, scope, max_commits}`. The guest has
no way to be handed a plan, so every call runs `groupViaLlm` over the diff
again. Two calls to a sampling model over the same input are two different
answers whenever anything goes wrong in one of them --- truncation here, but a
different grouping would do it just as well.

## Resolution

`smart_commit` gained a `commits` input: a plan to write as given. With one
present the guest skips `groupViaLlm` and the topological ordering entirely ---
the plan carries the order it was shown in --- and writes those groups. It
still validates every message as a conventional commit, and refuses outright if
the plan names a file the current diff does not hold, since the tree can move
between the preview and the write:

```
the plan names <path>, which is not in this diff; re-run the preview
```

`cmdCommit` in `src/cli.zig` now hands the previewed `commits` list to the
write call. The grouping model is called once per `clanker commit` rather than
twice, so a run is also about half the tokens it was.

Changed: `tools/zig/smart_commit.zig` (`planFromInput`, `unstagedPlanFile`),
`tools/manifests/smart_commit.tool.json` (the `commits` input schema, and the
descriptions the model reads), `src/cli.zig` (`CommitPlan`, `commitBody`,
`smartCommitPlan`'s `plan` parameter).

## Verification

`tests/e2e/commit_apply_test.zig` gained "clanker commit writes the plan it
previewed, without asking the model twice". The mock LLM is scripted with two
*different* groupings over the same diff: a two-commit plan first, then a
one-commit `chore: update working tree` plan of the kind a truncated reply
produces. Against the unfixed verb the second plan landed:

```
the apply path recomputed the plan:
chore: update working tree
initial e2e fixture
```

After the fix the test asserts both scripted messages from the first plan are
in the log, that `chore: update working tree` is not, and that
`mock.requestCount()` is 1 --- the grouping call happened once.

`zig build e2e` reports 20/20, and `clanker gate` passes every gate.

Checked in this checkout as well, on the commit that repaired an unrelated
build break: `clanker commit --yes` over an index narrowed to a single hunk
printed the same message in its preview and its result, and
`state/token_stats.jsonl` grew by exactly one row for the run.

## Follow-up

## References

- Investigation: none yet
