# Bug — The autolearn synthesis grant is spent entirely on reasoning

## TL;DR

- **What failed:** `clanker --model deepseek-v4-pro autolearn` exited with
  `autolearn: synthesizer returned an empty section`.
- **Impact:** the synthesis pass is unusable on any reasoning model, and the
  run exits non-zero. The deterministic Autolearn section is written before
  synthesis runs, so `docs/ROADMAP.md` was still updated — the failure loses
  the LLM rewrite, not the run.
- **Resolution:** Resolved on 2026-08-17. Grant raised to 16000 in tools/zig/autolearn_logic.zig synthesis_max_tokens and tools/manifests/autolearn.tool.json; emptyCompletionCause in src/sandbox/host.zig names the cause. Verified by rerunning clanker --model deepseek-v4-pro autolearn (4458 completion tokens, section written) and clanker gate all-pass.
  together to 16000 tokens (`tools/zig/autolearn_logic.zig`
  `synthesis_max_tokens`), and `ck_llm` now logs why any completion came back
  with no content.

## Status

Resolved on 2026-08-17. Grant raised to 16000 in tools/zig/autolearn_logic.zig synthesis_max_tokens and tools/manifests/autolearn.tool.json; emptyCompletionCause in src/sandbox/host.zig names the cause. Verified by rerunning clanker --model deepseek-v4-pro autolearn (4458 completion tokens, section written) and clanker gate all-pass.

## Symptom and impact

The command produced one LLM call and then failed:

```
[INFO] ts_ms=1786955454946 [llm] → ck_llm
[INFO] ts_ms=1786955496173 [llm] ✓ ck_llm … 41226ms (~18423 est. tokens)
autolearn: synthesizer returned an empty section
error: the internal tool returned an error; run `clanker doctor` to check the build
```

The call is logged as a success, because it was one: HTTP 200, usage
accounted. `state/token_stats.jsonl` records it as
`completion_tokens: 2500` against a 2500-token grant — the budget was spent
to the last token.

The deterministic aggregation had already been written. `upsertRoadmap` runs
at `tools/zig/autolearn.zig:202`, before the synthesis block, so the failing
run still left the mechanical `## Autolearn` section in `docs/ROADMAP.md`.

## Reproduction

Deterministic against the live endpoint. Any request to a reasoning model
whose `max_tokens` is smaller than its reasoning spend:

```
curl -s https://api.deepseek.com/chat/completions -H "Content-Type: application/json" -H "Authorization: Bearer $DEEPSEEK_API_KEY" -d '{"model":"deepseek-v4-pro","max_tokens":64,"messages":[{"role":"user","content":"Rewrite this list as three roadmap bullets: cache hit rate low, repeated tool calls, missing tool foo."}]}'
```

Run on 2026-08-17, this answered 200 with:

```
"content":"","reasoning_content":"We need answer user. Need rewrite list as three roadmap bullets. …"
"finish_reason":"length"
"completion_tokens":64,"completion_tokens_details":{"reasoning_tokens":64}
```

Every completion token went to reasoning; `content` is the empty string.

## Root cause

`max_tokens` bounds *output*, and on a reasoning model reasoning is output.
The provider fills `reasoning_content` first and only then emits `content`,
so a grant sized for the answer alone is exhausted before a visible token
exists.

Three layers each hid part of this:

- `tools/manifests/autolearn.tool.json` granted `config.max_tokens: 2500` and
  `tools/zig/autolearn.zig` requested the same 2500 — a figure sized for the
  section text, not for a model that thinks first. The synthesis actually
  needs more: the fixed run spent 4458 completion tokens, so 2500 could not
  have produced a section on this model under any prompt.
- `ckLlm` (`src/sandbox/host.zig`) returned `resp.message.content orelse ""`,
  dropping `resp.finish_reason` and `resp.reasoning`. Both were parsed
  (`src/llm/providers/openai.zig` sets `.reasoning` from
  `reasoning_content`) and both were discarded, so a truncated reasoning
  spend and a model that genuinely answered nothing reached the guest as the
  same empty string.
- The guest could then only report the symptom. `synthesizer returned an
  empty section` is what an operator saw, with nothing pointing at the grant.

This is the follow-up
[`2026-08-16-compaction-summary-budget-spent-on-reasoning.md`](2026-08-16-compaction-summary-budget-spent-on-reasoning.md)
predicted: "worth auditing every other internal LLM call that sets a small
`max_tokens` while the model is a thinking model". The compaction path was
fixed there; the `ck_llm` guests were not audited.

## Resolution

Two parts, one per layer that hid the cause.

1. **The grant is sized for a model that reasons.**
   `tools/zig/autolearn_logic.zig` gains `synthesis_max_tokens = 16000`, used
   by the guest's `ck_llm` call and matched by `config.max_tokens` in
   `tools/manifests/autolearn.tool.json`. The two must move together because
   `clampCkLlmMaxTokens` lets a guest only lower the descriptor grant, never
   raise it, so a guest-side raise alone would be silently clamped away.
2. **An empty completion says why it is empty.**
   `emptyCompletionCause` in `src/sandbox/host.zig` classifies the three
   cases from `content`, `finish_reason` and `reasoning`: a truncated
   reasoning spend (naming `config.max_tokens` as the fix), a truncation with
   no reasoning, and a model that simply returned nothing. `ckLlm` logs it as
   a warning with the completion tokens spent against the grant.

The guest still receives the empty string rather than an error, so a
fail-open caller — `thinking`, `advisor` — degrades exactly as before.

## Verification

`clanker --model deepseek-v4-pro autolearn` completes and writes a synthesized
`## Autolearn` section of `- [ ]` items. `state/token_stats.jsonl` for that
run:

```
"completion_tokens":4458,"total_tokens":20381,"ok":true
```

4458 output tokens is the quantitative confirmation: it is above the old 2500
cap, so no prompt could have made the old grant work on this model.

`zig build test` covers the classifier directly — "ck_llm names why a
completion came back with no visible content" in `src/sandbox/host.zig` pins
all three cases and the content-present case. The test was written first and
failed on the undeclared identifier before the function existed.

## Follow-up

The audit the compaction bug asked for is still not finished. Grants of the
other `"llm": true` descriptors, read from `tools/manifests/` on 2026-08-17:

| tool | `config.max_tokens` |
|---|---|
| `thinking` | 5 |
| `advisor` | 256 |
| `compare` | 600 |
| `arena` | 1400 |
| `chain`, `mutate`, `translate` | 2048 |
| `smart_commit` | 4096 |
| `providers`, `rlm`, `subagent`, `swarm` | grant default 1024 |

Each of these is below a reasoning model's spend on a non-trivial prompt, so
each returns empty content on one. What that costs differs per tool and none
of it is measured here: `thinking` and `advisor` fail open, so they degrade
silently; `compare` and `translate` surface an empty answer. Raising them is
not done and each needs its own sizing.

## References

- Related bug: [`2026-08-16-compaction-summary-budget-spent-on-reasoning.md`](2026-08-16-compaction-summary-budget-spent-on-reasoning.md)
  — same failure mode on the compaction path, and the follow-up that named this one.
- Code: `src/sandbox/host.zig` (`ckLlm`, `emptyCompletionCause`,
  `clampCkLlmMaxTokens`), `tools/zig/autolearn.zig`,
  `tools/zig/autolearn_logic.zig` (`synthesis_max_tokens`),
  `tools/manifests/autolearn.tool.json`,
  `src/llm/providers/openai.zig` (`parseResponse` sets `.reasoning`)
