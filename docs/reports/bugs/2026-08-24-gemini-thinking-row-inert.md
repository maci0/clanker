# Bug — gemini and vertex-Gemini write no thinkingConfig, so the PRD 0024 thinking row is inert there

## TL;DR

- **What failed:** generationConfig has no reasoning_effort equivalent, so a pinned --reasoning-effort and the profile table's thinking row are both silently discarded for kind = gemini and for vertex on a Gemini model. The duplicated orelse chains in gemini.zig are gone as of 2026-08-24; the missing thinkingConfig write is not, because the correct generateContent shape could not be established from the tree or from Google's docs. Deliberately not guessed.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Blocked on

The exact `generationConfig` thinking field names from the Gemini API
reference plus a live 200 against a real key. `GEMINI_API_KEY` is not in
this checkout's `.env`, and the shape was deliberately not guessed (see
"Why the shape was not guessed" below). Clear this body when a key and
the reference shape are available.

## Symptom and impact

`gemini.zig`'s `buildRequest` writes `generationConfig` with `temperature`,
`topP`, `maxOutputTokens` and (optionally) `responseMimeType`. There is no
reasoning field of any kind. So for `kind = "gemini"`, and for `kind =
"vertex"` on a model `isAnthropicModel` does not match:

- `clanker run --reasoning-effort high` is accepted, logged, and discarded.
  Same for `[agent] reasoning_effort`, `POST /api/run`'s `reasoning_effort`,
  and the TUI `/effort` pin.
- A `[models."gemini/…"] reasoning_effort = "..."` in `config.toml` is
  likewise never sent.
- PRD 0024's thinking row — the one that fires for any model whose
  `capabilities` contain `"thinking"`, which `providers fill` derives from
  models.dev `reasoning: true` — is inert. A Gemini thinking SKU therefore
  gets no reasoning field *and* no temperature, since the table returns the
  effort row instead of the temperature row for those models.

The last point is the one worth flagging: a thinking-capable Gemini model
currently ships a `generationConfig` carrying only `maxOutputTokens`. It is
not that the effort is lost and a temperature ships in its place; both are
absent.

The impact is a silently ignored operator control, not a failed request:
Gemini accepts the body as sent.

## Reproduction

Not reproduced against the real endpoint: no Gemini credential is available
in this checkout (`.env` holds `DEEPSEEK_API_KEY` only). Reproducing it does
not need one — the field is absent from the emitted body, so a wire capture
against a loopback recorder shows it. Point a `kind = "gemini"` provider at a
recorder, give its model `capabilities = ["thinking"]`, and run
`clanker run --provider <name> --reasoning-effort high "hi"`; the captured
`generationConfig` carries `maxOutputTokens` and nothing else.

## Root cause

`generationConfig` has no `reasoning_effort` slot, so there was nothing for
`writeSamplingParams` to write even if this codec had called it — and it did
not: it re-implemented the precedence chain inline for `temperature`/`topP`
and simply never computed the effort at all.

## Partial fix, 2026-08-24

Half of the original PRD 0024 known issue 3 is fixed. `gemini.zig` no longer
keeps its own copy of the precedence chain: it calls
`common.resolveSampling`, which returns all three resolved knobs, and spells
`topP` itself. That removes the drift risk the PRD named ("any field added to
`Profile` later is silently absent from Gemini requests") — a new field is now
at least visible to this codec.

The `thinkingConfig` write is **not** done. That is deliberate.

## Why the shape was not guessed

The correct `generateContent` request shape could not be established:

- Nothing in the tree documents it. `grep -rn thinkingConfig` has no hits;
  `state/models-dev.json` carries `reasoning: true` as a capability flag and
  no wire shape.
- Google's own thinking documentation (`ai.google.dev/gemini-api/docs/thinking`,
  read 2026-08-24) documents `thinking_level` with `low`/`medium`/`high` and
  `thinking_summaries` for the **Interactions API**, and states outright that
  "the Interactions API handles thoughts and signatures differently than the
  `generateContent` API" without giving the `generateContent` fields. So the
  one string-valued effort knob that page does name is on an API clanker does
  not speak.
- The alternatives recalled from elsewhere — `thinkingConfig.thinkingBudget`
  as an integer token count, `thinkingConfig.includeThoughts`,
  `thinkingConfig.thinkingLevel` — differ by model generation, and mapping
  clanker's five-level `ReasoningEffort` enum onto a token count would be an
  invented number, not a translation.

Writing one anyway is the exact mistake the sibling Anthropic report
catalogues: its original Resolution proposed
`{"thinking":{"type":"enabled","budget_tokens":N}}` from a code read, and a
later Correction found that shape is removed from every current model and
400s — so implementing it as written would have replaced one rejected body
with another. A body-shape unit test would have passed in both cases, which
is why a passing test is not the bar here.

## Resolution

Open. Closing it needs the `generateContent` reasoning fields established
from the API reference (not the thinking guide) for the model generations
clanker actually configures, and then a live 200 from a real key. Until then
a pinned effort is silently dropped on these kinds, which is at least a
no-op rather than a 400.

## References

- PRD: [0024-sampling-profiles.md](../../prds/0024-sampling-profiles.md),
  known issue 3
- Sibling: [the Anthropic wire report](2026-08-23-anthropic-wire-gets-openai-reasoning-effort.md),
  whose Correction section is the reason this one was not guessed
- Code: `src/llm/providers/gemini.zig` (`buildRequest`),
  `src/llm/providers/vertex.zig` (`buildRequest`, the Gemini branch),
  `src/llm/providers/common.zig` (`resolveSampling`),
  `src/llm/sampling_profiles.zig`

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
