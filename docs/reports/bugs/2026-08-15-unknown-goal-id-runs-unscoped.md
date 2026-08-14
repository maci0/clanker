# Bug — Unknown goal id runs unscoped task

## TL;DR

- **What failed:** An explicit run --goal id that does not exist warns and starts the task without goal context instead of refusing the requested saved-goal run.
- **Impact:** A typo or stale id could run an unrelated task without the requested goal context.
- **Resolution:** Resolved on 2026-08-15.

## Status

Resolved.

## Symptom and impact

An explicit `clanker run --goal <id>` is a request to execute one saved record. Previously, an unknown id logged a warning and ran the supplied task without any goal context.

## Reproduction

1. Create `state/goals.json` without the requested id.
2. Call `resolveRunTask` with that explicit id.
3. Before the fix it returned the plain task; now it returns `error.GoalNotFound`.

## Root cause

The explicit-id branch used the same fallback as absent auto-steer state, despite an explicit id being a stronger operator instruction.

## Resolution

`resolveRunTask` now returns `error.GoalNotFound` for a missing explicit id. CLI reports a concrete recovery path and `POST /api/run` returns 404 `goal not found`.

## Verification

The focused resolver test plus two independent full sweeps passed `zig build`, `zig build tools`, `zig build test`, `zig build e2e`, `zig fmt --check`, and `git diff --check`.

## Follow-up

None.

## References

- Lifecycle PRD: [0035-goal-lifecycle.md](../../prds/0035-goal-lifecycle.md)
