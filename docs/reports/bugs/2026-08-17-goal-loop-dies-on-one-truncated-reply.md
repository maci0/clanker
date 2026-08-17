# Bug — A goal loop stops dead on a single AnswerTruncatedToEmpty instead of retrying the turn

## TL;DR

- **What failed:** goal loop run-1786958796 died at iteration 127 after ~12 minutes of exploration: the model's reply hit the 16384-token completion cap with only reasoning_content, chatWithFallbackChain surfaced AnswerTruncatedToEmpty, and the loop terminated, discarding all progress. For clanker run failing is right; a goal loop is documented to continue until achieved, blocked, or budget-limited, so one length-stopped turn should count as a failed turn and be retried, not end the loop.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence

From the run log (goal loop started 2026-08-17, request_id=run-1786958796, model deepseek/deepseek-v4-pro with max_tokens 16384, reasoning_effort medium):

- iteration 127 completed a read_file call normally
- then: [ERROR] final reply hit the completion-token limit before any text; raise max_tokens (or the tool's grant) and retry
- then: [ERROR] goal loop stopped: deepseek: AnswerTruncatedToEmpty, process exit 1

The AnswerTruncatedToEmpty error itself is the 2026-08-17 fix working as designed for clanker run (a length-stopped empty reply must not exit 0). The defect is the goal loop's handling: ADR 0012 describes the loop as continuing until achieved, blocked, cancelled, or budget-limited, and one truncated completion is none of those. The run's 127 iterations of context were discarded; the retry hint in the error text was addressed to a human, not acted on by the loop.

## Expected

The goal loop treats AnswerTruncatedToEmpty from a turn like any failed turn: retry the turn (the same-provider retry path already exists for 429/5xx in client.zig), optionally once with a raised cap, and only report the goal blocked if the retry also fails. Terminating the whole loop should be reserved for errors that make further turns meaningless.

## Workaround

Raise the model's max_tokens so reasoning has headroom (this checkout: deepseek-v4-pro 16384 -> 32768 in config.local.toml) and restart the goal from scratch.