# ADR 0040 — Browser is a first-class catalog tool; phase 1 is status and setup

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0028 — Whether clanker ships a first-class browser catalog tool](../rfcs/0028-first-class-browser.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

Web tasks depended on an MCP Playwright server the model had to discover by qualified name. jcode ships one browser tool and a provider protocol. RFC 0028 compared a catalog tool, MCP-only docs, the status quo, and fetch_web plus the eval kernel.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

Ship a catalog tool named browser. Phase 1 implements status and setup that report availability and manual steps, including not_ready when no backend is configured. Live open/click wait on a later host channel. MCP client remains for operators who already have a server. fetch_web is not a page.

> The RFC recommended: **Recommended option:** Option A: first-class browser catalog tool; phase 1 is status/setup reporting not_ready; live backends later; MCP remains


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

The model has one name to call. Phase 1 is honest about not being able to click. The honest downside: a status-only tool can rot if later phases never land; the PRD must keep those phases named. A live backend may need ck_browser (privileged, like ck_debug), which is a later ADR if the socket cannot be exec-gated. Kernel JS is the wrong security class (ADR 0010).

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
