# ADR 0039 — Foreign transcripts import as new clanker sessions, Claude Code JSONL first

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0027 — Whether clanker imports foreign harness session transcripts](../rfcs/0027-foreign-session-resume.md).

## Context

jcode resumes Claude Code, Codex, OpenCode, and pi sessions. clanker resumed only its own store (ADR 0033). RFC 0020 drives those CLIs as children, which does not help after they crash. RFC 0027 compared a guest parser, driving the CLI, paste, and HTML export.

## Decision

Import writes a new clanker session via a host-tested parser. Phase 1 is Claude Code JSONL, fail-closed on unknown schema. Other harnesses are later phases. Do not mutate the foreign file. Do not write back to their format.

> The RFC recommended: **Recommended option:** Option A: guest parser writing a new clanker session, Claude Code JSONL first


## Consequences

A dead Claude Code session can continue here with tool history. The honest downside: we own adapter rot as their JSONL drifts; fail-closed means a format bump is a hard error until the parser is updated, not a silent partial import. RFC 0020 remains the way to drive a live vendor CLI.
