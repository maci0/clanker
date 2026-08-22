# Bug — Goal-loop work turns ignore --backend and call Agent.run

## TL;DR

- **What failed:** clanker goal --backend, TUI /goal, and a goal-loop POST /api/run parsed or persisted the backend then still called Agent.run for each work turn. starts_goal_loop took that path first; only a non-goal run used the coding-agent driver. Work turns now go through runIfBackend.
- **Impact:** A goal whose work was supposed to run on grok/claude/codex still burned the in-process LLM loop (and its API key). `--backend` on `goal` was parse-only.
- **Resolution:** Resolved on 2026-08-22. CLI/TUI/HTTP goal-loop work turns call runIfBackend; zig build test -Dtest-filter=runIfBackend and goal --backend work turn exit 0.

## Status

Resolved on 2026-08-22. CLI/TUI/HTTP goal-loop work turns call runIfBackend; zig build test -Dtest-filter=runIfBackend and goal --backend work turn exit 0.

## Symptom and impact

`clanker goal --backend grok "the work is done"` copied the flag onto `cfg.agent.backend` in `cmdRun`, then `starts_goal_loop` took `goal_loop.run` with `cliGoalLoopRunTurn`, which always called `Agent.run`. TUI `/goal` and a goal-loop `POST /api/run` did the same. A non-goal `clanker run --backend` was the only path that spawned the vendor.

## Reproduction

Parse `clanker goal --backend grok ...` (flag accepted), then inspect `cliGoalLoopRunTurn` / `tuiGoalLoopRunTurn` / `serverGoalLoopRunTurn`: they called `Agent.run` with no `cfg.agent.backend` check.

## Root cause

`--backend` was applied to config before the run, but the goal-loop work-turn callbacks were written against the in-process agent and never consulted the backend key. The HTTP and TUI goal loops copied that callback shape.

## Resolution

`acp_driver.runIfBackend` returns null when backend is empty (caller runs `Agent.run`) and otherwise `run`. `cliGoalLoopRunTurn`, `tuiGoalLoopRunTurn`, and `serverGoalLoopRunTurn` all call it. A CLI backend turn still writes the answer to stdout when streaming is on (`on_token` is set but the vendor does not stream through it).

## Verification

`zig build test -Dtest-filter="runIfBackend"`: empty backend is null; named `grok` against `tests/fixtures/fake-acp-agent.py` returns `fake-acp-answer`. `zig build test -Dtest-filter="goal --backend work turn"` parses the flag and drives that same `runIfBackend` call.

## Follow-up

None.

## References

- Hang sibling: docs/reports/bugs/2026-08-22-acp-hang-never-unblocks-a-silent-child.md
- ADR 0032 / PRD 0043 / RFC 0020
