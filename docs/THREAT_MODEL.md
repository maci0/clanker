# clanker Threat Model

Last reviewed: 2026-09-27. Every line reference below was re-read against the tree on that
date; evidence is static code inspection, not attack testing. Owner, review cadence, and
disclosure process remain unset (organizational, not invented here).

Owner: unassigned. Review cadence: not set. Vulnerability disclosure process: none documented
(no `SECURITY.md`; see [Response readiness](#8-response-readiness-note-only)).

## TL;DR: risk-ranked summary

| # | Risk | Impact | Likelihood | Notes |
|---|------|--------|------------|-------|
| R1 | **Unauthenticated control includes native configuration and backend execution, not just sandboxed tools.** The HTTP handler has Host/Origin checks but no caller authentication (`src/cli.zig:8143`, `src/cli.zig:8170`). Raw config reads disclose file contents (`src/cli.zig:11548`); validated writes change the operator's policy (`src/cli.zig:11576`). `/api/run` can select a native backend (`src/cli.zig:16402-16407`, dispatched `src/cli.zig:16800`, `src/cli.zig:16903`). | Critical: configuration, credentials stored there, and operator-level execution | High for a reachable local client; remote exposure depends on bind/network policy | Loopback/Host/Origin are not user identity. WASM grants do not contain the native paths; see T7. The docs state the absence plainly (`docs/README.md:1571`, `README.md:197`). |
| R2 | **Proxy credential spending.** Proxy authentication is optional; a `proxy_token_env` naming an unset variable skips authentication entirely (`src/cli.zig:8149-8161`, standalone `src/proxy_main.zig:311-321`). The standalone proxy runs no Host/Origin guard: `src/proxy_main.zig` contains no `unexpectedHost` or `crossOriginRequest` call. | High: provider spend and submitted prompt data | High when reachable without a token | A proxy token protects only proxy paths, never `/api/*`. Startup warnings are not access controls (`src/cli.zig:7705-7712`, `src/proxy_main.zig:127-134`). |
| R3 | **Prompt injection through LLM responses.** Provider output is untrusted input to the agent loop; retrieved documents, memory hits, and tool results are untrusted text the model is told never to execute (`src/agent/system_prompt.zig:669`). Containment is the sandbox, not the prompt. | High (tool misuse within sandbox policy) | Certain (inherent to an agent harness) | The sandbox is the trust boundary that makes this survivable; see M5. |
| R4 | **Mesh join without credential.** Mesh admission is allowlist-by-name, prompt, or open (`Admission`, `src/peers/mesh.zig:114`; `admit` `src/peers/mesh.zig:123`); the wire carries no authentication beyond the admission handshake and no encryption (plain TCP). Default bind is loopback `127.0.0.1:7420` (`src/config.zig:948`). | Medium (chat/fan-out spoofing, membership) | Medium (needs LAN reach or misconfig) | Off by default (`modules.mesh`). |
| R5 | **Sandbox escape via symlinks was a real class** (ADR 0017); `safeJoinSecure` now refuses symlinked components on granted paths (`src/sandbox/host.zig`, path policy). Anything that broadens the sandbox (kernel, docker, exec allowlist, `agent.sandbox_follow_symlinks`) re-opens it. | High | Low (fixed, recurring class) | See [history](#threats-the-history-already-demonstrates-recurring-classes). |
| R6 | **DoS: connection limit 64** (`max_connection_threads`, `src/cli.zig:7835`, enforced `:7866`; proxy surface keeps a web UI reserve `:7872`; `/health/ready` reports `saturated`, `src/cli.zig:9373-9376`), request bodies capped at `max_body_bytes` +64 KiB slack (`src/cli.zig:8100`), images capped 4 MB × 4 (`src/cli.zig:9602-9603`, count `:16201`). Saturation refusals reset their own per-request state, book under `errors_total`, and log with a fresh request id (`respondSaturated`, `src/cli.zig:7924-7933`), then FIN-then-drain so the 503 survives the close (`drainThenClose`, `src/cli.zig:7950`). The proxy's upstream deadlines default to 300 s first byte / 60 s idle (`src/serve/proxy.zig:30`, wiring `:388-389`, knobs `src/config.zig:1010-1013`). The mesh join handshake holds its own bounded thread pool (`max_inbound_conns`, `src/serve/mesh_net.zig:38`, enforced `:459-468`). Still no inbound per-route rate limit (`src/llm/rate_limit.zig` limits *outbound* provider requests, not callers), so any local process can hold all 64 slots. | Medium | Medium | Loopback-only default keeps this local. |

Priority order for the next pass: R1/R2 (internet-facing + authentication boundary, covered
below), then R3 abuse cases, then R4-R6.

---

## 1. Attack surface inventory

### Network listeners (process-external)

| Entry point | Where | Default reach | AuthN/AuthZ |
|-------------|-------|---------------|-------------|
| HTTP server (web UI + every `/api/*` route, health, metrics, A2A, `/proxy/v1`) | `clanker serve`: `resolveListen` `src/cli.zig:7590` (default `default_serve_host` `src/cli.zig:7517`), per-connection `serveConnection` `src/cli.zig:7861`; route dispatch from `src/cli.zig:8213`; route table `docs/README.md:1474`, `:1489` | `127.0.0.1:17921` (`--host` widens; one socket, `docs/README.md:1574`) | **None**; Host allowlist + Origin check only |
| Proxy listener (dedicated) | `--proxy-port`; serves `/v1/*` and no `/api/*` (`docs/README.md:1574`); standalone binary `src/proxy_main.zig` (default `127.0.0.1:17922`) | loopback | Optional `proxy_token_env` (`src/config.zig:1002`), compared in constant time over SHA-256 digests (`proxy.authorize`, `src/serve/proxy.zig:54-69`) |
| Mesh TCP listener | `src/serve/mesh_net.zig` (`acceptLoop` `:453`; inbound cap `:38`, `:459-468`) | `127.0.0.1:7420` (`src/config.zig:948`) | Admission allowlist/prompt/open (`src/peers/mesh.zig:114`, `:123`); JOIN handshake bounded by frame cap + read timeout |
| Outbound peer HTTP (`POST /api/chat/message`, notify) | `src/peers/chatrooms.zig` fan-out; `src/peers/command.zig` | none | Peers are *outbound* URLs, never listeners (`docs/README.md:1574`) |

### IPC / local-process surfaces

| Entry point | Where | Notes |
|-------------|-------|-------|
| MCP server (stdio JSON-RPC) | `src/mcp/server.zig` | Exposes the tool registry; trust = whoever can spawn the process (`docs/README.md:433`) |
| ACP v1 stdio | `src/acp/server.zig` | Same model |
| DAP (debug adapter) | `src/debug/dap.zig` | Can start/debug subprocesses (`src/agent/subprocess.zig`) |
| Lifecycle hooks | `src/hooks/runner.zig`, `src/hooks/config.zig` | Configured commands run at lifecycle points: config-trust surface |
| REPL `!cmd` shell escape | `docs/README.md:827` | Deliberate: interactive user shell; `repl_exec_allow` widens only what tool policy already allowed (`docs/README.md:1393`) |

### Scheduled / triggered

- `clanker schedule run-due` invoked by system cron (`src/schedule/`); nothing fires on its own
  (ADR 0008). An attacker who can write the schedule file or the cron line gains scheduled
  execution.
- **Opt-in state-backup timers**: user-level systemd units installed by
  `scripts/install-state-backup.sh` — `clanker-state-backup.timer` runs
  `scripts/backup-state.sh` at :00/:30 (`scripts/systemd/clanker-state-backup.timer`) and
  `clanker-state-verify.timer` restore-verifies weekly (`scripts/systemd/clanker-state-verify.timer`).
  The backup copies the *entire* `state/` tree (session DBs = transcripts, logs, token stats,
  goals, plugins) to `backups/` beside wherever `state` resolves (`scripts/backup-state.sh:8-11`)
  and refuses to run when that root would land inside the repo (`scripts/backup-state.sh:17-31`).
  Threat shape: same trust level as cron (runs as the operator's user), but it widens where
  transcripts live — see T5/T6 and the assets table.
- LLM client outbound HTTPS (all providers, `src/llm/client.zig`), outbound-paced by
  `src/llm/rate_limit.zig`; the *response* side is untrusted input (R3).

### Inputs that cross the trust boundary as untrusted data

- HTTP request bodies (JSON), headers (`Host`, `Origin`, `Content-Type`), query strings,
  resource ids (`requestPath` strips query first, `src/serve/http.zig:24`).
- `/api/run` `images` (base64, 4 MB each, at most 4, requires `modules.multimodal`;
  `src/cli.zig:9602-9603`, `:16201`; `docs/README.md:1623`).
- Chatroom messages fanned in from peers (`POST /api/chat/message`, `src/peers/chatrooms.zig`).
- SSE event stream `GET /api/events`, long-lived, Origin-gated (`src/cli.zig:8362`).
- Mesh wire frames (length-prefixed, `decodeFrame` against `max_frame`,
  `src/serve/mesh_net.zig:342-346`), JOIN name/id, seeds.
- Provider API responses: SSE streams, tool-call deltas, JSON error bodies
  (`src/llm/client.zig`); Vertex error bodies
  (`docs/reports/bugs/2026-08-19-vertex-error-bodies-discarded.md`).
- `state/models-dev.json` snapshot (fetched from models.dev at runtime), parsed as
  config-adjacent JSON.
- Saved sessions loaded from `state/sessions/<id>.db` (WAL-mode SQLite, one db per
  conversation, `src/agent/session.zig:33`, `src/util/sqlite.zig`), goal records from
  `state/goals.json`, board from `state/board*.json`; on-disk state is a trust boundary (see T5).

### Deployment / dependency surface

- `dependabot.yml` present (`.github/`), dependency CVEs tracked by GitHub, not in the model
  (owned by deps-review).
- No admin/debug ports beyond the ones listed; `/health/live`, `/health/ready` and
  `/api/metrics` ride the same socket (`src/cli.zig:8213`, `:8217`).

## 2. Trust boundaries and data flow

| # | Boundary | Direction | Validation / authn point |
|---|----------|-----------|--------------------------|
| T1 | **Client → HTTP control plane** | Browser/SDK/curl → `/api/*`, `/proxy/v1` | No authn. Host header checked on *every* request (`unexpectedHost`, `src/serve/http.zig:202`, enforced `src/cli.zig:8143`; combined predicate `src/serve/http.zig:191`); `Origin` checked on non-GET as CSRF (`crossOriginRequest`, `src/serve/http.zig:179`, enforced `src/cli.zig:8170`) and on the SSE stream (`src/cli.zig:8362`); body capped (`src/cli.zig:8100`). HEAD is rewritten to GET once, after the proxy dispatch and the Origin check, so POST-only routes stay unreachable via HEAD (`request_head` set `src/cli.zig:8129`, rewrite `:8211`). Loopback bind is the real control |
| T2 | **HTTP control plane → agent/tools** | `/api/run` task text (`src/cli.zig:8494`) → agent loop → sandboxed tools | Descriptor policy: `fs_prefixes`, `env_allow`, `network_allow`, `exec_allow` (`tools/manifests/*.tool.json`, honored in `src/sandbox/host.zig`); privileged `ck_*` channels check `tool_self_name` (`src/sandbox/host.zig`) |
| T3 | **Peer/mesh → local state** | `POST /api/chat/message`, mesh CHAT frames → `state/chatrooms.jsonl`, `state/notifications.jsonl` | Chat fan-out via sandboxed `peers` tool (`chat_fanout`, `network_from_config`); mesh admission handshake (`src/serve/mesh_net.zig:392-421`); no wire crypto |
| T4 | **Provider API → agent loop** | LLM response stream → conversation → next model request | Prompts treat provider output and retrieved text as untrusted (R3); sandbox is the enforcement point. History sent to model is append-only; request-only copies for compaction (`docs/README.md` agent section) |
| T5 | **Disk state → process** | `state/sessions/<id>.db`, `state/goals.json`, `state/models-dev.json`, `state/board*.json`, `state/plugins.json` + `plugin_config.json` | JSON state parsed with explicit bounds (guests read through `ck_fs_read_range`, not whole-file); sessions are read by tools through the `ck_session` channel rather than as files; `.env` refused by `safeJoin`; symlinked components refused by `safeJoinSecure` (ADR 0017) |
| T6 | **Secrets → code** | Provider keys via `api_key_env` (provider tables in `src/config.zig`), `[serve] proxy_token_env` (`src/config.zig:1002`), Vertex service-account JWT minting (`src/llm/vertex_token.zig`) | Keys live in `config.toml`/`config.local.toml`/env; guest access gated by `env_allow` + named `ck_getenv`; proxy credentials ride only `/v1/*` paths; token comparison is constant-time over SHA-256 digests (`src/serve/proxy.zig:54-69`) |
| T7 | **HTTP caller → native configuration and backends** | Raw config reads/writes (routes `src/cli.zig:8287-8288`, handlers `:11548` GET and `:11576` POST); backend selection (`src/cli.zig:16402-16407`) and native dispatch (`:16800`, `:16903`) | File-name restriction and config validation protect format, not caller authority. Backend-name validation (`acp_vendor.Name.parse`) selects supported adapters, not a WASM sandbox. No caller authentication precedes these routes (`src/cli.zig:8143-8170`). |

Privilege transitions:
- HTTP caller → policy author: native config writes validate and persist the config pair
  (`src/cli.zig:11576`), outside guest descriptor enforcement.
- HTTP caller → native backend process: `runCodingBackendCtx` (`src/cli.zig:4170`) passes
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

## 3. Assets and impact

| Asset | Held where | Blast radius if compromised |
|-------|-----------|-----------------------------|
| Provider credentials (LLM keys, Vertex service account) | `config.toml`, `config.local.toml`, env (`api_key_env`); read via `src/llm/auth.zig`; also readable through `GET /api/config/raw` (`src/cli.zig:11548`) | Financial (token spend), impersonation of the operator's provider identity |
| Native configuration and execution authority | `/api/config/raw` (`src/cli.zig:11548`, `:11576`), `/api/run` backend dispatch (`src/cli.zig:16800`) | Policy tampering and execution as the server's OS user; guest sandbox policy does not constrain these native paths (T7). No implication of OS root privileges. |
| Conversation transcripts (sessions) | `state/sessions/<id>.db` (WAL SQLite, `src/agent/session.zig:33`; + `state/spills/<session>/`, `state/exports/<id>.html`) | Data disclosure (conversations contain task context, possibly secrets pasted in). With the backup timers installed, twice-hourly snapshot copies of all of it live under `<storage_root>/backups/` (`scripts/backup-state.sh:8-11`) — anyone who can read the storage root reads every conversation, including ones since deleted from `state/` |
| Source code + git history | working tree, `.git` | Integrity; the improve loop can *self-modify* the repo through gated promotion (`src/improve/engine.zig`) |
| LLM spend | `state/token_stats.jsonl` (hard cap, `src/stats/tokens.zig:24-28`; `docs/README.md:446-449`) | Financial; also an availability signal |
| Mesh membership + chatrooms | `state/chatrooms.jsonl`, `state/chatrooms-sub.json` | Spoofing/reputation; fan-out amplification to peers |
| Board / goals / knowledge graph | `state/goals.json`, `state/board*.json`, knowledge entries | Integrity of the workflow record |
| The machine (via `ck_exec`, `ck_docker`, kernel) | sandbox policy | Highest impact; deliberately the hardest to reach |

## 4. Threats per boundary

### T1 (client → HTTP): STRIDE

- **Spoofing**: none, no authn. Any process on the host (or LAN once `--host` widened) is the
  operator. Accepted and documented by design (`docs/README.md:1571`).
- **Tampering**: cross-site POST refused by the Origin check (`src/cli.zig:8170`), but only for
  browsers; curl/raw clients carry no `Origin` and pass. CSRF strength = Origin trust. HEAD is
  rewritten to GET once after the check, so a HEAD cannot reach a POST-only route
  (`src/cli.zig:8211`).
- **Information disclosure**: GET endpoints expose logs (`/api/logs`), sessions
  (`/api/sessions`), transcripts, knowledge, stats, all unauthenticated (route table
  `docs/README.md:1489`).
- **DoS**: 64 connection slots (`src/cli.zig:7835`, enforced `:7866`); body cap
  (`:8100`); no per-route rate limit; `POST /api/run` holds a slot for the whole run; provider
  hangups are bounded only by `agent.request_timeout_ms` / `agent.stream_idle_timeout_ms` (the
  HTTP client itself has no read timeout; defaults `src/config.zig:526`). Saturation 503s reset
  their own threadlocal request state, book under `errors_total`, carry a fresh request id, and
  log (`respondSaturated`, `src/cli.zig:7924-7933`); readiness reports `"saturated"`
  (`:9373-9376`). The dedicated proxy surface keeps a web UI reserve (`:7872`); the proxy's own
  upstream deadlines default to 300 s/60 s (`src/serve/proxy.zig:30`).
- **Elevation**: `/api/ask` (`src/cli.zig:8490`) answers `confirm` events, so a same-origin
  script or local client that can already reach the port can also confirm writes.

### T2 (HTTP → agent/tools)

- **Elevation**: guest → host via `ck_*`. Mitigated by descriptor policy + `tool_self_name`
  checks on privileged channels (M6). History: symlink escape refused by `safeJoinSecure`
  (ADR 0017); CAS lock file naming resolved before hashing
  (`docs/reports/bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md`).
- **Tampering**: `ck_fs_write_if` compare-and-swap + lock (ADR 0031) prevents lost updates
  across concurrent sessions.
- **Information disclosure**: guest HTTP responses expose only allowlisted headers
  (`exposed_response_headers`, `src/sandbox/host.zig:3167`, ADR 0049), so `Set-Cookie`,
  `Authorization`, and `Location` do not reach a guest unless named.
- **DoS**: guest I/O size caps (`src/sandbox/host.zig`); 200-hit cap on find/grep walks
  (`util/fs_skip.zig` consumers `ck_fs_find`/`ck_fs_grep`).

### T3 (peer/mesh)

- **Spoofing**: mesh admission by self-asserted name (`matchesSeed`, `src/peers/mesh.zig:140`);
  an allowlist is name-matching, not a credential. `open` mode admits anyone
  (`src/peers/mesh.zig:114`).
- **Tampering**: no integrity on the wire (plain TCP); chat messages are unauthenticated
  application data.
- **Amplification**: a peer fans every room message out to all peers
  (`src/peers/chatrooms.zig`); a malicious or compromised peer can flood the fleet.
- **DoS**: the JOIN handshake runs under a bounded inbound connection pool
  (`max_inbound_conns = 64`, `src/serve/mesh_net.zig:38`, enforced `:459-468`) with a
  frame-size cap and read timeout (`:342-346`); joined members bounded by `mesh.max_members`
  (32, `src/peers/mesh.zig:9`, `src/config.zig:951`); pending joins by `max_pending_joins`
  (8, `src/config.zig:952`, clamped `src/serve/mesh_net.zig:507`).

### T4 (provider → agent)

- **Tampering / Elevation (prompt injection)**: provider output and retrieved text are
  untrusted; the model is instructed never to execute directives found there
  (`src/agent/system_prompt.zig:669`); fence markers inside retrieved text are neutralized so
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
  readable through `GET /api/config/raw` without redaction (`src/cli.zig:11548`); guests can
  read only named env vars via `env_allow` + `ck_getenv`; `.env` refused by `safeJoin`; no
  secrets in `env_allow` defaults. Proxy credentials ride only `/v1/*` paths.
- **Rotation**: not documented (organizational).

### T7 (HTTP → native policy and execution)

- **Information disclosure**: raw config reads return the complete selected file, without
  credential redaction (`src/cli.zig:11548`). Any inline secrets there share the control
  plane's reachability, regardless of guest environment restrictions.
- **Tampering / Elevation**: native config writes change operator policy after parsing
  (`src/cli.zig:11576`); supported backend selection reaches native process spawning
  (`src/cli.zig:16402-16407`, `:4170`, `src/acp/driver.zig`). Host/Origin checks reduce browser
  abuse but do not establish who may administer policy. Rank: critical impact, high likelihood
  for a reachable hostile client (R1). Missing control: caller authentication and authorization
  for administrative operations; implementation belongs to sec-review.
- **Availability**: config writes advertise restart-on-reload; repeated accepted policy
  changes can disrupt service. Config validity is not an availability quota or an authorization
  check.

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
| M1 | Loopback bind by default; exactly one socket; `--host` opt-in widening | `default_serve_host` `src/cli.zig:7517`, resolve layers `resolveListen` `src/cli.zig:7590`, binding trust model `docs/README.md:1569-1574` | R1, R2, R6 (network reach) |
| M2 | Host allowlist (DNS-rebinding defense) on every request, incl. GET | `unexpectedHost` `src/serve/http.zig:202`, combined with the Origin predicate `:191`, enforced `src/cli.zig:8143` | R1 (rebinding) |
| M3 | Origin check on non-GET (CSRF) and on the SSE stream; HEAD rewritten once, after the check | `crossOriginRequest` `src/serve/http.zig:179`, enforced `src/cli.zig:8170` (SSE `:8362`, HEAD rewrite `:8211`) | R1 (cross-site) |
| M4 | Optional proxy token, constant-time hashed comparison; warn when unset on non-loopback | `proxy.authorize` `src/serve/proxy.zig:54-69`; wiring `src/cli.zig:8149-8161` and `src/proxy_main.zig:311-321`; warnings `src/cli.zig:7705-7712`, `src/proxy_main.zig:127-134` | R2 (partial, off by default) |
| M5 | WASM sandbox: descriptor policy (`fs_prefixes`/`env_allow`/`network_allow`/`exec_allow`), size caps | `tools/manifests/*.tool.json`, `src/sandbox/host.zig` | R3, R5, T2, T3 |
| M6 | Privileged channels gated by `tool_self_name` (import ≠ grant) | `src/sandbox/host.zig` | T2 elevation |
| M7 | `safeJoin`/`safeJoinSecure` refuse `.env` and symlinked components; `sandbox_follow_symlinks` opt-in (ADR 0017) | `src/sandbox/host.zig` | R5, T5 |
| M8 | `ck_exec` allowlist (git/zig/uv verbs; no host-absolute or `..` args; git config-injection and `--git-dir` flags denied) | `src/sandbox/host.zig` exec policy | T2 elevation |
| M9 | CAS write lock (`state/locks/<sha256-of-resolved-target>.lock`, flock, aged sweep) | ADR 0031, `ck_fs_write_if` in `src/sandbox/host.zig` | T2 tampering |
| M10 | Improve loop gates: build/test/tools/fmt/lint + inert check + worktree isolation before promotion | `src/improve/engine.zig`, `src/improve/inert_check.zig` | self-modification integrity |
| M11 | Prompt-injection posture: untrusted retrieved text fenced, model told never to execute it | `src/agent/system_prompt.zig:669` | R3 (advisory; sandbox enforces) |
| M12 | Body caps: `max_body_bytes` +64 KiB slack (`src/cli.zig:8100`); images 4 MB × 4 (`src/cli.zig:9602-9603`); connection limit 64 (`:7835`, enforced `:7866`, proxy reserve `:7872`); saturation 503 recorded, logged, FIN-then-drain (`:7924-7933`, `:7951`); proxy upstream deadlines (`src/serve/proxy.zig:30`); mesh join-handshake connection cap (`src/serve/mesh_net.zig:38`, `:459-468`) | see left | R6, T3 DoS |
| M13 | Mesh admission (allowlist/prompt/open) + loopback default | `src/peers/mesh.zig:114`, `:123`; `src/config.zig:948` | R4 (partial, name-match, no credential) |
| M14 | Peers are outbound-only; nothing listens for peer traffic | `docs/README.md:1574` | T3 reach |
| M15 | Guest-visible HTTP response headers are an allowlist, lowercased, value-capped | `exposed_response_headers` `src/sandbox/host.zig:3167`, ADR 0049 | T2 information disclosure |

### Highest-value gaps (ranked)

1. **No authentication** on the control plane (R1): one control (loopback bind + Host/Origin)
   carries nearly every high-impact threat. Any local process, or any LAN client after
   `--host`, is the operator. The docs say so (`docs/README.md:1571`), so the gap is
   documented rather than misclaimed; it is still the largest one.
2. **Proxy token off by default** (R2): M4 exists but is opt-in, and an unset
   `proxy_token_env` disables the check rather than the surface (`src/cli.zig:8149-8161`).
   The standalone `clanker-proxy` additionally runs no Host/Origin guard.
3. **Mesh admission is not a credential** (R4): an allowlist matches a self-asserted name.
4. **No inbound rate limiting per route**: the DoS surface is the shared 64-slot connection
   limit; `src/llm/rate_limit.zig` paces outbound provider calls only.

### Single points of failure

- The **sandbox** (M5/M7/M8) is the load-bearing control for R3/R5 and the whole guest surface;
  a sandbox escape is the one event that turns prompt injection into host compromise.
- The **Host/Origin guard** (`src/serve/http.zig:179-213`, enforced `src/cli.zig:8143-8170`) is
  the entire CSRF/rebinding defense for an unauthenticated surface; a bypass (header parsing
  edge) removes the only per-request check.

## 6. Abuse cases (hostile-but-authenticated)

*Authenticated* here means "can reach the port", which is the only authentication there is.

- **Credential spending via proxy**: `POST /v1/chat/completions` (or `/proxy/v1/...` on the
  shared socket) with any body spends the configured provider keys; with no
  `proxy_token_env` there is no per-request gate. Enabling `--host 0.0.0.0` without a token
  makes this LAN-wide; the warning fires, nothing stops it (`src/cli.zig:7705-7712`).
- **Full agent drive and policy tampering**: `POST /api/run` (`src/cli.zig:8494`) dispatches
  agent work, but guest descriptor policy is not a boundary around the HTTP caller. The same
  caller can read and replace native configuration through `/api/config/raw`
  (`src/cli.zig:8287-8288`, handlers `:11548`, `:11576`). Config parsing validates values, not
  permission to change policy. See T7.
- **Backend selection**: a run body naming a supported backend (`src/cli.zig:16402-16407`)
  reaches native process spawning (`:16800`), where the vendor CLI's own permission model, not
  clanker's sandbox, governs what the task may do.
- **Write confirmation bypass**: `/api/ask` (`src/cli.zig:8490`) answers `confirm` events with a
  byte-exact option check; a client that already reaches the port can answer "allow" itself;
  the confirmation protects against *accidental* writes, not a hostile caller.
- **Transcript scraping**: `GET /api/sessions` + per-session reads and `/api/logs` are
  unauthenticated reads of conversation and log content (route table `docs/README.md:1489`).
  With the backup timers installed, the same transcripts exist off-checkout under
  `<storage_root>/backups/` (`scripts/backup-state.sh:8-11`).
- **State tampering through tools**: `POST /api/goals` / `/api/board` / `/api/plugins/config`
  mutate durable state via guests; a malicious payload is validated by the guest's own logic
  (e.g. `plugin_config_logic.zig` merge + `config_editable` refusal).
- **Mesh flooding**: a peer in `open`-admission mode can JOIN and then receive every fanned
  chat message; with many peers, fan-out multiplies traffic (`src/peers/chatrooms.zig`).

Trust placed in client-side enforcement: the web UI's stored session id and the `Origin` header
are the only "identity"; neither is a secret.

## 7. Threat-model document quality

- Starter created 2026-08-19; reference pass 2026-08-26; **references re-verified against the
  tree 2026-09-27** across all sections. Sections 2-4 remain partial in coverage: the
  internet-facing (T1, T2) and authentication (T1) boundaries are complete; the mesh/peer, disk
  state, and secrets boundaries are summarized and want a dedicated pass. The opt-in
  backup-timer surface (section 1, Scheduled) is inventoried but not threat-enumerated per
  STRIDE.
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
  `/api/metrics` (`src/cli.zig:7924-7933`), but there is no dedicated security event log.
- No documented path from "vulnerability reported" to "fix shipped": no `SECURITY.md`, no
  disclosure contact, no security policy in `.github/`. The improve loop's gated promotion
  (M10) is the only change-shipping pipeline.
