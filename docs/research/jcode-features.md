# Research — jcode feature inventory for clanker

## Status

Current — searched 2026-08-21. Opened jcode README and architecture docs at source 2026-08-21; local record search and tree reads back the seven steals and the rejects.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Which advertised jcode features are worth stealing into clanker, which we already have, and which we reject or defer, given existing RFC/ADR/PRD hits and the local tree?

Opened at source: the jcode README and architecture docs listed under Scope. A README heading either has a local counterpart (already-have), a decided ADR that forbids it (reject), a later phase (defer), or a gap worth an RFC (steal). Sweep snippets are leads only.

## TL;DR

Ranked findings, each with a confidence. Everything below is the evidence.

1. **Seven steals, none already decided as that question.** Passive every-turn memory, file-shift notify, foreign-session resume, provider extra_body, Anthropic cache-cold warning, first-class browser tool, structure-aware grep. `clanker rfc search jcode` and the per-idea searches returned no matching ADR for those seven. — high — local record search 2026-08-21
2. **Memory is a tool plus /api/run inject, not a graph.** PRD 0007 ships hash-embed search over Knowledge; memorySearch fires only from handleRun. REPL and clanker run do not auto-recall. Local ONNX is a PRD 0007 non-goal. — high — [PRD 0007](../prds/0007-memory.md)
3. **Swarm members cannot see each other.** ck_swarm is one-level host fan-out (ADR 0006) and PRD 0008 quotes the guest comment that members cannot see each other. File-shift notify is new; chat DMs and mesh already exist. — high — [PRD 0008](../prds/0008-arena.md)
4. **No extra_body, no cache-cold clock, no browser catalog tool, no foreign importers.** extra_body is absent from src/config.zig Provider and openai buildRequest. Cache usage is accounted but not timed. Browser is not a catalog tool. Sessions resume only clanker's own store (ADR 0033). — high — local tree 2026-08-21
5. **Reject the daemon, the RAM race, mermaid-rs, iOS, telemetry, sponsored discovery, self-dev exec.** ADR 0008 forbids an always-on loop. Ambient recasts as schedule run-due later, not a steal of the daemon. — high — [ADR 0008](../adrs/0008-the-scheduler-is-cron-driven-not-a-daemon.md)
6. **Already-have that look like gaps on a README skim:** explicit memory tool, session_search, chat DMs, ck_subagent/ck_swarm, MCP client (PRD 0032), mermaid in the web UI (PRD 0006), own-session resume (PRD 0005), clanker setup/providers. — high

## Scope and method

- **Searched:** opened-at-source GitHub raw files for jcode README plus docs/MEMORY_ARCHITECTURE.md, SWARM_ARCHITECTURE.md, SAFETY_SYSTEM.md, AMBIENT_MODE.md, SERVER_ARCHITECTURE.md, BROWSER_PROVIDER_PROTOCOL.md, RESUME_BEHAVIOR.md, MERMAID_RENDERING_REDESIGN.md (2026-08-21). Local: clanker reports/rfc/adr/prd search for jcode, memory graph, swarm, resume, extra_body, cache-cold, browser, provider login, agent-grep; tree reads of src/config.zig Provider, src/llm/providers/openai.zig, tools/zig/{memory,repo_search,symbols}.zig, PRDs 0005/0006/0007/0011/0032, ADRs 0004/0005/0008/0025/0033, RFC 0004/0008/0019/0020.
- **Not searched:** jcode crates source beyond the published docs, live jcode binary, Discord, telemetry-worker, iOS tree, mermaid-rs repo internals. Those would not change steal vs reject once the README claim and our ADRs are known.
- **Freshness:** 2026-08-21. jcode master as fetched that day (7106 commits on the repo page). Feature list ages with their README; our already-have column ages with this tree.

## Options found

jcode is one product, MIT, Rust, ~7106 commits, README dated by last commit 2026-08-21. The options are verdicts per advertised feature, not competing libraries.

### Steal — seven gaps that are not already decided

**Passive memory retrieval every turn (plus extraction).** jcode embeds each turn and injects cosine hits (optional sidecar verify) without a memory tool call. Extraction runs on semantic drift, K turns, or session end. Clanker: memory WASM tool + /api/run memorySearch only (PRD 0007). RFC 0004 out-of-scoped auto-inject of Muninn hits. Do not steal the ONNX embedder or petgraph (PRD 0007 non-goal; wasm32-freestanding). Evidence: jcode MEMORY_ARCHITECTURE.md (opened 2026-08-21); src/cli.zig memorySearch callers.

**Swarm file-shift notify.** When agent A edits a file agent B has read, the server notifies B. Clanker: ck_swarm members cannot see each other (PRD 0008). RFC 0008 is git claims, not read-set notify. Chat DMs already exist; this is a typed file-touch event, not a new chat. Evidence: jcode SWARM_ARCHITECTURE.md File Touch; docs/runbooks/concurrent-agent-sessions-on-one-checkout.md.

**Foreign-session resume.** Import Claude Code, Codex, OpenCode, pi transcripts into a clanker session. Own sessions already resume (PRD 0005, ADR 0033). RFC 0020 is drive their CLI, not parse their log. Evidence: jcode README Misc + RESUME_BEHAVIOR.md.

**Provider extra_body.** Merge a config JSON object last into openai_compat request bodies so NIM/vLLM chat_template_kwargs work. Absent from config.zig Provider and openai.zig buildRequest. Evidence: jcode README Extra request-body fields; local grep extra_body empty.

**Anthropic cache-cold warning.** Claude prompt cache goes cold after 5 minutes idle; warn before send and on unexpected miss. We already parse cache_read_input_tokens and show a cache segment when the provider reports it (PRD 0005). No 5-minute clock. Evidence: jcode README Misc; src/serve/proxy.zig usage mapping.

**First-class browser tool.** One catalog tool (status/setup/open/snapshot/click/type/...) with a provider protocol; Firefox Agent Bridge first. MCP client (PRD 0032) can attach a server but is not a first-class browser. Evidence: jcode BROWSER_PROVIDER_PROTOCOL.md and README Browser Automation.

**Structure-aware grep.** Attach enclosing fn/type (and displacement) to grep hits so the model infers file shape without a full read. repo_search and symbols are separate tools; rg hits have no enclosing symbol. Evidence: jcode README Agent grep; tools/zig/repo_search.zig, tools/zig/symbols.zig.

### Already-have — README features that are not gaps

Explicit memory tool (memory WASM). Session search (session_search / FTS5). Swarm DMs/broadcast (chat_*, ck_chat, mesh). Autonomous swarm spawn (ck_subagent/ck_swarm, one-level). OAuth/auth strategies (ADR 0005) and named providers. MCP config (PRD 0032/ADR 0025). Web UI mermaid (PRD 0006). Own-session resume (PRD 0005). clanker setup/providers. Confirm-before-write and hooks cover attended safety.

### Reject — contradicts a non-goal or a decided ADR

RAM/TTFF numbers. mermaid-rs. Handterm. 1000 fps. iOS/OpenClaw. Telemetry. Sponsored discovery. Self-dev binary reload. jcode serve auto-spawn daemon and Unix socket (ADR 0008). Local ONNX embedder (PRD 0007 non-goal). New git primitive (jcode planned, not shipped; RFC 0008 is ours). Server adjective-animal names.

### Defer — worth it later, not an RFC this round

Memory sidecar LLM verify. Ambient garden recast as schedule run-due (after a graph exists). TUI side panel, info widgets, alignment, emoji toggle. Multi-account /account switch (UX on ADR 0005). Semantic skill embedding inject (skills already listed by title+description). Adaptive grep seen-set truncation. Interleaved KV-cache-safe input. Dictate, SDK, memorable session names. Unattended safety queue (ambient-only).

## Out-of-the-box options

Checked explicitly, not skipped:

**Already in the tree.** Extend memory (PRD 0007 guest), repo_search, openai_compat buildRequest, token_stats / turn_stats, sessions store, MCP client. Do not add a native jcode clone. WASM-by-default still holds: extra_body and cache-cold are harness (provider hot path, ADR 0004); grep outline is a guest helper; browser is a guest plus a host channel if a socket is required.

**Standard library / OS primitive.** extra_body merge is JSON object overlay in std.json. Cache-cold is a timestamp compare. Enclosing-symbol is a line walk over source already read for the hit. Foreign resume is a parser over JSONL files on disk. None need a crate.

**Do nothing.** NIM/vLLM thinking stays broken without extra_body. Concurrent agents keep stomping files without notify (the 2026-08-16 incident). Operators whose Claude Code session died still cannot continue here. Grep still burns a follow-up read_file per hit. Cost of delay is operator time and token burn, not a safety hole except file-shift.

**Adjacent domain.** MuninnDB is the graph we already chose for LLM I/O (RFC 0004/ADR 0015) and could later back memory, but auto-inject was explicitly out of that RFC. Playwright/CDP MCP servers exist; a first-class tool is still the steal because the model should not pick among MCP names.

**Buy, host, or delegate.** Pointing openai_compat at jcode's proxy would not give us extra_body or cache-cold on our own providers. Driving jcode as a child (RFC 0020 shape) is rejected for the same reason as Claude Code children: a second agent binary is a trust expansion.

## Comparison

| Verdict | Maturity of the jcode idea | Licence | Fit here | Main risk |
|---|---|---|---|---|
| Steal extra_body | shipped in jcode README | MIT | native provider config, ADR 0004 | opaque keys can override our sampling fields |
| Steal cache-cold | shipped | MIT | timestamp + existing usage parse | 5 min is Anthropic-specific; other providers differ |
| Steal agent-grep outline | shipped | MIT | repo_search guest helper | language coverage; Zig-first is enough for phase 1 |
| Steal passive memory | shipped + graph planned | MIT | extend PRD 0007, hash embed not ONNX | token burn if we inject junk; no sidecar in v1 |
| Steal file-shift notify | shipped | MIT | host event, not ck_swarm rewrite | false positives on every write |
| Steal foreign resume | shipped for 4 harnesses | MIT | sessions guest parser | transcript formats drift |
| Steal browser tool | shipped Firefox backend | MIT | guest + optional host channel | setup burden; MCP already covers some users |
| Already-have (memory tool, chat, swarm spawn, MCP, mermaid web, own resume) | our tree | MIT | n/a | re-RFC would hide the duplicate |
| Reject daemon / ONNX / mermaid-rs / iOS / telemetry | n/a | n/a | ADR 0008, PRD 0007, plan non-goals | copying anyway would fight the sandbox |

## Evidence log

Rejected leads stay: RAM tables, mermaid-rs, handterm, ambient daemon, ONNX.

| Claim | Source | Read on | Confidence |
|---|---|---|---|
| jcode advertises memory graph, swarm file-shift, extra_body, cache-cold, browser, agent-grep, foreign resume | https://github.com/1jehuang/jcode README | 2026-08-21 | high |
| Memory architecture is async, cosine, optional sidecar, ONNX MiniLM | https://raw.githubusercontent.com/1jehuang/jcode/master/docs/MEMORY_ARCHITECTURE.md | 2026-08-21 | high |
| File touch notifications exist in swarm design | https://raw.githubusercontent.com/1jehuang/jcode/master/docs/SWARM_ARCHITECTURE.md | 2026-08-21 | high |
| Ambient is an always-on loop, disabled by default | https://raw.githubusercontent.com/1jehuang/jcode/master/docs/AMBIENT_MODE.md | 2026-08-21 | high |
| jcode serve is a Unix-socket daemon with /reload exec | https://raw.githubusercontent.com/1jehuang/jcode/master/docs/SERVER_ARCHITECTURE.md | 2026-08-21 | high |
| Browser tool is one tool, many providers, Firefox first | https://raw.githubusercontent.com/1jehuang/jcode/master/docs/BROWSER_PROVIDER_PROTOCOL.md | 2026-08-21 | high |
| /resume picker is local UI; foreign sessions convert then resume | https://raw.githubusercontent.com/1jehuang/jcode/master/docs/RESUME_BEHAVIOR.md | 2026-08-21 | high |
| mermaid-rs redesign is TUI-internal, not a product steal | https://raw.githubusercontent.com/1jehuang/jcode/master/docs/MERMAID_RENDERING_REDESIGN.md | 2026-08-21 | high |
| Safety system is ambient-first HITL | https://raw.githubusercontent.com/1jehuang/jcode/master/docs/SAFETY_SYSTEM.md | 2026-08-21 | high |
| no report/RFC/ADR/PRD mentions jcode | clanker reports/rfc/adr/prd search jcode | 2026-08-21 | high |
| extra_body absent from this tree | ripgrep extra_body over zig/toml/md | 2026-08-21 | high |
| memorySearch is /api/run only | src/cli.zig callers; PRD 0007 | 2026-08-21 | high |
| ck_swarm members cannot see each other | PRD 0008; ADR 0006 | 2026-08-21 | high |
| scheduler is not a daemon | ADR 0008 | 2026-08-21 | high |
| ONNX embedder is a PRD 0007 non-goal | PRD 0007 Non-goals | 2026-08-21 | high |

## Open questions

Whether Anthropic's 5-minute cache TTL is still the documented number (spike: read current Anthropic prompt-cache docs at RFC time). Whether Claude Code / Codex session file shapes have a stable schema version (spike: one sample file each before the importer lands). Whether a first-class browser needs a new ck_browser channel or can exec a local bridge under exec_allow (spike: Firefox Agent Bridge transport). Hash-embed recall quality vs a real embedder (already a PRD 0007 open; does not block the every-turn inject RFC).

## What would change the answer

A matching ADR for any of the seven steals. A PRD 0007 rewrite that already injects on every Agent.run turn. Anthropic changing cache TTL. jcode relicensing. This tree growing extra_body or a browser tool independently.

## References

Primary (opened 2026-08-21):
- https://github.com/1jehuang/jcode
- https://raw.githubusercontent.com/1jehuang/jcode/master/docs/MEMORY_ARCHITECTURE.md
- https://raw.githubusercontent.com/1jehuang/jcode/master/docs/SWARM_ARCHITECTURE.md
- https://raw.githubusercontent.com/1jehuang/jcode/master/docs/SAFETY_SYSTEM.md
- https://raw.githubusercontent.com/1jehuang/jcode/master/docs/AMBIENT_MODE.md
- https://raw.githubusercontent.com/1jehuang/jcode/master/docs/SERVER_ARCHITECTURE.md
- https://raw.githubusercontent.com/1jehuang/jcode/master/docs/BROWSER_PROVIDER_PROTOCOL.md
- https://raw.githubusercontent.com/1jehuang/jcode/master/docs/RESUME_BEHAVIOR.md
- https://raw.githubusercontent.com/1jehuang/jcode/master/docs/MERMAID_RENDERING_REDESIGN.md

Local:
- docs/prds/0005-repl-tui.md, 0006-webui.md, 0007-memory.md, 0008-arena.md, 0011-clanker-mesh.md, 0032-mcp-client-bridge.md
- docs/adrs/0004, 0005, 0006, 0008, 0025, 0033
- docs/rfcs/0004, 0008, 0019, 0020
- src/config.zig Provider, src/cli.zig memorySearch, tools/zig/repo_search.zig, tools/zig/symbols.zig

## Appendix

Full advertised-feature table with every verdict: scratch inventory.md written the same day as this note (goal scratch, not this repo). Record-store search capture: scratch record-search.txt.
