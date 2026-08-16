# Bug — Isolated-run e2e still called the removed `goal` guest

## TL;DR

- **What failed:** `zig build e2e` failed at `tests/e2e/tool_roundtrip_test.zig` reading `state/goals.json` after `clanker run --worktree`.
- **Impact:** GitHub `verify` e2e stayed red after hosted runners started again.
- **Resolution:** Fixed: the scripted model now loads and calls `goal_add`.

## Status

Resolved.

## Symptom and impact

`clanker run --worktree` itself exited 0 and printed the mock final text. The checkout then had no `state/goals.json`, so the e2e assertion raised `FileNotFound`. Session-file checks never ran. The same 10/11 split appeared on ubuntu-24.04 once billing no longer blocked runners.

## Reproduction

1. On a tree after ADR 0012 (`goal.tool.json` removed, persist guest is `goal_add`).
2. `zig build e2e`.
3. `tool_roundtrip_test` calls `load_tools(["goal"])` then `goal`.
4. Expected: `state/goals.json` in the temp checkout names the objective. Actual: file missing.

## Root cause

`df4a3db5` split draft / persist / loop and deleted the `goal` wasm tool. The worktree e2e (`baed78cf`) kept the old name. Dispatch treats an unknown tool as a JSON error and continues, so the run stays green and nothing writes `state/goals.json`. This is not the worktree `NotDir` symlink defect.

## Resolution

The e2e mock loads and calls `goal_add`, the guest that appends `state/goals.json`. The test still checks that guest write and native session write both land in the checkout.

## Verification

Local `zig build e2e`: 11/11 passed, including the worktree test. CI `verify` e2e on the same commit is the remaining check.

## Follow-up

None. Catalog names belong in the scripted mock; `goal` stays a CLI/TUI loop.

## References

- Investigation: none (name drift after [Goal lifecycle capabilities were conflated](2026-08-15-goal-lifecycle-capabilities-conflated.md))
- Code: `tests/e2e/tool_roundtrip_test.zig`, `tools/manifests/goal_add.tool.json`
- ADR: [Goal draft, persistence, and execution are separate](../../adrs/0012-goal-draft-persistence-and-execution-are-separate.md)
