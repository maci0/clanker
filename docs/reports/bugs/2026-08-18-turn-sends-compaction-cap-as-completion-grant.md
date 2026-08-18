# Bug — The agent loop sends max_tokens_per_turn as the completion grant

## TL;DR

- **What failed:** llmChat and the streaming path set ChatParams.max_tokens to agent.max_tokens_per_turn (default 4096). That key is the per-turn input/compaction cap. On a reasoning model the 4096 is spent on reasoning_content, the final reply is length-stopped and empty, and the run dies AnswerTruncatedToEmpty. Escalation run-1787011404 used deepseek-v4-pro configured at 32768 and still requested 4096.
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

Escalation run `run-1787011404`, provider `deepseek`, model `deepseek-v4-pro`, 34 iterations, then:

- graph last LLM node: `90158/4096 tok`, `detail: length`, `result_bytes: 0`
- `state/token_stats.jsonl` last line: `completion_tokens: 4096`, `ok: true`
- `clanker graph answer run-1787011404`: `(the run recorded an empty final answer: length)`
- stderr: `final reply hit the completion-token limit before any text` then `deepseek: AnswerTruncatedToEmpty`

`config.local.toml` has `[models."deepseek/deepseek-v4-pro"] max_tokens = 32768`. Both chat call sites in `src/agent/loop.zig` (`llmChat` and the streaming `chatWithFallbackChain` at the `on_token` path) passed `self.cfg.agent.max_tokens_per_turn` as `ChatParams.max_tokens`. That key defaults to 4096 and is documented as the per-turn *input* cap (`src/config.zig`, `docs/configuration.md`). `clampedMaxTokens` then sent 4096 to the API.

The post-hoc `PerTurnTokenBudgetExceeded` check used the same 4096 against `usage.completion_tokens`, so raising only the request grant would still abort a tool-call turn that reasoned past 4096.

## Expected

A turn's completion grant is the model's configured `max_tokens`. `max_tokens_per_turn` stays the compaction floor only.