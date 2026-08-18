# ADR 0032 — External coding agents are driven by an ACP client first, with headless spawn as fallback

## Status

Accepted — 2026-08-18. Records the decision opened in [RFC 0020 — How clanker drives an external coding agent (Claude Code, Codex, Grok)](../rfcs/0020-how-clanker-drives-claude-code-as-a-backend-agent.md).

## Context

The operator has Claude Code, Codex, and/or Grok Build logins and no console API keys. Pasting an oat into clanker does not make clanker those agents. They want clanker as the harness (board, runs, autolearn, improve-self) and those CLIs as the program that holds the login. RFC 0020 compared a generic ACP client (A), first-party headless spawn (B), status quo (C), and post-hoc log ingest (D). Spoofing vendor TLS/headers was rejected.

## Decision

Do both, in order. Ship a native ACP client first, everywhere a vendor speaks ACP (Grok first-party agent stdio; Claude/Codex via published adapters). Ship first-party headless spawn (claude -p, codex exec, grok -p) afterwards as the fallback when that vendor has no ACP or a provider update breaks ACP. Spawn is harness-native, not ck_job or ck_exec. The vendor credential never enters clanker. The feature this decides is [PRD 0043](../prds/0043-external-coding-agent-driver-acp-client-headless-fallback.md).

> The RFC recommended: **Recommended option:** Do both, in order. Option A (generic ACP client) first, everywhere a vendor speaks ACP. Option B (first-party headless spawn) afterwards as a fallback when that vendor has no ACP path, or when a provider update breaks ACP. B is not the product and not optional insurance we skip; it is the second deliverable so a Claude/Codex/Grok release cannot take the harness down.

## Consequences

A is an IDE-shaped client: session/request_permission is required, fs/* and terminal/* may be. Adapters will churn. The child uses its own tools and writes the worktree, so the WASM sandbox is off that path unless pointed at clanker mcp. Two transcript shapes (ACP updates vs stdout) must stay compatible in state/runs or one path cannot write a run. B cannot carry the awareness goal if it is the only path. Reversible until a transcript schema is baked into autolearn.
