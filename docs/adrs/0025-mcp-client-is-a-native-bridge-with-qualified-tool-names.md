# ADR 0025 — MCP client is a native bridge with qualified tool names and a registry dispatch kind

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0013 — MCP client configuration: how clanker consumes external MCP servers](../rfcs/0013-mcp-client-configuration-how-clanker-consumes-external-mcp.md).

## Context

Clanker serves MCP but does not consume external MCP servers; the Kimi parity gap needs a consume path without hand-writing a WASM shim per server.

Options in RFC 0013: A native bridge with qualified names, B WASM shim per server, C fork-per-call, D status quo. ROADMAP Planned (Kimi harness parity) motivates consuming external MCP servers.

## Decision

A native MCP client in src/mcp_client speaks tools/list and tools/call over stdio and streamable HTTP; discovered tools register as kind mcp_client under mcp__<server>__<tool> with a non-WASM dispatch that forwards over the live connection and reconnects on drop.

> The RFC recommended: **Recommended option:** Adopt Option A — native MCP client bridge with mcp__<server>__<tool> qualified names and [mcp_servers] config



## Consequences

MCP servers run outside the WASM sandbox as opt-in long-lived children (same trust as Claude/Codex MCP); one code path for N servers rather than N shims, but spec tracking becomes a maintenance surface.

