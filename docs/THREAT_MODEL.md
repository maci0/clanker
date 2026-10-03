# clanker Threat Model

Last reviewed: 2026-10-03. Every file:line reference below is re-resolved against the tree by
`scripts/check-threat-model.py`, which exits non-zero on any reference whose cited line does not
carry the symbol the reference names. A ±4-line window exists for a clause that cites a doc
comment or a call site instead of the `fn` line, and it belongs to the symbol that clause named:
before 2026-10-03 any symbol in the cell could use it, and three stale citations in the chatroom
row survived on a neighbour's definition.

```
python3 scripts/check-threat-model.py            # counts, exits non-zero on drift
python3 scripts/check-threat-model.py --list     # every reference and how it resolved
```

The totals are printed by the script and deliberately not transcribed here: a number written into
this file goes stale exactly like a line number does, and a stale count is the failure this pass
exists to fix. Run it and read the output.

Both the script and its unit tests (`scripts/test_check_threat_model.py`) run as the
"Check threat model references" CI step and as the same step in `scripts/verify.sh`. An earlier
version of this file asserted the property above while nothing in the tree invoked either, which
is how 98 references drifted; a check nothing runs is a claim, not a check.

That check was written this pass, after the same claim had been false three reviews running: 43 of
92, then 39 of 82, then 96 of 280 references landed on unrelated code, and the file below was
corrected each time. A claim in a document is not a check, so the check now ships and can be
re-run by whoever reads this next. Most references are checked against the symbol they name. The
rest sit in dense table rows that cite a location without naming a symbol, so no keyword can
confirm what the cited line says; the script asserts those spans *contain* named code text
instead, so they still fail when a line moves off the code it claims, and every needle was read
off the line it describes. That rule earned its place on the first run: it caught
`docs/README.md:854` and `docs/README.md:1535` both pointing into the route table instead of the
sections they claimed. The rest of the script's limits are in
[document quality](#7-threat-model-document-quality).

Evidence is static code inspection, not attack testing. Owner, review cadence, and disclosure
process remain unset (organizational, not invented here).

Owner: unassigned. Review cadence: not set. Vulnerability disclosure process: none documented
(no `SECURITY.md`; see [Response readiness](#8-response-readiness-note-only)).

## TL;DR: risk-ranked summary

| # | Risk | Impact | Likelihood | Notes |
|---|------|--------|------------|-------|
| R1 | **Unauthenticated control includes native configuration and backend execution, not just sandboxed tools.** The HTTP handler has Host/Origin checks but no caller authentication (`unexpectedHost` `src/cli.zig:8494`, `crossOriginRequest` `src/cli.zig:8519`). Raw config reads disclose file contents (`handleConfigRawGet` `src/cli.zig:12437`); validated writes change the operator's policy (`handleConfigRawSet` `src/cli.zig:12468`). `/api/run` can select a native backend (`req.backend` validated `src/cli.zig:17485`, dispatched `runCodingBackendCtx` `src/cli.zig:17885`, adapter name validated `acp_vendor.Name.parse` `src/cli.zig:4434`), and `POST /api/a2a/message` (`handleA2AMessage` call `src/cli.zig:8834`) is a second agent-invoking route that is on in a stock install (`modules.a2a` defaults true, `src/config.zig:1110`). | Critical: configuration, credentials stored there, and operator-level execution | High for a reachable local client; remote exposure depends on bind/network policy | Loopback/Host/Origin are not user identity. WASM grants do not contain the native paths; see T7. The same absence governs the local IPC surfaces (T9). The docs state the absence plainly (`docs/README.md:1623`, `README.md:250`). |
| R2 | **Proxy credential spending.** Proxy authentication is optional; a `proxy_token_env` naming an unset variable skips authentication entirely (`src/cli.zig:8498-8503`, standalone `src/proxy_main.zig:322-327`). The standalone proxy runs no Host/Origin guard: `src/proxy_main.zig` contains no `unexpectedHost` or `crossOriginRequest` call. | High: provider spend and submitted prompt data | High when reachable without a token | A proxy token protects only proxy paths, never `/api/*`. Startup warnings are not access controls (`src/cli.zig:8003`-`:8010`, `src/proxy_main.zig:131-132`). |
| R3 | **Prompt injection through LLM responses.** Provider output is untrusted input to the agent loop; retrieved documents, memory hits, and tool results are untrusted text the model is told never to execute (`src/agent/system_prompt.zig:697`). Containment is the sandbox, not the prompt. | High (tool misuse within sandbox policy) | Certain (inherent to an agent harness) | The sandbox is the trust boundary that makes this survivable; see M5. |
| R4 | **Mesh join without credential.** Mesh admission is allowlist-by-name, prompt, or open (`Admission`, `src/peers/mesh.zig:124`; `admit` `src/peers/mesh.zig:133`); the wire carries no authentication beyond the admission handshake and no encryption (plain TCP). Default bind is loopback `127.0.0.1:7420` (`Mesh.listen_host`/`listen_port` `src/config.zig:990-991`). | Medium (chat/fan-out spoofing, membership) | Medium (needs LAN reach or misconfig) | Off by default (`modules.mesh`). |
| R5 | **Sandbox escape via symlinks was a real class** (ADR 0017); `safeJoinSecure` now refuses symlinked components on granted paths (`src/sandbox/host.zig`, path policy). Anything that broadens the sandbox (kernel, docker, exec allowlist, `agent.sandbox_follow_symlinks`) re-opens it. | High | Low (fixed, recurring class) | See [history](#threats-the-history-already-demonstrates-recurring-classes). |
| R6 | **DoS: connection limit 64** (`max_connection_threads`, `src/cli.zig:8138`, enforced `:8139`; proxy surface keeps a web UI reserve `:8186`; `/health/ready` reports `saturated` in `readinessBody` `src/cli.zig:9986`), request bodies capped at `max_body_bytes` + 64 KiB slack (`src/cli.zig:8432-8435`), images capped 4 MB × 4 (`src/cli.zig:10321`, count `:10321-10322`). Saturation refusals reset their own per-request state, book under `errors_total`, and log with a fresh request id (`respondSaturated`, `src/cli.zig:8238`), then FIN-then-drain so the 503 survives the close (`drainThenClose`, `src/cli.zig:8264`). The proxy's upstream deadlines default to 300 s first byte / 60 s idle (`src/serve/proxy.zig:30-31`, wiring `:426-427`, knobs `src/config.zig:1052-1056`). The mesh join handshake holds its own bounded thread pool (`max_inbound_conns`, `src/serve/mesh_net.zig:38`, enforced `:630`). Still no inbound per-route rate limit (`src/llm/rate_limit.zig` limits *outbound* provider requests, not callers), so any local process can hold all 64 slots. | Medium | Medium | Loopback-only default keeps this local. |
| R7 | **Unauthenticated internal-infrastructure recon: `GET /api/mcp/servers` returns every configured `[mcp_servers.*]` command and URL** (`src/cli.zig:8653`, handler `:12619`), and each stanza names a program that would run outside the WASM sandbox once `modules.mcp_client` is on (`src/config.zig:1105`, stanza shape `McpServer` `src/config.zig:1266`). No authentication on the route. Lower impact than R1 because it exposes configuration rather than acting on it, but it is the one read-only route that names the operator's internal hosts | Low | Medium | Reads configuration only, but unauthenticated and loopback-default, like every other route. |
| R8 | **Extension points that are less bounded than the sandbox they were added beside.** `clanker <name>` Tier 2 execs a PATH binary unsandboxed with inherited stdio (`src/cli.zig:6033-6043`); DAP, hooks and `!cmd` name programs from config (`src/config.zig:769`, `src/hooks/config.zig:10`). Each is gated on an operator-set enabled list rather than a sandbox. Local-only, but the one class where adding a convenience *reduces* the containment the rest of the tree enforces | High | Low | Needs an operator action first (install + enable), which is why likelihood is Low. |
| R9 | **A native file reader over the workspace, unauthenticated.** `GET /api/files?path=` (`handleFiles`, `src/cli.zig:14492`) lists directories and returns file contents with the server's own authority, not through a sandboxed guest, so the descriptor grants that bound `read_file` do not bound it. Its own bounds hold: `..` is clamped at the root, a symlinked component answers 403 (`pathHasSymlinkComponent` refusal, `src/cli.zig:14553`), the body is capped at `file_preview_cap` (`src/cli.zig:14457`, enforced `:14687`), and dotenv files are hidden and unread through the module `safeJoin` also applies to guests (`secret_dotenv.isSecretDotenvPath`, `src/util/secret_dotenv.zig:49`, refused `src/cli.zig:14540`, hidden from the listing `:14626`). An owner-only file is skipped the same way (`isOwnerOnlyFile`, `src/cli.zig:14478`, applied `:14640`). What remains is every other non-dotenv file in the checkout, to any caller on the port — including one that reaches the agent only by transcript. Same trust as every other route (no authn), so it is not a new boundary; it is the widest *read* the control plane offers. | Medium-High | Medium | Bounded by the root clamp, the no-follow walk, the dotenv refusal and the owner-only skip. Those four are named above so a later pass can aim a check at them. |
| R10 | **The chatrooms HTTP writes are a shared, cross-instance control plane with no caller identity, and their ownership check compares the wrong side.** `POST /api/chat/send`, `/subscribe`, `/react`, `/edit`, `/delete`, `/pin`, `/topic` (`handleChatSend` `src/cli.zig:9318` through `handleChatTopic` `src/cli.zig:9507`) each write durable state attributed to `cfg.instance.name`, the *server's* identity: `sendMessageOpts` stamps `.from = cfg.instance.name` (`src/peers/chatrooms.zig:903`) and `editMessage`/`deleteMessage` accept a message when `m.from == from` (`src/peers/chatrooms.zig:706`, `src/peers/chatrooms.zig:739`) with each handler passing that same name (`handleChatEdit` `src/cli.zig:9425`, `handleChatDelete` `src/cli.zig:9464`). So the 403 fires for a *peer-authored* message and never for a second caller of this same instance, and `/api/chat/react` has no ownership check at all - any caller toggles a reaction attributed to this instance (`handleChatReact` `src/cli.zig:9395`). Worse, `send` auto-joins whatever room the body names (the `isSubscribed` guard `src/cli.zig:9338`, `subscribe` `src/peers/chatrooms.zig:1190`), and `receive` (`src/peers/chatrooms.zig:606`) logs any peer-shaped POST into any subscribed room, so the same anonymous caller can make this instance *speak* and *receive* in a fleet-wide room; what a peer's text then reaches is the model prompt (`readNew` `src/peers/chatrooms.zig:1266`, injected `src/agent/loop.zig:985`, `inbox_limit` 5). On by default in a stock install (`modules.chatrooms` `src/config.zig:1136`, `chatrooms.on` `src/config.zig:1085`). The shipped docs claimed "403 when the caller is not the sender" (`docs/README.md:1617`; the 403 row of `docs/api.md:40`); both now read what the code does. | High | Medium | Per-field caps hold (`max_text_len` 4096 `src/peers/chatrooms.zig:53`, `max_emoji_len` 64 `:83`, `max_topic_len` 1024 `:57`, UTF-8 sanitised on append (`sendMessageOpts` `src/peers/chatrooms.zig:900`), per-write lock (`acquireChatroomLock` `src/peers/chatrooms.zig:435`) + atomic rewrite). A fix belongs to authz-review |
| R11 | **The mesh operator controls sit on the same unauthenticated HTTP surface as everything else.** `POST /api/mesh/pending` admits or denies a queued peer (`resolvePending` `src/serve/mesh_net.zig:886`; `handleMeshPendingPost` `src/cli.zig:16956`) - prompt-mode admission is the only human check the mesh has, and any caller can answer it; `POST /api/mesh/leave` evicts one member or all of them (`leave` `src/serve/mesh_net.zig:841`; `handleMeshLeave` `src/cli.zig:16901`); `POST /api/mesh/join` dials an arbitrary `host:port` straight out of the request body (`parseHostPort` `src/serve/mesh_net.zig:316`; `handleMeshJoin` `src/cli.zig:16866`), an outbound connect on demand from an anonymous caller. `GET /api/mesh/pending` and `GET /api/mesh/status` disclose the queue and the membership (`handleMeshPendingGet` `src/cli.zig:16928`, `handleMeshStatus` `src/cli.zig:16830`). Off by default (`modules.mesh`, `src/config.zig:1146`), which is what keeps this below R10. | High | Low-Medium | Bounded by `join_wait_ns` on the dial and by `max_pending_joins` 8 (`src/config.zig:995`, clamped `src/serve/mesh_net.zig:695`). No caller check anywhere on the path |
| R12 | **`POST /api/live` is the unauthenticated twin of the gated `ck_publish` channel.** The guest path refuses without `"live_publish": true` and a non-empty `tool_self_name` (`src/sandbox/host.zig:2997`); the HTTP path only checks that `from` is a valid session-id-shaped slug (`validPluginName` `src/cli.zig:13203`) and that `data` is JSON under `event_cap / 2` (`livePublishFromBody` `src/cli.zig:9934`; `handleLivePublish` `src/cli.zig:9948`). Any caller can therefore speak as any plugin to every `GET /api/events` subscriber, which is what the web UI renders from. Not a frame injection: the payload is re-stringified, so the reserved-topic defense `ckPublish` documents (`src/sandbox/host.zig:3008`-`:3014`) still holds - the impersonation is the *slug*, not the topic. | Medium | Medium | Data is bounded and JSON-compacted; only the `plugin` topic is reachable |
| R13 | **Two routes let an anonymous caller spend the operator's egress and credentials.** `GET /api/providers/models` (`handleProviderModels` `src/cli.zig:12882`) attaches the configured provider's API key as a bearer (`src/cli.zig:12893`) and calls that provider's `/models`; `POST /api/catalog/refresh` (`handleCatalogRefresh` `src/cli.zig:12141`) refetches models.dev and reinstalls the in-process catalog (`installCatalogCacheLocked` `src/cli.zig:12162`). Neither is a sandboxed guest, so no descriptor bounds either. `GET /api/config/status` (`handleConfigStatus` `src/cli.zig:12674`) discloses the last validation error verbatim, which can carry file paths and config fragments. | Medium | Medium | `providers/models` runs under the provider check timeout (`budget_s`, `src/cli.zig:12906`) so one call cannot pin a thread forever; a caller can still repeat it |
| R14 | **The chatroom inbox was the one untrusted-bytes-into-prompt path left unfenced; it is fenced now (fixed).** Every place the harness puts third-party bytes in front of the model runs them through `prompt_fence.neutralize`, which rewrites the leading `<` of every harness fence tag so a document cannot close a block the harness drew around it: tool results (`capToolResult` `src/agent/loop.zig:4028`), retrieved knowledge and memory (`prompt_fence.neutralize` `src/cli.zig:5863`, `:17384`), and the Skills/Learnings sections (`neutralizeMarkers` `src/improve/history.zig:715`). The `[chatroom inbox]` block was the exception: a peer message, room name and author name all reach the model, and they reach it as *harness framing*. `buildChatroomInbox` (`src/agent/loop.zig:4049`) now neutralizes all three (`src/agent/loop.zig:4059-4061`) on top of the block's own untrusted-data instruction. Recorded because the class recurs: a new untrusted-bytes path is unfenced by default, and this table said so for two passes before the rewrite shipped. | Low (closed) | Was Medium | The fence rewrite is the control; the bounds under it hold independently: `inbox_limit` 5 (`src/peers/chatrooms.zig:87`), 300-byte previews (`max_chat_inbox_preview_bytes` `src/agent/loop.zig:104`), and the block's own instruction (`src/agent/loop.zig:4054`) |
| R15 | **The one surface that replaces the binary every other boundary runs inside.** `clanker update` (`cmdUpdate` `src/cli/update.zig:297`) downloads a release asset and a `.sha256` sidecar from GitHub and overwrites the running executable. What stands in the way is verification before the write: both URLs must be GitHub https (`trustedGithubUrl` `src/cli/update.zig:117`, host allowlist `hostTrusted` `src/cli/update.zig:104`, which admits `github.com`, `*.github.com` and `*.githubusercontent.com` and refuses userinfo and a `github.com.evil.com` suffix), the asset must match the sidecar digest (`checksumMatches` `src/cli/update.zig:149`), and `decide` `src/cli/update.zig:167` returns a non-`replaced` verdict for every other case, which `cmdUpdate` turns into `fail` (`src/cli/update.zig:377`) without touching the executable. What is *not* in the way: the digest is fetched from the same host as the asset, so there is no signature and no second source of truth, and a compromised release account, or a CDN that serves both files, passes verification. A downgrade is not fetched either — exact tag equality decides (`sameRelease` `src/cli/update.zig:50`), so a withheld newer asset leaves the installed binary in place rather than pulling an older one. | High: the replaced binary holds every T1-T7 capability the process had, including the provider credentials in T6 | Low: needs operator action (`clanker update`), or a compromised release account | Verification is a checksum against a same-host source, not a signature. Recorded so a later pass can aim a check at T15 rather than re-deriving it; the fix itself is not this review's to make |
R7-R9 in one line each: the one read-only route that names internal hosts (`/api/mcp/servers`, R7),
the extension points that escape the sandbox entirely (Tier 2 exec, DAP, hooks, `!cmd`, R8), and
the native reader no descriptor bounds (`/api/files`, R9). R10-R13 in one line each: the chat
writes whose owner check compares the server's own name rather than the caller (R10), the mesh
admission/membership controls on the same unauthenticated port (R11), `POST /api/live` without the
`live_publish` grant its guest twin requires (R12), and the two routes that spend the operator's
provider credential on request (R13). R14 is the fixed prompt-fencing gap: the chatroom inbox now
rewrites fence markers like every other untrusted-bytes path, so it stays in the table as the
recurrence that motivated the rule, not as a live gap.

Priority order for the next pass: R1/R2 (internet-facing + authentication boundary, covered
below), then R10 (the shared chat write plane, default-on), then R3 abuse cases, then R4-R6, then
R7-R9, then R11-R13.

---

## 1. Attack surface inventory

### Network listeners (process-external)

| Entry point | Where | Default reach | AuthN/AuthZ |
|-------------|-------|---------------|-------------|
| HTTP server (web UI + every `/api/*` route, health, metrics, A2A, `/proxy/v1`) | `clanker serve`: `resolveListen` `src/cli.zig:7888` (default `default_serve_host` `src/cli.zig:7805`), per-connection `serveConnection` `src/cli.zig:8175`; route predicate block (`is_webui`) from `src/cli.zig:8580`, dispatch chain from `src/cli.zig:8685`; route table `docs/README.md:1625` | `127.0.0.1:17921` (`--host` widens; one socket, `docs/README.md:1627`) | **None**; Host allowlist + Origin check only |
| Proxy listener (dedicated) | `--proxy-port`; serves `/v1/*` and no `/api/*` (`docs/README.md:1627`); standalone binary `src/proxy_main.zig` (default `127.0.0.1:17922`) | loopback | Optional `proxy_token_env` (`src/config.zig:1045`), compared by `proxy.authorize` `src/serve/proxy.zig:57` in constant time over SHA-256 digests (`proxy.authorize`, `src/serve/proxy.zig:57`) |
| Mesh TCP listener | `src/serve/mesh_net.zig` (`acceptLoop` `src/serve/mesh_net.zig:599`; inbound cap `src/serve/mesh_net.zig:38`, enforced `:630`) | `127.0.0.1:7420` (`src/config.zig:990-991`) | Admission allowlist/prompt/open (`Admission` `src/peers/mesh.zig:124`, `admit` `:133`); JOIN handshake bounded by frame cap + read timeout (`join_wait_ns`, `src/serve/mesh_net.zig:702-711`) |
| Outbound peer HTTP (`POST /api/chat/message`, notify) | `src/peers/chatrooms.zig` fan-out; `src/peers/command.zig` | none | Peers are *outbound* URLs, never listeners (`docs/README.md:1627`) |

### Routes the model treats as one boundary (T1)

Every route below is reached over the same listener and, with two named exceptions
(`/proxy/v1/*` against `proxy_token_env`, and `modules`-gated 404s), past the same two checks: the
Host allowlist and the non-GET Origin check. None carries caller identity. Grouped here so a later
pass can split them; each is enumerated under T1's STRIDE rows and T7.

| Route | Handler | What a caller gets |
|-------|---------|--------------------|
| `GET /api/config/raw`, `POST /api/config/raw`, `POST /api/config/table/set`, `POST /api/config/table/remove` | `handleConfigRawGet` `src/cli.zig:12437`, `handleConfigRawSet` `src/cli.zig:12468` | Full config file contents unredacted; validated writes to operator policy (T7). The table routes write `config.local.toml` |
| `POST /api/config/model/set`, `/remove`, `/model`, `/default` | route predicates `src/cli.zig:8570-8574` | Provider and default-model policy changes |
| `GET /api/files?path=` | `handleFiles` `src/cli.zig:14492`, content half `handleFileContent` `src/cli.zig:14681` | **Native file browser over the workspace**: directory listing plus file contents, capped at `file_preview_cap` `src/cli.zig:14457`. Not a sandboxed guest — it walks the tree with the server's own authority. Its bounds are `..` clamped at the root, a no-follow symlink walk (`pathHasSymlinkComponent` refusal, `src/cli.zig:14553`; definition `:14751`), and the shared dotenv refusal (`secret_dotenv.isSecretDotenvPath`, `src/util/secret_dotenv.zig:49`, refused `src/cli.zig:14540`, hidden `:14626`), so `.env` is hidden and unread — the parity rule `env_allow` keeps for guests. An owner-only file never appears in a listing and never opens (`isOwnerOnlyFile`, `src/cli.zig:14478`, applied `:14640`) |
| `POST /api/run`, `POST /api/ask`, `POST /api/steer` | `handleRun` `src/cli.zig:17256`, `handleAsk` `src/cli.zig:10665`, `handleSteer` `src/cli.zig:10901` | Agent work, write-confirmation answers, mid-turn steering (T1 elevation, T2) |
| `POST /api/a2a/message`, `GET /.well-known/agent.json` | `handleA2AMessage` `src/cli.zig:10079`, `handleAgentCard` `src/cli.zig:10007` | A second agent entry point, gated only by `modules.a2a` (default on) |
| `/api/plugins` (GET, POST), `/api/plugins/config` (POST), `/api/webui/plugins` (GET, POST) | `handlePlugins` `src/cli.zig:15347`, `handleWebuiPlugins` `src/cli.zig:13295` | Enable/disable plugins; `webui_addon` enable/disable, whose enabled list is the whole of T10's control |
| `/api/goals`, `/api/board`, `/api/knowledge`, `/api/prompts`, `/api/schedule`, `/api/arena`, `/api/compare` (all GET+POST), `GET /api/workflows`, `/api/runs`, `/api/workspaces`, and the five record stores | dispatch `src/cli.zig:8798-8823`, `recordStoreForPath` `src/cli.zig:14947` | Durable workflow-state writes, all through sandboxed guests, none authenticated |
| `/api/skills` (GET, POST) | `handleSkills` `src/cli.zig:14816`, input mapping `skillsRouteToToolInput` `src/cli.zig:14866` | `POST` toggles a skill's enable flag in `state/skills.json`, which decides what rides the next system prompt (`validSkillName` gate, `src/cli.zig:14873`) |
| `GET /api/sessions`, `/api/sessions/search`, `DELETE /api/sessions/<id>`, `GET /api/logs`, `GET /api/stats`, `GET /api/metrics`, `GET /api/status`, `GET /api/providers`, `GET /api/catalog`, `GET /api/janitor`, `/api/feedback` (GET, POST), `GET /api/mesh/*`, `POST /api/live`, `POST /api/notify`, `GET /api/events` | `handleSessions` `src/cli.zig:14140`, `handleLogs` `src/cli.zig:13870`, and the rest of the dispatch chain | Reads of transcripts, logs and metrics; the SSE stream; peer notifications (T1 disclosure, T3) |
| `GET /api/mcp/servers` | `handleMcpServers` `src/cli.zig:12619` | R7: the operator's internal command/URL map, env values withheld |
| `GET /api/peers` | `handlePeers` `src/cli.zig:16805` | Relays the `peers` guest `{"action":"phonebook"}` verdict verbatim, so a caller learns every configured peer's identity and reachability (up/down, "no peers") - an unauthenticated map of the operator's mesh and the hosts behind it. Gated on `modules.peers` (`src/cli.zig:8679`), so it 404s with the module off |
| `POST /api/chat/send`, `/subscribe`, `/react`, `/edit`, `/delete`, `/pin`, `/topic` | `handleChatSend` `src/cli.zig:9318`, `handleChatSubscribe` `src/cli.zig:9380`, `handleChatReact` `src/cli.zig:9395`, `handleChatEdit` `src/cli.zig:9425`, `handleChatDelete` `src/cli.zig:9464`, `handleChatPin` `src/cli.zig:9491`, `handleChatTopic` `src/cli.zig:9507` | R10: durable writes to the shared room log and metadata on behalf of `cfg.instance.name`. Every handler is an unauthenticated mutation of a store a *fleet* of instances reads, and none of them knows who is calling. Reachable in a stock install: `modules.chatrooms` and `chatrooms.on` are both on by default (`src/config.zig:1136`, `src/config.zig:1085`) |
| `POST /api/mesh/join`, `/leave`, `POST /api/mesh/pending`, `GET /api/mesh/pending`, `GET /api/mesh/status`, `GET /api/mesh/map` | `handleMeshJoin` `src/cli.zig:16866`, `handleMeshLeave` `src/cli.zig:16901`, `handleMeshPendingPost` `src/cli.zig:16956`, `handleMeshPendingGet` `src/cli.zig:16928`, `handleMeshStatus` `src/cli.zig:16830`, `handleMeshMap` `src/cli.zig:16992` | R4/T3: the operator's mesh membership is mutable by any caller. `join` dials an arbitrary `host:port` the body names (`parseHostPort` `src/serve/mesh_net.zig:316`, `join` `src/serve/mesh_net.zig:727`), `leave` evicts a named member or all of them (`leave` `src/serve/mesh_net.zig:841`), and `pending` POST *approves a peer admission* (`resolvePending` `src/serve/mesh_net.zig:886`) — the one prompt-mode control an operator has, exposed on the same unauthenticated surface. Off by default (`modules.mesh`, `src/config.zig:1146`) |
| `POST /api/live` | `handleLivePublish` `src/cli.zig:9948`, body parsed by `livePublishFromBody` `src/cli.zig:9934` | Publishes onto the SSE bus under any slug that passes `validPluginName` (`src/cli.zig:13203`). The slug and data shape are checked; the *caller* is not, so any caller can speak as any plugin to every `GET /api/events` subscriber. The guest channel behind it is gated (`ckPublish` refuses without `"live_publish": true` and a non-empty `tool_self_name`); the HTTP route is not |
| `POST /api/catalog/refresh`, `GET /api/providers/models`, `GET /api/config/status` | `handleCatalogRefresh` `src/cli.zig:12141`; `handleProviderModels` `src/cli.zig:12882`; `handleConfigStatus` `src/cli.zig:12674` | A network fetch and a live upstream call on behalf of the caller: `refresh` replaces `state/models-dev.json` from models.dev and installs the in-process copy (`installCatalogCacheLocked`, called `src/cli.zig:12162`); `providers/models` calls the configured provider's `/models` **carrying its API key** (`src/cli.zig:12893` builds the bearer from `provider.api_key_env`), so any caller can make the operator's credential talk to that provider for as long as the request takes. `config/status` discloses the last validation error verbatim |

### IPC / local-process surfaces

Trust for every row below is "whoever can spawn the process or write the config naming its
command"; none carries client authentication. Enumerated as T9.

| Entry point | Where | Notes |
|-------------|-------|-------|
| MCP server (stdio JSON-RPC) | `src/mcp/server.zig` | Exposes the tool registry; trust = whoever can spawn the process (`docs/README.md:458`) |
| ACP v1 stdio | `src/acp/server.zig` | Same model |
| DAP (debug adapter) | `src/debug/dap.zig` | Can start/debug subprocesses (`src/agent/subprocess.zig`) |
| Lifecycle hooks | `src/hooks/runner.zig`, `src/hooks/config.zig` | Configured commands run at lifecycle points: config-trust surface |
| CLI Tier 2 plugin `clanker <name>` | `cmdPlugin` `src/cli.zig:6089`, `std.process.spawn` `src/cli.zig:6118` | An external `clanker-<name>` binary from PATH or `~/.clanker/plugins/`, exec'd **unsandboxed** with the remaining argv verbatim and stdio inherited. Gated on the same enabled list Tier 1 uses (`cli_plugins.resolveTier2` `src/cli/cli_plugins.zig:125`), so being on PATH is not consent (T11) |
| `clanker auth login` native OAuth flows | `cmdAuth` `src/cli.zig:3058`, per-plugin flows (`loginDevice` .. `loginManual`, `src/llm/oauth_command.zig:43-79`) | Device-code and manual-PKCE logins against Codex/Grok/Claude (`src/llm/oauth_plugins/`); tokens land under `agent.state_dir/oauth/<provider>.json` at `0600` (`src/llm/oauth_store.zig:31`, `:55`). Operator-initiated, but the token store is an asset (T12) |
| `[mcp_servers.*]` external MCP servers | `McpServer` `src/config.zig:1256-1266`, validated by `parseMcpServer` at load (`src/config.zig:3319`); surfaced unauthenticated by `GET /api/mcp/servers` (`src/cli.zig:8653`, handler `src/cli.zig:12619`) | Each stanza names a `command`/`url` that would run **outside** the WASM sandbox with the same trust as an `exec_allow` line. Off by default (the `modules.mcp_client` toggle `src/config.zig:1105`); the GET route exposes the configured host/command shape to any caller (T13) |
| REPL `!cmd` shell escape | `docs/README.md:865` | Deliberate: interactive user shell; `repl_exec_allow` widens only what tool policy already allowed (`docs/README.md:1424`) |
| `clanker update` binary self-replacement | `cmdUpdate` `src/cli/update.zig:297`, command-table row `src/cli.zig:2425` | Fetches a release asset plus its `.sha256` sidecar from GitHub and **overwrites the running executable**. Operator-initiated, but the write is to the binary every other boundary runs inside, so it is enumerated as T15 rather than filed under dependencies |

### Drop-in code the host serves without a signature

| Entry point | Where | Notes |
|-------------|-------|-------|
| Web UI plugin assets `GET /webui/plugins/<name>/app.js` and `app.css` | `handleWebuiPluginAsset` `src/cli.zig:13343`, gated on the plugin being enabled (`listedEnabled`, `:13371`) | Served from disk byte-for-byte, and the `app.js` is injected as a plain `<script>` into the operator's page (`loadPluginScript`, `ui/app/core/plugins.js:403-421`), so it runs in the same origin as `/api/*`. Enumerated as T10. |
| MCP server descriptors / peer wires | `tools/manifests/*.tool.json`, `src/peers/mesh.zig` | Declarative, unsigned (T5) |

### Scheduled / triggered

- `clanker schedule run-due` invoked by system cron (`src/schedule/`); nothing fires on its own
  (ADR 0008). An attacker who can write the schedule file or the cron line gains scheduled
  execution.
- **Opt-in state-backup timers**: user-level systemd units installed by
  `scripts/install-state-backup.sh` — `clanker-state-backup.timer` runs
  `scripts/backup-state.sh` at :00/:30 (`scripts/systemd/clanker-state-backup.timer`) and
  `clanker-state-verify.timer` restore-verifies weekly (`scripts/systemd/clanker-state-verify.timer`).
  The backup copies the *entire* `state/` tree (session DBs = transcripts, logs, token stats,
  goals, plugins) to `backups/` beside wherever `state` resolves (`scripts/backup-state.sh:154-197`),
  plus `config.local.toml`, `config.local.json`, and `.env` from the checkout
  (`scripts/backup-state.sh:213-230`), and refuses to run when that root would land inside the
  repo (`scripts/backup-state.sh:79-83`).
  Threat shape: same trust level as cron (runs as the operator's user), but it widens where
  transcripts live — see T5/T6 and the assets table. Both are threat-enumerated under T8.
- LLM client outbound HTTPS (all providers, `src/llm/client.zig`), outbound-paced by
  `src/llm/rate_limit.zig`; the *response* side is untrusted input (R3).

### Inputs that cross the trust boundary as untrusted data

- HTTP request bodies (JSON), headers (`Host`, `Origin`, `Content-Type`), query strings,
  resource ids (`requestPath` strips query first, `src/serve/http.zig:25`).
- `/api/run` `images` (base64, 4 MB each, at most 4, requires `modules.multimodal`;
  `src/cli.zig:10321`, `:10321-10322`; `docs/README.md:1675`).
- Chatroom messages fanned in from peers (`POST /api/chat/message`, `src/peers/chatrooms.zig`).
- SSE event stream `GET /api/events`, long-lived, Origin-gated (`src/cli.zig:8634`).
- Mesh wire frames (length-prefixed, `decodeFrame` against `max_frame`,
  `src/serve/mesh_net.zig:375`), JOIN name/id, seeds.
- Provider API responses: SSE streams, tool-call deltas, JSON error bodies
  (`src/llm/client.zig`); Vertex error bodies
  (`docs/reports/bugs/2026-08-19-vertex-error-bodies-discarded.md`).
- `state/models-dev.json` snapshot (fetched from models.dev at runtime), parsed as
  config-adjacent JSON.
- Saved sessions loaded from `state/sessions/<id>.db` (WAL-mode SQLite, one db per
  conversation, `src/agent/session.zig:35`, `src/util/sqlite.zig`), goal records from
  `state/goals.json`, board from `state/board*.json`; on-disk state is a trust boundary (see T5).

### Deployment / dependency surface

- `dependabot.yml` present (`.github/`), dependency CVEs tracked by GitHub, not in the model
  (owned by deps-review).
- No admin/debug ports beyond the ones listed; `/health/live`, `/health/ready` and
  `/api/metrics` ride the same socket (`src/cli.zig:8495`, `:8539`).

## 2. Trust boundaries and data flow

| # | Boundary | Direction | Validation / authn point |
|---|----------|-----------|--------------------------|
| T1 | **Client → HTTP control plane** | Browser/SDK/curl → `/api/*`, `/proxy/v1` | No authn. Host header checked on *every* request (`unexpectedHost`, `src/serve/http.zig:211`, enforced `src/cli.zig:8494`; combined predicate `crossOriginRequest` `src/serve/http.zig:188`); `Origin` checked on non-GET as CSRF (`crossOriginRequest`, `src/serve/http.zig:188`, enforced `src/cli.zig:8519`) and on the SSE stream (`src/cli.zig:8707`); body capped (`src/cli.zig:8432-8435`). HEAD is rewritten to GET once, after the proxy dispatch and the Origin check, so POST-only routes stay unreachable via HEAD (`request_head` set `src/cli.zig:8480`, rewrite `:8560`). Loopback bind is the real control |
| T2 | **HTTP control plane → agent/tools** | `/api/run` task text (dispatch `src/cli.zig:8839`) → agent loop → sandboxed tools | Descriptor policy: `fs_prefixes`, `env_allow`, `network_allow`, `exec_allow` (`tools/manifests/*.tool.json`, honored in `src/sandbox/host.zig`); privileged `ck_*` channels check `tool_self_name` (`src/sandbox/host.zig`) |
| T3 | **Peer/mesh → local state** | `POST /api/chat/message`, mesh CHAT frames → `state/chatrooms.jsonl`, `state/notifications.jsonl` | Chat fan-out via sandboxed `peers` tool (`chat_fanout`, `network_from_config`); mesh admission handshake (`handleConnection` join branch `src/serve/mesh_net.zig:526-556`); no wire crypto |
| T4 | **Provider API → agent loop** | LLM response stream → conversation → next model request | Prompts treat provider output and retrieved text as untrusted (R3); sandbox is the enforcement point. History sent to model is append-only; request-only copies for compaction (`docs/README.md` agent section) |
| T5 | **Disk state → process** | `state/sessions/<id>.db`, `state/goals.json`, `state/models-dev.json`, `state/board*.json`, `state/plugins.json` + `plugin_config.json` | JSON state parsed with explicit bounds (guests read through `ck_fs_read_range`, not whole-file); sessions are read by tools through the `ck_session` channel rather than as files; `.env` refused by `safeJoin`; symlinked components refused by `safeJoinSecure` (ADR 0017) |
| T6 | **Secrets → code** | Provider keys via `api_key_env` (provider tables in `src/config.zig`), `[serve]` `proxy_token_env` (`src/config.zig:1045`) compared by `proxy.authorize` `src/serve/proxy.zig:57`, Vertex service-account JWT minting (`src/llm/vertex_token.zig`) | Keys live in `config.toml`/`config.local.toml`/env; guest access gated by `env_allow` + named `ck_getenv`; proxy credentials ride only `/v1/*` paths; token comparison is constant-time over SHA-256 digests (`src/serve/proxy.zig:57`) |
| T7 | **HTTP caller → native configuration and backends** | Raw config reads/writes (predicates `is_config_raw_get` `src/cli.zig:8648`, `is_config_raw_set` `src/cli.zig:8649`; handlers `handleConfigRawGet` `src/cli.zig:12437` and `handleConfigRawSet` `src/cli.zig:12468`); backend selection (`req.backend` `src/cli.zig:17485`) and native dispatch (`runCodingBackendCtx` `src/cli.zig:17885`) | File-name restriction and config validation protect format, not caller authority. Backend-name validation (`acp_vendor.Name.parse` `src/cli.zig:4434`) selects supported adapters, not a WASM sandbox. No caller authentication precedes these routes (`unexpectedHost` `src/cli.zig:8494`, `crossOriginRequest` `src/cli.zig:8519`). `GET /api/files` is the other native path (`handleFiles` `src/cli.zig:14492`): it reads the workspace with the server's authority, bounded by the root clamp, the no-follow walk and the dotenv refusal rather than by a descriptor |
| T8 | **Local automation → host execution** | System cron `clanker schedule run-due` (`src/schedule/`), the opt-in state-backup units (`scripts/install-state-backup.sh`, `scripts/systemd/clanker-state-backup.timer`), which shell out to `scripts/backup-state.sh` | No caller input crosses a wire: the trust question is *who may write the schedule file or the timer/cron line*. Backup refuses to run when its root would land inside the checkout (`scripts/backup-state.sh:79-83`) |
| T9 | **Local process → IPC surfaces** | MCP stdio JSON-RPC (`serve` `src/mcp/server.zig:49`); ACP stdio (`serve` `src/acp/server.zig:302`); DAP (`"launch"`/`"attach"` adapter select `src/debug/dap.zig:528`, requests `Session.launch` `src/debug/dap.zig:361` and `Session.attach` `src/debug/dap.zig:395`); lifecycle hooks (`run` `src/hooks/runner.zig:16`); REPL `!cmd` (`execUnderPolicy` `src/tui/repl.zig:4326`); `ck_debug` (`src/sandbox/host.zig:2172`) | Trust = whoever can spawn the process or write the config that names its command. Hooks and `!cmd` run through the same exec allowlist as `ck_exec` (`execUnderPolicyInput`, `src/sandbox/host.zig:7004`; `execUnderPolicy`, `src/tui/repl.zig:4330`); DAP `launch`/`attach` picks a *configured* adapter by name and never takes argv from the client (`src/debug/dap.zig:395`); `ck_debug` requires `debug.enabled` (`ckDebugEnabled` refusal `src/sandbox/host.zig:2172`) |
| T10 | **Third-party drop-in code → operator's browser origin** | `ui/plugins/<name>/app.js` served from disk (`handleWebuiPluginAsset` `src/cli.zig:13343`) and injected as a plain `<script>` into the page that also holds the control plane's `localStorage` session id (`loadPluginScript` `ui/app/core/plugins.js:405`) | The only gate is that the plugin is *enabled* (`listedEnabled` `src/cli.zig:13251`, called at `:13371`); there is no signature, no separate origin, and no `sandbox` attribute, so plugin code holds every capability the page has: read `/api/config/raw` (T7), read every transcript, and `POST /api/run` with the operator's reachability. Trust = whoever can write `ui/plugins/<name>/app.js`, or whoever gets an operator to enable a plugin they did not write. |
| T11 | **Host PATH / plugin dir → unsandboxed process** | `clanker <name>` Tier 2 → `std.process.spawn` (`cmdPlugin` `src/cli.zig:6089`, `std.process.spawn` `src/cli.zig:6118`, gate `cli_plugins.resolveTier2` `src/cli/cli_plugins.zig:125`) | Only the enabled list gates it: `resolveTier2` consults the same enabled set Tier 1 does, precisely so a bare `clanker <word>` cannot spawn any `clanker-<word>` on PATH. That is a consent gate, not a sandbox: the child inherits stdio and runs with the operator's full authority, outside every `ck_*` descriptor. Tier 1 (an enabled `cli-plugins/*.json` naming a sandboxed tool) adds no new trust surface. |
| T12 | **Provider OAuth endpoint → local token store** | `clanker auth login` (`cmdAuth` `src/cli.zig:3058`, flows `loginDevice`/`loginCodexDevice`/`loginManual` `src/llm/oauth_command.zig:43-79`) → `state/oauth/<provider>.json` | Provider-hosted device-code and manual-PKCE flows; no callback listener is opened, the operator pastes the code back. Tokens are written owner-only (`atomic_write.private_file` 0600, `atomic_write.private_file` `src/llm/oauth_store.zig:55`). Nothing here is reachable over HTTP: the trust question is who can read the state directory, and whether a leaked refresh token is distinguishable from the API keys in T6 (they are not, in blast radius). |
| T13 | **Config → external MCP server (outside the sandbox)** | `[mcp_servers.*]` `command`/`url` (`McpServer` `src/config.zig:1266`) | Off by default: the client bridge that would connect is behind the `modules.mcp_client` toggle, off by default (`src/config.zig:1105`). The stanzas are parsed and validated by `parseMcpServer` at load (`src/config.zig:3319`), so a `stdio` entry with no `command` is refused before anything spawns. The configuration *is* readable without authn today: `GET /api/mcp/servers` (`is_mcp_servers` `src/cli.zig:8653`) returns the configured host/command shape to any caller on the port. |
| T15 | **GitHub release → the installed binary** | `clanker update` (`cmdUpdate` `src/cli/update.zig:297`) fetches the release asset and its `.sha256` sidecar over HTTPS and replaces the running executable | Not a network-facing boundary: the caller is the operator. The control is verification before the write: `trustedGithubUrl` `src/cli/update.zig:117` (GitHub https only, userinfo and lookalike suffixes refused), `checksumMatches` `src/cli/update.zig:149`, and `decide` `src/cli/update.zig:167` returning a non-`replaced` verdict for every other case. The digest arrives from the same host as the asset, so there is no signature and no second source of truth: a compromised release account or CDN passes verification (T15, "What it does not do") |

Privilege transitions:
- HTTP caller → policy author: native config writes validate and persist the config pair
  (`handleConfigRawSet` `src/cli.zig:12468`), outside guest descriptor enforcement.
- HTTP caller → native backend process: `runCodingBackendCtx` (`src/cli.zig:4424`) passes
  configured ACP argv to the driver (`src/acp/driver.zig`); the driver spawns an ACP transport or
  falls back to a headless subprocess. Any backend-specific permission system is separate from
  clanker's WASM policy.
- guest (WASM) → host function (`ck_exec` allowlist: git/zig/uv verbs, no host-absolute or `..`
  args, deny tokens for config-injection and alternate-git-dir flags), the sandbox's only
  escape ladder.
- sandboxed tool → unsandboxed kernel subprocess: `ck_kernel` requires `kernel.enabled`
  (default off, `src/config.zig`), `ck_docker` requires a descriptor grant; both opt-in
  (ADR 0010).
- operator CLI → scheduled execution: `clanker schedule` writes `state/schedule.json`;
  system cron runs `run-due` as the operator. Same shape for the opt-in backup timers
  (`scripts/install-state-backup.sh`).
- config → host process, outside any guest descriptor: a hook's `command`
  (`src/hooks/config.zig:10`), `agent.repl_exec_allow`, and a DAP adapter's `command`
  (`src/config.zig:769`) all name a program that runs with the server's own authority. The
  exec allowlist bounds the first two (M16); the DAP adapter list is a config-time trust
  decision with no allowlist, mitigated only by the operator choosing the config.

## 3. Assets and impact

| Asset | Held where | Blast radius if compromised |
|-------|-----------|-----------------------------|
| Provider credentials (LLM keys, Vertex service account) | `config.toml`, `config.local.toml`, env (`api_key_env`); read via `src/llm/auth.zig`; also readable through `GET /api/config/raw` (`handleConfigRawGet` `src/cli.zig:12437`) | Financial (token spend), impersonation of the operator's provider identity |
| Provider credentials, second copy | `<storage_root>/backups/<timestamp>/config/` once the opt-in backup timer is installed (`scripts/backup-state.sh:213-230`) | Same keys, copied off the checkout into an append-only snapshot tree; outlives deleting `config.local.toml`/`.env`, and no rotation sweep reaches it |
| Native configuration and execution authority | `/api/config/raw` (`handleConfigRawGet`, `src/cli.zig:12437`, `handleConfigRawSet` `src/cli.zig:12468`), `/api/run` backend dispatch (`handleRun` `src/cli.zig:17256`) | Policy tampering and execution as the server's OS user; guest sandbox policy does not constrain these native paths (T7). No implication of OS root privileges. |
| Conversation transcripts (sessions) | `state/sessions/<id>.db` (WAL SQLite, `src/agent/session.zig:35`; + `state/spills/<session>/`, `state/exports/<id>.html`) | Data disclosure (conversations contain task context, possibly secrets pasted in). With the backup timers installed, twice-hourly snapshot copies of all of it live under `<storage_root>/backups/` (`scripts/backup-state.sh:154-197`) — anyone who can read the storage root reads every conversation, including ones since deleted from `state/` |
| Source code + git history | working tree, `.git` | Integrity; the improve loop can *self-modify* the repo through gated promotion (`src/improve/engine.zig`) |
| LLM spend | `state/token_stats.jsonl` (hard cap, `src/stats/tokens.zig:25`; `docs/README.md:471`) | Financial; also an availability signal |
| Mesh membership + chatrooms | `state/chatrooms.jsonl`, `state/chatrooms-sub.json` | Spoofing/reputation; fan-out amplification to peers |
| Board / goals / knowledge graph | `state/goals.json`, `state/board*.json`, knowledge entries | Integrity of the workflow record |
| The installed binary itself | the executable `clanker update` replaces (`replaceExecutable` `src/cli/update.zig:282`, writing through `replaceVerified` `src/cli/update.zig:184`); the running image's digest is what `checksumMatches` verifies (`src/cli/update.zig:149`) | Everything below it at once: the replaced binary carries every capability T1-T7 describe, including the provider credentials and the full tool surface, and a wrong-but-verified digest is indistinguishable from a correct one downstream |
| The machine (via `ck_exec`, `ck_docker`, kernel) | sandbox policy | Highest impact; deliberately the hardest to reach |

## 4. Threats per boundary

### T1 (client → HTTP): STRIDE

- **Spoofing**: none, no authn. Any process on the host (or LAN once `--host` widened) is the
  operator. Accepted and documented by design (`docs/README.md:1623`).
- **Tampering**: cross-site POST refused by the Origin check (`crossOriginRequest` `src/cli.zig:8519`), but only for
  browsers; curl/raw clients carry no `Origin` and pass. CSRF strength = Origin trust. HEAD is
  rewritten to GET once after the check, so a HEAD cannot reach a POST-only route
  (`request_head` `src/cli.zig:8480`, rewrite `src/cli.zig:8560`).
- **Information disclosure**: GET endpoints expose logs (`/api/logs`), sessions
  (`/api/sessions`), transcripts, knowledge, stats, all unauthenticated (route table
  `docs/README.md:1625`).
- **DoS**: 64 connection slots (`max_connection_threads` `src/cli.zig:8138`, enforced
  `src/cli.zig:8180`); body cap
  (`src/cli.zig:8435`); no per-route rate limit; `POST /api/run` holds a slot for the whole run; provider
  hangups are bounded only by `agent.request_timeout_ms` / `agent.stream_idle_timeout_ms` (the
  HTTP client itself has no read timeout; defaults `src/config.zig:529`). Saturation 503s reset
  their own threadlocal request state, book under `errors_total`, carry a fresh request id, and
  log (`respondSaturated`, `src/cli.zig:8238`); readiness reports `"saturated"`
  (`readinessBody` `src/cli.zig:9986`). The dedicated proxy surface keeps a web UI reserve (`max_connection_threads` arithmetic `src/cli.zig:8186`); the proxy's own
  upstream deadlines default to 300 s/60 s (`src/serve/proxy.zig:30-31`).
- **Elevation**: `/api/ask` (`handleAsk` `src/cli.zig:10665`, dispatched at `src/cli.zig:8835`) answers `confirm` events, so a same-origin
  script or local client that can already reach the port can also confirm writes. Three further
  routes reach the agent, the mesh, or the live bus with no authn in front of any of them:
  `POST /api/a2a/message` (`src/cli.zig:8834`) runs the incoming JSON-RPC message through the
  agent model (gated only by `modules.a2a`, on by default, `src/config.zig:1110`; otherwise 404,
  (`is_a2a` `src/cli.zig:8589`; the run itself is `handleA2AMessage`, `src/cli.zig:10079`),
  `POST /api/mesh/join` (`handleMeshJoin` `src/cli.zig:16866`) admits a peer into the mesh, and
  `POST /api/live` (`handleLivePublish` `src/cli.zig:9948`) publishes onto the live bus. A caller that reaches the
  port is the operator on all four.

### T2 (HTTP → agent/tools)

- **Elevation**: guest → host via `ck_*`. Mitigated by descriptor policy + `tool_self_name`
  checks on privileged channels (M6). History: symlink escape refused by `safeJoinSecure`
  (ADR 0017); CAS lock file naming resolved before hashing
  (`docs/reports/bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md`).
- **Tampering**: `ck_fs_write_if` compare-and-swap + lock (ADR 0031) prevents lost updates
  across concurrent sessions.
- **Information disclosure**: guest HTTP responses expose only allowlisted headers
  (`exposed_response_headers`, `src/sandbox/host.zig:3297`, ADR 0049), so `Set-Cookie`,
  `Authorization`, and `Location` do not reach a guest unless named.
- **DoS**: guest I/O size caps (`src/sandbox/host.zig`); 200-hit cap on find/grep walks
  (`util/fs_skip.zig` consumers `ck_fs_find`/`ck_fs_grep`).

### T3 (peer/mesh)

- **Spoofing**: mesh admission by self-asserted name (`matchesSeed`, `src/peers/mesh.zig:150`),
  behind an `admit` that refuses only an empty or self `join_id` before it compares names
  (`src/peers/mesh.zig:133`, `:140`);
  an allowlist is name-matching, not a credential. `open` mode admits anyone
  (`src/peers/mesh.zig:124`).
- **Tampering**: no integrity on the wire (plain TCP); chat messages are unauthenticated
  application data.
- **Amplification**: a peer fans every room message out to all peers
  (`src/peers/chatrooms.zig`); a malicious or compromised peer can flood the fleet.
- **DoS**: the JOIN handshake runs under a bounded inbound connection pool
  (`max_inbound_conns = 64`, `src/serve/mesh_net.zig:38`, enforced `:629`) with a
  frame-size cap and read timeout (`join_wait_ns`, `src/serve/mesh_net.zig:702-711`); joined members bounded by `mesh.max_members`
  (`max_members` 32, `src/peers/mesh.zig:12`, `src/config.zig:994`); pending joins by `max_pending_joins`
  (8, `src/config.zig:977`, clamped `src/serve/mesh_net.zig:695`).

### T4 (provider → agent)

- **Tampering / Elevation (prompt injection)**: provider output and retrieved text are
  untrusted; the model is instructed never to execute directives found there
  (`src/agent/system_prompt.zig:697`); fence markers inside retrieved text are neutralized so
  docs can't close retrieval blocks. Enforcement is the sandbox, not the prompt (R3).

### T5 (disk state)

- **Tampering**: `state/*.json` is operator-writable; a hostile file (e.g. a crafted
  `state/goals.json` or a malicious plugin manifest) is parsed as config-adjacent data.
  Plugins are declarative and **unsigned** (ADR 0007); the improve loop and `plugins` guest
  both trust descriptor contents.
- **History**: `2026-08-15-unknown-goal-id-runs-unscoped.md`: a goal id that didn't exist
  ran without scope. `2026-08-16-guest-writes-refused-under-symlinked-state.md`: symlinked
  `state/` denied guest writes until ADR 0017's opt-in.

### T6 (secrets)

- **Disclosure**: secrets in config files on disk (plaintext keys), and the same files are
  readable through `GET /api/config/raw` without redaction (`handleConfigRawGet`, `src/cli.zig:12437`); guests can
  read only named env vars via `env_allow` + `ck_getenv`; `.env` refused by `safeJoin`; no
  secrets in `env_allow` defaults. Proxy credentials ride only `/v1/*` paths.
- **Rotation**: not documented (organizational).

### T7 (HTTP → native policy and execution)

- **Information disclosure**: raw config reads return the complete selected file, without
  credential redaction (`handleConfigRawGet`, `src/cli.zig:12437`). Any inline secrets there share the control
  plane's reachability, regardless of guest environment restrictions.
- **Tampering / Elevation**: native config writes change operator policy after parsing
  (`handleConfigRawSet`, `src/cli.zig:12468`); supported backend selection reaches native process spawning
  (`src/cli.zig:17322-17327`, `:4391`, `src/acp/driver.zig`). Host/Origin checks reduce browser
  abuse but do not establish who may administer policy. Rank: critical impact, high likelihood
  for a reachable hostile client (R1). Missing control: caller authentication and authorization
  for administrative operations; implementation belongs to sec-review.
- **Availability**: config writes advertise restart-on-reload; repeated accepted policy
  changes can disrupt service. Config validity is not an availability quota or an authorization
  check.

### T8 (local automation)

- **Elevation**: whoever can write `state/schedule.json` or the cron line gains execution as
  the operator's user on every fire. Same for the backup units: editing
  `scripts/systemd/clanker-state-verify.timer` (or the script it runs) is code execution on a
  timer. Neither path re-checks who scheduled the entry.
- **Information disclosure**: the backup copies the whole `state/` tree (transcripts, logs,
  token stats, goals, plugin config) to `<storage_root>/backups/` twice an hour
  (`scripts/backup-state.sh:154-197`). A read of that directory is a read of every conversation
  the harness has had, including ones since deleted from `state/`. The refusal to run when the
  backup root lands inside the checkout (`:79-88`) removes the false-backup case; it says
  nothing about who may read the external root.
- **Information disclosure (credentials)**: the snapshot also copies `config.local.toml`,
  `config.local.json`, and `.env` out of the checkout
  (`scripts/backup-state.sh:213-230`), which is where the provider API keys live
  (T6). So installing the backup units creates a second copy of the credentials,
  in a different directory, with no rotation story for either copy, and it
  survives deleting the original. Mitigated in part by M18 (owner-only snapshot
  root); unbounded in time, since snapshots are append-only.
- **Tampering**: `backup-state.sh` derives its root from wherever `state` resolves
  (`scripts/backup-state.sh:71-72`); a `state` symlink pointed at a hostile directory redirects
  every snapshot. That is an operator-writable decision, not a guest-reachable one.
- **DoS**: two cron fires an hour over the full state tree; on a large session store that is
  sustained I/O. No quota, and the script is not part of the connection-limit accounting.
- Missing control: no record of who scheduled an entry or installed the units; both are
  filesystem audit, outside clanker.

### T9 (local IPC surfaces)

- **Elevation**: MCP and ACP stdio expose the tool registry and the agent loop to whatever
  process spawned them; there is no client authentication on either (`src/mcp/server.zig:49`,
  `src/acp/server.zig:302`). Anyone who can spawn the process is the operator, exactly as with
  the HTTP control plane (R1).
- **Elevation (DAP)**: `launch`/`attach` names a configured adapter and spawns it
  (`src/debug/dap.zig:513`), so a DAP client selects among operator-chosen programs rather than
  injecting argv. The trust is in the config (`src/config.zig:768`), which the guest `debug`
  tool can only reach when `debug.enabled` (`src/sandbox/host.zig:2172`).
- **Tampering**: a hook's `command` is config (`src/hooks/config.zig:10`) and its output is
  logged, not parsed as instructions, but the command itself runs with the server's authority.
  M16 is the only bound on it.
- **Repudiation**: hook and adapter invocations are logged at warn/info with the argv, but
  there is no security event log tying a DAP session or a hook fire to a caller identity,
  because stdio and DAP have none.

### T10 (drop-in plugin code → browser origin)

- **Elevation**: an enabled plugin's `app.js` is not a guest. It is a `<script>` in the
  document that also renders the control plane, so it can call any `/api/*` route the
  operator's browser can, including `GET /api/config/raw` (T7 disclosure), `GET /api/sessions`
  for transcripts, and `POST /api/run` to drive the agent. There is no origin separation, no
  capability restriction, and no signature on the file.
- **Tampering**: `app.js` and `app.css` are served from disk byte-for-byte, so whoever can
  write the plugin directory changes what the operator's page executes on next load, and the
  `data-plugin` script tag is created once per session (`loadPluginScript`,
  `ui/app/core/plugins.js:403`).
- **Missing control**: the enabled list is the entire gate (`src/cli.zig:13242`), and
  `webui_addon` owns it. Enabling a plugin is a trust decision with the same weight as
  `plugins validate` on a tool manifest, which is not where the web UI plugin's trust is
  documented. Disabling one stops its code reaching the browser, which is the one control
  here and is operator-initiated only.

### T11 (host PATH → unsandboxed process)

- **Elevation**: a `clanker-<name>` on PATH is exec'd with the caller's argv verbatim and
  inherited stdio (`src/cli.zig:6033-6043`), so it is a normal program the operator ran,
  not a sandboxed guest. The enabled list is what keeps `clanker <word>` from spawning
  arbitrary PATH entries, and it is operator-set. Once enabled, that binary holds the
  operator's authority: filesystem, network, and the credentials in its environment.
- **Spoofing**: nothing verifies the binary's provenance; a writable PATH entry or a planted
  `~/.clanker/plugins/clanker-<name>` is indistinguishable from a real install.
- **Repudiation**: the spawn inherits stdio, so what it did is only visible if it logs.
- Missing control: no signature, and no separate authority reduction — Tier 2 is the one
  extension point in this tree whose execution is *less* bounded than every other one.

### T12 (provider OAuth → local token store)

- **Information disclosure**: `state/oauth/<provider>.json` holds a refresh token with the
  same blast radius as an API key (spend, impersonation). It is written 0600
  (`src/llm/oauth_store.zig:55`) and is under `agent.state_dir`, so it is covered by the
  same "who can read the state dir" question as the T8 backup copies, and inherits their
  snapshot history when the backup timers are installed.
- **Spoofing**: the device-code and manual-PKCE flows bind the pasted code to the request
  that opened the authorization URL (`src/llm/oauth_plugins/api.zig`); a hostile page that
  convinces an operator to paste a code into the wrong terminal is an operator-trust
  failure, and the CLI prints the provider it is logging into.
- **Repudiation**: no record names which login wrote a token or when, beyond the file's
  own mtime; `clanker auth status` reports presence, not history (`src/llm/oauth_command.zig:12`).

### T13 (config → external MCP server)

- **Elevation**: a `stdio` `[mcp_servers.*]` entry names a program that runs outside the WASM
  sandbox, with the same trust as an `exec_allow` line (`McpServer.command`/`args`, `src/config.zig:1267-1275`). The gate
  is `modules.mcp_client`, off by default (`src/config.zig:1105`), and the shape is validated
  at load (`src/config.zig:3292`) — but validation is a *shape* check, and the authority the
  command would carry is not bounded by anything.
- **Information disclosure**: `GET /api/mcp/servers` (`src/cli.zig:8653`) returns the
  configured command and URL to any unauthenticated caller, which maps the operator's
  internal infrastructure (an internal MCP host, a bespoke command) to anyone who can reach
  the port. Same class as the rest of the T1 disclosure rows, higher recon value.
- **DoS**: a `tool_call_timeout_ms` per server (`src/config.zig:1275`) bounds a call, but
  nothing bounds the count of configured servers or their concurrent processes.

### T14 (HTTP caller → the fleet-shared chat and mesh control plane)

This boundary is T1's *persistence* half: the same listener, the same absent caller
identity, but the store on the other side is shared with other instances and its writes
land in the model's next prompt. Enumerated separately because the blast radius is
different in kind from the T1 rows, which mostly read or configure this one host.

- **Spoofing (the one that the shipped docs got wrong)**: `sendMessageOpts` stamps every
  outbound message `.from = cfg.instance.name` (`src/peers/chatrooms.zig:903`), so a message
  written through `POST /api/chat/send` (`handleChatSend` `src/cli.zig:9318`) is indistinguishable from one the
  agent itself authored, to every reader and every peer it fans out to. `receive`
  (`src/peers/chatrooms.zig:606`) takes the sender from the peer-shaped POST body
  (`handleChatMessage` `src/cli.zig:9065`, sender taken from the body at `:9079`), so an inbound
  message's sender is whatever the body says - the mesh
  admission check (`admit`, `src/peers/mesh.zig:133`, which refuses an empty `join_id` at `:140`)
  applies to a JOIN, not to a message on
  an already-admitted connection.
- **Elevation / authorization**: `editMessage` and `deleteMessage` are documented as
  sender-only (`editMessage` `src/peers/chatrooms.zig:685`; `deleteMessage` `src/peers/chatrooms.zig:719`).
  Each rejects a non-owner with `error.NotOwner` (`editMessage` `src/peers/chatrooms.zig:706`;
  `deleteMessage` `src/peers/chatrooms.zig:739`), but the comparison is `m.from == from` and both
  handlers pass `cfg.instance.name` (`handleChatEdit` `src/cli.zig:9425`; `handleChatDelete` `src/cli.zig:9464`).
  So the check means "is this message one *I* sent", not "is this message the caller's": on a
  single-instance install every message the instance sent is editable and deletable by every
  caller, and every peer-authored message is editable by nobody.
  `toggleReaction` has no owner check at all (`handleChatReact` `src/cli.zig:9395`;
  `toggleReaction` `src/peers/chatrooms.zig:638`).
  `setTopic` takes no owner argument (`handleChatTopic` `src/cli.zig:9507`;
  `setTopic` `src/peers/chatrooms.zig:803`), and neither does `togglePin`
  (`handleChatPin` `src/cli.zig:9491`; `togglePin` `src/peers/chatrooms.zig:820`).
- **Tampering / membership**: `POST /api/chat/subscribe` writes the durable subscription set
  (`subscribe` `src/peers/chatrooms.zig:1190`; `handleChatSubscribe` `src/cli.zig:9380`), and
  `handleChatSend` auto-joins any room the body names before sending (`src/cli.zig:9338`).
  An anonymous caller chooses which rooms this instance now receives into, and that
  subscription set is what `receive` and `readNew` filter on (`isSubscribed`
  `src/peers/chatrooms.zig:260`).
- **Information disclosure**: `GET /api/chat/messages` serves the room log to any caller
  (`handleChatMessages` `src/cli.zig:9159`); so do `GET /api/chat/rooms`
  (`handleChatRooms` `src/cli.zig:9619`) and `GET /api/chat/pins`
  (`handleChatPins` `src/cli.zig:9529`). A join-then-read gets a room's history, and the
  board room folds Kanban cards and their work log out of the same log (ADR 0001,
  `docs/README.md:501`).
- **Injection across the boundary**: what `receive` accepts becomes the `[chatroom inbox]`
  user message on the next agent run (`readNew` `src/peers/chatrooms.zig:1266`; injected
  `src/agent/loop.zig:987`, built by `buildChatroomInbox` `src/agent/loop.zig:4049`), capped at `inbox_limit` 5 messages
  (`inbox_limit` `src/peers/chatrooms.zig:87`) and `max_chat_inbox_preview_bytes` 300 per
  message (`max_chat_inbox_preview_bytes` `src/agent/loop.zig:104`). The framing text tells the
  model the messages are untrusted data (`src/agent/loop.zig:4054`), and the block now also runs
  through `prompt_fence.neutralize`, which every other untrusted-bytes-into-prompt path does:
  tool results (`capToolResult` `src/agent/loop.zig:4028`, `prompt_fence.neutralize` call
  `src/agent/loop.zig:4029`), knowledge and memory hits
  (`prompt_fence.neutralize` `src/cli.zig:5863`), and the Skills/Learnings sections
  (`neutralizeMarkers` `src/improve/history.zig:715`). `buildChatroomInbox` neutralizes all three
  peer-chosen strings - message text, room name, author name (`src/agent/loop.zig:4059-4061`),
  which is what closes this row: a peer writing a harness fence marker into a chat message now
  has it rewritten like any other untrusted source. Same class as the T1 injection row, with a
  shorter hop. See R14.
- **DoS**: each chat write rewrites the whole shared log under a lock
  (`rewriteLog` `src/peers/chatrooms.zig:628`, lock `acquireChatroomLock`
  `src/peers/chatrooms.zig:435`) with a
  `max_history`-sized read (`chatrooms.max_history` 500, `src/config.zig:1090`), so a
  caller that can fill the retained window pays that cost per write. Bounded, not free.
- **Repudiation**: a chat mutation logs at `error_` only on failure (`src/cli.zig:9417`);
  a successful write leaves the log line and the message's `from`, which by the above is the
  server's name, not the caller's.

### T15 (GitHub → the installed binary)

`clanker update` is the one surface that *replaces the executable this process is running
from*, so its blast radius is everything above it at once. Nothing about it is remote-attacker
reachable — it is a local-operator boundary, not an inbound one — but it is the boundary whose
compromise needs no second stage, so it is modeled rather than left under "dependencies".

- **Entry point**: `clanker update [--check] [--repo <owner/name>]`, declared
  `src/cli.zig:2425` (command-table row, `.command = .update`), implemented `cmdUpdate`
  `src/cli/update.zig:297`. It reads
  `--repo` (an operator argument, `validRepo` `src/cli/update.zig:87`) and the ambient
  `GITHUB_TOKEN` (`githubBearer` `src/cli/update.zig:270`).
- **Tampering**: the downloaded asset must equal the hex digest in the `.sha256` sidecar
  published beside it (`checksumMatches` `src/cli/update.zig:149`) before anything is
  written, and both URLs must be GitHub https (`trustedGithubUrl` `src/cli/update.zig:117`,
  host allowlist `hostTrusted` `src/cli/update.zig:104` — `github.com`, `*.github.com`, `*.githubusercontent.com`,
  userinfo and lookalike suffixes refused). `decide` `src/cli/update.zig:167` returns a
  non-`replaced` verdict for every other case, and `cmdUpdate` exits through `fail`
  (`src/cli/update.zig:377`) without touching the executable.
- **What it does not do**: there is no signature. The digest is fetched from the *same* host
  as the asset, so a compromise of the release account or the CDN that can serve both files
  passes verification. That is the residual risk on this boundary, and it is inherent to a
  checksum rather than a fix the code is failing to make.
- **Repudiation**: the replaced path and the version are printed to stdout
  (`formatInstalled` `src/cli/update.zig:203`); `--check` prints the release page URL to
  stdout and the comparison to stderr (`src/cli/update.zig:333-338`). The install line is
  the only durable record, and it is not appended to any log store.
1. Sandbox path handling: symlinks (ADR 0017), lock-path resolution
   (`2026-08-17-cas-lock-name-hashes-an-unresolved-path.md`), `.env` refusal.
2. Untrusted bytes breaking host framing: a truncated exec result's `note` had to become a
   JSON string, not raw prose
   (`2026-08-18-exec-truncated-note-is-not-json.md`).
3. Self-modification integrity: `2026-08-16-improve-worktree-merge-bound-to-promotion.md`,
   `2026-08-19-improve-self-merge-leaves-worktree-reverted.md` (promotion merges reverted by
   careless worktree reset), `2026-08-16-concurrent-sessions-commit-each-others-work.md`.
4. Unscoped execution: `2026-08-15-unknown-goal-id-runs-unscoped.md`.
5. Provider fallback confusion: `2026-08-18-fallback-tries-unconfigured-providers.md` (skipped
   providers are now gated by the same offline check as the TUI).
6. Overload paths losing their own bookkeeping: the saturation 503 arrived reset before the
   client read it
   (`2026-08-24-saturation-503-is-reset-before-the-client-reads-it.md`).

## 5. Mitigations mapping

| # | Control | Code reference | Covers |
|---|---------|----------------|--------|
| M1 | Loopback bind by default; exactly one socket; `--host` opt-in widening | `default_serve_host` `src/cli.zig:7805`, resolve layers `resolveListen` `src/cli.zig:7888`, binding trust model in `docs/README.md:1621-1625` | R1, R2, R6 (network reach) |
| M2 | Host allowlist (DNS-rebinding defense) on every request, incl. GET | `unexpectedHost` `src/serve/http.zig:211`, combined with the Origin predicate `crossOriginRequest` `src/serve/http.zig:188`, enforced `unexpectedHost` `src/cli.zig:8494` and `crossOriginRequest` `src/cli.zig:8519` | R1 (rebinding) |
| M3 | Origin check on non-GET (CSRF) and on the SSE stream; HEAD rewritten once, after the check | `crossOriginRequest` `src/serve/http.zig:188`, enforced `src/cli.zig:8519` (`crossOriginRequest` at `:8707`; the HEAD rewrite in `handleConnection` at `:8560`) | R1 (cross-site) |
| M4 | Optional proxy token, constant-time hashed comparison; warn when unset on non-loopback | `proxy.authorize` `src/serve/proxy.zig:57`; wiring `src/cli.zig:8498-8503`, `proxy.authorize` call `src/proxy_main.zig:324`; proxy-unprotected warning in `cmdServe` `src/cli.zig:8008` and in `main` `src/proxy_main.zig:131` | R2 (partial, off by default) |
| M5 | WASM sandbox: descriptor policy (`fs_prefixes`/`env_allow`/`network_allow`/`exec_allow`), size caps | `tools/manifests/*.tool.json`, `src/sandbox/host.zig` | R3, R5, T2, T3 |
| M6 | Privileged channels gated by `tool_self_name` (import ≠ grant) | `src/sandbox/host.zig` | T2 elevation |
| M7 | `safeJoin`/`safeJoinSecure` refuse `.env` and symlinked components; `sandbox_follow_symlinks` opt-in (ADR 0017) | `src/sandbox/host.zig` | R5, T5 |
| M8 | `ck_exec` allowlist (git/zig/uv verbs; no host-absolute or `..` args; git config-injection and `--git-dir` flags denied) | `src/sandbox/host.zig` exec policy | T2 elevation |
| M9 | CAS write lock (`state/locks/<sha256-of-resolved-target>.lock`, flock, aged sweep) | ADR 0031, `ck_fs_write_if` in `src/sandbox/host.zig` | T2 tampering |
| M10 | Improve loop gates: build/test/tools/fmt/lint + inert check + worktree isolation before promotion | `src/improve/engine.zig`, `src/improve/inert_check.zig` | self-modification integrity |
| M11 | Prompt-injection posture: untrusted retrieved text fenced, model told never to execute it | `src/agent/system_prompt.zig:697` | R3 (advisory; sandbox enforces) |
| M12 | Body caps: `max_body_bytes` + 64 KiB slack (`src/cli.zig:8432-8435`); images 4 MB × 4 (`max_image_bytes` `src/cli.zig:10321`); connection limit (`max_connection_threads` `:8138`, enforced `:8139`, proxy reserve `:8186`); saturation 503 recorded, logged, FIN-then-drain (`respondSaturated` `:8238`, `drainThenClose` `:8264`); proxy upstream deadlines (`default_first_byte_s` `src/serve/proxy.zig:30-31`); mesh join-handshake connection cap (`max_inbound_conns` `src/serve/mesh_net.zig:38`, check `:630`) | see left | R6, T3 DoS |
| M13 | Mesh admission (allowlist/prompt/open) + loopback default | `src/peers/mesh.zig:124`, `:133`; `src/config.zig:990-991` | R4 (partial, name-match, no credential) |
| M14 | Peers are outbound-only; nothing listens for peer traffic | `docs/README.md:1627` | T3 reach |
| M15 | Guest-visible HTTP response headers are an allowlist, lowercased, value-capped | `exposed_response_headers` `src/sandbox/host.zig:3297`, ADR 0049 | T2 information disclosure |
| M16 | Hooks and the REPL `!cmd` escape run under the same exec allowlist and deny tokens as `ck_exec`, not through a shell | `execUnderPolicyInput` `src/sandbox/host.zig:7004` wired in `src/hooks/runner.zig:38`; `execUnderPolicy` `src/tui/repl.zig:4326` with the allowlist unioned by `execAllowUnion` from tool manifests plus `agent.repl_exec_allow` (`src/tui/repl.zig:4250-4256`) | T9 elevation |
| M17 | Backup refuses to run when the snapshot root would land inside the checkout | `scripts/backup-state.sh:79-83` | T8 false-backup (not a confidentiality control) |
| M18 | Snapshot root is owner-only (`chmod 700` on `$backup_root`, `700` on the `config/` subdir) and each copied file keeps its own mode, so the credential copies are not world-readable | `scripts/backup-state.sh:95`, `:213-230` | T8 credential disclosure (partial: mode, not lifetime or rotation) |
| M19 | Only an *enabled* plugin's assets are served, so turning one off stops its code reaching the browser | `src/cli.zig:13214`, gate `:13242` | T10 (partial: an on/off switch, not a trust check) |
| M20 | CLI Tier 2 requires membership in the same enabled list Tier 1 uses, so a bare `clanker <word>` cannot spawn an arbitrary `clanker-<word>` on PATH | `cli_plugins.resolveTier2` `src/cli/cli_plugins.zig:125`; spawn inside `cmdPlugin` `src/cli.zig:6118` | R8/T11 (consent gate only: the child is unsandboxed and inherits stdio) |
| M21 | OAuth tokens are written owner-only (0600) under `agent.state_dir/oauth/`, and no callback listener is opened — the operator pastes the code back | `atomic_write.private_file` `src/util/atomic_write.zig:15`, applied `atomic_write.private_file` at `src/llm/oauth_store.zig:55`, path `path` `src/llm/oauth_store.zig:31`; flows `loginDevice` `src/llm/oauth_command.zig:43` and `loginManual` `src/llm/oauth_command.zig:78` | T12 confidentiality |
| M22 | `[mcp_servers.*]` shape is validated at config load, so a `stdio` stanza with no `command` is refused before anything could spawn, and the client bridge that connects stays behind `modules.mcp_client` (off by default) | `parseMcpServer` `src/config.zig:3319`, `McpServer` fields `:1266-1276`, `modules.mcp_client` `src/config.zig:1105` | T13/T11 elevation (partial: shape only, and `GET /api/mcp/servers` still discloses the configuration) |
| M23 | Chat writes are bounded and serialized at the store: per-field caps (`max_text_len` `src/peers/chatrooms.zig:53`, `max_topic_len` `src/peers/chatrooms.zig:57`, `max_emoji_len` `src/peers/chatrooms.zig:83`), UTF-8 sanitation on append (`sendMessageOpts` `src/peers/chatrooms.zig:900`), a per-write lock (`acquireChatroomLock` `src/peers/chatrooms.zig:435`) and a `max_history`-sized window (`chatrooms.max_history` `src/config.zig:1090`) | see left | R10/R11 (bounds only: none of this is an authorization check) |
| M24 | The chatroom inbox is bounded before it reaches the model: `inbox_limit` 5 messages (`inbox_limit` `src/peers/chatrooms.zig:87`) and a 300-byte UTF-8 preview per message (`max_chat_inbox_preview_bytes` `src/agent/loop.zig:104`), inside a block whose own text says the messages are untrusted and must not be followed (`src/agent/loop.zig:4054`), and with every peer-chosen string run through `prompt_fence.neutralize` (`src/agent/loop.zig:4059-4061`) | see left | R14 (closed: the fence rewrite every other untrusted-bytes path already had now covers the inbox too) |
| M25 | `clanker update` verifies before it writes: both the asset and the sidecar URL must be GitHub https (`trustedGithubUrl` `src/cli/update.zig:117`, host allowlist `hostTrusted` `src/cli/update.zig:104`), the asset must match the published `.sha256` sidecar (`checksumMatches` `src/cli/update.zig:149`), `decide` `src/cli/update.zig:167` returns a non-`replaced` verdict for every other case, `--check` never downloads an asset (`fetchesAsset` `src/cli/update.zig:143`), an equal version never does either (`sameRelease` `src/cli/update.zig:50`), and the replacement is atomic (`replaceVerified` `src/cli/update.zig:184`) | see left | T15 (partial: a same-host checksum, not a signature) |

### Highest-value gaps (ranked)

1. **No authentication** on the control plane (R1): one control (loopback bind + Host/Origin)
   carries nearly every high-impact threat. Any local process, or any LAN client after
   `--host`, is the operator. The docs say so (`docs/README.md:1623`), so the gap is
   documented rather than misclaimed; it is still the largest one.
2. **Proxy token off by default** (R2): M4 exists but is opt-in, and an unset
   `proxy_token_env` disables the check rather than the surface: `proxy.authorize` is
   only reached inside the `on_proxy` branch, and `proxy.token` yields no expected value
   to compare against, so every `/v1/*` request is admitted (`src/cli.zig:8498-8503`).
   The standalone `clanker-proxy` additionally runs no Host/Origin guard.
3. **Mesh admission is not a credential** (R4): an allowlist matches a self-asserted name.
4. **No inbound rate limiting per route**: the DoS surface is the shared 64-slot connection
   limit; `src/llm/rate_limit.zig` paces outbound provider calls only.
5. **Web UI plugins are unsigned code in the operator's origin** (T10): a drop-in
   `app.js` inherits the whole control plane in the browser, and the only control is the
   operator's own enable switch.
6. **The chat control plane has no caller identity and its owner check compares the wrong side** (R10): every message is stamped with the *server's* name, so the 403 in `editMessage`/`deleteMessage` means "is this one mine" rather than "is this one the caller's" (`src/peers/chatrooms.zig:706`, `src/peers/chatrooms.zig:739`), and `/api/chat/react` has no check at all. Default-on, fleet-shared, and its output reaches other instances and the model prompt.
7. **No untrusted-bytes path is unfenced** (R14, closed): the `[chatroom inbox]` runs `prompt_fence.neutralize` like every other one, so a peer's fence markers are rewritten before they reach the prompt (`src/agent/loop.zig:4059-4061`, against tool results `prompt_fence.neutralize` call `src/agent/loop.zig:4029`). Kept in this list because the class recurs: a new untrusted-bytes path is unfenced until someone adds the call.
8. **Configuration disclosure with no authentication**: `GET /api/mcp/servers` (R7,
   `src/cli.zig:8653`) hands an unauthenticated caller every configured MCP command and
   URL. It is the one read-only route whose answer is a map of the operator's internal
   hosts, and it is easy to mistake for harmless because nothing in it is a credential.
9. **Extension points that leave the sandbox** (R8): the CLI Tier 2 plugin exec
   (`src/cli.zig:6033-6043`) and `[mcp_servers.*]` (`src/config.zig:1248`) both name
   programs that run with the operator's full authority. Both are gated on operator
   consent rather than containment, which is the right default, but it means the
   security story for these two is a switch and not a policy.

10. **The binary self-replacement has no signature** (R15): `clanker update` verifies a
    same-host checksum before overwriting the executable, which is the only boundary whose
    compromise is instantly total, so the checksum is the whole control. A signature over
    the release, verified against a pinned public key, is the upgrade the code is not
    making; recorded here so the gap is named rather than counted as covered.

### Single points of failure

- The **sandbox** (M5/M7/M8) is the load-bearing control for R3/R5 and the whole guest surface;
  a sandbox escape is the one event that turns prompt injection into host compromise.
- The **enabled-plugin switch** (`src/cli.zig:13242`) is the whole of T10's mitigation, and
  it sits in the same origin as the control plane whose reach it would have to constrain.
- The **Host/Origin guard** (`src/serve/http.zig:188-211`, enforced `unexpectedHost` `src/cli.zig:8494` and
  `crossOriginRequest` `src/cli.zig:8519`) is
  the entire CSRF/rebinding defense for an unauthenticated surface; a bypass (header parsing
  edge) removes the only per-request check.
- The **enabled list** is now the single control for three separate surfaces with real
  authority behind them: web UI plugins in the browser (T10, `src/cli.zig:13242`), the
  unsandboxed CLI Tier 2 exec (T11, `src/cli.zig:6040`), and the external MCP bridge
  (T13, `src/config.zig:1105`). They share no policy and no sandbox, only the idea that
  enabling is consent; one list's compromise is three unrelated exposures.

## 6. Abuse cases (hostile-but-authenticated)

*Authenticated* here means "can reach the port", which is the only authentication there is.

- **Speaking as the fleet in a shared chat room**: `POST /api/chat/send`
  (`handleChatSend` `src/cli.zig:9318`) stamps every message with `cfg.instance.name`
  (`sendMessageOpts` `src/peers/chatrooms.zig:903`) and the same call auto-joins whatever room
  the body names (`src/cli.zig:9338`). A caller that can reach the port therefore posts as this
  instance into a room its *peers* subscribe to, and `fanOut` (`src/peers/chatrooms.zig:1115`, called `src/peers/chatrooms.zig:919`)
  carries it onward: the message is attributed to a real instance name, so nothing downstream
  distinguishes it from one the agent wrote. Editing or deleting it back is likewise possible
  for any caller, because the owner check compares the same stamped name
  (`src/peers/chatrooms.zig:706`). The business-logic abuse is impersonation inside a fleet
  control plane, and the room log is the durable record of it.
- **Answering the mesh admission prompt for the operator**: with `mesh.admission = "prompt"`
  (`src/config.zig:993`), `POST /api/mesh/pending` (`handleMeshPendingPost` `src/cli.zig:16956`)
  is the one place a human approves a peer. Any caller can send `{"allow":true}` for a queued
  `join_id` and the peer is admitted (`resolvePending` `src/serve/mesh_net.zig:886`), so the
  prompt mode is advisory against a caller that does not have to be the operator. The same
  caller can evict members with `POST /api/mesh/leave` (`handleMeshLeave` `src/cli.zig:16901`).
- **Credential spending via proxy**: `POST /v1/chat/completions` (or `/proxy/v1/...` on the
  shared socket) with any body spends the configured provider keys; with no
  `proxy_token_env` there is no per-request gate. Enabling `--host 0.0.0.0` without a token
  makes this LAN-wide; the warning fires, nothing stops it (`src/cli.zig:7932-7937`).
- **Full agent drive and policy tampering**: `POST /api/run` (`src/cli.zig:8839`) dispatches
  agent work, but guest descriptor policy is not a boundary around the HTTP caller. The same
  caller can read and replace native configuration through `/api/config/raw`
  (`handleConfigRawGet` `src/cli.zig:12437`, `handleConfigRawSet` `src/cli.zig:12468`). Config parsing validates values, not
  permission to change policy. See T7.
- **Workspace read without a descriptor**: `GET /api/files?path=` (`handleFiles`,
  `src/cli.zig:14492`) is a native reader over the workspace, not a sandboxed guest, so the
  descriptor grants that cover `read_file` do not bound it. Its own bounds are the root clamp, the
  no-follow symlink walk (`pathHasSymlinkComponent` refusal, `src/cli.zig:14553`; definition
  `src/cli.zig:14751`) and the dotenv refusal (`src/cli.zig:14540`); everything else in the
  checkout is readable, including a file a tool holds
  only by prefix grant. Enabling a plugin (T10) hands that plugin a reader too.
- **A second unauthenticated agent entry point**: `POST /api/a2a/message`
  (`is_a2a` predicate `src/cli.zig:8589`, handler `handleA2AMessage` `src/cli.zig:10079`) is a
  JSON-RPC-shaped route that runs a task
  through the agent model with the same tool registry. Its only gate is `modules.a2a`, which
  defaults **on** (`src/config.zig:1110`), so unlike `modules.acp` and `modules.mcp_client`
  (off by default, `src/config.zig:1108` and `:1105`) this is a second agent-invoking route
  present in a stock install, carrying no check of its own.
- **Backend selection**: a run body naming a supported backend (`src/cli.zig:17322-17327`)
  reaches native process spawning (`src/cli.zig:17722`), where the vendor CLI's own permission model, not
  clanker's sandbox, governs what the task may do.
- **Write confirmation bypass**: `/api/ask` (`handleAsk` `src/cli.zig:10665`, dispatched `src/cli.zig:8835`) answers `confirm` events with a
  byte-exact option check; a client that already reaches the port can answer "allow" itself;
  the confirmation protects against *accidental* writes, not a hostile caller.
- **Transcript scraping**: `GET /api/sessions` + per-session reads and `/api/logs` are
  unauthenticated reads of conversation and log content (route table `docs/README.md:1625`).
  With the backup timers installed, the same transcripts exist off-checkout under
  `<storage_root>/backups/` (`scripts/backup-state.sh:154-197`).
- **Prompt-surface tampering**: `POST /api/skills` (`handleSkills`, `src/cli.zig:14816`) flips a
  skill's enable flag in `state/skills.json`, and that flag decides which markdown files are
  inlined into the next system prompt (the `skills` guest's `fs_prefixes` is `skills` plus that one
  file, `tools/manifests/skills.tool.json:18`; the name is gated by `validSkillName`,
  `src/cli.zig:14751`). Disabling a skill removes a control the operator believes is present. It is
  the cheapest durable change a caller can make, and it lands in the highest-authority position of
  every later prompt.
- **State tampering through tools**: `POST /api/goals` / `/api/board` / `/api/plugins/config`
  mutate durable state via guests; a malicious payload is validated by the guest's own logic
- **Mesh flooding**: a peer in `open`-admission mode can JOIN and then receive every fanned
  chat message; with many peers, fan-out multiplies traffic (`src/peers/chatrooms.zig`).
- **Trust laundering through the plugin directory**: installing a plugin is a drop-in
  (`clanker plugins new`), enabling it is one call, and its `app.js` then runs with the
  operator's full browser-side authority (T10). Every other extension point in this tree is
  a signed-by-nothing but *described* unit whose host half enforces a descriptor; the web UI
  plugin has no host half, so there is no point at which its authority is bounded.

Trust placed in client-side enforcement: the web UI's stored session id and the `Origin` header
are the only "identity"; neither is a secret.

## 7. Threat-model document quality

- Starter created 2026-08-19; reference pass 2026-08-26. Two boundaries that had inventory
  rows but no threat enumeration were added on 2026-08-26: T8 (local automation: cron
  schedule, backup timers) and T9 (local IPC: MCP, ACP, DAP, hooks, `!cmd`), with M16 (shared
  exec allowlist) and M17.
- Line references drift fast in this tree, and two passes in a row have now
  overclaimed their own check. The 2026-09-27 pass recorded that every reference
  "lands on the named symbol" while roughly 40 of its 129 did not; the 2026-09-29
  pass found the same failure again, 30 explicit references and 6 bare `:NNNN`
  shorthands stale after two days. `src/cli.zig` is the bulk of it and drifts
  fastest: it moved ~74 lines between the two passes, so every one of its ~30
  references had to be re-anchored (e.g. `respondSaturated` was cited at `:8008`
  and is at `:8074`; `max_connection_threads` at `:7908` and at `:7974`;
  `handleConfigRawGet` was cited at `:11887` and is at `:12129`; the mesh
  `acceptLoop` in `src/serve/mesh_net.zig` at `:599`, its `max_inbound_conns` check at `:630`). The rest sat
  in `src/sandbox/host.zig`, `src/tui/repl.zig`, `scripts/backup-state.sh`, and
  `docs/README.md` (the no-authentication paragraph the model cites is
  `docs/README.md:1623`, not the `GET /` paragraph at `:1619` that the previous
  pass pointed at).
- The check that actually catches this is mechanical, not by eye: extract every
  `file:line` in the document, print the cited line plus two on each side, and
  assert an expected keyword appears in that window. Reading 89 spans by hand is
  what let the drift stand twice. Re-run it on any edit that renumbers anything,
  and treat the bare `:NNNN` shorthand as the first thing to distrust: it inherits
  its file from the preceding reference in the same cell, and the count above
  shows a shorthand going stale in the same pass as the explicit references
  around it.
- Two habits made the drift cheap to fix and are worth keeping: the bare `:NNNN` shorthand
  inherits its file from the preceding reference in the same cell, and that is the form that
  silently rots: the bare form is what the mechanical check has to guess a file for, and a
  guessed file makes a wrong line look verified. A reference whose line lands inside a comment
  (`scripts/backup-state.sh:99-103` is the `case` that opens the in-checkout refusal, which is
  the right span) is worth re-reading rather than re-numbering. Prefer a symbol
  (`respondSaturated`) over a line number when adding a new reference here; where a line number
  is kept, the symbol belongs next to it.
- An earlier pass found one gap the model had missed: the backup snapshot copies
  `config.local.toml`/`.env`, so the provider keys get a second off-checkout copy
  (`scripts/backup-state.sh:213-230`). Added as an asset row, a T8 disclosure threat, and
  M18 (owner-only snapshot root).
- T10 (drop-in web UI plugin code in the operator's browser origin) was added on
  2026-09-29 with M19. It was the one entry point in the tree whose trust was not named: the
  plugin system is documented as unsigned (T5) for *descriptors*, and the browser-side half
  had no row at all.
- 2026-09-30 pass: the third occurrence of the same failure, and the largest yet. The
  2026-09-29 header claimed every reference re-resolved; 43 of its 92 explicit
  references and 39 of its 46 bare `:NNNN` shorthands pointed at unrelated code
  (`src/cli.zig` alone had ~30 stale, the file having moved ~74 lines in a day).
  All 46 were re-anchored by symbol rather than by arithmetic, and the header's count
  now states the number the current check actually resolves. The mechanical check is
  what makes this pass cheap; the third recurrence is the argument for keeping it.
- 2026-09-30 pass: three entry points the model never named were found by walking the
  tree rather than the document, and added as T11 (CLI Tier 2 plugin, an unsandboxed
  PATH exec behind an enabled list), T12 (native OAuth logins and the token store under
  `state/oauth/`), and T13 (`[mcp_servers.*]`, which names programs that run outside
  the sandbox, and whose configuration is readable unauthenticated over HTTP). T13's
  route is the new R7; the other two are new R8. Their absence is the shape of the
  remaining drift: an entry point added as a feature is added to the inventory only
  if the author also thinks of it as security, and `mcp_servers`/`cli-plugins` are
  feature surfaces first.
- 2026-10-01 pass: the fourth recurrence, and the first one the walk found rather than
  the check. 51 of 96 explicit references and 6 of the bare shorthands were stale, all
  downstream of `src/cli.zig` moving ~130 lines; each was re-anchored by symbol, not by
  offset. Two entry points the model never named were found by enumerating the route
  predicates in `src/cli.zig` against the model's tables: `GET /api/files` (R9, a row
  under T1, and an elevation bullet under T7) — a native directory-and-content reader
  over the workspace that no guest descriptor bounds — and the skill-enable write behind
  `POST /api/skills`, an unauthenticated edit of what rides the next system prompt.
  Both are recorded as threats with their existing mitigations named; the fixes belong
  to a point review. The same walk confirmed that no endpoint named in the model has been
  deleted.
- 2026-10-01 pass: the fourth occurrence of the same failure, and the largest: 96 of 280
  references (232 explicit spans, 53 bare) landed on unrelated code. `src/cli.zig` again
  carried the bulk (124 of its references stale; the file has moved far enough that
  `resolveTier2` went from `:5970` to `:6040` and the route predicate block from `:8456`
  to `:8491`), with `src/config.zig`, `src/serve/`, `src/peers/mesh.zig` and
  `scripts/backup-state.sh` behind it. All 221 stale spans were re-anchored by symbol.
  Two things about this pass are worth recording, because they are the generalizable part:
  a bare `:NNNN` inherits its file from the *preceding reference in the same table cell*,
  so a cell whose explicit references all move can leave its bare ones resolving against a
  different file than it looks like; and a reference whose cell happens to name a symbol
  that also occurs elsewhere in the file (a `test` block, say) satisfies a naive
  keyword-in-window check without the cited line being right. A checker that trusts either
  is a checker that reports a green wrong number.
- The check now ships, as `scripts/check-threat-model.py`. It has to be able to fail, so it was
  verified failing first: pointed at `src/cli.zig:9316`, and at a real line that no longer holds
  the symbol its reference names, it exits non-zero on both. Two ways it briefly gave a false
  green while being written are worth recording, because both are easy to reintroduce: a
  keyword window that accepted a `test`-block occurrence of the right symbol on the wrong line,
  and an expectation scope narrow enough (per clause) that it flagged correct citations. The
  scope now used is the cell plus the row's subject cell, and the strictness lives in `resolve()`.
  What it still cannot do is match an identifier where the cell names none, and a good share of
  the spans are like that (a dense row citing a dispatch line, a cap constant and an enforcement
  site without backticking any of them). Those are covered by `ASSERTED`, which requires the cited
  lines to *contain* named code text rather than a symbol name, so they still fail on drift; a
  table of prose descriptions would have been a waiver, and a waiver is how the last three passes
  each reported green over a third of the file. `--list` prints which bucket each reference landed
  in, so the split is auditable rather than asserted here.
- 2026-10-03 pass: the shipped checker reported 0 stale over 480 references, and the
  document was still wrong, because the checker's own tolerance was the hole. A cell
  naming several symbols let *any* of them use the ±4-line `nearby` window, so a citation
  for `handleChatPin` was satisfied by `handleChatSubscribe` four lines off: the chatroom
  row names five handlers and three of its citations were stale while the run stayed green.
  `resolve()` now holds each reference to the symbol its own clause names: the
  `\`sym\` \`path:line\`` idiom binds, anything further back in the row does not, and a
  qualified `cli_plugins.resolveTier2` resolves through its bare name. A reference may
  land on the `fn` line, on a doc comment above it (`nearby`, ±4), or on any line
  inside the body (`span`, brace-matched with string literals stripped), which is
  what keeps the dense multi-symbol rows working. Thirty-one citations were
  re-anchored against the code: the readiness report at `:9858-9872`, the three
  chatroom handler lines, `handleFiles` at `:14322`, the raw-config routes at
  `:12292`/`:12323`, the backend dispatch at `:17306`/`:17706`, `modules.a2a` at
  `src/config.zig:1092`, the Tier 2 plugin spawn (cited at `src/cli.zig:6040`
  while `cli_plugins.resolveTier2` is `src/cli/cli_plugins.zig:125`), the proxy
  warning lines, and the OAuth private-mode path. Two of those were not stale
  lines but invented claims: a symbol that does not exist under that name, and a
  bare `:31` whose file had been renamed out from under it.
- 2026-10-03 pass: one entry point the model never named, found by walking the `Command`
  enum rather than the document: `clanker update` (`src/cli/update.zig`) downloads a
  release asset and a `.sha256` sidecar from GitHub and **overwrites the running
  executable**. It was filed under "deployment / dependency surface", which is exactly the
  bucket that assumes the supply chain is someone else's problem; the write lands inside the
  binary every other boundary in this document runs in. Added as T15 with R15, an asset row,
  M25, and a ranked gap naming what is absent (no signature — the digest is fetched from
  the same host as the asset, so a compromised release account or CDN passes it). The fix
  belongs to a point review; recording it here is what a later pass can aim at.
- Sections 2-4 remain partial in coverage: the internet-facing (T1, T2), authentication
  (T1, T9, T10), and local-automation (T8) boundaries are complete; the mesh/peer, disk state,
  and secrets boundaries are summarized and want a dedicated pass.
- `SECURITY.md` does not exist; no disclosure contact, supported-version statement, or security
  claims to check. `.github/dependabot.yml` is the only security automation. This is recorded
  as a gap, not filled in with invented contacts.
- Risk ranking lives in the TL;DR above; owner and cadence are organizational and unset.

## 8. Response readiness (note only)

- Audit trail: `state/sessions/<id>.db` (transcripts), `state/token_stats.jsonl`, `state/logs/`
  (via `GET /api/logs`), mesh/chat logs, `state/history/` snapshots, plus off-checkout
  snapshot copies under `<storage_root>/backups/` once the backup timer is installed — that
  root extends how long transcripts outlive their deletion from `state/`. Structure is owned by
  o11y-review; noted here that security events (a refused proxy auth, a refused Host or Origin,
  a refused sandbox path, a saturation 503) surface in logs, and saturation also books into
  `/api/metrics` (`recordHttpRequest(io, 503, 0)` `src/cli.zig:8246`, surfaced as
  `http_errors_total.load` at `src/cli.zig:9803`), but there is no dedicated security event log.
- No documented path from "vulnerability reported" to "fix shipped": no `SECURITY.md`, no
  disclosure contact, no security policy in `.github/`. The improve loop's gated promotion
  (M10) is the only change-shipping pipeline.
