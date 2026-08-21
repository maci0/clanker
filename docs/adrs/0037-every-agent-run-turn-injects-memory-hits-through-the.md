# ADR 0037 — Every Agent.run turn injects memory hits through the existing guest

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0025 — Whether every agent turn injects memory hits without a tool call](../rfcs/0025-passive-memory-inject.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

memorySearch ran only on /api/run. REPL and clanker run required the model to call the memory tool. jcode injects every turn. RFC 0004 out-of-scoped Muninn auto-inject; this is PRD 0007 hash-embed applied to every turn. RFC 0025 compared loop inject, a sidecar verifier, the status quo, and learnings.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Before the first completion of an Agent.run turn, call the memory WASM search the same way handleRun does, with the same untrusted fence and byte cap. No ONNX. No sidecar in v1. Extraction is a later PRD phase.

> The RFC recommended: **Recommended option:** Option A: inject memorySearch on every Agent.run turn via the existing guest and fence; no ONNX, no sidecar in v1


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

REPL, run, and web UI share one RAG story. The honest downside: hash-embed recall is weak and junk hits cost tokens every turn; fail-open on search error so a Knowledge listing failure cannot block a turn. This is not a Muninn graph and does not reopen RFC 0004.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
