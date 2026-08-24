# RFC 0022 — How openai-compat extra_body is merged into chat requests

## Status

Decided — 2026-08-21. ADR 0034

## Overview

NVIDIA NIM and similar OpenAI-compat gateways require non-standard top-level body fields (chat_template_kwargs) that clanker currently cannot send. Decide how extra_body is stored and merged without violating ADR 0004.

**Decision to make.** How is extra_body stored and merged into openai_compat (and azure) chat request bodies?

**Why now.** NVIDIA NIM DeepSeek-V4 and similar gateways only enable thinking when chat_template_kwargs is present; without it they reply with no reasoning or hang. clanker has no way to send that field. jcode inventory: docs/research/jcode-features.md.

**Drivers.** ADR 0004: providers stay a native vtable; extra_body is harness, not a WASM guest. Merge last so it can override generated keys the way jcode documents. Invalid extra_body must not 400 the model by accident at request time if we can refuse at config load. No new dependency.

**Out of scope.** Anthropic Messages extra fields (different body). Multi-account login. New ProviderKind tags. Proxy raw-forward of extra_body (the proxy already forwards client bodies 1:1).

## Current state

src/llm/providers/openai.zig buildRequest writes a closed set of OpenAI chat fields (model, messages, tools, sampling via writeSamplingParams). src/config.zig Provider has no extra_body; unknown provider keys warn and are ignored (warnUnknownKeys). Workaround: none. Operators cannot send chat_template_kwargs without forking a provider file. Files that would change: src/config.zig (Provider + parseProvider), src/llm/providers/openai.zig or a shared merge after buildRequest, config.toml examples, CHANGELOG.

## Options considered

### Option A — Provider.extra_body JSON object, merged last on openai_compat and azure

What it is: parse extra_body as a JSON object on the provider (TOML table or JSON object string), store the canonical JSON, merge keys last into the built chat body. Same-name keys overwrite clanker-generated fields. Refuse at config load if extra_body is not an object.

Maturity: jcode ships this (config table plus JCODE_OPENAI_EXTRA_BODY). Opened at source 2026-08-21.

How it would fit: src/config.zig Provider.extra_body: []const u8; parseProvider stringify; src/llm/providers/common.zig mergeExtraBody used from openai.zig (azure reuses openai.buildRequest). No new kind. Tests on merge: add, override, empty, invalid ignored at request only if load already validated.

Pros: one knob; matches the NIM need; ADR 0004 native; unit-testable without HTTP.

Cons: an operator can override model/max_tokens; that is the documented point of merge-last.

Cost to adopt: config field + merge helper + tests, one release.

Cost to leave: drop the field; old configs warn as unknown keys again.

Evidence: jcode README extra_body; src/config.zig warnUnknownKeys; openai.zig buildRequest.

### Option B — environment variable only (CLANKER_OPENAI_EXTRA_BODY)

What it is: jcode's env overlay without a config key. Process-wide, all openai_compat providers share one blob.

Maturity: jcode uses env as override on top of config.

How it would fit: read env in openai.buildRequest. No config schema change.

Pros: no config.toml edit; secrets-adjacent values stay out of the file.

Cons: cannot differ per named provider (NIM vs vLLM); env is process-wide; harder to review in git.

Cost to adopt: tiny. Cost to leave: unset the env.

Evidence: jcode README JCODE_OPENAI_EXTRA_BODY.

### Option C — status quo

What it is: keep the closed body. NIM thinking stays off.

Pros: no new override footgun.

Cons: those backends stay unusable for reasoning models.

Cost to adopt: zero now; operators fork provider files or run a sidecar proxy.

Evidence: extra_body grep empty 2026-08-21.

### Option D — out of the box: a request-transform WASM plugin

What it is: a transform guest rewrites the JSON body. Catalog already has transform chains.

How it would fit: new plugin; body would have to enter the sandbox.

Pros: no config schema.

Cons: the chat body is on the native hot path (ADR 0004); sending it through WASM per token stream is the opposite of the vtable. Keys must not enter the sandbox; a body can echo prompts.

Cost to adopt: new plugin + a host hook that does not exist. Cost to leave: disable the plugin.

Evidence: ADR 0004; toolhost transform chains.

## Implications by horizon

### Short term (this release / 0–3 months)

If A: NIM/vLLM thinking works from config.toml this release. If B: works only when the env is set, all openai_compat providers share it. If status quo: those backends stay broken. If D: no hook exists, so nothing ships.

### Medium term (3–12 months)

If A: per-model extra_body can be added later without changing the merge. If B: we will still want a per-provider config key. If status quo: more provider files get forked.

### Long term (12+ months)

If A: extra_body stays a documented escape hatch; new kinds keep using the vtable. If D: the sandbox grows a request-rewrite channel we do not want.

## Recommendation

**Recommended option:** Option A: Provider.extra_body JSON object merged last on openai_compat and azure

**Confidence:** 8/10

**Rationale.** Matches the NIM need without a new kind or a WASM rewrite of the hot path. Env-only cannot differ per provider. Status quo leaves those backends unusable. Transform plugins would put request bodies in the sandbox, which ADR 0004 forbids.

## References



- Research: [jcode feature inventory](../research/jcode-features.md) — opened at source 2026-08-21.
- ADR 0004 — providers are a native vtable.
- jcode README extra_body section (raw GitHub, 2026-08-21).
