# ADR 0036 — repo_search attaches enclosing symbols to grep hits

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0024 — Whether repo_search attaches enclosing symbols to grep hits](../rfcs/0024-agent-grep-outline.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

jcode agent-grep returns enclosing functions with each hit. clanker repo_search returned file:line:text and symbols.zig looked up declarations by name, so the model paid a follow-up read to learn which function a hit sat in. RFC 0024 compared an enclosing walk, prompt-guidance, the status quo, and relying on ast-grep default.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Attach enclosing symbol (kind, name, declaration line) on repo_search hits via a host-tested helper, Zig first with a weak generic fallback. No new catalog tool. Adaptive seen-set truncation is a later phase.

> The RFC recommended: **Recommended option:** Option A: attach enclosing symbols on repo_search hits via a host-tested helper, Zig first


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

One grep call carries file shape. The honest downside: the walk is a heuristic, not an AST, and will mis-attribute hits in unusual macros or generated files. Extra bytes per hit must be capped. ast-grep remains a separate engine, not a replacement for this field.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
