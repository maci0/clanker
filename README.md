# clanker

<p align="center">
  <img src="docs/assets/mascot.jpg" alt="clanker mascot" width="280">
</p>

clanker is a self-improving AI agent harness written in Zig 0.16. It runs its tools as sandboxed WebAssembly modules via zwasm, and improves its own source code through a gated loop: the agent proposes an exact-match patch, applies it to a staging copy, verifies it with `zig build`, `zig build test`, `zig build tools`, `zig fmt`, and lint, and promotes it to the live tree only if all gates pass.

## Quick start

```sh
zig build          # build the clanker binary
zig build tools    # build the WASM tools
zig build test     # run the test suite
./zig-out/bin/clanker init   # create config.local.json + state/
./zig-out/bin/clanker gate   # run the full deterministic gate (build/test/tools/fmt/lint)
```

Set the API key env var for your chosen provider (see [config.json](config.json)), then:

```sh
./zig-out/bin/clanker providers check
./zig-out/bin/clanker run "hello"
```

## Configuration

clanker loads **[config.json](config.json)** (committed example) and merges **`config.local.json`** on top when present (gitignored, for machine-local overrides). API keys are never stored in config: each provider points at an env var via `api_key_env`. Copy **[.env.example](.env.example)** to `.env` and fill in the keys for the providers you use; it is loaded automatically when `modules.dotenv` is enabled.

| Key | Purpose |
|-----|---------|
| `default_provider` | Name of the active entry under `providers` |
| `providers` | Map of named backends (`kind`, `base_url`, `api_key_env`, `default_model`, `models` — a map of model name to `max_tokens` / `context_window` / `reasoning_effort` / etc.; per-model settings on the provider itself are rejected, see below) |
| `agent` | Loop limits, `tools_dir` / `skills_dir`, sandbox root, compaction |
| `improve` | Self-improvement iteration and context size caps |
| `instance` | This agent's `name` and `id` |
| `peers` | Other instances (`name` + `url`) for notify / phonebook |
| `notify` | Peer notification topic / enable |
| `chatrooms` | Default room subscriptions (`rooms`, `max_history`) — separate from the `modules.chatrooms` on/off flag |
| `modules` | Feature flags (`mcp`, `peers`, `a2a`, `webui`, `graphs`, `sessions`, `goal`, `token_budget`, `streaming`, `dotenv`, `hot_reload`, `autolearn`, `subagents`, `rlm`, `multimodal`, `chatrooms`, `token_stats`) |

Provider `kind` is `openai_compat`, `anthropic`, or `vertex_anthropic` (Anthropic models via Google Vertex AI; requires `project` + `location`, and either `api_key_env` or `service_account_file`). See the full field list and HTTP/CLI reference in [docs/README.md](docs/README.md#configuration).

## Features

- **WASM tools** – sandboxed tool execution via zwasm with an explicit ABI
- **MCP server** – stdio JSON-RPC server exposing tools to MCP clients
- **Peer notifications + phonebook** – send messages to other clanker instances and list agent cards
- **A2A agent cards** – `.well-known/agent.json` discovery
- **`/goal`** – persistent structured goals steering agent runs
- **REPL with streaming** – interactive session with live token output, plus slash commands (`/help`, `/tools`, `/sessions`, `/graph`, `/status`) served by internal WASM tools
- **Execution graphs** – every run is recorded to `state/runs/`; replay it with `/graph` or `clanker graph <run-id>`
- **Plugin toggles** – `/plugins` lists every WASM tool and switches the optional ones on or off; core tools stay on
- **Transform chains** – plugins that rewrite another tool's input or output, in order, each knowing which tool it wraps
- **Plugins that call the model** – `ck_llm` plus a per-plugin `config` for provider, model, and its own settings (see the `translate` plugin)
- **Token budget** – `compact_threshold_bytes` and `max_total_tokens` controls
- **Web UI** – internal WASM tool served at `GET /`

For full documentation, see [docs/README.md](docs/README.md).
