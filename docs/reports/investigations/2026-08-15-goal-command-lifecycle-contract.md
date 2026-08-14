# Investigation — Goal command lifecycle contract

## TL;DR

- **Question:** Audit and align the three separate goal capabilities across all entry points.
- **Finding:** The previous implementation treated `goal` as one normal agent run instead of a continuing goal loop.
- **Resolution:** Fixed: one shared loop now drives CLI, TUI, and web goal starts; it evaluates each completed turn and records the terminal outcome.

## Status

Resolved on 2026-08-15.

## Trigger and scope

The required contract has exactly three independent capabilities:

1. `write-goal` is an optional structured-drafting aid. It never persists or runs.
2. `add-goal` is an optional persistence action. It adds a goal without running it; the goal board uses this capability.
3. `goal` and `/goal` start a goal loop from a raw completion condition. They never require a prior `write-goal` draft or an `add-goal` record, and they keep taking turns until terminal.

`clanker run --goal <id>` starts that same goal loop from an existing persisted goal, particularly one created by `add-goal` but not yet started.

## Evidence

- Before the change, `goal_prompt` required a `write_goal` draft and persistence before execution, `clanker run "/goal …"` was an ordinary model task, and the board created goals through native file-writing logic.
- Draft and persistence surfaces divide cleanly: `write-goal`/`/write-goal` draft only and `add-goal`/`/add-goal` persist only. Goal starts now call `agent/goal_loop.zig`, which runs a turn, evaluates it, and schedules the next turn when needed.
- The board create endpoint invokes sandboxed `add_goal`; its explicit start-work action is a visible separate follow-up.
- The first full sweep exposed an inferred-error-set cycle between `cmdRun` and `cmdGoal`; the explicit `anyerror!void` routing boundary fixed it.

## Finding

The defect was confirmed: code and durable docs had made drafting, persistence, and starting a continuing loop look like a mandatory pipeline. The implementation now preserves their independence and the live goal paths continue across evaluated turns.

## Resolution

The persistence implementation and manifest are named `add_goal`; PRD 0035 and ADR 0012 define the three-capability contract, while PRD 0027 is only about drafting. `agent/goal_loop.zig` is the shared runtime: each surface supplies a turn runner and tool-free evaluator, so terminal semantics cannot drift.

## Verification

Three complete sweeps passed `zig build`, `zig build tools`, `zig build test`, and `zig build e2e`; the latter two also passed `zig fmt --check` and `git diff --check`.

## References

- Related bug: [Goal lifecycle capabilities were conflated](../bugs/2026-08-15-goal-lifecycle-capabilities-conflated.md)
- Lifecycle PRD: [0035-goal-lifecycle.md](../../prds/0035-goal-lifecycle.md)
- ADR: [0012-goal-draft-persistence-and-execution-are-separate.md](../../adrs/0012-goal-draft-persistence-and-execution-are-separate.md)

## Reopened evidence

External reference behavior is unambiguous: [Claude Code `/goal`](https://code.claude.com/docs/en/goal) starts work immediately and continues across turns until an evaluator confirms the condition; [Kimi Code goals](https://moonshotai.github.io/kimi-code/en/guides/goals.html) save the objective, start goal mode, and check after each turn. Clanker previously routed `cmdGoal` through one normal `cmdRun` call, so the prior resolution was incomplete. It now marks the run as a continuing loop and delegates sequencing to `agent/goal_loop.zig`; the web and TUI surfaces use that same driver.

## Final verification

The loop driver has focused continuation/budget/parser tests; CLI has a saved-goal-without-positional-task parse regression test; and saved terminal outcomes persist status, reason, and turn count for the board. `zig build test`, `zig build tools`, `zig fmt --check src`, and `git diff --check` passed. The e2e command could not be authorized after the tool environment reported its usage limit.
