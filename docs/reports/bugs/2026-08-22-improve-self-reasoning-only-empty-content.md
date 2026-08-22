# Bug — improve-self exhausts all attempts when the model answers only in reasoning

## TL;DR

- **What failed:** a improve-self batch run against `llamacpp/qwen3.8-27b-bf-tuned`
  stopped after iterations 1 and 2 because every proposal and plan LLM call came
  back with an empty `content` field, the whole output buried in
  `reasoning_content`, `finish_reason: "stop"`. The engine's reasoning-extraction
  fallback found no proposal JSON in the chain-of-thought, so every attempt failed
  with `model returned no proposal content` and the batch died.
- **Impact:** the improve-self loop is unusable on a reasoning model that never
  closes its think block; each iteration burned its full attempt budget on an
  identical, futile retry.
- **Resolution:** fixed by retrying without reasoning after an empty-content
  response (`reasoning_effort: "none"` on the next proposal/plan call), so the
  model is forced to emit the JSON in content; plus a targeted feedback message
  for the stop-reason/reasoning-only shape and regression tests that pin the
  existing `lastProposalJson` extraction.

## Status

Resolved.

## Symptom and impact

The failing batch (request_id `improve`, ts 1787360...) logged, for each of
iterations 1 and 2:

```
[WARN] plan: response was not a usable idea list
[WARN] content empty; extracting proposal from reasoning (31398 chars)
[ERROR] model returned no proposal content (finish_reason=stop, reasoning=31398 chars, raw=32785 bytes)
[WARN] iteration 1: all attempts failed
```

The engine already had a fallback that tries to lift a proposal out of the
reasoning (`lastProposalJson`), but the model's chain-of-thought contained no
complete, balanced `{...}` object carrying a `changes` field, so the fallback
returned null and the attempt was failed. Each retry re-sent the same prompt
(with reasoning still on), the model produced the same reasoning-only response,
and both attempts of each iteration failed. `state/improvements.jsonl` records
the two iterations' four attempts all as `"summary":"empty model response"`,
`"detail":"no proposal content"`.

This is distinct from the earlier
[ck_llm-grant-spent-on-reasoning](2026-08-17-ck-llm-grant-spent-on-reasoning.md)
defect: there `finish_reason` was `"length"` (the completion budget ran out
mid-reasoning). Here `finish_reason` is `"stop"` — the model *concluded*
without ever emitting a content token. The engine's then-feedback treated both
as the generic "empty content field" message, and its `budget_cut` classification
(which triggers the "keep reasoning short" advice) was only true for the
`length` case.

## Reproduction

Deterministic against a model that answers entirely in `reasoning_content` with
empty `content` and `finish_reason: "stop"` — observed on the qwen3-family
`bf-tuned` model served by the local llama.cpp endpoint (`base_url
http://127.0.0.1:8082/v1`). Ask the improve engine for a proposal; content comes
back empty, reasoning carries 30k+ characters and no balanced proposal JSON.

The e2e test `improve-self retries with reasoning disabled after a
reasoning-only empty-content response`
(`tests/e2e/improve_fallback_test.zig`) reproduces the wire behaviour with a
scripted mock: the plan call returns an empty idea list, attempt 1 returns a
reasoning-only body (`tests/e2e/mock_llm.zig` `reasoningOnlyTurn`), and the
test asserts attempt 2 is sent with `"reasoning_effort":"none"` and succeeds.

## Root cause

`src/improve/engine.zig` runs its proposal and plan LLM calls with the model's
configured `reasoning_effort` (here `"medium"`). A thinking model that never
closes its `<think>` block emits the whole response as `reasoning_content` and
leaves `content` empty, ending with `finish_reason: "stop"`. The engine's only
recoveries were:

- `lastProposalJson` over the reasoning text, which requires a balanced `{...}`
  containing the literal `"changes"` — a chain-of-thought that only *thinks*
  about a patch, or that is cut mid-structure, contains none; and
- a feedback message that for the non-`length` case was the generic "empty
  content field" line, which does not tell the model to stop burying the answer
  in thinking.

Neither changes what the next call sends, so a model that behaves this way
fails every retry identically and the iteration burns its whole budget.

## Resolution

`src/improve/engine.zig`:

1. **Retry without reasoning.** A new per-instance `Engine` flag
   `retry_without_reasoning` is set whenever a proposal or plan response comes
   back with empty content. The next proposal and plan calls then pass
   `reasoning_effort: "none"` (which overrides the model's configured effort in
   `writeSamplingParams`), forcing the model to emit the answer in `content`
   instead of re-burying it in chain-of-thought. The flag is cleared as soon as
   a response carries content again, so a healthy model returns to normal
   reasoning.
2. **Reasoning-only feedback.** The empty-content feedback now distinguishes the
   `finish_reason: "stop"` + non-empty reasoning shape from a genuine budget cut
   and tells the model plainly that reasoning is disabled for the next attempt.
3. **Regression tests.** `lastProposalJson` (the recovery that lifts a proposal
   out of the reasoning text) is unchanged, but new tests pin its existing
   handling of an escaped-backslash-before-quote boundary, so the extraction
   cannot silently regress on that brace-scan edge case.

## Verification

- `zig build`, `zig build test`, `zig fmt --check` all green in the fix worktree.
- New unit tests in `src/improve/engine.zig` cover `lastProposalJson`: a
  proposal followed by trailing unbalanced reasoning braces is still recovered;
  the `\\"` boundary case is recovered; and text with no proposal object returns
  null.
- New e2e test drives a scripted reasoning-only first attempt and asserts the
  retry carries `reasoning_effort: "none"` and completes.

## Follow-up

The deeper fix for the affected model is its serving config: a qwen3 variant
that never closes its think block should be served with thinking disabled, or
run with `reasoning_effort = "none"` in its model config, rather than relying on
the engine to recover after one wasted call. The engine change makes improve-self
robust to the shape regardless.

## References

- Related bug: [`2026-08-17-ck-llm-grant-spent-on-reasoning.md`](2026-08-17-ck-llm-grant-spent-on-reasoning.md)
  (same empty-content failure mode on the `ck_llm` path, `finish_reason: length`).
- Related bug: [`2026-08-16-compaction-summary-budget-spent-on-reasoning.md`](2026-08-16-compaction-summary-budget-spent-on-reasoning.md).
- Code: `src/improve/engine.zig` (`improveOnce`, `planOnce`, `lastProposalJson`),
  `src/llm/providers/common.zig` (`writeSamplingParams`),
  `tests/e2e/mock_llm.zig` (`reasoningOnlyTurn`),
  `tests/e2e/improve_fallback_test.zig`.
