# ADR 0034 — openai_compat extra_body is a provider JSON object merged last

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0022 — How openai-compat extra_body is merged into chat requests](../rfcs/0022-extra-body.md).

## Context

NVIDIA NIM and similar gateways require non-standard top-level chat fields. clanker wrote a closed OpenAI body, so thinking stayed off. RFC 0022 compared a config object, an env-only overlay, the status quo, and a WASM request transform.

## Decision

Store extra_body as a JSON object on the provider. Merge its keys last into openai_compat and azure chat bodies so they override generated fields. Refuse at config load if extra_body is not an object. No new ProviderKind. Env overlay is a later optional override, not the store.

> The RFC recommended: **Recommended option:** Option A: Provider.extra_body JSON object merged last on openai_compat and azure


## Consequences

Operators can send chat_template_kwargs without forking a provider file. The honest downside: merge-last can override model, max_tokens, or tools if the object names those keys; that is the documented point of the hatch, not a bug. Anthropic Messages bodies are unchanged. A WASM transform of the request was rejected because the body is the native hot path (ADR 0004) and must not enter the sandbox.
