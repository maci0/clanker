# Investigation — Escalation run died on DeepSeek ReadFailed and an unconfigured OpenAI fallback

## TL;DR

- **Question:** An escalation run (run-1787001820) that was repairing a failed repair exited 1: repo_search returned malformed JSON, the DeepSeek stream failed with ReadFailed, and the fallback chain then tried openai which has no credential (MissingApiKey). Tracing whether repo_search is a code defect and whether fallback should skip unconfigured providers.
- **Finding:** Resolved on 2026-08-19. both code defects fixed: bugs/2026-08-18-exec-truncated-note-is-not-json.md and bugs/2026-08-18-fallback-tries-unconfigured-providers.md; re-verified on main a99a052d: the chain filters rows with providers.unconfiguredReason (loop.zig), so a run fails on the real transport error instead of MissingApiKey. The DeepSeek ReadFailed itself was a mid-stream transport drop, no defect
- **Resolution:** Resolved on 2026-08-19. both code defects fixed: bugs/2026-08-18-exec-truncated-note-is-not-json.md and bugs/2026-08-18-fallback-tries-unconfigured-providers.md; re-verified on main a99a052d: the chain filters rows with providers.unconfiguredReason (loop.zig), so a run fails on the real transport error instead of MissingApiKey. The DeepSeek ReadFailed itself was a mid-stream transport drop, no defect

## Status

Resolved on 2026-08-19. both code defects fixed: bugs/2026-08-18-exec-truncated-note-is-not-json.md and bugs/2026-08-18-fallback-tries-unconfigured-providers.md; re-verified on main a99a052d: the chain filters rows with providers.unconfiguredReason (loop.zig), so a run fails on the real transport error instead of MissingApiKey. The DeepSeek ReadFailed itself was a mid-stream transport drop, no defect

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Finding

Two code defects, one environmental transport error.

1. `repo_search` malformed JSON was `writeExecResult` emitting an unquoted truncation `note` (`s.print` of prose). Filed as docs/reports/bugs/2026-08-18-exec-truncated-note-is-not-json.md.
2. The fallback chain tried `openai` after DeepSeek `ReadFailed` even though `OPENAI_API_KEY` is unset. Filed as docs/reports/bugs/2026-08-18-fallback-tries-unconfigured-providers.md.
3. DeepSeek `ReadFailed` itself is a mid-stream transport drop. The chain now skips the unconfigured openai row so the run fails on the real error instead of `MissingApiKey`.
## Resolution or handoff

Two code defects, one environmental transport error.

1. `repo_search` malformed JSON was `writeExecResult` emitting an unquoted truncation `note`. Filed as docs/reports/bugs/2026-08-18-exec-truncated-note-is-not-json.md.
2. The fallback chain tried `openai` after DeepSeek `ReadFailed` even though `OPENAI_API_KEY` is unset. Filed as docs/reports/bugs/2026-08-18-fallback-tries-unconfigured-providers.md.
3. DeepSeek `ReadFailed` itself is a mid-stream transport drop. The chain now skips the unconfigured openai row so the run fails on the real error instead of `MissingApiKey`.

A later escalation (`run-1787011404`) died for a different reason — the loop sent `max_tokens_per_turn` as the completion grant — filed as docs/reports/bugs/2026-08-18-turn-sends-compaction-cap-as-completion-grant.md.