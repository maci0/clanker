# Runbooks

Runbooks are concise, current recovery procedures for failures that recur in
operation or development. They answer "what should I check and do now?";
[reports](../reports/) preserve the broader evidence, failed hypotheses, and
historical resolution that explain why the procedure is safe.

## From a terminal

`clanker reports` reads and writes this directory alongside
[reports](../reports/), through the same tool. Search only the recovery
procedures:

```bash
clanker reports search "worktree" --kind runbook
```

Read one:

```bash
clanker reports open docs/runbooks/improve-staging-build-inputs.md
```

## Agent workflow

Before starting a fresh diagnosis, use the `reports` tool's `search` action
with the error text, command, subsystem, or symptom. It searches this directory
and [reports](../reports/) together. Read a matching runbook first, verify its
preconditions against the current tree, then follow its checks. If its procedure
no longer fits the evidence, stop treating it as current: update the linked
investigation and revise the runbook only after the new resolution is verified.
Use the same tool's `create` action to scaffold and index a newly verified
repeatable recovery procedure. Use its `append` action to add newly verified
evidence or its exact-match `update` action to revise an existing procedure;
both are compare-and-swap writes, so reopen the record after a conflict.

## Writing a runbook

- Start from [TEMPLATE.md](TEMPLATE.md) and keep `## TL;DR` immediately after
  the title.
- Name it for the recurring symptom, not the one incident that found it:
  `<subsystem>-<symptom>.md`.
- State preconditions, observable decision points, safe recovery actions, and
  the checks that prove recovery. Commands must be runnable as written; place
  substitutions and explanations in the surrounding prose.
- Link the report that established the procedure. A runbook is not a place for
  raw logs, rejected hypotheses, or unresolved guesses.
- Add each active runbook to the inventory below. Supersede rather than delete
  a procedure when its replacement changes the recovery model.

## Inventory

<!-- inventory:runbook:start -->
- [Leftover improve-self worktrees pile up under .clanker-worktrees/](improve-worktree-backlog.md) — Current

- [State backups are not running](state-backups-not-running.md) — Current

- [improve-self staging tests blocked by cwd-dependent and Io.Io mismatches](improve-self-staging-test-blocker.md) — Current

- [Agent run compaction thrash](agent-run-compaction-thrash.md) — Give
  compaction room when a run compacts on every iteration or stops with
  `CompactionStalled`.
- [Improve staging build inputs](improve-staging-build-inputs.md) — Verify the
  staging root list covers every local module declared by `build.zig`.
<!-- inventory:runbook:end -->
