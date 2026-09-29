# clanker Threat Model

Last reviewed: 2026-09-29. Every file:line reference below was re-resolved against the tree on
that date by a mechanical check (extract each reference, print the cited line and its neighbours,
assert an expected symbol appears in the window); 88 explicit references and every bare `:NNNN`
shorthand now land on the symbol or call site they name. Two earlier passes recorded the same
result for sets that 40 and then 30 references did not satisfy, so see
[document quality](#7-threat-model-document-quality) for how the check was redone and how fast
each set drifted. Evidence is static code inspection, not attack testing. Owner, review cadence,
and disclosure process remain unset (organizational, not invented here).

Owner: unassigned. Review cadence: not set. Vulnerability disclosure process: none documented
(no `SECURITY.md`; see [Response readiness](#8-response-readiness-note-only)).

## TL;DR: risk-ranked summary

| # | Risk | Impact | Likelihood | Notes |
|---|------|--------|------------|-------|
| R1 | **Unauthenticated control includes native configuration and backend execution, not just sandboxed tools.** The HTTP handler has Host/Origin checks but no caller authentication (`src/cli.zig:8314`, `src/cli.zig:8339`). Raw config reads disclose file contents (`src/cli.zig:12129`); validated writes change the operator's policy (`src/cli.zig:12160`). `/api/run` can select a native backend (`src/cli.zig:17126`, dispatched `src/cli.zig:17521`, `src/cli.zig:17624`), and `POST /api/a2a/message` (`src/cli.zig:8409`) is a second agent-invoking route that is on in a stock install (`modules.a2a` defaults true, `src/config.zig:1082`). | Critical: configuration, credentials stored there, and operator-level execution | High for a reachable local client; remote exposure depends on bind/network policy | Loopback/Host/Origin are not user identity. WASM grants do not contain the native paths; see T7. The same absence governs the local IPC surfaces (T9). The docs state the absence plainly (`docs/README.md:1621`, `README.md:224`). |
| R2 | **Proxy credential spending.** Proxy authentication is optional; a `proxy_token_env` naming an unset variable skips authentication entirely (`src/cli.zig:8319-8327`, standalone `src/proxy_main.zig:311-316`). The standalone proxy runs no Host/Origin guard: `src/proxy_main.zig` contains no `unexpectedHost` or `crossOriginRequest` call. | High: provider spend and submitted prompt data | High when reachable without a token | A proxy token protects only proxy paths, never `/api/*`. Startup warnings are not access controls (`src/cli.zig:7843-7846`, `src/proxy_main.zig:125-137`). |
| R3 | **Prompt injection through LLM responses.** Provider output is untrusted input to the agent loop; retrieved documents, memory hits, and tool results are untrusted text the model is told never to execute (`src/agent/system_prompt.zig:697`). Containment is the sandbox, not the prompt. | High (tool misuse within sandbox policy) | Certain (inherent to an agent harness) | The sandbox is the trust boundary that makes this survivable; see M5. |
| R4 | **Mesh join without credential.** Mesh admission is allowlist-by-name, prompt, or open (`Admission`, `src/peers/mesh.zig:123`; `admit` `src/peers/mesh.zig:132`); the wire carries no authentication beyond the admission handshake and no encryption (plain TCP). Default bind is loopback `127.0.0.1:7420` (`src/config.zig:962`). | Medium (chat/fan-out spoofing, membership) | Medium (needs LAN reach or misconfig) | Off by default (`modules.mesh`). |
| R5 | **Sandbox escape via symlinks was a real class** (ADR 0017); `safeJoinSecure` now refuses symlinked components on granted paths (`src/sandbox/host.zig`, path policy). Anything that broadens the sandbox (kernel, docker, exec allowlist, `agent.sandbox_follow_symlinks`) re-opens it. | High | Low (fixed, recurring class) | See [history](#threats-the-history-already-demonstrates-recurring-classes). |
| R6 | **DoS: connection limit 64** (`max_connection_threads`, `src/cli.zig:7974`, enforced `:8016`; proxy surface keeps a web UI reserve `:8022`; `/health/ready` reports `saturated`, `src/cli.zig:9706-9707`), request bodies capped at `max_body_bytes` +64 KiB slack (`src/cli.zig:8271`), images capped 4 MB × 4 (`src/cli.zig:10012`, count `:16917`). Saturation refusals reset their own per-request state, book under `errors_total`, and log with a fresh request id (`respondSaturated`, `src/cli.zig:8074`), then FIN-then-drain so the 503 survives the close (`drainThenClose`, `src/cli.zig:8100`). The proxy's upstream deadlines default to 300 s first byte / 60 s idle (`src/serve/proxy.zig:30-31`, wiring `:426-427`, knobs `src/config.zig:1025-1029`). The mesh join handshake holds its own bounded thread pool (`max_inbound_conns`, `src/serve/mesh_net.zig:38`, enforced `:638`). Still no inbound per-route rate limit (`src/llm/rate_limit.zig` limits *outbound* provider requests, not callers), so any local process can hold all 64 slots. | Medium | Medium | Loopback-only default keeps this local. |

Priority order for the next pass: R1/R2 (internet-facing + authentication boundary, covered
below), then R3 abuse cases, then R4-R6.

---

## 1. Attack surface inventory

### Network listeners (process-external)

| Entry point | Where | Default reach | AuthN/AuthZ |
|-------------|-------|---------------|-------------|
| HTTP server (web UI + every `/api/*` route, health, metrics, A2A, `/proxy/v1`) | `clanker serve`: `resolveListen` `src/cli.zig:7724` (default `default_serve_host` `src/cli.zig:7641`), per-connection `serveConnection` `src/cli.zig:8011`; route dispatch from `src/cli.zig:8495`; route table `docs/README.md:1536` | `127.0.0.1:17921` (`--host` widens; one socket, `docs/README.md:1624`) | **None**; Host allowlist + Origin check only |
| Proxy listener (dedicated) | `--proxy-port`; serves `/v1/*` and no `/api/*` (`docs/README.md:1624`); standalone binary `src/proxy_main.zig` (default `127.0.0.1:17922`) | loopback | Optional `proxy_token_env` (`src/config.zig:1017`), compared in constant time over SHA-256 digests (`proxy.authorize`, `src/serve/proxy.zig:57-69`) |
| Mesh TCP listener | `src/serve/mesh_net.zig` (`acceptLoop` `src/serve/mesh_net.zig:607`; inbound cap `src/serve/mesh_net.zig:38`, enforced `:638`) | `127.0.0.1:7420` (`src/config.zig:962`) | Admission allowlist/prompt/open (`Admission` `src/peers/mesh.zig:123`, `admit` `:132`); JOIN handshake bounded by frame cap + read timeout (`join_wait_ns`, `src/serve/mesh_net.zig:710-719`) |
| Outbound peer HTTP (`POST /api/chat/message`, notify) | `src/peers/chatrooms.zig` fan-out; `src/peers/command.zig` | none | Peers are *outbound* URLs, never listeners (`docs/README.md:1624`) |

### IPC / local-process surfaces

Trust for every row below is "whoever can spawn the process or write the config naming its
command"; none carries client authentication. Enumerated as T9.

| Entry point | Where | Notes |
|-------------|-------|-------|
| MCP server (stdio JSON-RPC) | `src/mcp/server.zig` | Exposes the tool registry; trust = whoever can spawn the process (`docs/README.md:457`) |
| ACP v1 stdio | `src/acp/server.zig` | Same model |
| DAP (debug adapter) | `src/debug/dap.zig` | Can start/debug subprocesses (`src/agent/subprocess.zig`) |
| Lifecycle hooks | `src/hooks/runner.zig`, `src/hooks/config.zig` | Configured commands run at lifecycle points: config-trust surface |
| REPL `!cmd` shell escape | `docs/README.md:854` | Deliberate: interactive user shell; `repl_exec_allow` widens only what tool policy already allowed (`docs/README.md:1418`) |

### Drop-in code the host serves without a signature

| Entry point | Where | Notes |
|-------------|-------|-------|
| Web UI plugin assets `GET /webui/plugins/<name>/app.js|app.css` | `handleWebuiPluginAsset` `src/cli.zig:13034`, gated on the plugin being enabled (`:13063`) | Served from disk byte-for-byte, and the `app.js` is injected as a plain `<script>` into the operator's page (`loadPluginScript`, `ui/app/core/plugins.js:420-427`), so it runs in the same origin as `/api/*`. Enumerated as T10. |
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
  goals, plugins) to `backups/` beside wherever `state` resolves (`scripts/backup-state.sh:178-183`),
  plus `config.local.toml`, `config.local.json`, and `.env` from the checkout
  (`scripts/backup-state.sh:199-225`), and refuses to run when that root would land inside the
  repo (`scripts/backup-state.sh:79-88`).
  Threat shape: same trust level as cron (runs as the operator's user), but it widens where
  transcripts live — see T5/T6 and the assets table. Both are threat-enumerated under T8.
- LLM client outbound HTTPS (all providers, `src/llm/client.zig`), outbound-paced by
  `src/llm/rate_limit.zig`; the *response* side is untrusted input (R3).

### Inputs that cross the trust boundary as untrusted data

- HTTP request bodies (JSON), headers (`Host`, `Origin`, `Content-Type`), query strings,
  resource ids (`requestPath` strips query first, `src/serve/http.zig:25`).
- `/api/run` `images` (base64, 4 MB each, at most 4, requires `modules.multimodal`;
  `src/cli.zig:10012`, `:16917`; `docs/README.md:1669`).
- Chatroom messages fanned in from peers (`POST /api/chat/message`, `src/peers/chatrooms.zig`).
- SSE event stream `GET /api/events`, long-lived, Origin-gated (`src/cli.zig:8527`).
- Mesh wire frames (length-prefixed, `decodeFrame` against `max_frame`,
  `src/serve/mesh_net.zig:383-387`), JOIN name/id, seeds.
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
  `/api/metrics` ride the same socket (`src/cli.zig:8388`, `:8432`).

## 2. Trust boundaries and data flow

| # | Boundary | Direction | Validation / authn point |
|---|----------|-----------|--------------------------|
| T1 | **Client → HTTP control plane** | Browser/SDK/curl → `/api/*`, `/proxy/v1` | No authn. Host header checked on *every* request (`unexpectedHost`, `src/serve/http.zig:211`, enforced `src/cli.zig:8314`; combined predicate `src/serve/http.zig:200`); `Origin` checked on non-GET as CSRF (`crossOriginRequest`, `src/serve/http.zig:188`, enforced `src/cli.zig:8339`) and on the SSE stream (`src/cli.zig:8527`); body capped (`src/cli.zig:8271`). HEAD is rewritten to GET once, after the proxy dispatch and the Origin check, so POST-only routes stay unreachable via HEAD (`request_head` set `src/cli.zig:8300`, rewrite `:8306`). Loopback bind is the real control |
| T2 | **HTTP control plane → agent/tools** | `/api/run` task text (`src/cli.zig:8659`) → agent loop → sandboxed tools | Descriptor policy: `fs_prefixes`, `env_allow`, `network_allow`, `exec_allow` (`tools/manifests/*.tool.json`, honored in `src/sandbox/host.zig`); privileged `ck_*` channels check `tool_self_name` (`src/sandbox/host.zig`) |
| T3 | **Peer/mesh → local state** | `POST /api/chat/message`, mesh CHAT frames → `state/chatrooms.jsonl`, `state/notifications.jsonl` | Chat fan-out via sandboxed `peers` tool (`chat_fanout`, `network_from_config`); mesh admission handshake (`src/serve/mesh_net.zig:528-556`); no wire crypto |
| T4 | **Provider API → agent loop** | LLM response stream → conversation → next model request | Prompts treat provider output and retrieved text as untrusted (R3); sandbox is the enforcement point. History sent to model is append-only; request-only copies for compaction (`docs/README.md` agent section) |
| T5 | **Disk state → process** | `state/sessions/<id>.db`, `state/goals.json`, `state/models-dev.json`, `state/board*.json`, `state/plugins.json` + `plugin_config.json` | JSON state parsed with explicit bounds (guests read through `ck_fs_read_range`, not whole-file); sessions are read by tools through the `ck_session` channel rather than as files; `.env` refused by `safeJoin`; symlinked components refused by `safeJoinSecure` (ADR 0017) |
| T6 | **Secrets → code** | Provider keys via `api_key_env` (provider tables in `src/config.zig`), `[serve] proxy_token_env` (`src/config.zig:1017`), Vertex service-account JWT minting (`src/llm/vertex_token.zig`) | Keys live in `config.toml`/`config.local.toml`/env; guest access gated by `env_allow` + named `ck_getenv`; proxy credentials ride only `/v1/*` paths; token comparison is constant-time over SHA-256 digests (`src/serve/proxy.zig:57-69`) |
| T7 | **HTTP caller → native configuration and backends** | Raw config reads/writes (routes `src/cli.zig:8468-8469`, handlers `:12129` GET and `:12160` POST); backend selection (`src/cli.zig:17126`) and native dispatch (`:17521`, `:17624`) | File-name restriction and config validation protect format, not caller authority. Backend-name validation (`acp_vendor.Name.parse`) selects supported adapters, not a WASM sandbox. No caller authentication precedes these routes (`src/cli.zig:8314-8339`). |
| T8 | **Local automation → host execution** | System cron `clanker schedule run-due` (`src/schedule/`), the opt-in state-backup units (`scripts/install-state-backup.sh`, `scripts/systemd/clanker-state-backup.timer`), which shell out to `scripts/backup-state.sh` | No caller input crosses a wire: the trust question is *who may write the schedule file or the timer/cron line*. Backup refuses to run when its root would land inside the checkout (`scripts/backup-state.sh:79-88`) |
| T9 | **Local process → IPC surfaces** | MCP stdio JSON-RPC (`src/mcp/server.zig:49`), ACP stdio (`src/acp/server.zig:302`), DAP (`src/debug/dap.zig:513-536` launch/attach selects a configured adapter), lifecycle hooks (`src/hooks/runner.zig:16`), REPL `!cmd` (`src/tui/repl.zig:4301`) | Trust = whoever can spawn the process or write the config that names its command. Hooks and `!cmd` run through the same exec allowlist as `ck_exec` (`execUnderPolicyInput`, `src/sandbox/host.zig:6970`; `execUnderPolicy`, `src/tui/repl.zig:4301`); DAP `launch`/`attach` picks a *configured* adapter by name and never takes argv from the client (`src/debug/dap.zig:513-536`); `ck_debug` requires `debug.enabled` (`src/sandbox/host.zig:2172`) |
| T10 | **Third-party drop-in code → operator's browser origin** | `ui/plugins/<name>/app.js` served from disk (`src/cli.zig:13034`) and injected as a plain `<script>` into the page that also holds the control plane's `localStorage` session id (`ui/app/core/plugins.js:420-427`) | The only gate is that the plugin is *enabled* (`src/cli.zig:13063`); there is no signature, no separate origin, and no `sandbox` attribute, so plugin code holds every capability the page has: read `/api/config/raw` (T7), read every transcript, and `POST /api/run` with the operator's reachability. Trust = whoever can write `ui/plugins/<name>/app.js`, or whoever gets an operator to enable a plugin they did not write. |

Privilege transitions:
- HTTP caller → policy author: native config writes validate and persist the config pair
  (`src/cli.zig:12160`), outside guest descriptor enforcement.
- HTTP caller → native backend process: `runCodingBackendCtx` (`src/cli.zig:4300`) passes
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
  (`src/config.zig:768`) all name a program that runs with the server's own authority. The
  exec allowlist bounds the first two (M16); the DAP adapter list is a config-time trust
  decision with no allowlist, mitigated only by the operator choosing the config.

## 3. Assets and impact

| Asset | Held where | Blast radius if compromised |
|-------|-----------|-----------------------------|
| Provider credentials (LLM keys, Vertex service account) | `config.toml`, `config.local.toml`, env (`api_key_env`); read via `src/llm/auth.zig`; also readable through `GET /api/config/raw` (`src/cli.zig:12129`) | Financial (token spend), impersonation of the operator's provider identity |
| Provider credentials, second copy | `<storage_root>/backups/<timestamp>/config/` once the opt-in backup timer is installed (`scripts/backup-state.sh:199-225`) | Same keys, copied off the checkout into an append-only snapshot tree; outlives deleting `config.local.toml`/`.env`, and no rotation sweep reaches it |
| Native configuration and execution authority | `/api/config/raw` (`src/cli.zig:12129`, `:12160`), `/api/run` backend dispatch (`src/cli.zig:17521`) | Policy tampering and execution as the server's OS user; guest sandbox policy does not constrain these native paths (T7). No implication of OS root privileges. |
| Conversation transcripts (sessions) | `state/sessions/<id>.db` (WAL SQLite, `src/agent/session.zig:35`; + `state/spills/<session>/`, `state/exports/<id>.html`) | Data disclosure (conversations contain task context, possibly secrets pasted in). With the backup timers installed, twice-hourly snapshot copies of all of it live under `<storage_root>/backups/` (`scripts/backup-state.sh:178-183`) — anyone who can read the storage root reads every conversation, including ones since deleted from `state/` |
| Source code + git history | working tree, `.git` | Integrity; the improve loop can *self-modify* the repo through gated promotion (`src/improve/engine.zig`) |
| LLM spend | `state/token_stats.jsonl` (hard cap, `src/stats/tokens.zig:25`; `docs/README.md:470`) | Financial; also an availability signal |
| Mesh membership + chatrooms | `state/chatrooms.jsonl`, `state/chatrooms-sub.json` | Spoofing/reputation; fan-out amplification to peers |
| Board / goals / knowledge graph | `state/goals.json`, `state/board*.json`, knowledge entries | Integrity of the workflow record |
| The machine (via `ck_exec`, `ck_docker`, kernel) | sandbox policy | Highest impact; deliberately the hardest to reach |

## 4. Threats per boundary

### T1 (client → HTTP): STRIDE

- **Spoofing**: none, no authn. Any process on the host (or LAN once `--host` widened) is the
  operator. Accepted and documented by design (`docs/README.md:1621`).
- **Tampering**: cross-site POST refused by the Origin check (`src/cli.zig:8339`), but only for
  browsers; curl/raw clients carry no `Origin` and pass. CSRF strength = Origin trust. HEAD is
  rewritten to GET once after the check, so a HEAD cannot reach a POST-only route
  (`src/cli.zig:8380`).
- **Information disclosure**: GET endpoints expose logs (`/api/logs`), sessions
  (`/api/sessions`), transcripts, knowledge, stats, all unauthenticated (route table
  `docs/README.md:1536`).
- **DoS**: 64 connection slots (`src/cli.zig:7974`, enforced `:8016`); body cap
  (`src/cli.zig:8271`); no per-route rate limit; `POST /api/run` holds a slot for the whole run; provider
  hangups are bounded only by `agent.request_timeout_ms` / `agent.stream_idle_timeout_ms` (the
  HTTP client itself has no read timeout; defaults `src/config.zig:527`). Saturation 503s reset
  their own threadlocal request state, book under `errors_total`, carry a fresh request id, and
  log (`respondSaturated`, `src/cli.zig:8074`); readiness reports `"saturated"`
  (`src/cli.zig:9706-9707`). The dedicated proxy surface keeps a web UI reserve (`src/cli.zig:8022`); the proxy's own
  upstream deadlines default to 300 s/60 s (`src/serve/proxy.zig:30-31`).
- **Elevation**: `/api/ask` (`src/cli.zig:8655`) answers `confirm` events, so a same-origin
  script or local client that can already reach the port can also confirm writes. Three further
  routes reach the agent, the mesh, or the live bus with no authn in front of any of them:
  `POST /api/a2a/message` (`src/cli.zig:8409`) runs the incoming JSON-RPC message through the
  agent model (gated only by `modules.a2a`, on by default, `src/config.zig:1082`; otherwise 404,
  `src/cli.zig:8497`; the run itself is `handleA2AMessage`, `src/cli.zig:9768`),
  `POST /api/mesh/join` (`src/cli.zig:16517`) admits a peer into the mesh, and
  `POST /api/live` (`src/cli.zig:8414`) publishes onto the live bus. A caller that reaches the
  port is the operator on all four.

### T2 (HTTP → agent/tools)

- **Elevation**: guest → host via `ck_*`. Mitigated by descriptor policy + `tool_self_name`
  checks on privileged channels (M6). History: symlink escape refused by `safeJoinSecure`
  (ADR 0017); CAS lock file naming resolved before hashing
  (`docs/reports/bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md`).
- **Tampering**: `ck_fs_write_if` compare-and-swap + lock (ADR 0031) prevents lost updates
  across concurrent sessions.
- **Information disclosure**: guest HTTP responses expose only allowlisted headers
  (`exposed_response_headers`, `src/sandbox/host.zig:3283`, ADR 0049), so `Set-Cookie`,
  `Authorization`, and `Location` do not reach a guest unless named.
- **DoS**: guest I/O size caps (`src/sandbox/host.zig`); 200-hit cap on find/grep walks
  (`util/fs_skip.zig` consumers `ck_fs_find`/`ck_fs_grep`).

### T3 (peer/mesh)

- **Spoofing**: mesh admission by self-asserted name (`matchesSeed`, `src/peers/mesh.zig:149`);
  an allowlist is name-matching, not a credential. `open` mode admits anyone
  (`src/peers/mesh.zig:123`).
- **Tampering**: no integrity on the wire (plain TCP); chat messages are unauthenticated
  application data.
- **Amplification**: a peer fans every room message out to all peers
  (`src/peers/chatrooms.zig`); a malicious or compromised peer can flood the fleet.
- **DoS**: the JOIN handshake runs under a bounded inbound connection pool
  (`max_inbound_conns = 64`, `src/serve/mesh_net.zig:38`, enforced `:638`) with a
  frame-size cap and read timeout (`join_wait_ns`, `src/serve/mesh_net.zig:710-719`); joined members bounded by `mesh.max_members`
  (32, `src/peers/mesh.zig:11`, `src/config.zig:966`); pending joins by `max_pending_joins`
  (8, `src/config.zig:967`, clamped `src/serve/mesh_net.zig:695`).

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
  readable through `GET /api/config/raw` without redaction (`src/cli.zig:12129`); guests can
  read only named env vars via `env_allow` + `ck_getenv`; `.env` refused by `safeJoin`; no
  secrets in `env_allow` defaults. Proxy credentials ride only `/v1/*` paths.
- **Rotation**: not documented (organizational).

### T7 (HTTP → native policy and execution)

- **Information disclosure**: raw config reads return the complete selected file, without
  credential redaction (`src/cli.zig:12129`). Any inline secrets there share the control
  plane's reachability, regardless of guest environment restrictions.
- **Tampering / Elevation**: native config writes change operator policy after parsing
  (`src/cli.zig:12160`); supported backend selection reaches native process spawning
  (`src/cli.zig:17126`, `:4300`, `src/acp/driver.zig`). Host/Origin checks reduce browser
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
  (`scripts/backup-state.sh:178-183`). A read of that directory is a read of every conversation
  the harness has had, including ones since deleted from `state/`. The refusal to run when the
  backup root lands inside the checkout (`:79-88`) removes the false-backup case; it says
  nothing about who may read the external root.
- **Information disclosure (credentials)**: the snapshot also copies `config.local.toml`,
  `config.local.json`, and `.env` out of the checkout
  (`scripts/backup-state.sh:199-225`), which is where the provider API keys live
  (T6). So installing the backup units creates a second copy of the credentials,
  in a different directory, with no rotation story for either copy, and it
  survives deleting the original. Mitigated in part by M18 (owner-only snapshot
  root); unbounded in time, since snapshots are append-only.
- **Tampering**: `backup-state.sh` derives its root from wherever `state` resolves
  (`scripts/backup-state.sh:49-53`); a `state` symlink pointed at a hostile directory redirects
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
  (`src/debug/dap.zig:513-536`), so a DAP client selects among operator-chosen programs rather than
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
  `data-plugin` script tag is created once per session (`loadPluginScript`, `:420-427`).
- **Missing control**: the enabled list is the entire gate (`src/cli.zig:13063`), and
  `webui_addon` owns it. Enabling a plugin is a trust decision with the same weight as
  `plugins validate` on a tool manifest, which is not where the web UI plugin's trust is
  documented. Disabling one stops its code reaching the browser, which is the one control
  here and is operator-initiated only.

### Threats the history already demonstrates (recurring classes)
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
| M1 | Loopback bind by default; exactly one socket; `--host` opt-in widening | `default_serve_host` `src/cli.zig:7641`, resolve layers `resolveListen` `src/cli.zig:7724`, binding trust model `docs/README.md:1621-1625` | R1, R2, R6 (network reach) |
| M2 | Host allowlist (DNS-rebinding defense) on every request, incl. GET | `unexpectedHost` `src/serve/http.zig:211`, combined with the Origin predicate `:200`, enforced `src/cli.zig:8314` | R1 (rebinding) |
| M3 | Origin check on non-GET (CSRF) and on the SSE stream; HEAD rewritten once, after the check | `crossOriginRequest` `src/serve/http.zig:188`, enforced `src/cli.zig:8339` (SSE `:8453`, HEAD rewrite `:8306`) | R1 (cross-site) |
| M4 | Optional proxy token, constant-time hashed comparison; warn when unset on non-loopback | `proxy.authorize` `src/serve/proxy.zig:57-69`; wiring `src/cli.zig:8319-8327` and `src/proxy_main.zig:311-316`; warnings `src/cli.zig:7843-7846`, `src/proxy_main.zig:125-137` | R2 (partial, off by default) |
| M5 | WASM sandbox: descriptor policy (`fs_prefixes`/`env_allow`/`network_allow`/`exec_allow`), size caps | `tools/manifests/*.tool.json`, `src/sandbox/host.zig` | R3, R5, T2, T3 |
| M6 | Privileged channels gated by `tool_self_name` (import ≠ grant) | `src/sandbox/host.zig` | T2 elevation |
| M7 | `safeJoin`/`safeJoinSecure` refuse `.env` and symlinked components; `sandbox_follow_symlinks` opt-in (ADR 0017) | `src/sandbox/host.zig` | R5, T5 |
| M8 | `ck_exec` allowlist (git/zig/uv verbs; no host-absolute or `..` args; git config-injection and `--git-dir` flags denied) | `src/sandbox/host.zig` exec policy | T2 elevation |
| M9 | CAS write lock (`state/locks/<sha256-of-resolved-target>.lock`, flock, aged sweep) | ADR 0031, `ck_fs_write_if` in `src/sandbox/host.zig` | T2 tampering |
| M10 | Improve loop gates: build/test/tools/fmt/lint + inert check + worktree isolation before promotion | `src/improve/engine.zig`, `src/improve/inert_check.zig` | self-modification integrity |
| M11 | Prompt-injection posture: untrusted retrieved text fenced, model told never to execute it | `src/agent/system_prompt.zig:697` | R3 (advisory; sandbox enforces) |
| M12 | Body caps: `max_body_bytes` +64 KiB slack (`src/cli.zig:8271`); images 4 MB × 4 (`src/cli.zig:10012`); connection limit 64 (`:7974`, enforced `:8016`, proxy reserve `:8022`); saturation 503 recorded, logged, FIN-then-drain (`:8074`, `:8100`); proxy upstream deadlines (`src/serve/proxy.zig:30-31`); mesh join-handshake connection cap (`src/serve/mesh_net.zig:38`, `:638`) | see left | R6, T3 DoS |
| M13 | Mesh admission (allowlist/prompt/open) + loopback default | `src/peers/mesh.zig:123`, `:132`; `src/config.zig:962` | R4 (partial, name-match, no credential) |
| M14 | Peers are outbound-only; nothing listens for peer traffic | `docs/README.md:1624` | T3 reach |
| M15 | Guest-visible HTTP response headers are an allowlist, lowercased, value-capped | `exposed_response_headers` `src/sandbox/host.zig:3283`, ADR 0049 | T2 information disclosure |
| M16 | Hooks and the REPL `!cmd` escape run under the same exec allowlist and deny tokens as `ck_exec`, not through a shell | `execUnderPolicyInput` `src/sandbox/host.zig:6970` wired in `src/hooks/runner.zig:38`; `execUnderPolicy` `src/tui/repl.zig:4301` with the allowlist unioned from tool manifests plus `agent.repl_exec_allow` (`src/tui/repl.zig:4225-4231`) | T9 elevation |
| M17 | Backup refuses to run when the snapshot root would land inside the checkout | `scripts/backup-state.sh:79-88` | T8 false-backup (not a confidentiality control) |
| M18 | Snapshot root is owner-only (`chmod 700` on `$backup_root`, `700` on the `config/` subdir) and each copied file keeps its own mode, so the credential copies are not world-readable | `scripts/backup-state.sh:95`, `:199-225` | T8 credential disclosure (partial: mode, not lifetime or rotation) |
| M19 | Only an *enabled* plugin's assets are served, so turning one off stops its code reaching the browser | `src/cli.zig:13031-13034`, gate `:13063` | T10 (partial: an on/off switch, not a trust check) |

### Highest-value gaps (ranked)

1. **No authentication** on the control plane (R1): one control (loopback bind + Host/Origin)
   carries nearly every high-impact threat. Any local process, or any LAN client after
   `--host`, is the operator. The docs say so (`docs/README.md:1621`), so the gap is
   documented rather than misclaimed; it is still the largest one.
2. **Proxy token off by default** (R2): M4 exists but is opt-in, and an unset
   `proxy_token_env` disables the check rather than the surface (`src/cli.zig:8319-8327`).
   The standalone `clanker-proxy` additionally runs no Host/Origin guard.
3. **Mesh admission is not a credential** (R4): an allowlist matches a self-asserted name.
4. **No inbound rate limiting per route**: the DoS surface is the shared 64-slot connection
   limit; `src/llm/rate_limit.zig` paces outbound provider calls only.
5. **Web UI plugins are unsigned code in the operator's origin** (T10): a drop-in
   `app.js` inherits the whole control plane in the browser, and the only control is the
   operator's own enable switch.

### Single points of failure

- The **sandbox** (M5/M7/M8) is the load-bearing control for R3/R5 and the whole guest surface;
  a sandbox escape is the one event that turns prompt injection into host compromise.
- The **enabled-plugin switch** (`src/cli.zig:13063`) is the whole of T10's mitigation, and
  it sits in the same origin as the control plane whose reach it would have to constrain.
- The **Host/Origin guard** (`src/serve/http.zig:188-211`, enforced `src/cli.zig:8314-8339`) is
  the entire CSRF/rebinding defense for an unauthenticated surface; a bypass (header parsing
  edge) removes the only per-request check.

## 6. Abuse cases (hostile-but-authenticated)

*Authenticated* here means "can reach the port", which is the only authentication there is.

- **Credential spending via proxy**: `POST /v1/chat/completions` (or `/proxy/v1/...` on the
  shared socket) with any body spends the configured provider keys; with no
  `proxy_token_env` there is no per-request gate. Enabling `--host 0.0.0.0` without a token
  makes this LAN-wide; the warning fires, nothing stops it (`src/cli.zig:7843-7846`).
- **Full agent drive and policy tampering**: `POST /api/run` (`src/cli.zig:8659`) dispatches
  agent work, but guest descriptor policy is not a boundary around the HTTP caller. The same
  caller can read and replace native configuration through `/api/config/raw`
  (`src/cli.zig:8468-8469`, handlers `:12129`, `:12160`). Config parsing validates values, not
  permission to change policy. See T7.
- **A second unauthenticated agent entry point**: `POST /api/a2a/message`
  (`src/cli.zig:8409`, `handleA2AMessage` `:9768`) is a JSON-RPC-shaped route that runs a task
  through the agent model with the same tool registry. Its only gate is `modules.a2a`, which
  defaults **on** (`src/config.zig:1082`), so unlike `modules.acp` and `modules.mcp_client`
  (off by default, `src/config.zig:1080` and `:1077`) this is a second agent-invoking route
  present in a stock install, carrying no check of its own.
- **Backend selection**: a run body naming a supported backend (`src/cli.zig:17126`)
  reaches native process spawning (`src/cli.zig:17521`), where the vendor CLI's own permission model, not
  clanker's sandbox, governs what the task may do.
- **Write confirmation bypass**: `/api/ask` (`src/cli.zig:8655`) answers `confirm` events with a
  byte-exact option check; a client that already reaches the port can answer "allow" itself;
  the confirmation protects against *accidental* writes, not a hostile caller.
- **Transcript scraping**: `GET /api/sessions` + per-session reads and `/api/logs` are
  unauthenticated reads of conversation and log content (route table `docs/README.md:1536`).
  With the backup timers installed, the same transcripts exist off-checkout under
  `<storage_root>/backups/` (`scripts/backup-state.sh:178-183`).
- **State tampering through tools**: `POST /api/goals` / `/api/board` / `/api/plugins/config`
  mutate durable state via guests; a malicious payload is validated by the guest's own logic
  (e.g. `plugin_config_logic.zig` merge + `config_editable` refusal).
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
  `acceptLoop` in `src/serve/mesh_net.zig` at `:589` and at `:607`). The rest sat
  in `src/sandbox/host.zig`, `src/tui/repl.zig`, `scripts/backup-state.sh`, and
  `docs/README.md` (the no-authentication paragraph the model cites is
  `docs/README.md:1621`, not the `GET /` paragraph at `:1617` that the previous
  pass pointed at).
- The check that actually catches this is mechanical, not by eye: extract every
  `file:line` in the document, print the cited line plus two on each side, and
  assert an expected keyword appears in that window. Reading 89 spans by hand is
  what let the drift stand twice. Re-run it on any edit that renumbers anything,
  and treat the bare `:NNNN` shorthand as the first thing to distrust: it inherits
  its file from the preceding reference in the same cell, and the count above
  shows a shorthand going stale in the same pass as the explicit references
  around it.
- Two habits made the drift cheap to fix and are worth keeping: a reference whose
  line lands inside a comment (`scripts/backup-state.sh:79-88` is the `case` that
  opens the in-checkout refusal, which is the right span) is worth re-reading
  rather than re-numbering. Prefer a symbol (`respondSaturated`) over a line
  number when adding a new reference here; where a line number is kept, the
  symbol belongs next to it.
- Two habits made the drift cheap to fix and are worth keeping: the bare `:NNNN` shorthand
  inherits its file from the preceding reference in the same cell, and that is the form that
  silently rots: the bare form is what the mechanical check has to guess a file for, and a
  guessed file makes a wrong line look verified. A reference whose line lands inside a comment
  (`scripts/backup-state.sh:79-88` is the `case` that opens the in-checkout refusal, which is
  the right span) is worth re-reading rather than re-numbering. Prefer a symbol
  (`respondSaturated`) over a line number when adding a new reference here; where a line number
  is kept, the symbol belongs next to it.
- An earlier pass found one gap the model had missed: the backup snapshot copies
  `config.local.toml`/`.env`, so the provider keys get a second off-checkout copy
  (`scripts/backup-state.sh:199-225`). Added as an asset row, a T8 disclosure threat, and
  M18 (owner-only snapshot root).
- T10 (drop-in web UI plugin code in the operator's browser origin) was added on
  2026-09-29 with M19. It was the one entry point in the tree whose trust was not named: the
  plugin system is documented as unsigned (T5) for *descriptors*, and the browser-side half
  had no row at all.
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
  `/api/metrics` (`src/cli.zig:8074`), but there is no dedicated security event log.
- No documented path from "vulnerability reported" to "fix shipped": no `SECURITY.md`, no
  disclosure contact, no security policy in `.github/`. The improve loop's gated promotion
  (M10) is the only change-shipping pipeline.
