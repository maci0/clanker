# ADR 0026 — ACP server is minimal automation-only over stdio

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0014 — ACP server: how clanker is driven as an agent by an IDE over the Agent Client Protocol](../rfcs/0014-acp-server-how-clanker-is-driven-as-an-agent-by-an-ide.md).

## Context

IDE needs a native agent session, not a tool-call bridge; the Kimi parity gap requires an ACP surface without duplicating MCP.

Options in RFC 0014: A minimal ACP, B reuse MCP, C shell bridge, D status quo. ROADMAP Planned (Kimi harness parity) motivates a native ACP server.

## Decision

A minimal ACP server over stdio implements session/new, session/prompt, session/update streaming, and session/request_permission gated by modules.acp, mirroring deepseek-harness automation-only scope.

> The RFC recommended: **Recommended option:** Adopt Option A — minimal automation-only ACP over stdio (session/new, prompt, update, permission)



## Consequences

ACP adds a stable editor channel alongside MCP; scope is narrow so terminal provider and full tool-surface parity are deferred. Reversible: remove the ACP methods and gate.

