# ADR 0039 — Foreign transcripts import as new clanker sessions, Claude Code JSONL first

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0027 — Whether clanker imports foreign harness session transcripts](../rfcs/0027-foreign-session-resume.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

jcode resumes Claude Code, Codex, OpenCode, and pi sessions. clanker resumed only its own store (ADR 0033). RFC 0020 drives those CLIs as children, which does not help after they crash. RFC 0027 compared a guest parser, driving the CLI, paste, and HTML export.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Import writes a new clanker session via a host-tested parser. Phase 1 is Claude Code JSONL, fail-closed on unknown schema. Other harnesses are later phases. Do not mutate the foreign file. Do not write back to their format.

> The RFC recommended: **Recommended option:** Option A: guest parser writing a new clanker session, Claude Code JSONL first


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

A dead Claude Code session can continue here with tool history. The honest downside: we own adapter rot as their JSONL drifts; fail-closed means a format bump is a hard error until the parser is updated, not a silent partial import. RFC 0020 remains the way to drive a live vendor CLI.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
