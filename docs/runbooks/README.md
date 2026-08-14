# Runbooks

Runbooks are concise, current recovery procedures for failures that recur in
operation or development. They answer "what should I check and do now?";
[reports](../reports/) preserve the broader evidence, failed hypotheses, and
historical resolution that explain why the procedure is safe.

## Agent workflow

Before starting a fresh diagnosis, use the `reports` tool's `search` action
with the error text, command, subsystem, or symptom. It searches this directory
and [reports](../reports/) together. Read a matching runbook first, verify its
preconditions against the current tree, then follow its checks. If its procedure
no longer fits the evidence, stop treating it as current: update the linked
investigation and revise the runbook only after the new resolution is verified.
Use the same tool's `create` action to scaffold and index a newly verified
repeatable recovery procedure.

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
No runbooks yet. Add one after a report establishes and verifies a repeatable
recovery procedure.
<!-- inventory:runbook:end -->
