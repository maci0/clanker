# ADR 0044 — Markdown session export is a second renderer in the session_export guest

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0032 — How session export grows a markdown form](../rfcs/0032-session-export-md.md).

## Context

Kimi /export-md writes markdown. Clanker export is HTML-only. RFC 0032 compared same-guest format=md, a second guest, copy-from-TUI, and status quo.

## Decision

session_export grows format html|md. Markdown is role headings plus fenced literal bodies. Untrusted text is never parsed as CommonMark HTML.

> The RFC recommended: **Recommended option:** Adopt Option A: format=md on the existing session_export guest, preformatted text


## Consequences

A readable share exists beside the safe HTML file. Honest downside: two renderers must both learn new message fields.
