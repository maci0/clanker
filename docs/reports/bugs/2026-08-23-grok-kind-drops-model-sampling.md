# Bug — kind = grok discards per-model temperature and top_p and never consults the PRD 0024 profile table

## TL;DR

- **What failed:** grok routes buildRequest to responses.zig, which writes temperature and top_p only from params, never from provider.activeModel() and never from sampling.forParams. params.temperature is set in only three places in the tree, none of them the agent loop, and the webui per-run override writes into the models map, the tier responses.zig does not read. So a configured per-model temperature is silently dropped on every turn, against PRD 0024 acceptance criteria 1 and 2.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

`kind = "grok"` routes `buildRequest` to `src/llm/providers/responses.zig`,
which writes `temperature`/`top_p` from `params` only — never from
`provider.activeModel()`, never from `sampling.forParams`. It is not going
through `common.writeSamplingParams` at all.

`params.temperature` is set in exactly three places in the tree: two inbound
proxy transcode paths and the auto-thinking classifier. The agent loop's own
dispatch never sets it, and the web UI's per-run override writes into the
provider's *models map* — precisely the tier `responses.zig` does not read.

So for a grok provider, a `[models."grok/grok-4.6"] temperature = 0.2` in
`config.toml` is silently discarded on every agent turn, as is the PRD 0024
profile-table default. That contradicts PRD 0024 acceptance criteria 1 and 2
("a model with an explicit `config.toml` `temperature` ships that value
unchanged regardless of use case") for that kind.

Same file, same shape: `max_output_tokens` comes only from
`params.max_tokens`, so `common.clampedMaxTokens` never runs for `grok` — the
half-the-context-window clamp does not apply there.

`codex` also skips sampling through the same file, but deliberately and with a
test saying so. `grok`'s registry entry declares `sampling: true` and has no
equivalent.

## Reproduction

Configure a grok provider with an explicit per-model `temperature` and capture
the request body; the field is absent.

## Root cause

A second, partial implementation of the sampling write next to the shared one,
reading only the top tier of a three-tier precedence chain.

## Resolution

Open. `responses.zig`'s sampling branch should call
`common.writeSamplingParams` (or at least the same three-tier `orelse` chain)
and `common.clampedMaxTokens`, with `codex`'s intentional opt-out staying an
explicit flag rather than an accident of which file it shares.

## Verification

Needs a body-shape test on `responses.buildRequest` asserting a per-model
`temperature` reaches the wire, plus one that `codex` still omits it.

## Follow-up

`gemini.zig` has a related-but-different version of this: it re-implements
`writeSamplingParams`' two `orelse` chains inline and correctly honours
`temperature`/`top_p`, but computes `rec.reasoning_effort` and throws it away,
writing no `thinkingConfig`. The profile table's thinking row is inert for
`gemini` and for `vertex`-Gemini. Filed with the Anthropic wire report.

## References

- PRD: [0024-sampling-profiles.md](../../prds/0024-sampling-profiles.md)
- Code: `src/llm/providers/responses.zig`, `src/llm/providers/grok.zig`,
  `src/llm/providers/codex.zig`, `src/llm/providers/common.zig`
  (`writeSamplingParams`, `clampedMaxTokens`), `src/cli.zig`
  (`applySamplingOverride`)

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
