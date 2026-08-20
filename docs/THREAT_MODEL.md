# clanker — Threat Model

Living document owned by the threat-model review pass. Every entry point, boundary, and
mitigation below carries a file reference so the next pass can re-verify it against the code.
Last reviewed: 2026-08-20 (re-verified every reference against the tree: the 08-19 pass's
`src/cli.zig` line numbers had drifted ≈80 lines and are renumbered; the proxy surface gained
reserved slots and upstream deadlines since).

Owner: unassigned. Review cadence: not set. Vulnerability disclosure process: none documented
(no `SECURITY.md`; see [Response readiness](#8-response-readiness-note-only)).

## TL;DR — risk-ranked summary

| # | Risk | Impact | Likelihood | Notes |
|---|------|--------|------------|-------|
| R1 | **Control plane has no authentication.** `clanker serve` exposes the full agent (`/api/run` runs tasks, tools exec and write, `/api/ask` answers write confirmations) to *anyone who can reach the port* — this is stated, not hidden: `docs/README.md:1350`. Mitigated only by loopback bind default, the Host/Origin guards, and a firewall. | Critical | High (any local process, any LAN client once `--host` widened) | The single biggest exposure; everything else hangs off it. |
| R2 | **Proxy credential spending.** `/proxy/v1` (OpenAI/Anthropic compat) lets a caller spend any configured provider's credentials, incl. Vertex. `proxy_token_env` is **optional** and absent by default; only a stderr warning fires when it is unset on a non-loopback bind (`src/cli.zig:6989-6990`, `src/proxy_main.zig:112-113`). | High (financial: token spend, data exfil via prompt) | High when exposed | Same socket as the control plane by default (`docs/README.md:1354`). |
| R3 | **Prompt injection through LLM responses.** Provider output is untrusted input to the agent loop; retrieved documents, memory hits, and web results are untrusted text the model is told never to execute (`src/agent/system_prompt.zig:636-644`, notice text at `:643-644`, tests at `:693`/`:722`). Containment is the sandbox, not the prompt. | High (tool misuse within sandbox policy) | Certain (inherent to an agent harness) | The sandbox is the trust boundary that makes this survivable; see M5. |
| R4 | **Mesh join without credential.** Mesh admission is allowlist-by-name, prompt, or open (`src/peers/mesh.zig:123-136`); the wire carries no authentication beyond the admission handshake and no encryption (plain TCP, `src/serve/mesh_net.zig:458-463`). Default bind is loopback `127.0.0.1:7420` (`src/config.zig:744`). | Medium (chat/fan-out spoofing, membership) | Medium (needs LAN reach or misconfig) | Off by default (`modules.mesh`). |
| R5 | **Sandbox escape via symlinks was a real class** (ADR 0017); `safeJoinSecure` now refuses symlinked components on granted paths. Anything that broadens the sandbox (kernel, docker, exec allowlist, `agent.sandbox_follow_symlinks`) re-opens it. | High | Low (fixed, recurring class) | See [history](#threats-the-history-already-demonstrates). |
| R6 | **DoS: connection limit 64** (`max_connection_threads`, `src/cli.zig:7116`; `/health/ready` "saturated", `src/cli.zig:8548-8549`), request bodies capped at `max_body_bytes` +64 KiB slack (`src/cli.zig:7246`), images capped 4 MB × 4 (`docs/README.md:1396`). The dedicated proxy listener reserves `proxy.webui_reserved_slots` so it cannot starve the web UI (`src/cli.zig:7148`); the proxy's own upstream deadlines default to 300 s/60 s (`src/config.zig:806-809`). No rate limiting per-route; authenticated-less surface means any local process can hold all 64 slots. | Medium | Medium | Loopback-only default keeps this local. |

Priority order for the next pass: R1/R2 (internet-facing + authentication boundary — covered
below), then R3 abuse cases, then R4-R6.

---

## 1. Attack surface inventory

### Network listeners (process-external)

| Entry point | Where | Default reach | AuthN/AuthZ |
|-------------|-------|---------------|-------------|
| HTTP server (web UI + every `/api/*` route, health, metrics, A2A, `/proxy/v1`) | `clanker serve`, loop in `src/cli.zig:7189-7330`; route table `docs/README.md:1270-1341` | `127.0.0.1:17921` (`--host` widens; one socket, `docs/README.md:1350-1355`) | **None**; Host allowlist + Origin check only |
| Proxy listener (dedicated) | `--proxy-port`; `/v1` at root, no `/api/*` (`docs/README.md:1354`) | `127.0.0.1:17922` standalone (`src/proxy_main.zig`) | Optional `proxy_token_env` (`src/cli.zig:7296`) |
| Mesh TCP listener | `src/serve/mesh_net.zig:458-463` | `127.0.0.1:7420` (`src/config.zig:744`) | Admission allowlist/prompt/open (`mesh.Admit`, `src/peers/mesh.zig:123-136`) |
| Outbound peer HTTP (`POST /api/chat/message`, notify) | `src/peers/chatrooms.zig` fan-out; `src/peers/command.zig` | — | Peers are *outbound* URLs, never listeners (`docs/README.md:1354`) |

### IPC / local-process surfaces

| Entry point | Where | Notes |
|-------------|-------|-------|
| MCP server (stdio JSON-RPC) | `src/mcp/server.zig` | Exposes the tool registry; trust = whoever can spawn the process (`docs/README.md:396-398`) |
| ACP v1 stdio | `src/acp/server.zig` | Same model |
| DAP (debug adapter) | `src/debug/dap.zig` | Can start/debug subprocesses (`src/agent/subprocess.zig`) |
| Lifecycle hooks | `src/hooks/runner.zig`, `src/hooks/config.zig` | Configured commands run at lifecycle points — config-trust surface |
| REPL `!cmd` shell escape | `docs/README.md:746` | Deliberate: interactive user shell |

### Scheduled / triggered

- `clanker schedule run-due` invoked by system cron (`src/schedule/`); nothing fires on its own
  (ADR 0008). An attacker who can write the schedule file or the cron line gains scheduled
  execution.
- LLM client outbound HTTPS (all providers, `src/llm/client.zig`) — the *response* side is
  untrusted input (R3).

### Inputs that cross the trust boundary as untrusted data

- HTTP request bodies (JSON), headers (`Host`, `Origin`, `Content-Type`), query strings,
  resource ids (`requestPath` strips query before id, `docs/README.md:1344`).
- `/api/run` `images` (base64, capped 4 MB × 4, `docs/README.md:1396`).
- Chatroom messages fanned in from peers (`POST /api/chat/message`, `src/peers/chatrooms.zig`).
- SSE event stream `GET /api/events` — long-lived, Origin-gated (`src/cli.zig:7482-7484`).
- Mesh wire frames (length-prefixed, `decodeFrame`/`max_frame`, `src/serve/mesh_net.zig:328-332`), JOIN name/id, seeds.
- Provider API responses: SSE streams, tool-call deltas, JSON error bodies
  (`src/llm/client.zig`); Vertex error bodies (`docs/reports/bugs/2026-08-19-vertex-error-bodies-discarded.md`).
- `state/models-dev.json` snapshot (fetched from models.dev at runtime, `src/cli.zig:3059`) —
  parsed as config-adjacent JSON.
- Saved sessions loaded from `state/sessions/*.json`, goal records from `state/goals.json`,
  board from `state/board*.json` — on-disk state is a trust boundary (see T5).

### Deployment / dependency surface

- `dependabot.yml` present (`.github/`) — dependency CVEs tracked by GitHub, not in the model
  (owned by deps-review).
- No admin/debug ports beyond the ones listed; `/health/live` and `/api/metrics` ride the same
  socket (`docs/README.md:1277-1278`).

## 2. Trust boundaries and data flow

| # | Boundary | Direction | Validation / authn point |
|---|----------|-----------|--------------------------|
| T1 | **Client → HTTP control plane** | Browser/SDK/curl → `/api/*`, `/proxy/v1` | No authn. Host header checked on *every* request (`unexpectedHost`, `src/cli.zig:15603`, enforced `src/cli.zig:7289`); `Origin` checked on non-GET as CSRF (`crossOriginRequest`, `src/cli.zig:15583`, enforced `src/cli.zig:7316`) and on the SSE stream (`src/cli.zig:7483`); body capped (`src/cli.zig:7246`). Loopback bind is the real control |
| T2 | **HTTP control plane → agent/tools** | `/api/run` task text → agent loop → sandboxed tools | Descriptor policy: `fs_prefixes`, `env_allow`, `network_allow`, `exec_allow` (`src/sandbox/host.zig:245-326`); privileged `ck_*` channels check `tool_self_name` (`src/sandbox/host.zig`, 32 sites) |
| T3 | **Peer/mesh → local state** | `POST /api/chat/message`, mesh CHAT frames → `state/chatrooms.jsonl`, `state/notifications.jsonl` | Chat fan-out via sandboxed `peers` tool (`chat_fanout`, `network_from_config`); mesh admission handshake (`mesh_net.zig:384-405`); no wire crypto |
| T4 | **Provider API → agent loop** | LLM response stream → conversation → next model request | Prompts treat provider output and retrieved text as untrusted (R3); sandbox is the enforcement point. History sent to model is append-only; request-only copies for compaction (`docs/README.md` agent section) |
| T5 | **Disk state → process** | `state/sessions/*.json`, `state/goals.json`, `state/models-dev.json`, `state/board*.json`, `state/plugins.json` + `plugin_config.json` | Parsed with explicit bounds (1 MiB arena reads via `ck_fs_read_range`, `docs/README.md`); `.env` refused by `safeJoin`; symlinked components refused by `safeJoinSecure` (ADR 0017) |
| T6 | **Secrets → code** | Provider keys via `api_key_env` (`src/config.zig:1205-1246`), `[serve] proxy_token_env`, Vertex service-account JWT minting (`src/llm/vertex_token.zig`) | Keys live in `config.toml`/`config.local.toml`/env; guest access gated by `env_allow` + named `ck_getenv` (`docs/README.md` sandbox section); proxy forwards creds only on `/v1/*` (path gate `src/serve/proxy.zig:42-47`, `:108-109`) |

Privilege transitions not explicitly documented anywhere as a list:
- guest (WASM) → host function (`ck_exec` allowlist: git/zig/uv verbs, no host-absolute or `..`
  args, `docs/README.md` sandbox section) — the sandbox's only escape ladder.
- sandboxed tool → unsandboxed kernel subprocess: `ck_kernel` requires `kernel.enabled`
  (`src/config.zig:560`); `ck_docker` requires descriptor grant; both opt-in (ADR 0010).
- operator CLI → scheduled execution: `clanker schedule` writes `state/schedule.json`;
  system cron runs `run-due` as the operator.

## 3. Assets and impact

| Asset | Held where | Blast radius if compromised |
|-------|-----------|-----------------------------|
| Provider credentials (LLM keys, Vertex service account) | `config.toml`, `config.local.toml`, env (`api_key_env`); read via `src/llm/auth.zig` | Financial (token spend), impersonation of the operator's provider identity |
| Full agent control (read/write/exec on the checkout + state) | `/api/run`, `/api/ask`, `/api/steer` | Machine compromise up to sandbox policy; with kernel/docker on, host compromise |
| Conversation transcripts (sessions) | `state/sessions/*.json` (+ `state/spills/<session>/`, `state/exports/<id>.html`) | Data disclosure (conversations contain task context, possibly secrets pasted in) |
| Source code + git history | working tree, `.git` | Integrity; the improve loop can *self-modify* the repo through gated promotion (`src/improve/engine.zig`) |
| LLM spend | `state/token_stats.jsonl` (32 MiB cap, `docs/README.md:413`) | Financial; also an availability signal |
| Mesh membership + chatrooms | `state/chatrooms.jsonl`, `state/chatrooms-sub.json` | Spoofing/reputation; fan-out amplification to peers |
| Board / goals / knowledge graph | `state/goals.json`, `state/board*.json`, knowledge entries | Integrity of the workflow record |
| The machine (via `ck_exec`, `ck_docker`, kernel) | sandbox policy | Highest impact; deliberately the hardest to reach |

## 4. Threats per boundary

### T1 (client → HTTP) — STRIDE

- **Spoofing**: none — no authn. Any process on the host (or LAN once `--host` widened) is the
  operator. Accepted by design (`docs/README.md:1350`).
- **Tampering**: cross-site POST refused by Origin check (`src/cli.zig:7316`) — but only for
  browsers; curl/raw clients carry no `Origin` and pass. CSRF strength = Origin trust.
- **Information disclosure**: GET endpoints expose logs (`/api/logs`), sessions
  (`/api/sessions`), transcripts (`/api/sessions/<id>`), knowledge, stats — all unauthenticated.
- **DoS**: 64 connection slots (`src/cli.zig:7116`); body cap (`src/cli.zig:7246`); no
  per-route rate limit; `POST /api/run` holds a slot for the whole run — provider hangups are
  bounded only by `agent.request_timeout_ms` / `agent.stream_idle_timeout_ms` (the HTTP client
  itself has no read timeout, `docs/README.md` agent section). The dedicated proxy listener
  reserves `proxy.webui_reserved_slots` so it cannot starve the web UI (`src/cli.zig:7148`);
  the proxy's own upstream deadlines default to 300 s/60 s (`src/config.zig:806-809`).
- **Elevation**: `/api/ask` answers `confirm` events — a same-origin script or local client
  that can already reach the port can also confirm writes (`docs/README.md:1409-1411`).

### T2 (HTTP → agent/tools)

- **Elevation**: guest → host via `ck_*`. Mitigated by descriptor policy + `tool_self_name`
  checks on privileged channels (M6). History: symlink escape refused by `safeJoinSecure`
  (ADR 0017); `state/locks` CAS lock file naming (`docs/reports/bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md`).
- **Tampering**: `ck_fs_write_if` compare-and-swap + lock (ADR 0031) prevents lost updates
  across concurrent sessions.
- **DoS**: guest I/O size caps ("size caps on all I/O", `src/sandbox/host.zig:3`); 200-hit cap
  on find/grep walks (`docs/README.md` sandbox section).

### T3 (peer/mesh)

- **Spoofing**: mesh admission by self-asserted name (`matchesSeed`, `src/peers/mesh.zig:140`)
  — an allowlist is name-matching, not a credential. `open` mode admits anyone.
- **Tampering**: no integrity on the wire (plain TCP); chat messages are unauthenticated
  application data.
- **Amplification**: a peer fans every room message out to all peers
  (`src/peers/chatrooms.zig` fan-out) — a malicious or compromised peer can flood the fleet.

### T4 (provider → agent)

- **Tampering / Elevation (prompt injection)**: provider output and retrieved text are
  untrusted; model is instructed never to execute directives found there
  (`src/agent/system_prompt.zig:636-644`); fence markers inside retrieved text are neutralized so
  docs can't close retrieval blocks. Enforcement is the sandbox, not the prompt (R3).

### T5 (disk state)

- **Tampering**: `state/*.json` is operator-writable; a hostile file (e.g. a crafted
  `state/goals.json` or a malicious plugin manifest) is parsed as config-adjacent data.
  Plugins are declarative and **unsigned** (ADR 0007) — the improve loop and `plugins` guest
  both trust descriptor contents.
- **History**: `2026-08-15-unknown-goal-id-runs-unscoped.md` — a goal id that didn't exist
  ran without scope. `2026-08-16-guest-writes-refused-under-symlinked-state.md` — symlinked
  `state/` denied guest writes until ADR 0017's opt-in.

### T6 (secrets)

- **Disclosure**: secrets in config files on disk (plaintext keys); guests can read only named
  env vars via `env_allow` + `ck_getenv`; `.env` refused by `safeJoin`; no secrets in
  `env_allow` defaults (`docs/README.md` sandbox section).
- **Rotation**: not documented (organizational).

### Threats the history already demonstrates (recurring classes)

1. Sandbox path handling: symlinks (ADR 0017), lock-path resolution
   (`2026-08-17-cas-lock-name-hashes-an-unresolved-path.md`), `.env` refusal.
2. Unsanitized tool output breaking host parsing: `2026-08-18-exec-truncated-note-is-not-json.md`
   (tool note must be a JSON string, not raw prose).
3. Self-modification integrity: `2026-08-16-improve-worktree-merge-bound-to-promotion.md`,
   `2026-08-19-improve-self-merge-leaves-worktree-reverted.md` (promotion merges reverted by
   careless worktree reset), `2026-08-16-concurrent-sessions-commit-each-others-work.md`.
4. Unscoped execution: `2026-08-15-unknown-goal-id-runs-unscoped.md`.
5. Provider fallback confusion: `2026-08-18-fallback-tries-unconfigured-providers.md` (skipped
   providers are now gated by the same offline check as the TUI).

## 5. Mitigations mapping

| # | Control | Code reference | Covers |
|---|---------|----------------|--------|
| M1 | Loopback bind by default; exactly one socket; `--host` opt-in widening | `default_serve_host` `src/cli.zig:6803`, serve usage `src/cli.zig:2092`, `docs/README.md:1350-1355` | R1, R2, R6 (network reach) |
| M2 | Host allowlist (DNS-rebinding defense) on every request, incl. GET | `unexpectedHost` `src/cli.zig:15603`, enforced `src/cli.zig:7289`; tests `src/cli.zig:15659` | R1 (rebinding) |
| M3 | Origin check on non-GET (CSRF) and on the SSE stream | `crossOriginRequest` `src/cli.zig:15583`, enforced `src/cli.zig:7316` (SSE `7483`) | R1 (cross-site) |
| M4 | Optional proxy token | `proxy.authorize` `src/serve/proxy.zig:53`; wiring `src/cli.zig:7296`, `src/proxy_main.zig:270`; warn when unset on non-loopback `src/cli.zig:6989-6990` | R2 (partial — off by default) |
| M5 | WASM sandbox: descriptor policy (`fs_prefixes`/`env_allow`/`network_allow`/`exec_allow`), size caps | `src/sandbox/host.zig:245-326`, `:3` | R3, R5, T2, T3 |
| M6 | Privileged channels gated by `tool_self_name` (import ≠ grant) | `src/sandbox/host.zig` (32 `tool_self_name` sites), `docs/README.md` sandbox section | T2 elevation |
| M7 | `safeJoin`/`safeJoinSecure` refuse `.env` and symlinked components; `sandbox_follow_symlinks` opt-in (ADR 0017) | `src/util/` sandbox path code, ADR 0017 | R5, T5 |
| M8 | `ck_exec` allowlist (git/zig/uv verbs; no host-absolute or `..` args) | sandbox exec policy, `docs/README.md` | T2 elevation |
| M9 | CAS write lock (`state/locks/<sha256-of-resolved-target>.lock`, flock, aged sweep) | ADR 0031, `ck_fs_write_if` | T2 tampering |
| M10 | Improve loop gates: build/test/tools/fmt/lint + inert check + worktree isolation before promotion | `src/improve/engine.zig`, `src/improve/inert_check.zig` | self-modification integrity |
| M11 | Prompt-injection posture: untrusted retrieved text fenced, model told never to execute it | `src/agent/system_prompt.zig:636-644` | R3 (advisory; sandbox enforces) |
| M12 | Body caps: `max_body_bytes` +64 KiB slack; images 4 MB × 4; connection limit 64; proxy reserved slots + upstream deadlines | `src/cli.zig:7246`, `docs/README.md:1396`, `src/cli.zig:7116`/`7148`, `src/config.zig:806-809` | R6 |
| M13 | Mesh admission (allowlist/prompt/open) + loopback default | `src/peers/mesh.zig:123-136`, `src/config.zig:744` | R4 (partial — name-match, no credential) |
| M14 | Peers are outbound-only; nothing listens for peer traffic | `docs/README.md:1354` | T3 reach |

### Highest-value gaps (ranked)

1. **No authentication** on the control plane (R1) — one control (loopback bind + Host/Origin)
   carries nearly every high-impact threat. Any local process, or any LAN client after
   `--host`, is root.
2. **Proxy token off by default** (R2) — M4 exists but is opt-in; the warning at
   `src/cli.zig:6989-6990` is the only guard when unset.
3. **Mesh admission is not a credential** (R4) — allowlist matches a self-asserted name.
4. **No rate limiting per route** — DoS surface is the shared 64-slot connection limit.

### Single points of failure

- The **sandbox** (M5/M7/M8) is the load-bearing control for R3/R5 and the whole guest surface;
  a sandbox escape is the one event that turns prompt injection into host compromise.
- The **Host/Origin guard** (`src/cli.zig:7289-7317`) is the entire CSRF/rebinding defense
  for an unauthenticated surface; a bypass (header parsing edge) removes the only per-request
  check.

## 6. Abuse cases (hostile-but-authenticated)

*Authenticated* here means "can reach the port" — which is the only authentication there is.

- **Credential spending via proxy**: `POST /proxy/v1/chat/completions` with any body spends the
  configured provider keys; with no `proxy_token_env` there is no per-request gate
  (`src/serve/proxy.zig:53`, `src/cli.zig:7296`). Enabling `--host 0.0.0.0` without a token
  makes this LAN-wide (the warning at `src/cli.zig:6989-6990` fires, nothing stops it).
- **Full agent drive**: `POST /api/run` with an arbitrary task; the model then calls sandboxed
  tools under descriptor policy (read/write/exec). Scope is bounded by the sandbox, not by the
  caller.
- **Write confirmation bypass**: `/api/ask` answers `confirm` events with a byte-exact option
  check (`docs/README.md:1409-1411`); a client that already reaches the port can answer "allow"
  itself — the confirmation protects against *accidental* writes, not a hostile caller.
- **Transcript scraping**: `GET /api/sessions` + `/api/sessions/<id>` and `/api/logs` are
  unauthenticated reads of conversation and log content (route table `docs/README.md:1288-1291`,
  `:1340`).
- **State tampering through tools**: `POST /api/goals` / `/api/board` / `/api/plugins/config`
  mutate durable state via guests; a malicious payload is validated by the guest's own logic
  (e.g. `plugin_config_logic.zig` merge + `config_editable` refusal).
- **Mesh flooding**: a peer in `open`-admission mode can JOIN and then receive every fanned
  chat message; with many peers, fan-out multiplies traffic (`src/peers/chatrooms.zig`).

Trust placed in client-side enforcement: the web UI's `localStorage` session id and the
Origin header are the only "identity" — neither is a secret.

## 7. Threat-model document quality

- Starter created 2026-08-19; no prior model existed. Re-verified 2026-08-20: every reference
  checked against the tree, `src/cli.zig` renumbered (≈80-line drift), proxy reserved slots and
  upstream deadlines recorded; no boundary or entry point added or removed this pass. Sections
  2-4 are partial: internet-facing (T1, T2) and authentication (T1) boundaries are complete;
  the mesh/peer, disk-state, and secrets boundaries are summarized and need a dedicated pass.
- `SECURITY.md` does not exist; no disclosure contact, supported-version statement, or security
  claims to check. `.github/dependabot.yml` is the only security automation.
- No risk-ranking or review cadence existed before this file; owner and cadence are
  organizational and not set.

## 8. Response readiness (note only)

- Audit trail: `state/sessions/*.json` (transcripts), `state/token_stats.jsonl`, `state/logs/`
  (via `GET /api/logs`), mesh/chat logs, `state/history/` snapshots. Structure is owned by
  o11y-review; noted here that security events (a failed proxy auth, a refused host, a refused
  sandbox path) surface in logs but there is no dedicated security event log.
- No documented path from "vulnerability reported" to "fix shipped": no `SECURITY.md`, no
  disclosure contact, no security policy in `.github/`. The improve loop's gated promotion is
  the only change-shipping pipeline (M10).
