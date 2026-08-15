# Bug — the compaction summary always fails on a thinking model

## TL;DR

- **What failed:** every LLM compaction summary returned `EmptyResponse` on
  `deepseek/deepseek-v4-flash`, so compaction always fell back to the local
  extractive summary.
- **Impact:** one wasted LLM round trip per compaction (4.4-6.3 s each in the
  observed run), a permanently degraded summary, and the model's actual answer —
  returned in `reasoning_content` — thrown away. Any model with `thinking` in its
  capabilities is affected.
- **Resolution:** resolved in `d2628464`. The summary call is budgeted for the
  model it runs on, falls back to the model's reasoning text, and is not retried
  once it has failed twice in a run.

## Status

Resolved. Established by
[Investigation — `clanker run` never finishes](../investigations/2026-08-16-run-livelock-compaction-thrash.md);
verified against the live DeepSeek endpoint.

## Symptom and impact

Every compaction in the affected run logged the same warning, with no successful
summary anywhere in the log:

```
[WARN] compaction summary failed (EmptyResponse), trying local extractive summary
```

The run still made progress on this axis, because `localSummary`
(src/agent/loop.zig:1425) produces an extractive fallback. The costs are the
round trip, and a summary that is a clipped transcript rather than a distillation.

## Reproduction

Deterministic. Replay the request `summarizeMessages` builds — one user message,
`max_tokens: 512`, `temperature: 0.2`, `reasoning_effort: "low"`, no tools — with
a 12,000-character transcript of real source code as the excerpt, against
`api.deepseek.com` with `deepseek-v4-flash`:

```
finish_reason: length
content len: 0 | reasoning len: 1978
reasoning_tokens: {'reasoning_tokens': 512}
```

Expected: 3-5 bullet points. Actual: every one of the 512 completion tokens was
spent on reasoning, the content field is empty, and
`resp.message.content orelse return error.EmptyResponse` (src/agent/loop.zig:1575)
fires.

The near miss is as informative. The same request with an easy, repetitive
transcript:

```
finish_reason: length
content len: 250 | reasoning len: 1666
usage: completion_tokens 512, reasoning_tokens 438
```

74 tokens of summary, cut mid-word — and Clanker accepts that as a good summary,
because nothing inspects `finish_reason`.

## Root cause

`summarizeMessages` (src/agent/loop.zig:1531) requests `max_tokens = 512`
(src/agent/loop.zig:1573). That figure was chosen for "3-5 concise bullet points",
which is right for a non-thinking model. For a thinking model the same number is
the *combined* budget for chain-of-thought and answer:
`clampedMaxTokens` (src/llm/providers/common.zig:46) passes it straight through as
`max_tokens`, and `writeSamplingParams` (src/llm/providers/common.zig:54) still
applies the model's configured `reasoning_effort`, because the summary call goes
through the ordinary request path with no opt-out. Reasoning runs first, so on
any non-trivial excerpt it consumes the entire allowance before a single content
token is emitted.

Three smaller gaps sit on the same path:

- `resp.reasoning` is populated by the provider (src/llm/providers/openai.zig:267)
  and holds 1,978 characters of exactly the analysis being asked for, but the
  summary path ignores it.
- `resp.finish_reason` is parsed (src/llm/providers/openai.zig:265) and ignored,
  so `"length"` with partial content is indistinguishable from a complete answer.
- The failure is not remembered. Once it has failed, the next compaction pays the
  same round trip to fail identically — 170+ times in the observed run.

## Resolution

Not yet implemented. The changes that address the root cause:

1. **Budget the summary call for the model it runs on.** Either raise
   `max_tokens` for this call well above the reasoning allowance, or send an
   explicit low/none `reasoning_effort` for it — the request is a mechanical
   distillation and does not need chain-of-thought. Sending both is fine.
2. **Use the reasoning text when content is empty.** It is the same model
   answering the same prompt; falling back to `resp.reasoning` beats falling back
   to a clipped transcript.
3. **Treat truncation as a failure.** `finish_reason == "length"` with short or
   empty content should be a distinct error that names the cause, instead of a
   generic `EmptyResponse` or a silently accepted half-summary.
4. **Stop retrying a summarizer that has failed.** After a small number of
   failures in one run, go straight to the extractive summary and log the reason
   once.

## Verification

Pending. The fix must show, against the reproduction above, a non-empty summary
with `finish_reason` other than `length`; and, on a run with a thinking model, at
most one `compaction summary failed` line instead of one per compaction.

## Follow-up

Worth auditing every other internal LLM call that sets a small `max_tokens` while
the model is a thinking model — the advisor and any classifier calls on the same
request path share this failure mode.

## References

- Investigation: [`2026-08-16-run-livelock-compaction-thrash.md`](../investigations/2026-08-16-run-livelock-compaction-thrash.md)
- Related bug: [`2026-08-16-compaction-cannot-shrink-immovable-history.md`](2026-08-16-compaction-cannot-shrink-immovable-history.md)
- Code: `src/agent/loop.zig` (1425, 1531, 1573, 1575), `src/llm/providers/common.zig` (46, 54),
  `src/llm/providers/openai.zig` (265, 267)
- Fix: none yet
