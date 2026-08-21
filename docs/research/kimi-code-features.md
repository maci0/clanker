# Research — Kimi Code CLI feature inventory for clanker

## Status

Current — searched 2026-08-21. Opened kimi-code README and docs/en at source 2026-08-21; local record search back the seven steals and the ADR 0007 reject.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Which advertised Kimi Code CLI features are worth stealing into clanker, which we already have, and which we reject or defer, given existing RFC/ADR/PRD hits and the local tree?

State it precisely enough that a source either answers it or does not. "What
should we use for X" is not answerable; "which X can run inside a
wasm32-freestanding guest with no libc" is.

## TL;DR

Opened at source 2026-08-21: https://github.com/MoonshotAI/kimi-code README plus docs/en/{guides,customization,reference} (getting-started, interaction, sessions, goals, server, plugins, agents, mcp, tools, slash-commands, kimi-acp). Sweep snippets were leads only.

1. **Most advertised Kimi surface is already here under other names.** ACP (PRD 0030), MCP client (ADR 0025), hooks (ADR 0027), skills catalogue (PRD 0006 7.2), web video input (PRD 0006 7.1), plan mode, confirm-before-write, subagents, jobs list/wait/kill, schedule, goals loop (PRD 0035), presets (ADR 0030), session resume/fork/HTML export, !shell, /attach, mermaid. ROADMAP leftover "MCP client, ACP, hooks" is stale. — high — local records 2026-08-21
2. **Seven steals, none already decided as that question.** @-file mentions, session permission modes (yolo/auto/approve-for-session), operator /compact with a hint, markdown session export, goal queue, nested explore/plan/coder profiles, REPL mid-stream inject. clanker rfc search on those names returned no matching ADR. — high
3. **Plugin marketplace is rejected by ADR 0007.** Fetching, installing, signing, publisher identity, and a registry index are out of scope in writing. Kimi /plugins install from GitHub is that fetch path. — high — ADR 0007
4. **Computer Use, Datasource, WebSocket, and millisecond-startup races are rejects.** Desktop Accessibility automation is native host, not WASM. Datasource is a billed Kimi-account plugin. PRD 0006 forbids a WebSocket. Matching Kimi TTFF is a plan non-goal the way jcode RAM was. — high
5. **WebBridge overlaps PRD 0051 (later, from the jcode audit), not a new RFC.** First-class browser is already decided as later; do not open a rival. — high — PRD 0051

## Scope and method

- **Searched:** GitHub raw 2026-08-21: MoonshotAI/kimi-code README.md; docs/en/guides/{getting-started,interaction,sessions,goals,server,ides}.md; docs/en/customization/{plugins,agents,mcp,hooks,skills}.md; docs/en/reference/{tools,slash-commands,kimi-acp,kimi-command}.md. Local: clanker reports/rfc/adr/prd/research search for kimi, kimi-code, marketplace, yolo, mcp config, agent presets, hooks, video input, permission rules, background task, SYSTEM.md, device-code, compact instruction, undo; tree reads of src/tui/repl.zig command_registry, tools/manifests/jobs.tool.json, PRDs 0005/0006/0030/0032/0033/0035/0041/0051, ADRs 0004/0005/0007/0008/0025/0027/0030.
- **Not searched:** kimi-code TypeScript packages beyond the published docs, live kimi binary, kimi web UI source, changelog 99k internals, Chinese locale pages (mirrors). Those would not change steal vs reject once the English advertised claim and our ADRs are known.
- **Freshness:** 2026-08-21. kimi-code main as fetched that day. Already-have column ages with this tree; Kimi changelog ages fast.

## Options found

Kimi Code CLI is one product, MIT, TypeScript, advertised as a terminal coding agent. The options are verdicts per advertised feature, not competing libraries.

### Steal: @ file mentions inject path contents

Type @ to complete a relative path; the agent loads the file when it reads the message. Clanker composers take prose and /attach for images only. RFC 0010 mentioned mentions as future, not a decision. Evidence: kimi docs/en/guides/interaction.md File references, opened 2026-08-21; src/tui/repl.zig has no @ path expander.

### Steal: session permission modes

Kimi has manual / yolo / auto plus Approve for this session and [[permission.rules]] pattern allow/deny. Clanker has agent.confirm_writes never|browser|always and descriptor sandbox, no session-scoped allow after one approval, no /yolo. Evidence: interaction.md Approval flow and Mode switching; slash-commands.md /yolo /auto /permission; config-files permission section cited from mcp.md.

### Steal: operator /compact with a hint

/compact [instruction] compresses now and can tell the summarizer what to keep. Clanker compactMessages runs automatically with no slash command and no hint. Evidence: sessions.md Context compression; repl.zig command_registry has no /compact.

### Steal: markdown session export

/export-md writes a human-readable markdown file. Clanker session export is HTML-only (session_export_logic.zig, self-contained, no markdown re-render of untrusted text). A markdown form is a second renderer, not a rewrite of HTML. Evidence: sessions.md Exporting a session; tools/zig/session_export_logic.zig.

### Steal: goal queue

/goal next queues an upcoming objective that starts only when the current goal completes. PRD 0035 is one active goal loop; no queue. Evidence: docs/en/guides/goals.md Queue upcoming goals, opened 2026-08-21.

### Steal: nested explore/plan/coder profiles

Built-in subagents: coder (writes), explore (read-only), plan (no shell). Clanker ck_subagent is one generic nested Agent; ADR 0030 shipped main-session preset.toml, not default nested types. Evidence: customization/agents.md Built-in Sub-Agents; tools/manifests for subagent.

### Steal: REPL mid-stream inject

Ctrl-S injects composer text into the running turn without waiting. Web UI has POST /api/steer; the vaxis REPL has no equivalent. Evidence: interaction.md During streaming output; PRD 0006 8.6 is web-only.

### Already-have — advertised features that are not gaps

Single-binary (clanker is Zig). TUI (libvaxis REPL). Video in the web UI (PRD 0006 7.1). Skills catalogue (7.2). Hooks (ADR 0027). MCP client config.toml (ADR 0025). ACP (PRD 0030, clanker acp). Plan mode /plan. Confirm-before-write. Subagents and ck_swarm. jobs start/list/wait/kill. clanker schedule (ADR 0008). Goals loop (PRD 0035). Agent presets (ADR 0030). Session resume, /sessions, fork/branch, HTML export. !shell. /attach images. /model /theme /help. Shift-Enter. ask_user. todos. web_search/web_fetch. mermaid. AGENTS.md inject. Device OAuth strategies exist as ADR 0005 (no Kimi-specific login required to steal). kimi-for-coding is another openai_compat provider.

### Reject — contradicts a decided ADR or a non-goal

Plugin marketplace and /plugins install from GitHub (ADR 0007: fetch path without signing is the option they refused). Computer Use (macOS Accessibility / Windows mouse takeover: native desktop, not wasm32-freestanding). Kimi Datasource billed plugin (vendor quota). WebSocket event stream (PRD 0006: HTTP commands, SSE watch, no WebSocket). Millisecond startup / Node-free install race. Porting the TypeScript runtime. YOLO as removing the sandbox always-denied tier. Official Kimi plugins that require a Kimi Code account.

### Defer — worth it later, not an RFC this round

TUI video paste and ReadMediaFile (PRD 0041 explicitly non-goals video; web already samples frames). Conversational /mcp-config TUI and MCP OAuth (UX on ADR 0025, not a new client). /undo last prompts. /btw side conversation. Ctrl-G external editor. Serve bearer token. /import-from-cc-codex for skills/MCP (PRD 0050 is session transcripts). Subagent model pool. SYSTEM.md full prompt replace (presets append, non-goal to replace). Session-bound CronCreate while a process lives (recast onto clanker schedule; do not add a serve thread, ADR 0008). ACP session/close and terminal reverse-RPC (PRD 0030 remaining). Drag-drop image paste (PRD 0041 open). WebBridge as a Kimi extension (PRD 0051 is the browser steal).

## Out-of-the-box options

Checked explicitly, not skipped:

**Already in the tree.** Extend session_export_logic (markdown), session.compactMessages plus a /compact slash command, a host-tested @-mention expander used by the REPL submit path, preset.toml for nested explore/plan, POST /api/steer shape for REPL inject, confirm_writes plus a session allow-set. Do not add a native kimi-code clone. WASM-by-default: mention expand and markdown export are guests or host-tested helpers; permission modes and compact are harness (agent loop).

**Standard library / OS primitive.** @-mention expand is a path walk plus fs read. Markdown export is escaping plus role headings. Compact hint is a string appended to an existing summarizer prompt. None need a crate.

**Do nothing.** Operators keep pasting file contents, keep waiting for auto-compact, keep HTML-only shares, keep one goal at a time, keep generic subagents, keep switching to the web UI to steer. Cost is operator time, not a safety hole except permission modes (without yolo they already have never/always).

**Adjacent domain.** Claude Code @ mentions and permission modes are the same family; we already bridged their hooks.json (ADR 0027). Do not import their marketplace.

**Buy, host, or delegate.** Driving kimi as a child (RFC 0020 / ADR 0032 ACP client) is already the way to *use* kimi, not to steal its surface into clanker.

## Comparison

| Feature | Verdict | Local counterpart | Risk if stolen badly |
|---|---|---|---|
| @ mentions | steal | none | leaking .env if expander ignores secret_dotenv |
| permission modes | steal | confirm_writes | yolo as sandbox off |
| /compact hint | steal | auto compact | hint injected as untrusted prompt |
| markdown export | steal | HTML export | XSS if markdown is re-rendered from untrusted |
| goal queue | steal | PRD 0035 one goal | queue starting on blocked |
| explore/plan/coder | steal | preset.toml | unenforced read-only |
| REPL inject | steal | web steer | splice into wrong turn |
| marketplace | reject | ADR 0007 | unsigned fetch |
| Computer Use | reject | none | host desktop control |
| WebBridge | defer/already PRD 0051 | PRD 0051 | rival RFC |

## Evidence log

| Claim | Source | Read on | Confidence |
|---|---|---|---|
| README advertised features | https://raw.githubusercontent.com/MoonshotAI/kimi-code/main/README.md | 2026-08-21 | high |
| @ mentions, paste video, yolo, Ctrl-S | docs/en/guides/interaction.md | 2026-08-21 | high |
| compact hint, export-md, fork stays | docs/en/guides/sessions.md | 2026-08-21 | high |
| goal queue | docs/en/guides/goals.md | 2026-08-21 | high |
| plugins marketplace, WebBridge, Computer Use, Datasource | docs/en/customization/plugins.md | 2026-08-21 | high |
| coder/explore/plan | docs/en/customization/agents.md | 2026-08-21 | high |
| /mcp-config | docs/en/customization/mcp.md | 2026-08-21 | high |
| tools including CronCreate, AgentSwarm, ReadMediaFile | docs/en/reference/tools.md | 2026-08-21 | high |
| slash command table | docs/en/reference/slash-commands.md | 2026-08-21 | high |
| ACP matrix | docs/en/reference/kimi-acp.md | 2026-08-21 | high |
| kimi web token + WebSocket | docs/en/guides/server.md | 2026-08-21 | high |
| marketplace out of scope | docs/adrs/0007-plugin-manifests-are-declarative-and-unsigned.md | 2026-08-21 | high |
| no daemon | ADR 0008 | 2026-08-21 | high |
| no websocket | PRD 0006 Design constraint 3 | 2026-08-21 | high |
| jobs already list/wait/kill | tools/manifests/jobs.tool.json | 2026-08-21 | high |
| no /compact in REPL | src/tui/repl.zig command_registry | 2026-08-21 | high |

## Open questions

Whether Kimi permission.rules argument matching is worth copying (mcp.md says MCP parameters are not in permission matching). Spike: one session allow-set vs a full pattern language. Settled in the permission-modes RFC, not here.

## What would change the answer

ADR 0007 superseded to allow a signed registry. PRD 0041 growing a video phase. Kimi dropping MIT. Our ACP coverage catching kimi session/close.

## References

- https://github.com/MoonshotAI/kimi-code
- https://moonshotai.github.io/kimi-code/en/
- docs/prds/0006-webui.md (Kimi harness parity phases 6-7, shipped)
- docs/adrs/0007, 0008, 0025, 0027, 0030, 0032
- docs/prds/0030, 0032, 0033, 0035, 0041, 0051

## Appendix

Docs tree listed via GitHub git trees API sha d991402f (docs/en) on 2026-08-21. Full changelog not inventoried line by line.
