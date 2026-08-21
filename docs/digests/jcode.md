# Digest: jcode

Source: <https://github.com/1jehuang/jcode> (MIT, Rust), README plus
architecture docs opened at source on 2026-08-21
(`MEMORY_ARCHITECTURE.md`, `SWARM_ARCHITECTURE.md`, `SAFETY_SYSTEM.md`,
`AMBIENT_MODE.md`, `SERVER_ARCHITECTURE.md`, `BROWSER_PROVIDER_PROTOCOL.md`,
`RESUME_BEHAVIOR.md`, `MERMAID_RENDERING_REDESIGN.md`). A RAM-efficient
coding-agent harness with a TUI, a Unix-socket daemon, a memory graph,
swarm file-shift notify, and a first-class browser tool. The interesting
part is not the RAM table (a plan non-goal) but the operational details
that sit next to capabilities we already have under different names.

Evidence and per-feature verdicts:
[docs/research/jcode-features.md](../research/jcode-features.md).

## What it actually is

A single-binary Rust harness: TUI client, optional `jcode serve` daemon
on a Unix socket, many named provider logins, an ONNX embedder plus
sidecar for passive memory, and swarm coordination that notifies an
agent when a file it has read is edited under it. Self-dev reloads the
binary in place. Ambient mode is an always-on garden/scout/work loop
behind a safety review queue.

Clanker is already the agent, already has `clanker serve` (HTTP, opt-in),
already has WASM tools, already has `ck_swarm` / `ck_subagent`, already
has a memory *tool* and `/api/run` inject (PRD 0007). The overlap is
large. The gaps are specific.

## The ideas worth stealing

### 1. Passive recall every turn, not a memory tool the model must remember to call

jcode embeds the turn, cosine-searches a graph, and injects hits (or
hands them to a sidecar). Extraction is a separate sideagent on drift /
K turns / session end. Explicit memory tools still exist.

**Clanker:** `memory` WASM + `memorySearch` on `/api/run` only. REPL and
`clanker run` do not auto-recall. RFC 0004 out-of-scoped auto-inject of
Muninn hits. Steal the *every-turn inject + extraction* shape on the
existing hash embedder; do not steal ONNX or petgraph (PRD 0007
non-goals; wasm32-freestanding).

### 2. File-shift notify when a peer edits a file you have read

Optimistic swarm: no locks. When A writes a path B has read, B is
notified and can ignore it or diff. Separate from DMs.

**Clanker:** `ck_swarm` members cannot see each other (PRD 0008). Chat
DMs and mesh exist. RFC 0008 is git claims, not a read-set. The
concurrent-sessions runbook is recovery after damage. Steal a typed
file-touch event between live sessions, not a second chat.

### 3. Resume someone else's dead session

Claude Code / Codex / OpenCode / pi transcripts import, then resume as
a jcode session.

**Clanker:** own sessions resume (PRD 0005, ADR 0033). RFC 0020 drives
those CLIs as children, it does not parse their logs. Steal importers.

### 4. `extra_body` merged last into OpenAI-compat requests

NIM DeepSeek-V4 and similar gateways only think when
`chat_template_kwargs` is present. jcode merges a config table (and
`JCODE_OPENAI_EXTRA_BODY`) last, overriding generated keys.

**Clanker:** no `extra_body` on `Provider` or in `openai.zig`
`buildRequest`. Steal the merge. Invalid values should fail config load
or be logged and skipped, not 400 the model by accident.

### 5. Anthropic cache-cold clock

Claude's prompt cache dies after five minutes idle. jcode warns before
send and on an unexpected miss.

**Clanker:** we parse `cache_read_input_tokens` and show a `cache`
segment when the provider reports it. We do not clock idle time. Steal
the clock; keep the existing usage parse.

### 6. One `browser` tool, provider protocol behind it

status / setup / open / snapshot / click / type / … with Firefox Agent
Bridge first, capability negotiation so Chrome/CDP can join later.

**Clanker:** MCP client (PRD 0032) can attach a Playwright server. That
is not a first-class catalog tool and the model has to pick among MCP
names. Steal the one-tool surface; defer the Firefox-specific setup
until the guest + protocol exist.

### 7. Structure on grep hits

Agent-grep returns enclosing functions and displacement with each hit,
and later truncates by what the agent has already seen.

**Clanker:** `repo_search` (rg / ast-grep / semcode) and `symbols` are
separate tools. Hits have no enclosing symbol. Steal outline-on-hit in
`repo_search`; defer seen-set truncation.

## Already-have (do not re-RFC)

Explicit `memory` tool. `session_search`. `chat_*` DMs and mesh.
`ck_subagent` / `ck_swarm` spawn. ADR 0005 auth + named `[providers.*]`.
MCP client. Web UI mermaid (PRD 0006). Own-session resume. `clanker
setup` / `providers`. Attended confirm-before-write and hooks.

## Reject

RAM/TTFF contests. mermaid-rs. Handterm. 1000 fps TUI. iOS / OpenClaw.
Telemetry. Sponsored discovery. Self-dev `exec` of a new binary. Auto-
spawn Unix-socket daemon (`/reload`). Local ONNX embedder. A new git
primitive (jcode's own planned feature; RFC 0008 is ours). Ambient as a
daemon (ADR 0008). Recast garden work as `clanker schedule run-due`
later, after a memory graph exists.

## Defer (no RFC this round)

Memory sidecar LLM verify. TUI side panel / info widgets / alignment /
emoji toggle. Multi-account `/account`. Semantic skill embedding.
Adaptive grep truncation. KV-cache-safe interleaved input. Dictate,
SDK, memorable session names. Unattended safety review queue.

## Security stances worth noting

jcode's safety system has no "always denied" tier: if the human
approves, the agent may do it. Clanker's sandbox *does* have always-
denied (descriptor policy, `ck_exec` allowlist, dotenv refusal). Do not
import "no always denied" into the guest. The steal of browser and
file-shift must still go through `fs_prefixes` / `network_allow`.
`extra_body` must not be a way to smuggle secrets onto the wire beyond
what the provider body already holds.

Ambient's "anything that talks to a human needs permission" is the same
spirit as our confirm-before-write, applied to an unattended loop we are
not adding.
