# PRD — External coding-agent driver (ACP client, headless fallback)

## Status

In progress — 2026-08-22. ACP client/headless/pickers shipped 2026-08-22 (src/acp/{client,fallback_spawn,driver,vendor}.zig, --backend). Image/prompt capabilities for grok/claude/codex are not forwarded yet — Goal 6.

Live (Goals 1–5): src/acp/client.zig, src/acp/fallback_spawn.zig, src/acp/driver.zig, src/acp/vendor.zig, plus --backend / [agent] backend in src/cli.zig and src/config.zig, pickers in ui/app/core/modelpicker.js and src/tui/repl.zig. Open (Goal 6): image ContentBlocks are not sent; HTTP/TUI still gate attachments on the LLM model image_in capability, which backends do not have.

## Problem

The operator has Claude Code, Codex, and Grok Build logins (OAuth / subscription) and no console API keys for those vendors. The vendor credential is issued for each vendor's own CLI client, expires, and the Messages / Responses APIs reject it from a third-party User-Agent — pasting an oat into clanker's provider env was tested by the operator and fails even though clanker already sends Bearer plus anthropic-beta: oauth-2025-04-20 (src/llm/providers/anthropic.zig). The only legitimate holder of that credential is the vendor's own CLI. clanker therefore cannot start Claude Code, Codex, or Grok Build today, and — because nothing drives them — their work cannot land in a run graph or be read by autolearn / improve-self. This is the harness half that ADR 0032 decided: clanker as the harness, the vendor CLI as the program that holds the login.



## Goals

1. Native ACP client starts a vendor ACP agent over stdio, sends initialize/authenticate/session/new/session/prompt, receives session/update, and implements session/request_permission.
2. First-party headless fallback (claude -p, codex exec, grok -p) is available when a vendor has no ACP, or when ACP breaks after a vendor update.
3. The vendor credential never enters clanker (not seen, stored, or logged).
4. Every driven session writes a run-graph node and autolearn can read it.
5. Spawn is harness-native code, not ck_job and not ck_exec's allowlist.
6. Composer/REPL/HTTP image attachments reach grok, claude, and codex backends the same way they reach a vision LLM: ACP session/prompt image ContentBlocks first, headless only if ACP cannot take them. Never silently drop an attached image.



## Non-goals

- **oat-as-API-key / TLS or header spoof.** Pasting the vendor login token into a provider env, or forging a vendor client to spend a subscription as an API key, is a hard reject (ADR 0032; RFC 0020). The credential is legitimate only inside the vendor's own CLI.
- **Replacing the clanker ACP server.** ADR 0026 / PRD 0030 keep clanker as the ACP *server* an IDE drives. This PRD adds the opposite role (clanker as an ACP *client* driving a vendor agent), reusing server framing only; it does not remove or rewrite `clanker acp`.
- **Making the child use WASM tools by default.** The child uses its own tools and writes the worktree. Pointing it at clanker's WASM tools via clanker MCP is possible but is not a default of this driver.
- **Ingest-only log watcher (RFC 0020 option D).** Reading vendor logs after the fact cannot start work or carry the session/request_permission awareness ACP provides; it was rejected in favor of A then B.

## Design

The driver is native harness code, not a guest and not `clanker acp` (that verb is the *server*, ADR 0026). clanker starts the vendor CLI as a subprocess and speaks ACP as the *client*.

**Operator surface.** No new work verb. The same backend selector is how every start picks the worker:

- CLI: `--backend` / `[agent] backend` on `run`, `repl`, and `goal` (names like `grok`, `codex`, `claude`).
- HTTP: `POST /api/run` takes the same field the web picker already sends for provider/model.
- Web UI model picker: these are rows in that picker, not a second dropdown. They sit in their own group under a short heading that says they are a local coding-agent backend (vendor CLI + login), not a `[providers.*]` API-key model. Same list, same save (`clanker.model` / whatever the picker already persists), visibly not DeepSeek/Anthropic-the-HTTP-API.
- TUI `/model` uses the same grouping so the two pickers do not drift.

Unset keeps today's in-process LLM loop. List a backend when that vendor CLI is actually present (PATH / configured command), not when an API key is set — `unconfiguredReason` does not apply. A fourth verb would fork the product the way a second `clanker acp` already would.

**Two paths, one Graph.** Path A sends initialize → authenticate (if the agent requires it) → session/new → session/prompt and consumes session/update; it implements session/request_permission (ACP client baseline). fs/* and terminal/* are not required to start: if the agent demands them, refuse the capability or fall through to B. Path B runs `claude -p`, `codex exec`, `grok -p`. Both persist the same `src/agent/graph.zig` `Graph` via the graph guest `write` action (the same JSON `Agent.persistGraph` already builds). They do **not** call `persistGraph` — that function is private on `Agent` and only runs at the end of an in-process loop. ACP `session/update` tool/message events map onto existing `NodeKind` (`tool`, `llm`, `final`). B writes a degraded graph: one `llm`/`final` pair from stdout. That is one schema, not two.

**ACP hang.** Cancel the child, persist a failed A node, then B for that vendor. Not "B or an error".

**Why native, not ck_job / ck_exec.** ck_job is jobs+subagent only (src/sandbox/jobs.zig). ck_exec allowlists git/zig/uv (src/sandbox/host.zig) and must not gain claude/codex/grok — that would let a guest spawn those CLIs outside the harness policy. Spawn lives in src/acp/ next to the client, using the process table in src/agent/subprocess.zig.

**Credential boundary.** clanker does not put a vendor token in config, argv, or logs, and does not parse one out of the stream. The child uses its own login store. JSON-RPC on stdio is the protocol, not a scan for "framing." Image bytes ride the same rule: they are ACP ContentBlock `data` (base64) or a temp file the child reads, never a log line and never a vendor token.

**Prompt capabilities (images).** Operator assertion, 2026-08-22: Codex takes images, same as Grok and Claude. All three backends are image-capable at the picker; do not consult the LLM catalog `image_in` flag for that. ACP v1 (https://agentclientprotocol.com/protocol/content, initialization at /protocol/v1/initialization, schema `ImageContent` in agentclientprotocol/agent-client-protocol `schema/v1/schema.json`, all fetched 2026-08-22):

- `session/prompt` `prompt` is an array of ContentBlocks. Text is required-to-support; image is optional and advertised as `agentCapabilities.promptCapabilities.image` (default false).
- Image block shape: `{"type":"image","mimeType":"image/png","data":"<base64>"}` with optional `uri`. Maps 1:1 onto clanker `types.ImagePart` (`mime` → `mimeType`, `b64` → `data`).
- `src/acp/server.zig` advertising `image: false` is clanker-as-server (an IDE driving clanker). Out of scope. Do not copy that into the client.

Policy when images are attached:

1. Picker / composer: a selected `grok`/`claude`/`codex` backend enables attach, independent of the in-process provider's `image_in`.
2. Path A: `Client.prompt` includes one image ContentBlock per `ImagePart` after the text block. For these three vendors, send even if initialize omitted `promptCapabilities.image` (they take images; a silent drop is worse than a vendor reject). A vendor that actually rejects is handshake_failed → Path B.
3. Path B: only if A cannot take them. Headless image argv for `claude -p` / `codex exec` / `grok -p` was **not** pinned at source this session; until it is, Path B with images must refuse with a named error rather than spawn text-only. Pin the flags at the vendor CLI `--help` / docs before writing `fallback_spawn.zig`. Candidate: write the decoded bytes to a temp file and pass the path; still must not log the bytes.
4. Forbidden: attach succeeding in the UI, run returning 200, child never seeing the image. HTTP already calls that "the worst failure mode" for the in-process loop (`src/cli.zig` around the multimodal gate).

**HTTP / TUI wiring (verified in tree at 878b8c65, not yet fixed).** `RunOpts` has no images field. `runCodingBackend` / `runIfBackend` take only `prompt`. `Client.prompt` hard-codes `[{"type":"text","text":...}]`. `POST /api/run` still runs `imageAttachmentsSupported(provider.activeModel())` even when `req.backend` is set, so a backend run either 400s on missing `image_in`, falls back to a vision *LLM* provider (wrong worker), or sets `Agent.pending_images` and then takes the backend path that ignores them. TUI submit slices into `Agent.pending_images` the same way. Files for the fix: `src/acp/client.zig` (`prompt` grows an images slice), `src/acp/driver.zig` (`RunOpts.images`), `src/cli.zig` (`runCodingBackendCtx` + skip the LLM `image_in` gate when backend is set and pass `req.images`), `src/tui/repl.zig` (backend run takes pending images), `ui/app/core/modelpicker.js` (backend rows advertise image so attach stays on). Tests drive shipped `driver.run` / fake ACP agent (`tests/fixtures/fake-acp-agent.py`) and assert the JSON-RPC line contains `"type":"image"` plus the mime and data; do not pre-build a Graph.

**Dependencies.**
- ADR 0032 — the decision this implements.
- RFC 0020 — the argument.
- ADR 0026 / PRD 0030 / src/acp/server.zig — JSON-RPC line framing only. session/request_permission on the server is the other direction (clanker asks the IDE). The client must implement the inverse (vendor agent asks clanker).
- tools/zig/graph.zig `write` + src/agent/graph.zig — persist shape.
- src/agent/auto_learn.zig `recordRun` — usage event (provider/model/tokens/tools). Hard blocker: none. The work is writing the client.

**Implementation.**
1. src/acp/client.zig (state machine + spawn). src/cli.zig / src/config.zig `--backend` / `[agent] backend`. GET /api/providers (or the same payload) lists backends as a separate group. ui/app/core/modelpicker.js (and TUI /model) render that group under the heading. Drive Grok `agent stdio`. Persist via graph `write` + autolearn.recordRun.
2. Same client, Codex argv `npx -y @agentclientprotocol/codex-acp` (published adapter).
3. Same client, Claude published ACP adapter once the package is opened and pinned.
4. src/acp/fallback_spawn.zig — B, same Graph write, used when ACP is missing or a turn is cancelled as broken.
5. CHANGELOG, docs/README.md, AGENTS.md.
6. Image attachments: `Client.prompt` emits ACP image ContentBlocks; `RunOpts.images` from CLI/TUI/HTTP; picker backend rows advertise image; skip LLM `image_in` when `backend` is set. Headless image flags only after pinning at vendor `--help`/docs.

## Known issues

- Image attachments never reach a coding-agent backend. Promised by Goal 6 (and by the composer, which will attach if the picker allows it). What happens: `session/prompt` is text-only (`src/acp/client.zig`); `runCodingBackend` does not take images (`src/cli.zig`); HTTP still gates on the LLM model's `image_in` (`imageAttachmentsSupported` in `src/cli.zig`). Fix belongs in the files listed under Design **Prompt capabilities (images)** / Implementation phase 6.

## Failure modes

| Condition | Behaviour |
| --- | --- |
| Vendor has no ACP | Fall back to B (headless spawn). |
| ACP hangs or deadlocks on session/request_permission | Cancel the child, persist a failed A node, then B. |
| Child exits non-zero | Failed run; persistGraph records the failure. |
| Unknown vendor | Refuse. |
| Vendor update breaks ACP | B takes over; A is not a hard dependency for that vendor. |
| Images attached + backend selected | Path A sends image ContentBlocks; never a 200 with the child seeing only text (Known issues until phase 6). |
| Images attached + backend + LLM model lacks image_in | Do not 400 and do not fall back to a vision LLM provider. The backend is the worker. |
| Images attached + ACP missing/hang and headless flags unpinned | Named refusal, not a text-only spawn. |

## Acceptance criteria

- [x] A native ACP client (src/acp/client.zig) starts a vendor ACP agent over stdio and completes initialize/authenticate/session/new/session/prompt, receiving session/update. (Goal 1)
- [x] The client implements session/request_permission. (Goal 1)
- [x] Headless fallback spawns claude -p / codex exec / grok -p when a vendor has no ACP, or when ACP breaks after a vendor update. (Goal 2)
- [x] No vendor credential is seen, stored, or logged by clanker on either path. (Goal 3)
- [x] Each driven session writes a run-graph node and autolearn can read it. (Goal 4)
- [x] Spawn is harness-native, not ck_job and not ck_exec's allowlist. (Goal 5)
- [x] The web UI model picker (and TUI /model) lists installed coding-agent backends in their own group, headed as a local CLI backend rather than an API-key provider; choosing one is what POST /api/run and run/repl/goal send as the backend. (Operator surface)
- [ ] Image attachments on grok, claude, and codex backends reach the child as ACP image ContentBlocks (`type`/`mimeType`/`data`) (Goal 6). Pinned by a driver.run test against the fake ACP agent, not a pre-built Graph.
- [ ] Selecting a backend does not disable composer attach and does not run the LLM image_in gate. (Goal 6)
- [ ] Headless fallback with images either uses vendor image flags pinned at that CLI help/docs, or refuses with a named error. It never strips the images and continues. (Goal 6)

## Open questions / future work

- Headless image argv for `claude -p`, `codex exec`, and `grok -p` is unset until pinned at each vendor CLI help/docs. ACP path does not wait on that. Settled policy is in Design (refuse named, do not spawn text-only).
- Whether fs/* and terminal/* must be implemented for a first working ACP session. Follow-on; Goals 1–5 already shipped without them. Fake ACP agent tests completed prompt-only sessions.
- Whether the child is later offered clanker MCP so it can call WASM tools. Optional follow-on; default off.
- Audio and embeddedContext prompt capabilities are the same ContentBlock family and stay out of scope until a vendor needs them; do not invent a second image-shaped path for them.
