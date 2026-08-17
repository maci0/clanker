# Bug — The autolearn synthesis grant is spent entirely on reasoning

## TL;DR

- **What failed:** `clanker --model deepseek-v4-pro autolearn` exited with
  `autolearn: synthesizer returned an empty section`.
- **Impact:** the synthesis pass is unusable on any reasoning model, and the
  run exits non-zero. The deterministic Autolearn section is written before
  synthesis runs, so `docs/ROADMAP.md` was still updated — the failure loses
  the LLM rewrite, not the run.
- **Resolution:** Resolved on 2026-08-17. Grant raised to 16000 in tools/zig/autolearn_logic.zig synthesis_max_tokens and tools/manifests/autolearn.tool.json; emptyCompletionCause in src/sandbox/host.zig names the cause. Verified by rerunning clanker --model deepseek-v4-pro autolearn (4458 completion tokens, section written) and clanker gate all-pass.

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

## The rest of the audit

Done in the same session. Every `"llm": true` descriptor, read from
`tools/manifests/` on 2026-08-17, and what it grants now:

| tool | was | now | content budget it is sized around |
|---|---|---|---|
| `thinking` | 5 | 4096 | one word; the budget is headroom |
| `advisor` | 256 | 4352 | a <150-word JSON note |
| `compare` | 600 | 4996 | its largest call, the 900-token synthesis |
| `arena` | 1400 | 5496 | its largest call, the 1400-token combatant turn |
| `chain` | 2048 | 6144 | a 2048-token `mutate` step |
| `mutate` | 2048 | 6144 | a 2048-token rewrite |
| `translate` | 2048 | 6144 | a 2048-token translation |
| `smart_commit` | 4096 | 8192 | a 4096-token JSON grouping |
| `providers` | 1024 (default) | unchanged | pings with `max_tokens: 1` and never reads the completion |
| `rlm`, `subagent`, `swarm` | 1024 (default) | unchanged | no `ck_llm` call; they reach a model through `ck_subagent`/`ck_swarm`, which the harness budgets |

Each new grant is its content budget plus `llm_budget.reasoning_headroom`.
Two of these were failing *silently*, which is why the audit mattered more than
the one reported failure: `thinking` and `advisor` are fail-open, so the effort
classifier had been returning `''` and falling through to `medium` for every
turn of every run on a reasoning model, and the advisor's note never parsed.

`thinking` and `advisor` now pass `0` (keep the grant) rather than naming a
number, so their budget has one home. `arena`, `chain` and `compare` keep
per-call numbers because their calls genuinely differ in size, and each is now
written as `budget.withHeadroom(<content>)` rather than a bare literal.

### Verified

The classifier prompt from `thinking_logic.classifyPrompt`, replayed against
`api.deepseek.com` with `deepseek-v4-pro` at the old grant and the new one:

| `max_tokens` | `finish_reason` | completion | reasoning | `content` |
|---|---|---|---|---|
| 5 | `length` | 5 | 5 | `''` |
| 4096 | `stop` | 95 | 92 | `'xhigh'` |

The 95 is the answer to the cost objection: the grant caps what a call may
generate, not what it does, so raising it does not make a non-reasoning model
dearer. `clanker compare` with two DeepSeek entrants returns full answers from
both.

## Follow-up

`toolDescriptorGate` now fails any `"llm": true` descriptor whose
`config.max_tokens` is under `llm_budget.reasoning_headroom`, so a new tool
cannot reintroduce this. It runs in the improve loop's gate set; wiring it into
`clanker gate`'s eight would mean editing `verifyGates` in `src/cli.zig`, which
another session held for the whole of this one, and is not done.

The compaction path has a second, separate exposure that is **not** fixed here:
`summarizeMessages` picks its budget with `sampling.hasThinking`, which reads
`Model.capabilities`, which `applyCatalogSpecs` leaves empty when
`state/models-dev.json` is absent — and `load` never downloads it. This
checkout has no snapshot, so `hasThinking` is false for every model here and
the 4096-token thinking branch from `d2628464` never fires. Not verified
against a live compaction; established by reading `applyCatalogSpecs` and by
`clanker providers models` reporting no capabilities for either DeepSeek model.

## References

- Related bug: [`2026-08-16-compaction-summary-budget-spent-on-reasoning.md`](2026-08-16-compaction-summary-budget-spent-on-reasoning.md)
  — same failure mode on the compaction path, and the follow-up that named this one.
- Code: `src/sandbox/host.zig` (`ckLlm`, `emptyCompletionCause`,
  `clampCkLlmMaxTokens`), `tools/zig/autolearn.zig`,
  `tools/zig/autolearn_logic.zig` (`synthesis_max_tokens`),
  `tools/manifests/autolearn.tool.json`,
  `src/llm/providers/openai.zig` (`parseResponse` sets `.reasoning`)
