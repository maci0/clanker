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
- `ck_llm` – one-shot model call (requires `"llm": true` in the descriptor)
- `ck_config` – this tool's own `config` object from its descriptor
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
| `graph [run-id]` | List recorded runs, or render one as an ASCII timeline |
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
- `clanker graph [run-id]` — list recorded runs, or render one as an ASCII timeline.
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
| `ck_llm` | One-shot model call; denied unless the descriptor sets `"llm": true` |
| `ck_config` | Return this tool's `config` object from its descriptor |
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

## Tool catalog

Every entry in `tools.d/` is one WASM module plus its descriptor. `internal: true` hides the tool from the model's tool list: it is reachable only through a REPL slash command or an HTTP route, never chosen by the agent. `fs_prefixes` is the complete filesystem authority the sandbox grants that tool; a tool with no prefixes cannot read or write anything.

| Tool | Internal | Filesystem | Purpose |
|------|----------|------------|---------|
| `calculator` | | none | Arithmetic, either `{"a","b","op"}` or `{"expr": "2+3*4"}` (`+ - * / ^`, parentheses, standard precedence) |
| `search_code` | | none | Search the project via `{"engine": "rg" \| "ast-grep" \| "semcode", "query", "path"}` |
| `fetch_web` | | none | HTTP GET a URL and return a truncated body; the host must be allowlisted |
| `web_search` | | none | DuckDuckGo HTML search, up to 8 results with title, url, snippet |
| `git` | | none | Sandboxed git: `status`, `diff`, `log`, `show`, `add`, `commit`, `ls-files`, `rev-parse`, `branch`. Destructive verbs (`push`, `reset`, `rebase`, `checkout`, `clean`, `rm`, `fetch`, `merge`, `revert`, `stash`) are denied |
| `docker` | | none | Query the local Docker daemon over its Unix socket |
| `write_note` | | `state/` | Append a learning to `state/learnings.md`, included in later system prompts |
| `edit_skill` | | `skills/` | Write or replace a markdown skill file, changing the agent's own instructions |
| `goal` | | `state/` | Design and persist a structured goal that steers later runs |
| `cmd_help` | yes | none | Slash-command reference |
| `cmd_tools` | yes | `tools.d/` | List registered tools |
| `cmd_sessions` | yes | `state/sessions/` | List saved sessions |
| `cmd_graph` | yes | `state/runs/` | Render the latest execution graph |
| `cmd_plugins` | yes | `tools.d/`, `state/` | List plugins, toggle the optional ones |
| `translate` | yes | none | Transform plugin (off by default): translates tool results via `ck_llm` |
| `cmd_status` | yes | `config.json`, `config.local.json` | Show this instance and its peers |
| `format` | yes | none | Markdown to ANSI formatter used for REPL output |
| `webui` | yes | none | Serve the self-contained web UI (no external scripts or fonts) at `GET /` |

`tools.d/examples/` holds descriptors that are not loaded, such as `calc_ts.tool.json` (the AssemblyScript build of the calculator).

## Plugins

Every tool is a WASM plugin; the descriptor decides how much of the harness it gets.

| Descriptor key | Meaning |
|----------------|---------|
| `internal` | Hidden from the model's tool catalog (slash commands, the web UI, transforms) |
| `enabled` | Default on/off state; ships `false` for anything that spends tokens on its own |
| `llm` | May call the model through `ck_llm`; forces sequential execution |
| `config` | Free-form settings object, returned to the guest by `ck_config` |
| `transform` | Marks the tool as a chain link: `{ "phase": "before"\|"after", "tools": ["*"], "order": 50 }` |
| `fs_prefixes` / `network_allow` | Filesystem and network authority |

### Switching plugins on and off

`/plugins` in the REPL lists every tool with its state; `/plugins off <name>` and `/plugins on <name>` toggle one. The choice is written to `state/plugins.json` (`{"disabled": [...], "enabled": [...]}`, machine-local, gitignored) and the running REPL reloads its registry immediately.

Core tools cannot be switched off: those are the `internal` tools with no `transform`, since they back the REPL slash commands and the HTTP routes. Transforms are internal too, but toggling them is the point, so they stay switchable.

### Transform chains

A transform plugin wraps other tools instead of being called by the model. `before` transforms rewrite the arguments going into a tool; `after` transforms rewrite the result coming out, in ascending `order`, before it reaches the agent. Each transform receives:

```json
{ "tool": "fetch_web", "phase": "after", "payload": "<the tool's JSON>", "prior": ["redact"] }
```

so a chained plugin knows which tool it is wrapping and which transforms already ran. It answers `{"ok": true, "payload": "<rewritten>"}`, or anything else to decline. A transform that errors, denies, or returns no payload is skipped with a warning and the original payload continues down the chain: a broken filter never takes the tool with it.

### Calling the model from a plugin

A descriptor with `"llm": true` may call `ck_llm(prompt)` and get completion text back. Without it the call is denied. By default the plugin borrows the provider the agent is running on; `config` can aim it elsewhere:

```json
"config": { "provider": "kimi-k3", "model": "kimi-k2.7-code", "max_tokens": 2048 }
```

The harness reads `provider`, `model`, and `max_tokens` to build that call; every other key is the plugin's own and reaches it verbatim through `ck_config`.

The shipped `translate` plugin combines all of it: an `after` transform on every tool, off by default, that asks its configured model to translate the human-readable text in a tool result into `config.lang` before the next layer sees it. It validates that the answer is still JSON and declines rather than passing on corrupted output.

## REPL slash commands

A line starting with `/` is a command; anything else is sent to the agent as a task. Except for the two handled in-process, `/<name>` dispatches to the internal WASM tool `cmd_<name>` (`src/cli.zig`), so the command set is exactly the `cmd_*` tools in `tools.d/`.

| Command | Runs as | Description |
|---------|---------|-------------|
| `/help` | `cmd_help` | List these commands |
| `/tools` | `cmd_tools` | List registered tools |
| `/sessions` | `cmd_sessions` | List saved sessions |
| `/graph` | `cmd_graph` | Show the latest execution graph |
| `/plugins [on\|off <name>]` | `cmd_plugins` | List plugins and switch the optional ones on or off |
| `/status` | `cmd_status` | Show instance and peers |
| `/goal <intent>` | in-process | Design and persist a goal (runs the agent) |
| `/quit`, `/exit`, `/q` | in-process | Leave the REPL |

### `/graph`

Every agent run records an execution graph and writes it to `state/runs/run-<timestamp>.json` on exit (`src/agent/graph.zig`), unless `modules.graphs` is `false`. `/graph` reads the lexically last of those files, which is the most recent run since the ids sort chronologically, and prints a header plus one line per node grouped by iteration:

```
run-1786365428 — summarize the config
  (kimi-k3, 8421ms, prompt=3190 completion=412)
iter 1
  llm  kimi-k3  3190/180 tok, 5120ms
  tool search_code  2048 B
iter 2
  llm  kimi-k3  3402/232 tok, 3301ms
  done 512 B, stop
```

`llm` lines carry prompt/completion tokens and latency, `tool` lines the result size, and the closing `done` line the final answer size and stop reason. With no runs recorded yet it prints `(no runs yet — clanker run creates one)`. To read an older run, pass its id to the CLI: `clanker graph <run-id>`.

## CLI commands

| Command | Description |
|---------|-------------|
| `init` | Create `config.local.json` and `state/` |
| `providers check [name]` | Verify provider connectivity |
| `run "<task>"` | Run the agent on a task |
| `repl` | Start an interactive REPL with streaming |
| `sessions` | List saved sessions |
| `graph [run-id]` | List recorded runs, or render one as an ASCII timeline |
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
