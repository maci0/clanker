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
`.anthropic_thinking` arm that writes
`{"thinking":{"type":"enabled","budget_tokens":N}}` with `N` derived from the
effort level and clamped below `max_tokens`. Note that Anthropic also
constrains `temperature` when thinking is enabled, so the two writes in
`writeSamplingParams` are not independent.

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
