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

The driver is a native harness module (a `cmdAcp`-class verb), not a guest. It inverts the role of the existing ACP server: instead of being driven over stdio, clanker drives a vendor ACP agent over stdio, and folds the transcript it receives into the run-graph/autolearn path the native agent loop already uses.

**Two paths, one transcript.** Path A (ACP client) sends initialize → authenticate → session/new → session/prompt and consumes session/update; it must implement session/request_permission and may need fs/* and terminal/* (ACP spec, opened 2026-08-18). Path B (headless spawn) runs `claude -p`, `codex exec`, `grok -p`. Both must emit one compatible transcript shape into state/runs, or only one path can write a run.

**Why native, not ck_job / ck_exec.** ck_job is jobs+subagent only (src/sandbox/jobs.zig); ck_exec's allowlist is git/zig/uv (src/sandbox/host.zig) and must never gain claude/codex/grok, because that would hand a guest arbitrary subprocess reach beyond its manifest. Spawn lives beside src/agent/subprocess.zig and src/acp/.

**Credential boundary.** The vendor CLI is the only holder of the credential. clanker passes no token and never reads one back; it scans stdout/stderr only for transcript framing, not credentials.

**Dependencies.**
- ADR 0032 — the decision this implements.
- RFC 0020 — the options and argument.
- ADR 0026 / PRD 0030 (src/acp/server.zig) — JSON-RPC line framing only; the client reuses the wire, not the server.
- src/agent/loop.zig persistGraph — where a driven run's node lands.
- src/agent/auto_learn.zig — what reads it.
- Hard blocker: none of the driver exists yet; the ACP client must be written before phase 1 can record a run.

**Implementation.**
1. Create src/acp/client.zig — ACP client state machine (initialize/authenticate/session/new/session/prompt, session/update, session/request_permission). Add a cli/config flag to spawn the Grok first-party `agent stdio` and record a run (edit src/cli.zig, src/config.zig).
2. Same client plus a Codex adapter argv (`codex-acp` community adapter).
3. Claude adapter once the published ACP package is confirmed (Claude Code has no first-party acp verb).
4. Create src/acp/fallback_spawn.zig (or similar) — path B: `claude -p`, `codex exec`, `grok -p`.
5. docs/ + CHANGELOG.md.



## Failure modes

| Condition | Behaviour |
| --- | --- |
| Vendor has no ACP | Fall back to B (headless spawn). |
| ACP hangs or deadlocks on session/request_permission | Cancel the child, then B or an error. |
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
