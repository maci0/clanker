# Investigation — Goal command lifecycle contract

## TL;DR

- **Question:** Audit and align the three separate goal capabilities across all entry points.
- **Finding:** The current code and documentation conflate persistence with execution.
- **Resolution:** Resolved: separate direct draft, persistence, and execution surfaces, verified in three full sweeps.

## Status

Resolved.

## Trigger and scope

The required contract has exactly three independent capabilities:

1. `write-goal` is an optional structured-drafting aid. It never persists or runs.
2. `add-goal` is an optional persistence action. It adds a goal without running it; the goal board uses this capability.
3. `goal` and `/goal` execute the supplied goal directly. They accept a raw goal prompt and never require a prior `write-goal` draft or an `add-goal` record.

`clanker run --goal <id>` executes an existing persisted goal, particularly one created by `add-goal` but not yet started.

## Evidence

- Before the change, `goal_prompt` required a `write_goal` draft and persistence before execution, `clanker run "/goal …"` was an ordinary model task, and the board created goals through native file-writing logic.
- Direct surfaces now divide cleanly: `write-goal`/`/write-goal` draft only; `add-goal`/`/add-goal` persist only; `goal`/`/goal` execute directly.
- The board create endpoint invokes sandboxed `add_goal`; its explicit start-work action is a visible separate follow-up.
- The first full sweep exposed an inferred-error-set cycle between `cmdRun` and `cmdGoal`; the explicit `anyerror!void` routing boundary fixed it.

## Finding

The defect was confirmed: code and durable docs had made drafting, persistence, and execution look like a mandatory pipeline. That contradicted the intended direct-execution contract and left the board with a second persistence implementation.

## Resolution

Resolved on 2026-08-15. The persistence implementation and manifest are named `add_goal`; PRD 0035 and ADR 0012 define the contract, while PRD 0027 is only about drafting.

## Verification

Three complete sweeps passed `zig build`, `zig build tools`, `zig build test`, and `zig build e2e`; the latter two also passed `zig fmt --check` and `git diff --check`.

## References

- Related bug: [Goal lifecycle capabilities were conflated](../bugs/2026-08-15-goal-lifecycle-capabilities-conflated.md)
- Lifecycle PRD: [0035-goal-lifecycle.md](../../prds/0035-goal-lifecycle.md)
- ADR: [0012-goal-draft-persistence-and-execution-are-separate.md](../../adrs/0012-goal-draft-persistence-and-execution-are-separate.md)
