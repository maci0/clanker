# PRD — External coding-agent driver (ACP client, headless fallback)

## Status

Draft — opened 2026-08-18. Implements the decision recorded in [ADR 0032 — External coding agents are driven by an ACP client first, with headless spawn as fallback](../adrs/0032-external-coding-agents-are-driven-by-an-acp-client-first.md).

No part of this driver exists yet — no source file names it. Everything below is the intended shape, not a description of shipped code.

## Problem

The operator has Claude Code, Codex, and Grok Build logins (OAuth / subscription) and no console API keys for those vendors. The vendor credential is issued for each vendor's own CLI client, expires, and the Messages / Responses APIs reject it from a third-party User-Agent — pasting an oat into clanker's provider env was tested by the operator and fails even though clanker already sends Bearer plus anthropic-beta: oauth-2025-04-20 (src/llm/providers/anthropic.zig). The only legitimate holder of that credential is the vendor's own CLI. clanker therefore cannot start Claude Code, Codex, or Grok Build today, and — because nothing drives them — their work cannot land in a run graph or be read by autolearn / improve-self. This is the harness half that ADR 0032 decided: clanker as the harness, the vendor CLI as the program that holds the login.



## Goals

1. Native ACP client starts a vendor ACP agent over stdio, sends initialize/authenticate/session/new/session/prompt, receives session/update, and implements session/request_permission.
2. First-party headless fallback (claude -p, codex exec, grok -p) is available when a vendor has no ACP, or when ACP breaks after a vendor update.
3. The vendor credential never enters clanker (not seen, stored, or logged).
4. Every driven session writes a run-graph node and autolearn can read it.
5. Spawn is harness-native code, not ck_job and not ck_exec's allowlist.



## Non-goals

- **oat-as-API-key / TLS or header spoof.** Pasting the vendor login token into a provider env, or forging a vendor client to spend a subscription as an API key, is a hard reject (ADR 0032; RFC 0020). The credential is legitimate only inside the vendor's own CLI.
- **Replacing the clanker ACP server.** ADR 0026 / PRD 0030 keep clanker as the ACP *server* an IDE drives. This PRD adds the opposite role (clanker as an ACP *client* driving a vendor agent), reusing server framing only; it does not remove or rewrite `clanker acp`.
- **Making the child use WASM tools by default.** The child uses its own tools and writes the worktree. Pointing it at clanker's WASM tools via clanker MCP is possible but is not a default of this driver.
- **Ingest-only log watcher (RFC 0020 option D).** Reading vendor logs after the fact cannot start work or carry the session/request_permission awareness ACP provides; it was rejected in favor of A then B.

## Design

The driver is native harness code, not a guest and not `clanker acp` (that verb is the *server*, ADR 0026). clanker starts the vendor CLI as a subprocess and speaks ACP as the *client*.

**Operator surface.** No new work verb. Existing starts (`clanker run`, `repl`, `goal`, `POST /api/run`) gain a backend selector (`--backend` / `[agent] backend`, names like `grok`, `codex`, `claude`). Unset keeps today's in-process LLM loop. A fourth verb would fork the product the way a second `clanker acp` already would.

**Two paths, one Graph.** Path A sends initialize → authenticate (if the agent requires it) → session/new → session/prompt and consumes session/update; it implements session/request_permission (ACP client baseline). fs/* and terminal/* are not required to start: if the agent demands them, refuse the capability or fall through to B. Path B runs `claude -p`, `codex exec`, `grok -p`. Both persist the same `src/agent/graph.zig` `Graph` via the graph guest `write` action (the same JSON `Agent.persistGraph` already builds). They do **not** call `persistGraph` — that function is private on `Agent` and only runs at the end of an in-process loop. ACP `session/update` tool/message events map onto existing `NodeKind` (`tool`, `llm`, `final`). B writes a degraded graph: one `llm`/`final` pair from stdout. That is one schema, not two.

**ACP hang.** Cancel the child, persist a failed A node, then B for that vendor. Not "B or an error".

**Why native, not ck_job / ck_exec.** ck_job is jobs+subagent only (src/sandbox/jobs.zig). ck_exec allowlists git/zig/uv (src/sandbox/host.zig) and must not gain claude/codex/grok — that would let a guest spawn those CLIs outside the harness policy. Spawn lives in src/acp/ next to the client, using the process table in src/agent/subprocess.zig.

**Credential boundary.** clanker does not put a vendor token in config, argv, or logs, and does not parse one out of the stream. The child uses its own login store. JSON-RPC on stdio is the protocol, not a scan for "framing."

**Dependencies.**
- ADR 0032 — the decision this implements.
- RFC 0020 — the argument.
- ADR 0026 / PRD 0030 / src/acp/server.zig — JSON-RPC line framing only. session/request_permission on the server is the other direction (clanker asks the IDE). The client must implement the inverse (vendor agent asks clanker).
- tools/zig/graph.zig `write` + src/agent/graph.zig — persist shape.
- src/agent/auto_learn.zig `recordRun` — usage event (provider/model/tokens/tools). Hard blocker: none. The work is writing the client.

**Implementation.**
1. src/acp/client.zig (state machine + spawn). src/cli.zig / src/config.zig `--backend` / `[agent] backend`. Drive Grok `agent stdio`. Persist via graph `write` + autolearn.recordRun.
2. Same client, Codex argv `npx -y @agentclientprotocol/codex-acp` (published adapter).
3. Same client, Claude published ACP adapter once the package is opened and pinned.
4. src/acp/fallback_spawn.zig — B, same Graph write, used when ACP is missing or a turn is cancelled as broken.
5. CHANGELOG, docs/README.md, AGENTS.md.



## Failure modes

| Condition | Behaviour |
| --- | --- |
| Vendor has no ACP | Fall back to B (headless spawn). |
| ACP hangs or deadlocks on session/request_permission | Cancel the child, persist a failed A node, then B. |
| Child exits non-zero | Failed run; persistGraph records the failure. |
| Unknown vendor | Refuse. |
| Vendor update breaks ACP | B takes over; A is not a hard dependency for that vendor. |

## Acceptance criteria

- [ ] A native ACP client (src/acp/client.zig) starts a vendor ACP agent over stdio and completes initialize/authenticate/session/new/session/prompt, receiving session/update. (Goal 1)
- [ ] The client implements session/request_permission. (Goal 1)
- [ ] Headless fallback spawns claude -p / codex exec / grok -p when a vendor has no ACP, or when ACP breaks after a vendor update. (Goal 2)
- [ ] No vendor credential is seen, stored, or logged by clanker on either path. (Goal 3)
- [ ] Each driven session writes a run-graph node and autolearn can read it. (Goal 4)
- [ ] Spawn is harness-native, not ck_job and not ck_exec's allowlist. (Goal 5)

## Open questions / future work

- Whether fs/* and terminal/* must be implemented for a first working ACP session, or whether a vendor agent can complete a prompt-only session without them. Follow-on capability, not a start blocker — phase 1 settles it empirically.
- Whether the child is later offered clanker MCP so it can call WASM tools. Optional follow-on; default off.
