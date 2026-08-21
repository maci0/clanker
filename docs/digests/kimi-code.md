# Digest: Kimi Code CLI

Source: <https://github.com/MoonshotAI/kimi-code> (MIT, TypeScript),
README plus `docs/en/` guides, customization, and reference opened at
source on 2026-08-21 (`interaction`, `sessions`, `goals`, `server`,
`plugins`, `agents`, `mcp`, `tools`, `slash-commands`, `kimi-acp`).
A terminal coding agent with a TUI, `kimi acp`, `kimi web`, a plugin
marketplace, and built-in `coder`/`explore`/`plan` subagents. The
interesting part is not the install script (clanker is already a
single binary) but the operational details that sit next to
capabilities we already have under different names.

Evidence and per-feature verdicts:
[docs/research/kimi-code-features.md](../research/kimi-code-features.md).

## What it actually is

A Node/TypeScript harness: interactive TUI (pi-tui), print mode
(`kimi -p`), ACP stdio, a loopback web server with REST plus
WebSocket, skills/hooks/MCP, and official plugins (Datasource,
WebBridge, Computer Use) that talk to a Kimi Code account.

Clanker is already the agent, already has `clanker serve` (HTTP +
SSE, no WebSocket), already has WASM tools, already has `clanker
acp`, already has an MCP *client* (ADR 0025), already has Claude-
shaped hooks, already has video in the web UI and skills in the
Tools view (PRD 0006 7.1/7.2). ROADMAP leftover "MCP client, ACP,
hooks" is stale. The overlap is large. The gaps are specific.

## The ideas worth stealing

### 1. `@path` in the composer loads the file

Type `@` to complete a relative path; the model sees the file
without a follow-up `read_file`.

**Clanker:** prose plus `/attach` for images. Steal a mention
expander that refuses dotenv/secret paths the sandbox already
refuses.

### 2. Session permission modes, not only confirm_writes

manual / yolo / auto, "Approve for this session", and
`[[permission.rules]]`. Yolo skips regular tool confirms; auto
also answers `ask_user`; plan-exit still confirms under yolo.

**Clanker:** `agent.confirm_writes` is never/browser/always. The
sandbox always-denied tier stays. Steal session modes on top of
it, never instead of it.

### 3. `/compact` with an optional hint

Operator-triggered compression, with a sentence that tells the
summarizer what to keep.

**Clanker:** compact is automatic and silent of hints. Steal the
slash command.

### 4. Markdown session export beside HTML

`/export-md` is for humans; the debug ZIP is for bugs.

**Clanker:** HTML export is the local-first share (no upload).
Steal a markdown renderer that does not re-parse untrusted text
as markdown HTML.

### 5. A queue behind the one active goal

`/goal next` holds upcoming objectives the agent does not see
until the current goal completes.

**Clanker:** PRD 0035 is one loop. Steal the queue.

### 6. Nested explore / plan / coder profiles

Read-only explore, no-shell plan, write-capable coder. Built-in
subagents cannot recurse.

**Clanker:** `ck_subagent` is one generic nested Agent; presets
are a main-session bundle (ADR 0030). Steal nested types as
shipped presets the subagent tool may name.

### 7. REPL mid-stream inject

Ctrl-S dumps the composer into the running turn.

**Clanker:** `POST /api/steer` is web-only. Steal the same queue
on the vaxis REPL.

## Already-have (do not re-RFC)

ACP, MCP client, hooks, skills catalogue, web video frames, plan
mode, confirm-before-write, subagents, jobs list/wait/kill,
schedule, goals loop, presets, session resume/fork/HTML export,
`!shell`, `/attach`, mermaid, `ask_user`, todos, AGENTS.md.

## Reject

Plugin marketplace / `install` from GitHub (ADR 0007). Computer
Use desktop automation. Datasource billed plugin. WebSocket
(PRD 0006). Millisecond-startup race. Porting TypeScript. YOLO as
sandbox off.

## Defer

TUI video paste (PRD 0041 non-goal). `/mcp-config` TUI. `/undo`.
`/btw`. Ctrl-G editor. Serve bearer token. Import CC skills/MCP.
Session-bound CronCreate (use `clanker schedule`). WebBridge as
Kimi's extension (PRD 0051 is the browser steal).
