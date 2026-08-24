# PRD — Structure-aware grep outline

## Status

In progress — phases 1 and 2 shipped 2026-08-21 (rg, ast-grep, and host-fallback hits all attach outline); phase 3 (seen-set truncation) open. Decision: [ADR 0036](../adrs/0036-repo-search-attaches-enclosing-symbols-to-grep-hits.md). RFC: [0024](../rfcs/0024-agent-grep-outline.md). Source of truth: tools/zig/grep_outline.zig and tools/zig/repo_search.zig.

## Problem

repo_search hits are file:line:text. The model cannot tell which function a hit sat in without a follow-up read_file or symbols call, burning tokens on file shape.

## Goals

1. rg and host-fallback hits include enclosing symbol kind, name, and declaration line when the file is readable.  2. Zig declarations are recognized; a weak generic fallback covers def/function/class.  3. Outline bytes are capped.  4. Host tests drive the shipped helper on real source, not a reimplementation.

## Non-goals

A new catalog tool name. Replacing ast-grep or semcode. Adaptive seen-set truncation (later). Full AST outline for every language.

## Design

**Helper.** enclosingSymbol(source, line_no) walks backward from the 1-based line for the nearest Zig fn/const/var/struct/enum/union declaration, else a weak def/function/class fallback. Returns optional {kind, name, decl_line}. Pure, host-tested.

**Wiring.** repo_search structured matches (rg JSON and host fallback) attach outline when the file can be read. ast-grep/semcode engines unchanged in phase 1.

**Cap.** If attaching outline would blow a per-response byte budget, drop outline on later hits rather than fail the search.

**Dependencies.** Hard: ADR 0036, tools/zig/repo_search.zig, build.zig host_tested_helpers. Soft: tools/zig/symbols.zig (sibling, not this walk).

**Implementation.**

1. implement-now: grep_outline.zig helper + tests + repo_search attach on rg/host matches. Files: tools/zig/grep_outline.zig (create), tools/zig/repo_search.zig (edit), build.zig host_tested_helpers.
2. later: ast-grep hits get the same field. Files: tools/zig/repo_search.zig.
3. later: seen-set truncation. Files: tools/zig/repo_search.zig, session state.

## Failure modes

| Condition | Behaviour |
|---|---|
| File unreadable | Hit without outline |
| No enclosing declaration | Hit without outline |
| Binary / skipped dir | Unchanged skip |
| Huge hit set | Outline dropped after cap, search still ok |

## Acceptance criteria

1. [x] A Zig file with fn foo at line 3 and a hit on line 5 reports symbol foo kind fn decl_line 3 (Goal 1, Goal 2)
2. [x] A hit in a file of only comments has no outline (Goal 1)
3. [x] Python def bar fallback is recognized (Goal 2)
4. [x] Tests call enclosingSymbol, not a copy (Goal 4)
5. [x] repo_search rg, ast-grep, and host-fallback matches attach outline when file and line are present (Goal 1)

## Open questions / future work

More languages (phase 2/3). Seen-set truncation is deferred on purpose.
