# Bug — Goal lifecycle capabilities were conflated

## TL;DR

- **What failed:** Goal-related CLI, TUI, prompt, board, and documentation paths treated drafting, persistence, and execution as a required pipeline, so direct execution could require a draft and board persistence bypassed the add_goal tool.
- **Impact:** Direct goal execution was not direct; save-only and run actions were ambiguous across CLI, TUI, and web UI.
- **Resolution:** Resolved on 2026-08-15.

## Status

Resolved.

## Symptom and impact

`clanker goal`, `/goal`, and `clanker run "/goal …"` did not consistently mean direct execution. The board also created persistent goals through a native writer rather than the intended persistence capability. Operators could not tell from the contract whether drafting, saving, or running would happen.

## Reproduction

1. Inspect the old goal prompt and lifecycle documentation.
2. Invoke a direct goal path with a raw prompt.
3. Observe instructions to draft then persist instead of immediately executing the supplied goal.

## Root cause

One overloaded `goal` name was used for a persistence guest and for execution wording. The draft PRD, skill, prompt, CLI/TUI routing, and board endpoint each encoded different pieces of the resulting pipeline.

## Resolution

Separated the contract and implementations: `write_goal` drafts only, `add_goal` persists only, and `goal` executes only. Added direct CLI/TUI persistence surfaces; routed the board create request through `add_goal`; made `run "/goal …"` the direct-execution alias; and documented the contract in PRD 0035 and ADR 0012.

## Verification

Three complete sweeps passed `zig build`, `zig build tools`, `zig build test`, and `zig build e2e`; the latter two also passed `zig fmt --check` and `git diff --check`.

## Follow-up

None.

## References

- Investigation: [Goal command lifecycle contract](../investigations/2026-08-15-goal-command-lifecycle-contract.md)
- PRD: [Goal lifecycle capabilities](../../prds/0035-goal-lifecycle.md)
- ADR: [Goal draft, persistence, and execution are separate](../../adrs/0012-goal-draft-persistence-and-execution-are-separate.md)
