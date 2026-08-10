# clanker — Reference Documentation

## Architecture

- **src/agent/loop.zig** – the agent loop: think (LLM chat) → act (execute WASM tool calls) → observe (feed results back), with stateful sessions and token statistics.
- **src/llm/** – OpenAI-compatible and Anthropic providers, including `deepseek`, `kimi-k3` (at `api.moonshot.ai/v1` with reasoning), and `muse-spark`.
- **src/sandbox/** – zwasm runtime with `ck_*` host functions and a sandbox policy.
- **src/improve/** – gated self-improvement engine that proposes patches, stages them, and promotes on green gates.
- **src/evals/** + **src/gate/checks.zig** – deterministic gates (`zig build`, `zig build test`, `zig build tools`, `zig fmt`, lint).
- **src/mcp/server.zig** – stdio JSON-RPC Model Context Protocol server.
- **src/peers/notify.zig** + `phonebook` command – peer notifications and agent-card discovery.
- **src/patch/apply.zig** – exact-match patch application.

## WASM Tool ABI

Guest tools export `scratch`, `host_arena`, and `run`; they import `env.ck_*` host functions:

- `ck_log` – write a log line
- `ck_now` – current timestamp
- `ck_random` – random bytes
- `ck_http` – outbound HTTP request
- `ck_fs_read` / `ck_fs_write` – sandboxed file access
- `ck_getenv` – read an environment variable
- `ck_exec` – run a subprocess
- `ck_docker` – invoke Docker
- `ck_result` – read back the host-written result from the host arena

Host functions write results into the host arena; the guest reads them back via `ck_result`. Tools compile to `wasm32-freestanding` (not `wasip1`).

## Tool Layout

- `tool-src/zig/` – Zig tool sources
- `tool-src/ts/` – AssemblyScript sources
- `tools.d/*.tool.json` – tool descriptors, with optional `internal: true` flag
- `zig-out/tools/` – built WASM modules
- `tool-bin/` – committed AssemblyScript artifacts

## CLI Commands

| Command | Description |
|---------|-------------|
| `init` | Create `config.local.json` + `state/` |
| `providers check [name]` | Verify provider connectivity |
| `run"<task>"` | Run the agent on a task |
| `repl` | Interactive REPL with `:help`/`:quit` and stateful sessions |
| `sessions` | List persisted sessions |
| `tools list` | List registered tools |
| `eval [name]` | Run evaluation(s) |
| `improve-self` | Run the gated self-improvement loop |
| `revert <id>` | Revert a previous promotion |
| `git` | Git passthrough |
| `mcp` | Start the MCP server |
| `goal <intent>` | Design and persist a structured goal |
| `notify <peer> "<message>"` | Send a peer notification |
| `phonebook` | List peer agent cards |
| `serve` | Start the HTTP server |

## Configuration

`config.json` (and optional `config.local.json` override) supports:

- `providers` – provider definitions (e.g., `deepseek`, `kimi-k3`, `muse-spark`) with `kind`, `base_url`, `api_key_env`, `model`, `max_tokens`
- `agent` – `max_iterations`, `compact_threshold_bytes`, `max_total_tokens`, `tools_dir`
- `peers` – list of peer `{name, url}`
- `instance` – `name` and `id` for this instance
- `notify` – `topic` for notifications
- `improve` – `min_delta`, `max_context_bytes`

## HTTP Serve Endpoints

- `GET /` – web UI via the internal `webui` WASM tool
- `GET /.well-known/agent.json` – A2A agent card
- `GET /api/status` – instance + peers status
- `POST /api/notify` – receive peer notifications
- `POST /api/a2a/message` – A2A message handling
- `POST /api/run` – run an agent task synchronously

## Streaming

`client.chatStream` parses Server-Sent Events (SSE) with tool-call accumulation. The agent exposes an `on_token` hook; the REPL attaches to it for live token output during a run.

## Self-Improvement Loop

1. Model proposes a JSON patch (summary, rationale, exact-match changes).
2. Changes are applied to a staging copy of the project.
3. Gates run in staging: `zig build`, `zig build test`, `zig build tools`, `zig fmt`, lint.
4. On success, the changes are promoted to the live tree, a git commit is created (`clanker: <summary> [imp-<id>]`), and peers are notified.
5. On failure, the error tail is fed back for a retry.


clanker is a self-improving AI agent harness written in Zig 0.16. It wraps LLM APIs and executes tools as WebAssembly modules via the zwasm sandbox. The agent can modify its own source code through a gated improvement loop, then commit the changes with git.

## Architecture

- `src/agent/loop.zig` — the main agent loop: builds the message stream, calls the model, executes tool calls, and repeats until the task is done.
- `src/llm/providers.zig` — provider abstraction for OpenAI-compatible and Anthropic chat APIs. Each provider is configured in JSON and references an API key from the environment.
- `src/sandbox/` — zwasm WebAssembly runtime. Tools are compiled to `wasm32-freestanding` (see `build.zig`) and run inside a sandbox that exposes `ck_*` host functions.
- `src/improve/engine.zig` — the self-improvement engine. It assembles relevant source files as context, asks a model for an exact-match patch proposal, applies it to a staging copy, runs gates (`zig build`, `zig build test`, `zig build tools`, plus format/lint checks), and promotes on success.
- `src/evals/` and `src/gate/` — evaluation harness and gate checks (build, test, tools, format, lint) used both for self-assessment and pre-promotion verification.
- `src/mcp/server.zig` — a Model Context Protocol server that exposes clanker’s tools over MCP.
- `src/peers/notify.zig` — peer discovery and notification. Each instance can serve an agent card at `/.well-known/agent.json` and accept notifications at `/api/notify`. `src/cli.zig` implements a `phonebook` command that scans peers.
- `src/patch/apply.zig` — applies patch proposals (exact-match replaces) to files on disk.

## Tool ABI

Tools are WebAssembly modules compiled with zwasm-compatible exports:

- `scratch` — the sandbox scratch memory used for input/output buffers.
- `host_arena` — a host-managed arena for larger allocations.
- `run` — the entry point; called with a pointer to a descriptor in scratch memory.

Tools import host functions prefixed with `env.ck_*` (e.g. `ck_read`, `ck_write`, `ck_log`) to interact with the host. The exact set is defined by the sandbox runtime.

## Tool layout

- `tool-src/zig/` — Zig source for compiled tools.
- `tool-src/ts/` — TypeScript source (compiled via a JS toolchain) for tools.
- `tools.d/*.tool.json` — descriptor files that declare each tool’s name, input schema, and compiled artifact.
- `zig-out/tools/` — Zig build output for local tools.
- `tool-bin/` — built `.wasm` artifacts (also copied into staging for the tools gate).

## Build and test

- `zig build` — build the clanker executable.
- `zig build tools` — compile all tools (Zig and TypeScript) into WebAssembly.
- `zig build test` — run unit tests.

All three are required for the self-improvement gates.

## CLI commands

- `clanker init` — create `config.local.json` and `state/`.
- `clanker providers check [name]` — verify provider connectivity.
- `clanker run "<task>"` — run the agent on a task.
- `clanker run --goal <id> "<task>"` — run with an active goal.
- `clanker sessions` — list saved sessions.
- `clanker tools list` — list registered tools.
- `clanker eval <name>` — run a specific evaluation.
- `clanker improve-self "<instruction>"` — run the self-improvement loop.
- `clanker revert <improvement-id>` — revert a promoted improvement.
- `clanker git <args>...` — passthrough to git.
- `clanker mcp` — serve the MCP protocol.
- `clanker goal "<intent>"` — ask the agent to design and persist a structured goal.
- `clanker notify <peer> "<message>"` — send a notification to a peer.
- `clanker phonebook` — list peer agent cards.
- `clanker serve --port <port>` — serve the agent card, notify, and A2A endpoints.

Use `--verbose` or `-v` for debug logging and `--dry-run` with `improve-self` to preview changes without applying them.

## Configuration

Configuration is read from `config.json` (committed example) and merged with `config.local.json` (gitignored, user-specific). Providers are defined under `providers`, each referencing an API key via an environment variable. Example providers include `deepseek`, `kimi-k3`, and `muse-spark`. Other sections:

- `agent` — iteration limits, tool/skills directories, sandbox root, git commit toggle.
- `improve` — iteration count, context size, and other self-improvement limits.
- `peers` — list of peer clanker instances (name + URL) for notifications and phonebook.
- `instance` — identity of this instance (name, id).
- `notify` — notification settings (enable/disable, topic).

## Self-improvement loop

The `improve-self` command runs the following loop (with retries):

1. **Proposal** — gather relevant source files as context and ask the model for a patch proposal (JSON with `summary`, `rationale`, and `changes`).
2. **Staging** — copy the modifiable tree into `state/staging/<id>` and apply the proposal.
3. **Gates** — run `zig build`, `zig build test`, `zig build tools`, plus format and lint checks on the staged copy.
4. **Promote** — if all gates pass, copy the changed files into the live tree.
5. **Commit** — optionally commit with git using the proposal summary.

The engine also snapshots the original files in `state/history/` and records the outcome so a failed improvement can be retried with error feedback.# clanker documentation

## Architecture

clanker is a self-improving AI agent harness written in Zig 0.16. It runs tools as sandboxed WebAssembly modules via zwasm and improves its own source through a gated loop.

### Agent loop (`src/agent/loop.zig`)

The agent loop is a think-act-observe cycle:
1. *Think*: call the LLM with the conversation and available tool definitions.
2. *Act*: if the response contains tool calls, execute them in the sandbox.
3. *Observe*: feed the tool results back into the conversation.

Sessions are stateful: messages persist across turns and can be saved/restored via `state/sessions/*.json`. Token usage is tracked cumulatively per run. The `Agent.on_token` hook streams content deltas as they arrive.

### LLM providers (`src/llm/`)

- **OpenAI-compatible** (`src/llm/client.zig`): works with any OpenAI-compatible endpoint.
- **Anthropic** (`src/llm/providers.zig`): supports Anthropic's native API.
- **deepseek**: OpenAI-compatible provider at `https://api.deepseek.com` with model `deepseek-chat`.
- **kimi-k3**: OpenAI-compatible provider at `api.moonshot.ai/v1`, supports reasoning.
- **muse-spark**: Anthropic-compatible provider for Muse Spark models.

Providers are configured in `config.json` / `config.local.json` (see below).

### Sandbox (`src/sandbox/`)

Tools run in a WebAssembly sandbox using the zwasm runtime. The guest exports `scratch`, `host_arena`, and `run`. Host functions (`env.ck_*`) provide:

| Function | Purpose |
|----------|---------|
| `ck_log` | Log a message |
| `ck_now` | Get current timestamp |
| `ck_random` | Generate random bytes |
| `ck_http` | Make an HTTP request |
| `ck_fs_read` | Read a file from the sandbox root |
| `ck_fs_write` | Write a file into the sandbox root |
| `ck_getenv` | Read an environment variable |
| `ck_exec` | Execute a command in the sandbox |
| `ck_docker` | Run a Docker container (if allowed) |
| `ck_result` | Write the tool result into the host arena |

Host functions write results into the host arena, and the guest reads them back via `ck_result`. Tool definitions in `tools.d/*.tool.json` control network and filesystem access.

The tool target is `wasm32-freestanding` (not `wasip1`).

### Self-improvement engine (`src/improve/`)

`clanker improve-self "<instruction>"` runs a gated loop:

1. Collect relevant source files as context.
2. Ask the model for a patch proposal (JSON with `summary`, `rationale`, `changes`).
3. Validate and apply the proposal to a staging copy of the project.
4. Run gates: `zig build`, `zig build test`, `zig build tools`, `zig fmt`, and lint.
5. On green, promote the changes to the live tree and commit as `clanker: <summary> [imp-<id>]`.

The history is stored in `state/history/` and can be reverted with `clanker revert <id>`.

### Evals and gates (`src/evals/`, `src/gate/checks.zig`)

Deterministic evals live in `src/evals/` (harness) with task definitions in `eval-tasks/*.task.json`, and run with `clanker eval`. The gates are used both for self-improvement and CI. They include:
- `selfhost_build`: `zig build`
- `selfhost_tests`: `zig build test`
- `selfhost_tools`: `zig build tools`
- plus `zig fmt` and a lint check.

### MCP server (`src/mcp/server.zig`)

`clanker mcp` starts a Model Context Protocol server over stdio (JSON-RPC). It exposes the tool registry to MCP clients.

### Peers (`src/peers/notify.zig`)

`clanker notify <peer> "<message>"` sends a notification to a peer. `clanker phonebook` lists peer agent cards by fetching `/.well-known/agent.json` from each configured peer URL.

### Patch application (`src/patch/apply.zig`)

Proposals are applied via exact-match `old` → `new` replacements. The first occurrence of each `old` is replaced.

## WASM tool ABI

Each tool is a WebAssembly module compiled to `wasm32-freestanding` with these exports:
- `scratch`: a mutable memory region for scratch data.
- `host_arena`: a larger memory region for results.
- `run`: the entry point that takes input and writes output.

The guest imports `env.ck_*` functions listed above. The host writes the tool result into the host arena, and the guest reads it back via `ck_result`.

## Tool layout

- `tool-src/zig/` — Zig tool sources.
- `tool-src/ts/` — AssemblyScript tool sources.
- `tools.d/*.tool.json` — tool descriptors, with optional `"internal": true` flag for internal tools (like `webui`).
- `zig-out/tools/` — built WASM binaries from `zig build tools`.
- `tool-bin/` — committed AssemblyScript artifacts (compiled JS/WASM).

Tools are discovered by the registry (`src/tools/registry.zig`) from the configured `tools_dir` (default `tools.d`).

## CLI commands

| Command | Description |
|---------|-------------|
| `init` | Create `config.local.json` and `state/` |
| `providers check [name]` | Verify provider connectivity |
| `run "<task>"` | Run the agent on a task |
| `repl` | Start an interactive REPL with streaming |
| `sessions` | List saved sessions |
| `tools list` | List registered tools |
| `eval [name]` | Run evals |
| `improve-self "<instructions>"` | Run the self-improvement loop |
| `revert <id>` | Revert a promoted improvement |
| `git` | Git passthrough (everything after `git` is passed through) |
| `mcp` | Start the MCP server |
| `goal` | Design and persist a structured goal |
| `notify <peer> "<message>"` | Send a notification to a peer |
| `phonebook` | List peer agent cards |
| `serve` | Start the HTTP server |

## Configuration

`config.json` is the global config; `config.local.json` overrides it. Example:

```json
{
  "default_provider": "deepseek",
  "providers": {
    "deepseek": { "kind": "openai_compat", "base_url": "https://api.deepseek.com", "api_key_env": "DEEPSEEK_API_KEY", "model": "deepseek-chat", "max_tokens": 2048 },
    "kimi-k3": { "kind": "openai_compat", "base_url": "https://api.moonshot.ai/v1", "api_key_env": "MOONSHOT_API_KEY", "model": "kimi-k3" },
    "muse-spark": { "kind": "anthropic", "base_url": "https://api.musespark.ai/v1", "api_key_env": "MUSE_SPARK_API_KEY", "model": "spark-v3" }
  },
  "agent": {
    "max_iterations": 12,
    "compact_threshold_bytes": 30000,
    "max_total_tokens": 100000,
    "tools_dir": "tools.d",
    "sandbox_root": "state/sandbox"
  },
  "peers": [
    { "name": "peer1", "url": "http://127.0.0.1:17922" }
  ],
  "instance": { "name": "clanker-1", "id": "abc" },
  "notify": { "topic": "updates" },
  "improve": { "min_delta": 0.05 }
}
```

Fields:
- `providers`: map of provider name → config.
  - `kind`: `"openai_compat"` or `"anthropic"`.
  - `base_url`, `api_key_env`, `model`, `max_tokens`.
  - `kimi-k3` supports reasoning (returns `reasoning` field).
- `agent`:
  - `max_iterations`: max agent loop iterations.
  - `compact_threshold_bytes`: if conversation exceeds this, compact history.
  - `max_total_tokens`: total token budget across the run.
  - `tools_dir`: directory containing `.tool.json` descriptors.
  - `sandbox_root`: base directory for file operations in tools.
- `peers`: list of peer agents with `name` and `url`.
- `instance`: identity of this agent.
- `notify`: default topic for notifications.
- `improve`: settings for self-improvement (`min_delta` etc.).

## HTTP server

`clanker serve` starts a local HTTP server on port 17921 (override with `--port`). Endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Web UI (rendered by the internal `webui` WASM tool) |
| `/.well-known/agent.json` | GET | Agent card for A2A discovery |
| `/api/status` | GET | Instance + peers status (JSON) |
| `/api/notify` | POST | Receive a notification (JSON) |
| `/api/a2a/message` | POST | A2A message handler |
| `/api/run` | POST | Run an agent task and return the response |

`GET /` loads the `webui` tool from the registry and renders its output as HTML.

## Streaming

The LLM client supports SSE streaming (`client.chatStream`). The agent parses the stream, accumulates tool-call deltas, and invokes `Agent.on_token` for each content token. The REPL uses this to display tokens live.

## Self-improvement loop

1. **Proposal**: model returns JSON `{summary, rationale, changes[]}`.
2. **Staging**: copy project to `state/staging/<id>` and apply changes.
3. **Gates**: run `zig build`, `zig build test`, `zig build tools`, `zig fmt`, lint.
4. **Promote**: if all pass, copy staged files into the live tree.
5. **Commit**: `git commit -m "clanker: <summary> [imp-<id>]"`.
6. **History**: store snapshot in `state/history/` for revert.

Gate failures give feedback to retry.
