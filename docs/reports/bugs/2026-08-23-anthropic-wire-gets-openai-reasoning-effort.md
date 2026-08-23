# Bug — the Anthropic wire is sent OpenAI's reasoning_effort field, and no thinking_schema value produces a valid Anthropic block

## TL;DR

- **What failed:** Provider.effectiveThinkingSchema defaults to .reasoning_effort for every kind, and anthropic.buildBody calls the shared writeSamplingParams. So --reasoning-effort, [agent] reasoning_effort, or a PRD 0024 profile row puts a top-level reasoning_effort field on POST /v1/messages, which Anthropic rejects as an extra input. The .thinking alternative writes GLM's shape and omits budget_tokens, which Anthropic requires, so only thinking_schema = none avoids a 400 and it discards the effort.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

`Provider.effectiveThinkingSchema` (`src/config.zig`) ends in
`orelse .reasoning_effort` — the same default for every wire kind — and
`anthropic.buildBody` calls the shared `common.writeSamplingParams`. That
`switch` writes a flat top-level `"reasoning_effort": "<level>"` for the
`.reasoning_effort` arm.

`anthropic.buildBody` serves four kinds: `anthropic`, `claude`,
`vertex_anthropic`, and `vertex` for Claude SKUs. None sets `thinking_schema`,
and the shipped `config.toml` `[providers.anthropic]` / `[models."anthropic/…"]`
set neither. Three triggers, none needing special config:

- `clanker run --reasoning-effort high` or `[agent] reasoning_effort`,
- `POST /api/run` with `reasoning_effort`, or the TUI `/effort`,
- the PRD 0024 profile table, which returns `medium`/`high` for any model whose
  `capabilities` contain `"thinking"` — and `models_dev` maps models.dev
  `reasoning: true` to that capability, which every Claude SKU has. With a
  models.dev snapshot present this fires on **every** turn with no user opt-in.

`docs/configuration.md` already scopes the field to "the OpenAI-compatible wire
(Ollama, DeepSeek, OpenAI, …)". Nothing in code enforces that.

The `.thinking` escape hatch does not help: it writes
`{"thinking":{"type":"enabled"}}`, which is GLM/Zhipu's shape. Anthropic
requires `budget_tokens` alongside `type: "enabled"`, and `grep -rn budget_tokens
src/` has no hits at all — clanker cannot construct a valid Anthropic extended
thinking block. Only `thinking_schema = "none"` avoids a 400, and it silently
discards the effort the operator asked for.

## Reproduction

Not reproduced against the real endpoint: no Anthropic credential is available
in this environment, which is why this is filed rather than fixed. Reproducing
it is one `clanker run --reasoning-effort high --provider anthropic "hi"` with a
working `ANTHROPIC_API_KEY`; the expected result is
`400 invalid_request_error`, "Extra inputs are not permitted".

There is no test covering sampling params on the Anthropic body at all:
`grep -n "reasoning_effort\|temperature" src/llm/providers/anthropic.zig`
returns only stream-parsing hits.

## Root cause

One default (`orelse .reasoning_effort`) shared by every wire kind, plus one
shared `writeSamplingParams` used by wires that do not accept the field.

## Resolution

Open. The shape that fits the existing design is a per-kind default in the
provider registry entry (the same place `auth` and `tool_schema` already vary
by kind) rather than a `kind ==` check in `common.zig`, plus a real
`.anthropic_thinking` arm.

**Corrected 2026-08-23 — read the Correction section below before implementing
this.** That arm must write `{"thinking":{"type":"adaptive"}}` and carry the
level in `output_config.effort`. The `{"type":"enabled","budget_tokens":N}` shape
originally proposed here is removed from every current Claude model and returns
a 400, so implementing it as written would replace one rejected body with
another. The sampling writes want dropping for these kinds rather than
reconciling: `temperature`, `top_p` and `top_k` are rejected outright on those
models, not merely constrained alongside thinking.

Deliberately not fixed blind: a wire-format change that cannot be checked
against the real endpoint is exactly the change that should not ship on a code
read alone.

## Verification

Needs an `ANTHROPIC_API_KEY` in the loop. Body-shape assertions on
`anthropic.buildBody` are necessary but not sufficient here — the question is
what the endpoint accepts.

## Follow-up

`gemini`/`vertex`-Gemini has the mirror-image gap: `gemini.zig` re-implements
`writeSamplingParams`' two `orelse` chains inline and drops
`rec.reasoning_effort` on the floor, writing no `thinkingConfig` at all. The
PRD 0024 table's thinking row is inert for those kinds.

## References

- PRD: [0024-sampling-profiles.md](../../prds/0024-sampling-profiles.md)
- Docs: `docs/configuration.md` (`reasoning_effort`, `thinking_schema`)
- Code: `src/config.zig` (`effectiveThinkingSchema`),
  `src/llm/providers/common.zig` (`writeSamplingParams`),
  `src/llm/providers/anthropic.zig` (`buildBody`),
  `src/llm/sampling_profiles.zig`, `src/llm/models_dev.zig`

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Correction — the finding holds, the stated mechanism is stale (2026-08-23)

Checked against the Anthropic Messages API reference and this tree. **The
headline is confirmed:** `reasoning_effort` is an OpenAI field with no Anthropic
equivalent — Anthropic controls depth with `output_config.effort`, nested, not a
top-level field — and `writeSamplingParams` does put it on the Anthropic body by
default. Verified in `src/llm/providers/common.zig`: the `.reasoning_effort` arm
writes a flat `"reasoning_effort"`, `effectiveThinkingSchema` defaults to it for
every kind (`src/config.zig:357`), and `anthropic.zig` is one of the callers.

**Two supporting claims are wrong, and the proposed fix follows from them.**
They describe the pre-Claude-4.6 API:

1. *"Anthropic requires `budget_tokens` alongside `type: enabled`"* — no longer.
   `budget_tokens` is **removed** on Opus 4.7, Opus 4.8, Opus 5, Sonnet 5 and
   Fable 5, and sending it returns a 400. It is required only on pre-4.6 models.
   So `grep -rn budget_tokens src/` returning nothing is correct behaviour for
   any current model, not evidence of the defect.
2. *"Anthropic also constrains `temperature` when thinking is enabled"* — on
   those same models `temperature`, `top_p` and `top_k` are removed outright and
   400 on any value. Stronger than "constrained", and it means the two writes in
   `writeSamplingParams` are not merely coupled: neither belongs on the wire.

**The current shapes.** The on-mode is `{"thinking":{"type":"adaptive"}}`;
`type: "enabled"` is itself gone. So the `.thinking` arm is invalid on current
models, as the record says — but because `enabled` is obsolete, not because a
budget is missing. `"none"` maps to `{"type":"disabled"}`, which *is* accepted on
Opus 4.8 and Sonnet 5; on Opus 5 only at effort `high` or below (400 at `xhigh`
/ `max`); and never on Fable 5, where the field must be omitted entirely. So the
`.none` escape hatch is closer to correct than the record credits, and its real
cost is the discarded effort, not a 400.

**Consequence for the fix:** an `.anthropic_thinking` arm writing
`{"type":"enabled","budget_tokens":N}` — the Resolution as originally written —
would 400 on every model anyone would run today. The correct target is
`{"thinking":{"type":"adaptive"}}` plus `output_config.effort` carrying the
level, and dropping the sampling writes for these kinds rather than reconciling
them.

The Verification note stands unchanged and is the reason this is still Open: no
Anthropic key here, and a wire-format change should not ship on a code read.
This correction is itself a documentation read, not an endpoint test.
