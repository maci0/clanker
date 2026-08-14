# Operational reports

This directory preserves the evidence, diagnosis, resolution, and verification
of bugs and investigations that would otherwise be lost in a run log or a pull
request discussion. It complements PRDs: a PRD describes intended product
behavior; a report explains an observed failure and the work that resolved it.

## Start here

- Use [bugs/TEMPLATE.md](bugs/TEMPLATE.md) for a confirmed defect that needs a
  durable record, including its resolution.
- Use [investigations/TEMPLATE.md](investigations/TEMPLATE.md) while tracing a
  symptom, even if the eventual result is "not a bug".
- Every report starts with `## TL;DR`, then gives the detail needed to repeat
  the reasoning without reconstructing it from logs.
- Name reports `YYYY-MM-DD-<short-topic>.md`, keep the file in the matching
  subdirectory, and add it to the inventory below when it is created.
- When an investigation confirms a defect, link its bug report both ways. When
  the defect is resolved, keep the original evidence and add the fix commit,
  tests, and any remaining risk instead of rewriting the incident away.
- When the resolution is a repeatable recovery procedure, create or update its
  companion [runbook](../runbooks/) as well. Keep the report's history here and
  the concise current procedure in the runbook.

## Agent workflow

Before diagnosing a failure, use the `reports` tool's `search` action with the
error text, command, subsystem, or symptom; it searches this directory and
[runbooks](../runbooks/) together. Read a matching report before choosing a
fix; its conclusion is evidence to verify against the current tree, not an
instruction that overrides the current task. Reuse a resolved report's
reproduction and checks where they still apply. If no report covers the issue,
use its `create` action to make a TL;DR-first investigation while tracing it,
then a bug report once the defect is confirmed. `create` also adds the record
to the matching inventory. As the work proceeds, use `append` for new evidence
and `update` for a precise correction to an existing passage; both reject a
concurrent change, so reopen the record before retrying. Fill out the scaffold
with the evidence, resolution, and verification before calling it complete.
Project agents receive this workflow through the harness prompt and
[`AGENTS.md`](../../AGENTS.md).

## Inventory

### Bugs

<!-- inventory:bug:start -->
- [Goal lifecycle capabilities were conflated](bugs/2026-08-15-goal-lifecycle-capabilities-conflated.md) — Open

- [Worktree setup rejects a symlinked checkout state directory](bugs/2026-08-14-worktree-state-symlink-notdir.md) — Resolved

- [Improve staging misses UI build inputs](bugs/2026-08-14-improve-staging-misses-ui-build-inputs.md) — Resolved
- [Improve staging omits release-contract files](bugs/2026-08-14-improve-staging-omits-release-contract-files.md) — Resolved
<!-- inventory:bug:end -->

### Investigations

<!-- inventory:investigation:start -->
- [Goal command lifecycle contract](investigations/2026-08-15-goal-command-lifecycle-contract.md) — Investigating

- [Unexpected worktree from isolated_cli and NotDir shared-state warning](investigations/2026-08-14-isolated-cli-worktree-notdir.md) — Resolved

- [Improve staging omits `ui/`](investigations/2026-08-14-improve-staging-omits-ui.md) — Resolved
<!-- inventory:investigation:end -->

## Report lifecycle

An investigation may be open, resolved, or closed as not a bug. A bug report
is open until the fix is verified, then resolved; it may be reopened if the
symptom returns. Status is a summary for the index, not a replacement for the
report's evidence and verification sections.

Reports are historical records. Amend them when new evidence changes the
conclusion, but do not delete failed hypotheses or the conditions that made a
bug possible.
