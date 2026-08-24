# PRD — First-class browser catalog tool

## Status

Draft. Later phases, not implement-now this round. Decision: [ADR 0040](../adrs/0040-browser-is-a-first-class-catalog-tool-phase-1-is-status.md). RFC: [0028](../rfcs/0028-first-class-browser.md).

## Problem

The model has no catalog tool named browser. Page control depends on an MCP server the operator must configure and the model must discover by qualified name. fetch_web is GET, not a page.

## Goals

1. A catalog tool named browser implements status and setup, reporting not_ready when no backend is configured.  2. status is launchable twice with stable JSON.  3. open/click/snapshot are later phases.  4. MCP client remains available.

## Non-goals

Implementing Firefox Agent Bridge in phase 1. Chrome/CDP. Replacing MCP client. fetch_web as a page. Eval kernel for DOM (ADR 0010). A daemon.

## Design

**Tool.** Catalog name browser. Actions: status, setup. JSON {ok, availability: not_ready|ready|degraded, setup_state, manual_steps[], diagnostics[]}.

**Phase 1 honesty.** availability is not_ready until a backend exists. setup returns the same plus recommended next manual step. No socket.

**Later.** open/snapshot/click behind a host channel if required (future ck_browser ADR). MCP remains.

**Dependencies.** Hard: ADR 0040, tools/manifests/, clanker plugins new shape. Soft: PRD 0032, ADR 0025.

**Implementation.** later, not implement-now this round (phase 1 is small but not in this goal's implement-now set).

1. browser guest status/setup + tests + manifest. Files: tools/zig/browser.zig, tools/manifests/browser.tool.json.
2. clanker browser status CLI plugin. Files: cli-plugins/browser.json.
3. Live backend. Files: src/sandbox/ (possible ck_browser), tools/zig/browser.zig.

## Failure modes

| Condition | Behaviour |
|---|---|
| Unknown action | ok false, error names the action |
| No backend | availability not_ready, not a crash |
| MCP Playwright also configured | Both exist; catalog tool does not hide MCP |

## Acceptance criteria

1. [ ] browser {"action":"status"} returns availability not_ready when no backend (Goal 1)
2. [ ] Two launches produce the same availability field (Goal 2)
3. [ ] open is refused or listed as unsupported in phase 1 (Goal 3)
4. [ ] MCP client code is not deleted (Goal 4)

## Open questions / future work

Whether live control needs ck_browser. Firefox vs CDP first for phase 3.
