# ADR 0041 — Composer @path mentions expand through a host-tested helper into the saved user message

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0029 — How composer @file mentions inject path contents](../rfcs/0029-file-mentions.md).

## Context

Kimi Code loads @path in the composer. Clanker has no expander. RFC 0029 compared inlining bytes, forging a tool result, /attach-for-text, and status quo.

## Decision

Inline whitespace-bounded @rel/path tokens via a host-tested helper into the saved user message. Refuse secret_dotenv and out-of-prefix paths. Cap bytes with a truncated notice.

> The RFC recommended: **Recommended option:** Adopt Option A: host-tested expander inlines fenced file bytes into the saved user message


## Consequences

Operators stop pasting files. Honest downside: a large mention still costs tokens; a cap that is too low looks like a truncated file. Email addresses must not expand.
