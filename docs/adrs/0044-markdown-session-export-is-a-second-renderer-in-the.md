# ADR 0044 — Markdown session export is a second renderer in the session_export guest

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0032 — How session export grows a markdown form](../rfcs/0032-session-export-md.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Kimi /export-md writes markdown. Clanker export is HTML-only. RFC 0032 compared same-guest format=md, a second guest, copy-from-TUI, and status quo.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

session_export grows format html|md. Markdown is role headings plus fenced literal bodies. Untrusted text is never parsed as CommonMark HTML.

> The RFC recommended: **Recommended option:** Adopt Option A: format=md on the existing session_export guest, preformatted text


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

A readable share exists beside the safe HTML file. Honest downside: two renderers must both learn new message fields.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
