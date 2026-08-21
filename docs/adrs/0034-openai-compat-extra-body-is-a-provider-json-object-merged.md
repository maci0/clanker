# ADR 0034 — openai_compat extra_body is a provider JSON object merged last

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0022 — How openai-compat extra_body is merged into chat requests](../rfcs/0022-extra-body.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

NVIDIA NIM and similar gateways require non-standard top-level chat fields. clanker wrote a closed OpenAI body, so thinking stayed off. RFC 0022 compared a config object, an env-only overlay, the status quo, and a WASM request transform.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Store extra_body as a JSON object on the provider. Merge its keys last into openai_compat and azure chat bodies so they override generated fields. Refuse at config load if extra_body is not an object. No new ProviderKind. Env overlay is a later optional override, not the store.

> The RFC recommended: **Recommended option:** Option A: Provider.extra_body JSON object merged last on openai_compat and azure


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Operators can send chat_template_kwargs without forking a provider file. The honest downside: merge-last can override model, max_tokens, or tools if the object names those keys; that is the documented point of the hatch, not a bug. Anthropic Messages bodies are unchanged. A WASM transform of the request was rejected because the body is the native hot path (ADR 0004) and must not enter the sandbox.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
