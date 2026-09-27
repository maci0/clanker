# ADR 0022 — REPL multi-line input via Shift+Enter (Enter still submits)

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0010 — REPL multi-line task input](../rfcs/0010-repl-multi-line-task-input.md).

## Context

Single-line vxfw.TextField forces multiline via paste folding; roadmap gap requires deliberate multiline composition. A raw `\n` in that buffer is written into a terminal cell at render time, so a break has to survive as something drawable.

## Decision

Bind Shift+Enter (and Alt+Enter fallback) to insert a line break in the composer; Enter continues to submit. Shipped as a marker grapheme: `vxfw.TextField` is a single-line widget, so the composer buffer holds `⏎` and `takeComposerText` decodes it to `\n` at submit. Both paths (chord and paste fold) go through that one insert, and the marker is never drawn, since terminals disagree on its cell width.

> The RFC recommended: **Recommended option:** Adopt Option A — Shift+Enter inserts newline in composer, Enter still submits


## Consequences

Improves composition for paste-heavy tasks; the composer buffer and the transcript are two parallel representations of one text, so every path that reads or fills the buffer has to go through the encode/decode helpers rather than touching it. Reversible: remove handler and revert to single-line. Extract later if second consumer needs it.
