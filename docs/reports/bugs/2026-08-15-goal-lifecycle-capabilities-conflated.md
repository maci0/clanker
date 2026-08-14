# Bug — Goal lifecycle capabilities were conflated

## TL;DR

- **What failed:** Goal-related CLI, TUI, prompt, board, and documentation paths treated drafting, persistence, and starting a continuing goal loop as a required pipeline. A raw goal could require a draft, board persistence bypassed the add_goal tool, and the goal command submitted only one normal run.
- **Impact:** Operators could not reliably distinguish save-only actions from a goal-loop start across CLI, TUI, and web UI.
- **Resolution:** Fixed: draft, persistence, and shared evaluated goal-loop starts are now separate capabilities.

## Status

Resolved on 2026-08-15.

## Symptom and impact

`clanker goal`, `/goal`, and `clanker run "/goal …"` must start a continuing goal loop from a raw completion condition; the shared loop now starts a first turn immediately, evaluates every completed turn, and continues until terminal. The board also created persistent goals through a native writer rather than the intended persistence capability. Operators could not tell from the contract whether drafting, saving, or running would happen.

## Reproduction

1. Inspect the old goal prompt and lifecycle documentation.
2. Invoke a direct goal path with a raw prompt.
3. Observe instructions to draft then persist instead of immediately executing the supplied goal.

## Root cause

One overloaded `goal` name was used for a persistence guest and for execution wording. The draft PRD, skill, prompt, CLI/TUI routing, and board endpoint each encoded different pieces of the resulting pipeline.

## Resolution

Separated the draft and persistence implementations: `write_goal` drafts only and `add_goal` persists only. Added matching CLI/TUI surfaces and routed the board create request through `add_goal`. Raw and saved starts now use `agent/goal_loop.zig`, a shared evaluated loop wired into CLI, TUI, and the web run route.

## Verification

Three complete sweeps passed `zig build`, `zig build tools`, `zig build test`, and `zig build e2e`; the latter two also passed `zig fmt --check` and `git diff --check`.

## Follow-up

None.

## References

- Investigation: [Goal command lifecycle contract](../investigations/2026-08-15-goal-command-lifecycle-contract.md)
- PRD: [Goal lifecycle capabilities](../../prds/0035-goal-lifecycle.md)
- ADR: [Goal draft, persistence, and execution are separate](../../adrs/0012-goal-draft-persistence-and-execution-are-separate.md)

## Reopened scope

The prior correction still described `goal` as direct execution, while its implementation submitted one normal run. The intended contract is stronger: `goal`, `/goal`, `run "/goal …"`, and saved-goal starts must run a continuing goal loop. See the linked investigation for the external Claude Code and Kimi references and the implementation plan.

## Final resolution

`agent/goal_loop.zig` now drives raw CLI/TUI starts and saved web/CLI starts. It runs the first turn immediately, evaluates every completed turn, supplies a continuation reason when work remains, and records review or blocked outcomes on saved goals.
