# RFC 0020 — How clanker drives an external coding agent (Claude Code, Codex, Grok)

## Status

Decided — 2026-08-18. See ADR 0032.

## Overview

The operator has Claude Code, Codex, and/or Grok Build logins (OAuth / subscription) and no console API keys for those vendors. Pasting an oat or similar token into clanker's provider env does not make clanker those agents: the tokens are issued for each vendor's own CLI client, they expire, and the Messages / Responses APIs reject them from a third-party User-Agent. What they want is clanker as the harness (board, runs, autolearn, improve-self, sandboxed tools) and Claude Code / Codex / Grok Build as the *program* that holds the login and talks to the vendor. That path is not built. ACP is a candidate common wire, not a given: Grok Build ships first-party `agent stdio`; Codex ACP is a published adapter; Claude Code has no first-party acp verb. Related but opposite records: RFC 0014 / ADR 0026 / PRD 0030 (clanker is the ACP *server* an IDE drives), PRD 0026 (foreign clients spend clanker keys), RFC 0013 (clanker consumes MCP servers), RFC 0015 (hooks dialect). Decide the integration shape before anyone spoofs vendor headers or forks serve --proxy into a subscription relay.

**Decision to make.** Which seam, if any, should clanker use to *start* work
in Claude Code, Codex, or Grok Build — a generic ACP client (A), first-party
headless CLIs (B), neither (C), or post-hoc log ingest (D) — given that the
operator has those logins and no console API keys?

**Who decides, and by when.** The operator. Settle before any implementation
branch. A spike is to prove A's first session, not to re-litigate A vs B
as equals. No calendar deadline beyond "before anyone pastes an oat into
ANTHROPIC_API_KEY again."

**Why now.** The operator has Claude Code / Codex / Grok OAuth logins and no
console API keys. Those credentials cannot be dropped into clanker's provider
env as an API key. Anthropic oat-as-API-key was tested by the operator and
fails even though clanker already sends Bearer plus anthropic-beta:
oauth-2025-04-20 (src/llm/providers/anthropic.zig). Codex/Grok subscription
tokens used as API keys are the same *class* of claim (vendor login is not a
console key) but were not reproduced here — treat that half as unverified. The only legitimate holder of that
credential is the vendor's own CLI. So the wanted product — clanker as harness
(board, state/runs, autolearn, improve-self, WASM tools) with the vendor CLI as
the agent — is not reachable through the provider path and is not built today.
Decide the integration shape before anyone reaches for spoofing vendor TLS or
headers to spend a subscription as an API key (rejected as a non-option below).

**Drivers.** Any acceptable option must satisfy:
- The vendor credential never enters clanker (not seen, stored, or logged).
- One seam for N agents: a single protocol is strongly preferred over three
  argv dialects.
- Reuse the ACP work already in-tree on the server side (src/acp/; RFC 0014 /
  ADR 0026 / PRD 0030) for JSON-RPC line framing only. Inverting the *role*
  is new work: an ACP client must implement session/request_permission and
  may have to implement fs/* and terminal/* (ACP spec, opened 2026-08-18).
- The child's transcript lands in a run graph and autolearn, not a black box.
- No spoofing vendor TLS/headers to spend a subscription as an API (hard reject).
- Spawn is native harness code (cmdAcp-class), not ck_job and not ck_exec.
  ck_job is jobs+subagent only (src/sandbox/jobs.zig). ck_exec allowlists
  git/zig/uv, not claude/codex/grok (src/sandbox/host.zig).

**Out of scope.** Whether the child gets WASM tools via `clanker mcp` or uses
its own tools (open question). Whether improve-self can actually learn from a
foreign agent's transcript (open question). Running clanker as an ACP server for
these vendors (already RFC 0014). The maturity/legitimacy of any vendor's ACP
implementation. Mapping clanker's reasoning-effort/prompt profile onto each CLI.

## Current state

clanker is a self-hosting agent harness — board, state/runs, autolearn,
improve-self, WASM tools — and talks to model providers over HTTP with its own
keys (src/llm/). There is no code path that launches an external vendor CLI as
the agent doing the work.

- `ck_subagent` (src/agent/subagent.zig) is a *nested clanker loop*, not a
  foreign agent; it uses clanker's own providers.
- clanker acp (src/acp/, PRD 0030 / ADR 0026 / RFC 0014) is the *opposite*
  direction: an IDE drives clanker as the ACP server.
- PRD 0026 `serve --proxy`: foreign clients spend clanker's keys — the wrong
  direction.
- RFC 0013: clanker as an MCP *client*; via `clanker mcp`, Claude Code can call
  clanker's tools today, but with no run graph / autolearn.
- RFC 0015 / ADR 0027: Claude-shaped *hooks*, not a backend agent.
- CodingAgentExplorer is a transparent inspect tap, not a driver.

Today the operator runs `claude`, `codex`, `grok` by hand; the harness sees only
what is pasted back.

## Options considered

One subsection per option, the status quo included, plus one out-of-the-box
option (D). A rejected non-option is listed after D so it stays on the record
as off the table.

### Option A — Generic ACP client

- **What it is:** clanker is the ACP *client*. It spawns a vendor ACP *agent*
  over stdio, sends initialize / authenticate / session/new / session/prompt,
  and *receives* session/update notifications. It must implement
  session/request_permission (baseline client method) and may have to implement
  fs/read_text_file, fs/write_text_file, and terminal/* if the agent advertises
  those capabilities. The transcript folds into a run graph and autolearn.
- **Maturity:** ACP v1 spec opened 2026-08-18
  (https://agentclientprotocol.com/protocol/overview). clanker already *serves*
  a subset (src/acp/server.zig: initialize, authenticate, session/new,
  session/prompt, session/cancel). No client exists. As *products*: Grok
  Build ships first-party ACP (`grok agent stdio` in the grok CLI; also
  listed on docs.x.ai and zed.dev/acp/agent/grok-build). Codex ACP is the
  published adapter `@agentclientprotocol/codex-acp`, not a `codex acp`
  verb. Claude Code's own command list has no `acp`; the usual published
  bridge is `@agentclientprotocol/claude-agent-acp` (npm page not opened).
- **How it would fit:** new native module (src/acp/client.zig), spawned like
  cmdAcp in reverse. One process per vendor session. Not ck_job / ck_exec.
- **Pros:** one JSON-RPC vocabulary for any ACP agent, including future ones;
  Grok already speaks it first-party; structured tool-call updates beat
  stdout scraping.
- **Cons:** an ACP client is an IDE-shaped role (permissions, optional fs and
  terminals), not a thin spawn. Claude and Codex need extra npm adapters.
  The child uses its own tools and writes the tree; WASM sandbox is off the
  path. "Invert RFC 0014" oversells reuse — framing yes, method set no.
- **Cost to adopt:** client RPC table + permission UI/policy + per-adapter
  smoke + transcript import. Larger than three argv wrappers.
- **Cost to leave:** drop the client module; stored run-graph shape is the
  only sticky piece.
- **Evidence:** ACP overview (opened); src/acp/server.zig (read);
  src/sandbox/jobs.zig and host.zig (read); Grok CLI + docs.x.ai + Zed
  listing; codex-acp README (opened); Claude Code command list (product
  CLI). claude-agent-acp package page: unverified.

### Option B — Per-CLI first-party headless runners

- **What it is:** clanker spawns each vendor's own non-interactive CLI and
  captures stdout. No shared session protocol.
- **Maturity:** first-party product flags: Claude Code `-p` / `--print`;
  Codex `exec`; Grok Build `-p` / `--single` (docs.x.ai/build/overview).
  `grok agent headless` is a WebSocket relay, not the print path. A
  current CLI install was only used to confirm those published
  interfaces, not to scope the RFC to one machine.
- **How it would fit:** native harness spawn (same as A), three argv
  templates + three stdout parsers. Grok `--output-format streaming-json`
  is documented as NDJSON of ACP session updates — a structured middle
  ground on that one vendor.
- **Pros:** no extra npm adapter; uses the path each vendor tests;
  smallest build to satisfy "clanker starts the work".
- **Cons:** three dialects; Claude/Codex stdout is not a tool-call
  graph; silent per-vendor breakage; still unsandboxed child writes.
- **Cost to adopt:** one spawn helper + three templates + ingest.
- **Cost to leave:** low; wrappers are self-contained.
- **Evidence:** local --help on claude, codex, grok (this host,
  2026-08-18); https://docs.x.ai/build/overview headless section (opened).

### Option C — status quo

- **What it is:** the operator runs the CLIs by hand; optionally `clanker mcp`
  exposes clanker tools to them. No run graph / autolearn from those sessions.
- **Pros:** zero build; no credential or subprocess risk; the vendor CLIs stay
  exactly the product their vendors test.
- **Cons:** the harness is not the thing that starts the work; no autolearn /
  improve-self signal from those runs; every handoff is manual.
- **Cost to adopt:** zero now; the recurring cost is the permanent absence of
  the wanted product.
- **Evidence:** RFC 0013 for the optional `clanker mcp` tools-only bridge.

### Option D — out of the box: do not drive them, ingest their logs

- **What it is:** do not spawn the agent. Ingest the vendor CLIs' existing
  session/hook logs (transcript import, CodingAgentExplorer) into state/runs and
  autolearn. Claude Code / Codex / Grok stay the human-facing agent.
- **Maturity:** depends on each vendor writing usable session logs/hooks;
  transcript import is a format question, not a protocol.
- **How it would fit:** a log/transcript ingester, no subprocess; runs and
  autolearn populated post hoc.
- **Pros:** no protocol dependency, no credential handling, works for any vendor
  that emits logs.
- **Cons:** does not satisfy "clanker is the harness that starts the work";
  autolearn sees only what the human already did.
- **Cost to adopt:** one ingester per log format.
- **Cost to leave:** low.
- **Evidence:** CodingAgentExplorer shows the shape of the data (inspect tap);
  vendor log formats `unverified`.

### Rejected non-option — spoofing vendor TLS/headers

Spending a subscription as an API by pretending clanker is the vendor's own
client (spoofed TLS/User-Agent/headers). Off the table: it is fragile, violates
the vendor terms, and is exactly the failure class the operator already hit with
oat-as-API-key. Listed so the decision does not drift back to it.

## Implications by horizon

### Short term (0–3 months)

- **If A:** the first deliverable is an ACP *client* (permission RPC), not a
  spawn. Grok Build ships first-party `agent stdio`; Claude and Codex ACP
  as published go through adapters. Failure mode: permission deadlock.
- **If B:** three first-party argv templates; run graph is stdout plus exit
  code. Grok can emit streaming-json ACP updates without a full client.
- **If C:** nothing changes; the ask stays unmet.
- **If D:** one vendor's log format; the run graph appears only for
  human-driven sessions.

### Medium term (3–12 months)

- **If A:** one client to maintain; adapter churn (npm pins, Codex
  community package) is the recurring cost. improve-self still may not
  learn (open question).
- **If B:** three parsers drift; or Grok's streaming-json becomes a
  second ACP dialect inside B.
- **If C:** every board→CLI handoff stays manual; autolearn starves.
- **If D:** observe-only; clanker still never starts the work.

### Long term (12+ months)

- **If A:** new ACP agents join for free *if* they speak the same
  baseline and the client implemented the methods they need.
- **If B:** a wrapper farm, unless it is retired in favor of A.
- **If C:** the want is parked.
- **If D:** never converges with the drive path.

## Recommendation

**Recommended option:** Do both, in order. Option A (generic ACP client) first, everywhere a vendor speaks ACP. Option B (first-party headless spawn) afterwards as a fallback when that vendor has no ACP path, or when a provider update breaks ACP. B is not the product and not optional insurance we skip; it is the second deliverable so a Claude/Codex/Grok release cannot take the harness down.

**Confidence:** 7/10

**Why this confidence.** 7 because both seams are required and A is
the goal; a live session/prompt has not been run. Raise: one ACP turn
on Grok and one on an adapter fold session/update into a run graph.
Sink: session/update cannot be mapped into runs/autolearn at all —
then B is still built, but it cannot carry the awareness goal, and
the product claim has to be cut back. Vendor ACP breaking is why B
exists, not a reason to drop A.

**Rationale.** The operator want is awareness (runs, autolearn, improve-self). Only A gives a structured session/update stream, so it ships first wherever ACP exists (Grok first-party agent stdio; Claude/Codex via published adapters). B exists because those adapters and even first-party ACP will break or vanish on vendor updates, and because some installs will have no ACP. C and D do not start the work. Spoofing stays rejected. Confidence 7: both seams are required; the unknown is only whether the first A spike maps session/update into a run graph, not which option is the goal.

**Reversibility.** Either seam can be deleted while the other still
starts work. Point of no return is baking one transcript shape into
state/runs so the other path cannot write a compatible run.

## Open questions

- Claude Code ACP: the product CLI has no `acp` verb. The published
  bridge name `@agentclientprotocol/claude-agent-acp` was not opened
  on npm (unverified).
- Whether improve-self can learn from a foreign transcript (tool-call
  shape differs from clanker's catalog).
- Whether the child is pointed at `clanker mcp` or uses its own tools —
  this decides if the WASM sandbox stays in the loop.
- Whether a non-interactive child can refresh OAuth without a browser
  (Codex adapter documents ChatGPT login / NO_BROWSER; not exercised).

## Next steps / action items

- [x] Identify vendor ACP and headless interfaces from product
      CLIs/docs.
- [ ] Spike A: ACP client against Grok `agent stdio` (session/new +
      prompt + session/update into a run-graph node).
- [ ] Same client against one published adapter (Codex
      `@agentclientprotocol/codex-acp`).
- [ ] Open `@agentclientprotocol/claude-agent-acp` and add Claude.
- [ ] Then ship B as the fallback: same harness spawn, first-party
      headless argv, used when ACP is missing or a vendor update
      breaks it.
- [ ] Write the ADR once the operator accepts the recommendation.

## References

- PRD 0030 / ADR 0026 / RFC 0014 — clanker as ACP *server*. Framing is
  reusable; the client role is not an invert.
- PRD 0026 — serve --proxy spends clanker keys (opposite direction).
- RFC 0013 — clanker mcp lets Claude Code call tools today; no run graph.
- RFC 0015 / ADR 0027 — Claude-shaped hooks, not a backend agent.
- src/llm/providers/anthropic.zig — Bearer + oauth beta; oat still fails
  (operator test).
- src/agent/subagent.zig — nested clanker loop.
- src/sandbox/jobs.zig, src/sandbox/host.zig — ck_job / ck_exec cannot
  be the spawn path.
- https://agentclientprotocol.com/protocol/overview — opened 2026-08-18.
- https://github.com/agentclientprotocol/codex-acp — opened 2026-08-18.
- https://docs.x.ai/build/overview — opened; grok -p and ACP documented.
- https://zed.dev/acp/agent/grok-build — opened; npx @xai-official/grok
  agent stdio.

## Appendix

### Validation log (2026-08-18)

rfc checklist items answered in the body.

clanker architecture (every checkout): ACP module is a server;
subagent is a nested Agent; ck_job / ck_exec cannot spawn vendor CLIs.

Vendor products (docs + their CLIs): ACP spec; codex-acp README; Grok
Build docs; Zed Grok ACP page; Claude `--print`, Codex `exec`, Grok
`-p` / `agent stdio`.

A current install was used only to confirm those published
interfaces, not to scope the RFC.

Sweep on a sentence-shaped topic was discarded.

Claims retracted as general errors: driving session/update;
jobs/subprocess as the spawn path; `grok headless`; one wire already
covers all three; invert RFC 0014; Codex/Grok oat-class failure as a
checked fact.
