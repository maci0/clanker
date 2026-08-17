# Bug — clanker run exits clean when the final reply is length-truncated to empty

## TL;DR

- **What failed:** Observed live (run-1786940774, deepseek-v4-pro): the last chat call hit its completion cap (4096 tokens, detail 'length') and the assembled final answer was empty, yet the run graph records failed:false, the process exits 0, and stdout ends after the log lines with no answer and no warning. An operator (or a script) reading exit status believes the task succeeded. A length-stopped empty answer should be surfaced as a failure, or at least a loud warning naming the cap.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. Resolved on 2026-08-17. The agent loop's final path now fails the run (error.AnswerTruncatedToEmpty, ERROR log naming the completion-token limit, graph final node ok:false) when finish_reason is length and the content is empty, and warns loudly on a truncated non-empty answer. E2E: tests/e2e/tool_roundtrip_test.zig scripts an empty length-stopped reply via mock_llm.emptyLengthTurn and asserts nonzero exit plus the stderr message.

## Status

Resolved on 2026-08-17. Resolved on 2026-08-17. The agent loop's final path now fails the run (error.AnswerTruncatedToEmpty, ERROR log naming the completion-token limit, graph final node ok:false) when finish_reason is length and the content is empty, and warns loudly on a truncated non-empty answer. E2E: tests/e2e/tool_roundtrip_test.zig scripts an empty length-stopped reply via mock_llm.emptyLengthTurn and asserts nonzero exit plus the stderr message.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
