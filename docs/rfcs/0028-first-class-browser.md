# RFC 0028 — Whether clanker ships a first-class browser catalog tool

## Status

Decided — 2026-08-21. ADR 0040

## Overview

jcode exposes one browser tool over a provider protocol, Firefox first. clanker's MCP client can attach a Playwright server but the model must pick among MCP names. Decide whether a first-class browser catalog tool exists.

**Decision to make.** Should clanker ship a first-class browser catalog tool, or keep telling operators to attach an MCP Playwright server?

**Why now.** Web tasks currently depend on MCP client config the model must discover. jcode has one browser tool and a provider protocol. Inventory: docs/research/jcode-features.md.

**Drivers.** WASM-by-default: the catalog tool is a guest. A live browser socket may need a host channel (like ck_debug), not a guest-held FD. network_allow still applies. Do not vendor Firefox. Setup must be machine-readable (status/setup), not a wiki.

**Out of scope.** Implementing Firefox Agent Bridge in phase 1. Chrome/CDP. Computer-use / ADB. Replacing MCP client (PRD 0032).

## Current state

MCP client (PRD 0032 / ADR 0025) can attach a Playwright/browser MCP server with qualified tool names. No catalog tool named browser. fetch_web is HTTP GET, not a page. Files: tools/zig/browser.zig + manifest; optional later ck_browser.

## Options considered

### Option A — Catalog browser tool with status/setup first; provider protocol later

What it is: one guest browser with actions status and setup that report availability and manual steps (not_ready until a backend exists). open/snapshot/click land in later phases behind a host channel if a socket is required. One tool name forever.

Maturity: jcode ships the tool plus Firefox backend. Their protocol doc is draft 0.1.

How it would fit: tools/zig/browser.zig, tools/manifests/browser.tool.json, optional clanker browser status CLI plugin. Phase 1 is status/setup so the surface exists without a daemon.

Pros: model sees one name; MCP remains for people who have Playwright. Setup is machine-readable.

Cons: phase 1 cannot click; risk of a stub that never grows.

Cost to adopt: guest + tests that status returns setup_required. Cost to leave: disable the plugin.

Evidence: jcode BROWSER_PROVIDER_PROTOCOL.md; PRD 0032.

### Option B — MCP-only: document a Playwright server

What it is: no catalog tool; doctor/docs point at MCP.

How it would fit: already possible.

Pros: zero code; existing MCP servers.

Cons: qualified names; every operator configures it; the model hunts.

Cost to adopt: a paragraph. Cost to leave: n/a.

Evidence: ADR 0025.

### Option C — status quo

What it is: MCP if configured, else fetch_web.

Pros: no stub tool.

Cons: no first-class browser; fetch_web is not a page.

Cost to adopt: zero.

Evidence: no browser in clanker tools list 2026-08-21.

### Option D — out of the box: fetch_web plus eval kernel for JS

What it is: GET the HTML, eval in kernel.

How it would fit: fetch_web + kernel (PRD 0016, opt-in unsandboxed).

Pros: already in tree.

Cons: no DOM, no click, kernel is unsandboxed (ADR 0010). Wrong security class.

Cost to adopt: a skill. Cost to leave: n/a.

Evidence: fetch_web; ADR 0010.

## Implications by horizon

### Short term (this release / 0–3 months)

If A: browser status/setup is callable and honest about not_ready. If B: docs only. If status quo: MCP or nothing. If D: unsandboxed kernel for page JS.

### Medium term (3–12 months)

If A: a Firefox or CDP backend behind the same tool. If B: every checkout reinvented MCP config.

### Long term (12+ months)

If A: one tool name as providers appear. If C: browser stays a bolt-on.

## Recommendation

**Recommended option:** Option A: first-class browser catalog tool; phase 1 is status/setup reporting not_ready; live backends later; MCP remains

**Confidence:** 7/10

**Rationale.** One name beats qualified MCP tools for the default agent. Phase 1 without a socket keeps ADR 0008 and the sandbox honest. fetch_web plus kernel is the wrong security class. A stub that never grows is the risk; the PRD must name later phases so it cannot be mistaken for done.

## References



- Research: [jcode feature inventory](../research/jcode-features.md).
- PRD 0032, ADR 0025, ADR 0010. jcode BROWSER_PROVIDER_PROTOCOL.md (2026-08-21).
