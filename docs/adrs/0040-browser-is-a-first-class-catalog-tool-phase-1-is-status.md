# ADR 0040 — Browser is a first-class catalog tool; phase 1 is status and setup

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0028 — Whether clanker ships a first-class browser catalog tool](../rfcs/0028-first-class-browser.md).

## Context

Web tasks depended on an MCP Playwright server the model had to discover by qualified name. jcode ships one browser tool and a provider protocol. RFC 0028 compared a catalog tool, MCP-only docs, the status quo, and fetch_web plus the eval kernel.

## Decision

Ship a catalog tool named browser. Phase 1 implements status and setup that report availability and manual steps, including not_ready when no backend is configured. Live open/click wait on a later host channel. MCP client remains for operators who already have a server. fetch_web is not a page.

> The RFC recommended: **Recommended option:** Option A: first-class browser catalog tool; phase 1 is status/setup reporting not_ready; live backends later; MCP remains


## Consequences

The model has one name to call. Phase 1 is honest about not being able to click. The honest downside: a status-only tool can rot if later phases never land; the PRD must keep those phases named. A live backend may need ck_browser (privileged, like ck_debug), which is a later ADR if the socket cannot be exec-gated. Kernel JS is the wrong security class (ADR 0010).
