# PRD — Provider extra_body

## Status

Draft. Implement-now: phase 1. Decision: [ADR 0034](../adrs/0034-openai-compat-extra-body-is-a-provider-json-object-merged.md). RFC: [0022](../rfcs/0022-extra-body.md). Source of truth once shipped: `src/config.zig` Provider.extra_body + parseProvider, `src/llm/providers/common.zig` mergeExtraBody, openai/azure buildRequest.

## Problem

OpenAI-compat gateways that require non-standard top-level body fields (NVIDIA NIM chat_template_kwargs) cannot enable thinking. clanker writes a closed chat body, so those models reply without reasoning or hang.

Constraint: providers are a native vtable (ADR 0004). The request body is built on the host hot path and must not enter a WASM guest. extra_body is therefore config plus a merge in the openai_compat codec, not a transform plugin.

## Goals

1. extra_body parses from provider config as a JSON object and is refused at load if it is not an object.  2. openai_compat and azure request bodies merge extra_body keys last, overriding same-name generated fields.  3. Empty extra_body is omitted and does not change the body.  4. Host tests drive merge and config parse from the shipped functions.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

Anthropic Messages extra fields (different body). A new ProviderKind. A WASM request transform (ADR 0004). Env-only overlay as the store. Multi-account login.

## Design

**Store.** Provider.extra_body is a JSON object string, empty meaning none. parseProvider accepts a TOML/JSON object (stringified) or a JSON object string. Any other type fails the load.

**Merge.** After openai.zig (and azure, which reuses that buildRequest) produces the body, mergeExtraBody in common.zig overlays extra_body keys last. Same-name keys overwrite. Empty extra_body is a no-op.

**Why native.** The body is the provider hot path. A guest rewrite would put prompts in the sandbox.

**Dependencies.** Hard: ADR 0004, ADR 0034, src/config.zig parseProvider, src/llm/providers/openai.zig. Soft: docs/configuration.md.

**Implementation.**

1. implement-now: extra_body field + parse + mergeExtraBody + tests. Files: src/config.zig, src/llm/providers/common.zig, src/llm/providers/openai.zig (call merge), tests in those files.
2. later: optional CLANKER_OPENAI_EXTRA_BODY overlay that wins on key collision. Files: src/llm/providers/common.zig.
3. later: per-model extra_body on Model settings. Files: src/config.zig Model.

## Failure modes

| Condition | Behaviour |
|---|---|
| extra_body missing or empty | Body unchanged |
| extra_body not an object at load | Config load fails; provider unusable |
| extra_body names model or max_tokens | Those keys overwrite generated fields (documented) |
| Merge JSON parse fails at request (should not after load) | Log and send the unmerged body |

## Acceptance criteria

1. [x] Config with extra_body as a JSON object string loads (Goal 1)
2. [x] openai_compat buildRequest with extra_body {"chat_template_kwargs":{"thinking":true}} contains that object at the top level (Goal 2)
3. [x] The same extra_body overrides a generated field of the same name (Goal 2)
4. [x] Empty extra_body leaves a baseline body byte-identical (Goal 3)
5. [x] Tests call mergeExtraBody and parseConfig, not a copy of them (Goal 4)

## Open questions / future work

Optional env overlay (phase 2) and per-model extra_body (phase 3). Not blockers.
