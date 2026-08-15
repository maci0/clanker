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

**How much of the budget goes to reasoning varies between replays, so the
severity does too.** A later replay of the same 512-token request against the
same model and transcript spent only 57 tokens on reasoning and returned 1,891
characters — still `finish_reason: length`, so still truncated, just not empty.
Under the old budget every replay was degraded, in one of those two ways; which
one is not predictable. The affected production run got the empty variant on
every compaction across 170+ iterations.

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

Fixed in `d2628464` (`src/agent/loop.zig`), in four parts.

1. **The summary call is budgeted for the model it runs on.**
   `summarizeMessages` asks `sampling.hasThinking` about the active model and
   requests `summary_thinking_max_tokens` (4096) instead of `summary_max_tokens`
   (512) when the model reasons, and sends `reasoning_effort: "low"` for this
   call specifically. Distilling a transcript into bullets does not need
   deliberation, and the per-call override beats the model's configured effort
   in `writeSamplingParams`, so this cannot be undone by configuration.
2. **Reasoning stands in for empty content.** When content is empty and
   `resp.reasoning` is not, the reasoning text is used as the summary (capped at
   `summary_reasoning_cap`) with a warning. It is the same model working the same
   prompt; it beats dropping to the extractive clip.
3. **Truncation is named.** `finish_reason == "length"` with empty content is
   `error.SummaryTruncated` rather than a generic `EmptyResponse`, and a
   truncated-but-present summary is used with a warning instead of being accepted
   silently.
4. **A failed summarizer is not retried all run.** `compactionSummary` counts
   failures; after `max_summary_failures` (2) it goes straight to the extractive
   summary and says so once:
   `compaction summary failed (SummaryTruncated), trying local extractive summary; further compactions in this run summarize locally`.

## Verification

The same request, replayed against `api.deepseek.com` with
`deepseek-v4-flash` and 12,000 characters of real source, old shape against new:

| request | finish_reason | content | reasoning tokens |
|---|---|---|---|
| old: `max_tokens 512`, effort from model config | `length` | 1,891 chars, truncated | 57 |
| new: `max_tokens 4096`, effort `low` for this call | `stop` | 951 chars, complete | 289 |

The new shape completes; the old one was still truncating on the same input.
An earlier replay of the old shape returned empty content with all 512 tokens
spent on reasoning, which is the variant the production run hit.

In the mock-provider reproduction (a provider that always answers the summary
request with empty content and `finish_reason: length`), the failure is now
reported as `SummaryTruncated` rather than `EmptyResponse`, and the third
compaction onward summarizes locally without a round trip.

## Follow-up

Worth auditing every other internal LLM call that sets a small `max_tokens` while
the model is a thinking model — the advisor and any classifier calls on the same
request path share this failure mode.

## References

- Investigation: [`2026-08-16-run-livelock-compaction-thrash.md`](../investigations/2026-08-16-run-livelock-compaction-thrash.md)
- Related bug: [`2026-08-16-compaction-cannot-shrink-immovable-history.md`](2026-08-16-compaction-cannot-shrink-immovable-history.md)
- Code: `src/agent/loop.zig` (`summarizeMessages`, `compactionSummary`, `localSummary`),
  `src/llm/providers/common.zig` (`clampedMaxTokens`, `writeSamplingParams`),
  `src/llm/providers/openai.zig` (`parseResponse`), `src/llm/sampling_profiles.zig` (`hasThinking`)
- Fix: `d2628464`
