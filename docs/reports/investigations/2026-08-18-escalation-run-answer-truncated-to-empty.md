# Investigation — Escalation run died AnswerTruncatedToEmpty after 34 iterations

## TL;DR

- **Question:** Escalation run-1787011404 (repairing a failed repair) spent 34 iterations then the final reply used exactly 4096 completion tokens, finish_reason length, empty content. deepseek-v4-pro is configured at max_tokens 32768; the agent loop sent agent.max_tokens_per_turn (default 4096) as ChatParams.max_tokens. That knob is an input/compaction cap, not the completion grant.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Evidence

`clanker graph run-1787011404` ends at iter 34 with `90158/4096 tok`, `done 0 B, length`. `clanker graph answer` records an empty final answer. `state/token_stats.jsonl` shows `deepseek-v4-pro` `completion_tokens: 4096` on that last call. `config.local.toml` grants that model 32768.

The 4096 is `agent.max_tokens_per_turn`, sent as `ChatParams.max_tokens` from both chat paths in `src/agent/loop.zig`.

## Finding

The escalation run did not die because 32768 was too small. It died because the loop never sent 32768. Same class as the ck_llm grant-spent-on-reasoning bugs, different knob.

Related: `docs/reports/bugs/2026-08-18-turn-sends-compaction-cap-as-completion-grant.md`.
The earlier escalation (`run-1787001820`) is a different failure (malformed repo_search JSON + unconfigured openai fallback), already filed.