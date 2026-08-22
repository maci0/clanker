# PRD — Markdown session export

## Status

In progress — phase 1 shipped 2026-08-21 (renderMarkdown + format switch in the session_export guest, CLI infers md from a .md destination); TUI /export-md is phase 2 and open. Source of truth: tools/zig/session_export_logic.zig, tools/zig/session_export.zig, src/cli.zig. Decision: [ADR 0044](../adrs/0044-markdown-session-export-is-a-second-renderer-in-the.md). RFC: [0032](../rfcs/0032-session-export-md.md).

Shipped / In progress / Draft. Name the source files that are the single
source of truth, and the surface(s) that expose it (tools, HTTP, CLI, web
UI). If a claim below is known to be stale or contradicted by the code,
say so here up front rather than burying it in Design — a reader who only
reads Status should not walk away misinformed.

## Problem

session export is HTML-only. Sharing a readable transcript means converting HTML or copying the TUI.

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

1. format=md on session_export.  2. Role headings plus fenced literal bodies.  3. Untrusted text is not parsed as CommonMark HTML.  4. CLI --format md.  5. TUI /export-md later.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

What this deliberately does not do, and why leaving it out is a feature
(not just unstarted work). This is what stops the next reader from
"fixing" a deliberate omission.

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

## Known issues

Only needed when verification against code turned up real drift between
what was designed/promised (in this doc, in a manifest, in a code comment)
and what the code actually does. Omit this section entirely for a PRD with
no known drift — an empty "Known issues: none" is noise. Each entry: what
was promised, what actually happens, and where the fix belongs (file, not
just "somewhere").

## Failure modes

A table: condition -> behaviour. Every "what happens when X goes wrong"
answer a caller would otherwise have to read the source to find out. Mark
a row as a known bug (cross-reference Known issues) rather than describing
buggy behavior as if it were the design.

## Acceptance criteria

Checkboxes, each traceable to a Goal. Use `[ ]` honestly for anything not
currently true — an unchecked box that names the gap is more useful than a
checked box that's aspirational. Re-verify this section, not just Design,
whenever the code changes underneath a shipped PRD.

## Open questions / future work

Real unresolved decisions, each phrased so a reader unfamiliar with the
history can tell what's actually being asked and why it's still open
(what would resolving it cost or break?). Distinguish a genuine open
design question from a plain bug that just hasn't been fixed yet — a bug
belongs in Known issues, not here, even if fixing it is future work.

Do not park build blockers here. If implementation cannot start until a
choice is made, make the choice in Design (and say why), then leave only
follow-on / optional refinements in this section.
