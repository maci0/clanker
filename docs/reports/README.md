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

## From a terminal

`clanker reports` is the same store from a shell. It calls the same `reports`
tool, so the inventory below, the templates and the compare-and-swap writes are
shared rather than reimplemented.

List every report and runbook:

```bash
clanker reports
```

Search both stores before diagnosing a failure:

```bash
clanker reports search "NotDir"
```

Read one record:

```bash
clanker reports open docs/reports/bugs/2026-08-14-worktree-state-symlink-notdir.md
```

Move a record to a new state, record and inventory together:

```bash
clanker reports status docs/reports/bugs/2026-08-14-worktree-state-symlink-notdir.md resolved "ensureDir handles the symlink; zig build test passes"
```

`clanker reports --help` covers `create`, `append`, `update` and `status`.

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
concurrent change, so reopen the record before retrying. When the work reaches
a new state, use `status` rather than editing the Status line: it rewrites the
record and its inventory entry in one call, and the inventory is what the next
reader skims. `resolved` requires a note naming the fix and what verified it,
so write the Resolution and Verification sections first. Fill out the scaffold
with the evidence, resolution, and verification before calling it complete.
Project agents receive this workflow through the harness prompt and
[`AGENTS.md`](../../AGENTS.md).

## Inventory

### Bugs

<!-- inventory:bug:start -->
- [Activity view shows only 'log' actions, so a board being worked on looks idle](bugs/2026-08-17-activity-view-shows-only-log-actions.md) — Resolved

- [clanker commit writes one commit and reports the whole multi-commit plan as written](bugs/2026-08-17-smart-commit-sweeps-the-whole-index.md) — Resolved

- [Every completed GET /api/events is logged at ERROR and counted as a server error](bugs/2026-08-17-sse-subscriptions-logged-as-server-errors.md) — Resolved

- [Runs filter's 'failed' keyword throws a TypeError and could never match](bugs/2026-08-17-runs-filter-failed-keyword-throws.md) — Resolved

- [clanker janitor never prunes sub-run graphs](bugs/2026-08-17-janitor-never-prunes-sub-run-graphs.md) — Resolved

- [smart_commit's apply path re-adds whole worktree files, widening a hunk-narrowed index](bugs/2026-08-17-smart-commit-readds-worktree-files.md) — Resolved

- [clanker commit generates a generic 'chore: update working tree' message for a clearly scoped diff](bugs/2026-08-16-smart-commit-generic-message.md) — Resolved

- [resolveExecPath leaks PATH-candidate allocations through ckStdApi](bugs/2026-08-17-resolveexecpath-candidate-leak.md) — Resolved

- [A commit on origin/main did not compile, and the break surfaced in an unrelated session's push](bugs/2026-08-16-pushed-main-did-not-compile.md) — Resolved

- [reports status updates the Status section but not the TL;DR](bugs/2026-08-16-reports-status-leaves-the-tldr-saying-open.md) — Resolved

- [Five agent sessions on one checkout committed and stashed each other's work](bugs/2026-08-16-concurrent-sessions-commit-each-others-work.md) — Open

- [clanker commit always fails: smart_commit returns no text field](bugs/2026-08-16-clanker-commit-tool-output-has-no-text-field.md) — Resolved

- [improve-self worktrees are never reclaimed when a run promotes nothing](bugs/2026-08-16-improve-worktree-merge-bound-to-promotion.md) — Resolved

- [Every guest read and write under a symlinked state/ was refused](bugs/2026-08-16-guest-writes-refused-under-symlinked-state.md) — Resolved

- [State backups stopped for two days because .agents is a real directory](bugs/2026-08-16-state-backup-aborts-on-checkout-local-agents.md) — Resolved

- [Isolated-run e2e still called the removed `goal` guest](bugs/2026-08-16-worktree-e2e-calls-removed-goal-tool.md) — Resolved

- [research status action never updates the README inventory entry](bugs/2026-08-16-research-status-leaves-inventory-draft.md) — Resolved

- [Worker parallel sandbox omitted tool_self_name, failing capability evals in improve-self](bugs/2026-08-16-worker-sandbox-missing-tool-self-name.md) — Resolved

- [Compaction repeats forever when the history it cannot move exceeds the threshold](bugs/2026-08-16-compaction-cannot-shrink-immovable-history.md) — Resolved

- [The compaction summary always fails on a thinking model](bugs/2026-08-16-compaction-summary-budget-spent-on-reasoning.md) — Resolved

- [Unknown goal id runs unscoped task](bugs/2026-08-15-unknown-goal-id-runs-unscoped.md) — Resolved

- [Goal lifecycle capabilities were conflated](bugs/2026-08-15-goal-lifecycle-capabilities-conflated.md) — Resolved

- [Worktree setup rejects a symlinked checkout state directory](bugs/2026-08-14-worktree-state-symlink-notdir.md) — Resolved

- [Improve staging misses UI build inputs](bugs/2026-08-14-improve-staging-misses-ui-build-inputs.md) — Resolved
- [Improve staging omits release-contract files](bugs/2026-08-14-improve-staging-omits-release-contract-files.md) — Resolved
<!-- inventory:bug:end -->

### Investigations

<!-- inventory:investigation:start -->
- [GET /api/events logs as ERROR status=0 and counts as an http error](investigations/2026-08-17-sse-requests-logged-as-errors.md) — Resolved

- [TUI Shift+Enter logs vaxis_parser unhandled ss3 instead of newline](investigations/2026-08-17-tui-shift-enter-ss3-unhandled.md) — Resolved

- [Web UI run history is stale because graph listings sort filenames lexically](investigations/2026-08-17-web-ui-run-history-stale.md) — Resolved

- [TUI selection copy never reaches the system clipboard in terminals that ignore OSC 52 or intercept Ctrl+Shift+C](investigations/2026-08-16-tui-selection-copy-not-reaching-clipboard.md) — Resolved

- [TUI crashes irrecoverably on terminal resize with mascot enabled](investigations/2026-08-16-tui-resize-crash.md) — Investigating

- [TUI Ctrl+C cannot interrupt a streaming turn while the picker or search modal is open](investigations/2026-08-16-tui-ctrl-c-swallowed-by-picker-and-search.md) — Resolved

- [Improve staging omits node UI-test data roots](investigations/2026-08-15-improve-staging-node-ui-data.md) — Resolved

- [ck_cas lock sidecars are never removed and bypass the create retry](investigations/2026-08-16-ck-cas-lock-sidecars.md) — Closed

- [`clanker run` never finishes, compacting on every iteration](investigations/2026-08-16-run-livelock-compaction-thrash.md) — Resolved

- [improve-self gate tool build failure (appendWriteFn) and follow-up](investigations/2026-04-15-improve-self-gate-build.md) — Resolved

- [improve-self iterations exhaust attempts on config.toml documentation test](investigations/2026-06-13-improve-staging-config-doc.md) — Resolved

- [improve-self iterations wasted on @errorUpdate in WASM guest](investigations/2026-06-12-improve-self-erroreupdate-guest.md) — Resolved

- [improve-self iterations fail on hallucinated @errorUpdate](investigations/2025-08-17-improve-self-errorupdate.md) — Closed

- [Goal command lifecycle contract](investigations/2026-08-15-goal-command-lifecycle-contract.md) — Resolved

- [Unexpected worktree from isolated_cli and NotDir shared-state warning](investigations/2026-08-14-isolated-cli-worktree-notdir.md) — Resolved

- [Improve staging omits `ui/`](investigations/2026-08-14-improve-staging-omits-ui.md) — Resolved
<!-- inventory:investigation:end -->

## Report lifecycle

An investigation may be open, resolved, or closed as not a bug. A bug report
is open until the fix is verified, then resolved; it may be reopened if the
symptom returns. Status is a summary for the index, not a replacement for the
report's evidence and verification sections.

The inventory above carries a second copy of each status. Only the `status`
action writes both; `create` sets the inventory copy once and never again, so a
record moved by hand leaves the index behind. A runbook has no status — its
inventory line carries a summary — and `status` refuses one for that reason.

Reports are historical records. Amend them when new evidence changes the
conclusion, but do not delete failed hypotheses or the conditions that made a
bug possible.
