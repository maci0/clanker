# RFC 0014 — ACP server: how clanker is driven as an agent by an IDE over the Agent Client Protocol

## Status

Decided — 2026-08-17. ADR 0026

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Clanker has clanker mcp as an MCP server but no ACP server for IDEs (Zed) to drive it as an agent; the Kimi parity gap names ACP/IDE integration as open. Need to choose transport/framing, session lifecycle, and edit permission model for clanker acp, analogous to DSH's minimal automation-only ACP and MCP as prior art.

**Decision to make.** Which wire and lifecycle should `clanker acp` adopt so an ACP-aware editor can drive clanker as an agent (session/new, prompt, streaming, permission), without duplicating the MCP surface?

**Why now.** ROADMAP Planned (Kimi harness parity) lists ACP/IDE integration as open; PRD 0030 already scaffolds a minimal stub (`initialize`/`authenticate`/`session/cancel`) gated by `modules.acp` but has no real session flow — the RFC must pin the approach before wiring more.

**Drivers.** Stdio JSON-RPC like `clanker mcp`; Zed-compatible method set; WASM tool reuse; session-per-prompt isolation matching clanker's existing session model; permission prompts gated by `modules.acp`.

**Out of scope.** Full tool/terminal coverage beyond the minimal automation-only profile; streaming-media chunking beyond plain text; plugin views inside the ACP transport.

## Current state

Today: `src/acp/server.zig` implements framing + `initialize` (protocol v1, baseline caps), `authenticate` (empty ok), and `session/cancel` as a no-op; `src/cli.zig:cmdAcp` guards by `modules.acp` (default false) and unknown methods return `-32601`. No `session/new`|`prompt`|`permission` flow yet; PRD 0030 is `In progress`. Status quo for users is using `clanker run`/`repl` directly, not via an editor.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — Minimal automation-only ACP over stdio (DSH/ACP spec: session/new, session/prompt, session/update, permission)

- **What it is:** Stdio JSON-RPC server exposing `initialize` (+ `authenticate`), `session/new`, `session/prompt` (streams `session/update`), `session/request_permission` dialog bridge, and `session/cancel`; transport identical to `clanker mcp`.
- **Maturity:** Agent Client Protocol v1 spec; DSH `packages/acp/acp/` is a working reference.
- **How it would fit:** `src/acp/server.zig` gains the four methods plus a streaming adapter that forwards agent deltas as `session/update` chunks; `src/cli.zig` keeps the `modules.acp` gate; tests drive ACP frames over a fake stream.
- **Pros:** Matches `kimi acp` shape; Zed-native; one transport already proven by MCP.
- **Cons:** Spec has sharp edges around cancellation and permission mapping.
- **Cost to adopt:** 1–2 weeks; narrow surface keeps it bounded.
- **Cost to leave:** Drop `src/acp/` and the CLI hook; no migration.
- **Evidence:** https://agentclientprotocol.com — verified spec; DSH tree has `packages/acp/acp/` — unverified in checkout.

### Option B — Reuse `clanker mcp` tool surface for IDEs

- **What it is:** Tell IDEs to use MCP's `tools/call` instead of ACP's `session/prompt`.
- **Maturity:** MCP is already shipped.
- **How it would fit:** No new code; docs point IDEs to `mcp`.
- **Pros:** No build.
- **Cons:** MCP is tool-oriented, not session/prompt/streaming; Zed does not speak MCP as an agent protocol.
- **Cost to adopt:** Doc edit.
- **Cost to leave:** Docs.
- **Evidence:** Zed docs describe ACP, not MCP for agent driving — verified.

### Option C — Status quo

- **What it is:** Leave `clanker acp` as a stub (`initialize`/`authenticate`) and do not wire session flow.
- **Maturity:** Current code.
- **How it would fit:** `src/acp/server.zig` stays as today.
- **Pros:** No work; no spec surface to maintain.
- **Cons:** Kimi parity gap remains open; IDE integration stays missing.
- **Cost to adopt:** Zero now; parity debt later.
- **Evidence:** `src/acp/server.zig` today returns `-32601` for prompt/permission — verified.

### Option D — Out-of-the-box: shell out to an external ACP bridge process

- **What it is:** keep doing what we do today.
- **Pros:**
- **Cons:**
- **Cost to adopt:** zero now; state what it costs later.
- **Evidence:**

## Implications by horizon

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

- **If A:** `clanker acp` becomes drivable from Zed with basic prompts and cancellations.
- **If B:** IDEs must go through MCP tools rather than agent sessions — poor fit.
- **If C:** Gap stays open.
- **If D:** Shell bridge would serialize every turn through a pipe.

### Medium term (3–12 months)

- **If A:** Permission UI and streaming polish can be layered without changing the wire.
- **If B/C:** Tool-call ergonomics degrade for editor users.
- **If D:** Extra process to maintain.

### Long term (12+ months)

- **If A:** Sustainable editor channel alongside MCP.
- **If B/C/D:** Editor parity remains behind.

## Recommendation

**Recommended option:** Adopt Option A — minimal automation-only ACP over stdio (session/new, prompt, update, permission)

**Confidence:** 8/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** Provides a native agent session for ACP editors (Zed) without reusing the tool-oriented MCP channel; session lifecycle and streaming map cleanly to clanker's existing agent/session model.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_

## Open questions

- Whether `session/update` should stream deltas or whole turns — decide at impl time.

## Next steps / action items

- [ ] ADR 00XX and PRD 0030 checklist; wire `session/new|prompt|update|permission` in `src/acp/server.zig` behind `modules.acp`. Test over fake stdio frames and one live Zed round-trip.

## References



- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
