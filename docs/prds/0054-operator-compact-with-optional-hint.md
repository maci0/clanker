# PRD — Operator /compact with optional hint

## Status

In progress — TUI half shipped 2026-08-21 (/compact + compact_hint through tools/zig/compact_hint.zig into the summarizer prompt); web UI Compact hint field open. Source of truth: src/tui/repl.zig, src/agent/loop.zig, tools/zig/compact_hint.zig. Decision: [ADR 0043](../adrs/0043-operator-compact-is-the-existing-summarizer-plus-an.md). RFC: [0031](../rfcs/0031-compact-hint.md).

## Problem

Compact is automatic. Operators cannot force it or tell the summarizer what to keep.

## Goals

1. /compact [hint] exists.  2. Hint is operator text on the existing summarizer prompt.  3. Idle-only.  4. Tests concat the hint.  5. Web button later.

## Design

**Command.** /compact [hint] is idle-only. Empty hint means trigger the existing summarizer as-is. A hint is operator text appended to the compact prompt, never retrieved knowledge.

**Path.** Same maybeCompactMessages / compactMessages already used automatically. No second summarizer.

**Dependencies.** Hard: ADR 0043, src/agent/loop.zig maybeCompactMessages, src/tui/repl.zig command_registry. Soft: web Compact button.

**Implementation.**

1. implement-now: /compact plus hint concat helper + tests. Files: src/tui/repl.zig, src/agent/loop.zig (hint field), a tiny host-tested concat if the prompt lives in a helper.
2. later: web UI Compact with hint field. Files: ui/app.

## Non-goals

A new compact algorithm. Rewriting already-sent provider prefix (append-only rule stays).

## Failure modes

| Condition | Behaviour |
|---|---|
| /compact while streaming | refused, idle-only |
| empty session | no-op with a notice |
| summarizer fails | existing extractive fallback |

## Acceptance criteria

1. [x] /compact exists in command_registry (Goal 1)
2. [x] a hint appears in the summarizer prompt (Goal 2)
3. [x] streaming refuses it (Goal 3)
4. [x] tests drive the concat, not a copy (Goal 4)

## Open questions / future work

Web button is phase 2.
