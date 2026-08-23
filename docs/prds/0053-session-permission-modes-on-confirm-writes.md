# PRD — Session permission modes on confirm_writes

## Status

Draft — opened 2026-08-21. Name the source files that are the single source of truth, and the surfaces that expose it.

## Problem

confirm_writes is never/browser/always. There is no session-scoped allow after one yes, and no yolo that still confirms plan-exit.

## Goals

1. Mode manual/yolo/auto.  2. Session allow-set from Approve for this session.  3. Sandbox always-denied never lifts.  4. /yolo /auto /permission.  5. Pattern rules later.

## Design

**Mode.** manual (ask), yolo (skip regular confirms, still confirm plan-exit and secrets), auto (skip confirms and ask_user). Session allow-set records tool names after Approve for this session.

**Floor.** Descriptor sandbox, exec_allow, secret_dotenv never lift.

**Dependencies.** Hard: ADR 0042, agent.confirm_writes, confirm_fn. Soft: /permission TUI.

**Implementation.**

1. later: mode enum + allow-set + /yolo /auto. Files: src/config.zig, src/agent/loop.zig, src/tui/repl.zig.
2. later: [[permission.rules]] config. Files: src/config.zig.

## Non-goals
YOLO as sandbox off. Marketplace.

## Failure modes
| Condition | Behaviour |
|---|---|
| yolo + plan exit | still confirms |
| dotenv under auto | still refused |

## Acceptance criteria
1. [ ] /yolo skips regular confirms (Goal 1)
2. [ ] sandbox dotenv still refused (Goal 3)

## Open questions / future work
Pattern rules are phase 2.
