# RFC 0013 — MCP client configuration: how clanker consumes external MCP servers

## Status

Decided — 2026-08-17. ADR 0025

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Clanker only serves MCP today; the Kimi harness parity gap notes "MCP client configuration (clanker already serves MCP; /mcp-config-style client management is new)" as the next open item. Need a user-facing way to configure external MCP servers the agent can consume, bridging them into the existing WASM tool registry without breaking the sandbox trust model.

**Decision to make.** Which MCP client configuration and bridge should clanker adopt so an external MCP server's tools appear as normal tools to the agent, without violating the WASM sandbox or requiring per-server hand code?

**Why now.** ROADMAP Planned (Kimi harness parity) names MCP client config as the next open Kimi-parity gap; `clanker mcp` only *serves*, the missing direction is *consume*; PRD 0032 already drafts the feature but has no RFC→ADR trail.

**Drivers.** `config.toml`-shaped ergonomics like `[providers.<name>]`; stdio + streamable HTTP transports; server-qualified tool naming to avoid collisions; reconnect/backoff; sandbox trust: the external MCP process sits outside the WASM sandbox (operator opt-in, same level as Claude/Codex MCP clients); no new hard dependency beyond stdlib.

**Out of scope.** ACP/IDE integration and lifecycle hooks (separate PRDs 0030/0028).

## Current state

Today: `clanker mcp` is a stdio JSON-RPC *server* (`src/mcp/server.zig`) exposing local tools to an MCP client such as an IDE. Consuming an external MCP server (e.g. the `github` filesystem server) requires a custom WASM shim per server. No `[mcp_servers.<name>]` config exists; no client transport exists; `src/toolhost/registry.zig` only registers WASM-backed tools.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — Native MCP client bridge with `[mcp_servers.<name>]` + `mcp__<server>__<tool>` registry kind (DSH mcp-client shape)

- **What it is:** Native client in `src/mcp_client/` speaking `tools/list`/`tools/call` over stdio and streamable HTTP, connecting at startup, registering discovered tools as a new (non-WASM) registry kind under the qualified name `mcp__<server>__<tool>`; dispatch forwards over the live connection; reconnect/backoff on drop.
- **Maturity:** DSH `packages/mcp/mcp-client` is the reference wire contract; JSON-RPC stdio is stable; HTTP streaming is MCP spec 2024-11.
- **How it would fit:** New `src/mcp_client/` (transport + RPC), new `mcp_servers` table in `src/config.zig`, one new registry dispatch kind in `src/toolhost/registry.zig`, gated by `modules.mcp_client` (default off), `clanker mcp-client list` introspection.
- **Pros:** Ergonomic config like providers; collision-safe names; graceful reconnect.
- **Cons:** External process is out-of-sandbox by design (trust is opt-in); adds a small native long-lived child.
- **Cost to adopt:** 1–2 weeks; ongoing MCP spec tracking.
- **Cost to leave:** Drop the `mcp_client` module and the flag; tools disappear.
- **Evidence:** DSH reference https://github.com/deepseek-ai/deepseek-harness `packages/mcp/mcp-client/` — verified tree has transports.

### Option B — WASM shim per server (hand-written proxy tools)

- **What it is:** Keep the registry WASM-only and ship one thin WASM tool per external MCP server that speaks the MCP wire itself.
- **Maturity:** WASM tooling is first-class; no native client.
- **How it would fit:** `tools/zig/mcp_github.zig`, `tools/mcp_servers.toml`, one manifest per shim; no registry change.
- **Pros:** No new host surface; sandbox stays uniform.
- **Cons:** Incompatible with many transports (stdio child per call); per-server code duplication; poor for reconnect/stateful sessions.
- **Cost to adopt:** One shim per integration; not scalable.
- **Cost to leave:** Remove the shims.
- **Evidence:** `tools/zig/doctor.zig` shows the existing shim pattern; `registry.zig` today loads only `.wasm` — verified.

### Option C — One-shot forking subprocess without persistent connection

- **What it is:** For each tool call, fork the MCP server, call `tools/call`, read the result and exit.
- **Maturity:** Simple; no daemon.
- **How it would fit:** Thin `std.process.Child` wrapper per call; no registry of connections.
- **Pros:** Stateless; no reconnect logic.
- **Cons:** High latency; no notification/streaming support; many servers dislike cold start per call.
- **Cost to adopt:** Small initially; scales poorly.
- **Cost to leave:** Remove the forking wrapper.
- **Evidence:** Fork-per-call is common in thin MCP fetchers; not in tree — unverified throughput.

### Option D — Status quo

- **What it is:** keep doing what we do today.
- **Pros:**
- **Cons:**
- **Cost to adopt:** zero now; state what it costs later.
- **Evidence:**

## Implications by horizon

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

- **If A:** `github` MCP server usable in one config stanza; agent sees normal tools.
- **If B:** One server shim ships; second request needs a second shim.
- **If D:** Still need a shim per server.

### Medium term (3–12 months)

- **If A:** Multiple servers with qualified names coexist; reconnect handles flaky networks.
- **If B:** Registry polluted with N shims; drift risk as MCP spec evolves.
- **If D:** Users avoid MCP or write ad-hoc scripts.

### Long term (12+ months)

- **If A:** Sustainable MCP ecosystem; spec updates in one place.
- **If B:** Maintenance burden per shim; slow to support new servers.
- **If D:** Missing feature debt.

## Recommendation

**Recommended option:** Adopt Option A — native MCP client bridge with mcp__<server>__<tool> qualified names and [mcp_servers] config

**Confidence:** 8/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** Native bridge scales to N servers with one implementation, handles reconnect/streaming, and matches the provider-config ergonomics clanker already uses; shims duplicate per server and lose fidelity, forking per call adds latency and state loss.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_

## Open questions

- Whether streamable HTTP chunking requires a dedicated framing library or plain `content-type: application/json` lines — verify against DSH's `mcp-client`.
- Whether to expose MCP server env/cwd via `config.toml` or `config.local.toml` only — decide before implementing config parse.

## Next steps / action items

- [ ] ADR 00XX naming the registry-kind change; PRD 0032 checklist cleared before building.
- [ ] Implement `src/mcp_client/` with `tools/list`/`tools/call` over stdio + HTTP, `config: mcp_servers`, registry kind, and `modules.mcp_client` gate. Test against a toy stdio echo server and one real external MCP server.

## References



- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
