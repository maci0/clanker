# PRD — Markdown session export

## Status

In progress — phase 1 shipped 2026-08-21 (renderMarkdown + format switch in the session_export guest, CLI infers md from a .md destination); TUI /export-md is phase 2 and open. Source of truth: tools/zig/session_export_logic.zig, tools/zig/session_export.zig, src/cli.zig. Decision: [ADR 0044](../adrs/0044-markdown-session-export-is-a-second-renderer-in-the.md). RFC: [0032](../rfcs/0032-session-export-md.md).

## Problem

session export is HTML-only. Sharing a readable transcript means converting HTML or copying the TUI.

## Goals

1. format=md on session_export.  2. Role headings plus fenced literal bodies.  3. Untrusted text is not parsed as CommonMark HTML.  4. CLI --format md.  5. TUI /export-md later.

## Design

**Format.** session_export accepts format=html (default) or format=md. Markdown is # title, role headings, fenced literal message bodies. Fence markers inside bodies are broken so they cannot close the fence.

**Why not CommonMark.** Untrusted model output must not become HTML. HTML export already made that call; md is the readable twin, not a renderer.

**Dependencies.** Hard: ADR 0044, tools/zig/session_export_logic.zig, tools/zig/session_export.zig. Soft: TUI /export-md.

**Implementation.**

1. implement-now: renderMarkdown + format switch + tests with hostile ``` and <script>. Files: tools/zig/session_export_logic.zig, tools/zig/session_export.zig, CLI flag if any.
2. later: TUI /export-md. Files: src/tui/repl.zig.

## Non-goals

Debug ZIP. Upload. Re-parsing markdown as HTML.

## Failure modes

| Condition | Behaviour |
|---|---|
| unknown format | refuse |
| empty messages | file with title only |
| body contains ``` | fence broken, still literal |

## Acceptance criteria

1. [x] format=md writes a .md string (Goal 1)
2. [x] role headings exist (Goal 2)
3. [x] <script> stays literal (Goal 3)
4. [x] CLI infers md from a .md destination path (Goal 4)

## Open questions / future work

TUI command is phase 2.
