# clanker

<p align="center">
  <img src="docs/assets/mascot.jpg" alt="clanker mascot" width="280">
  <br>
  <strong><em>embrace the jank.</em></strong>
</p>

clanker is a self-improving AI agent harness written in Zig 0.16. It runs its tools as sandboxed WebAssembly modules via zwasm, and improves its own source code through a gated loop: the agent proposes an exact-match patch, applies it to a staging copy, verifies it with `zig build`, `zig build test`, `zig build tools`, `zig fmt`, and lint, and promotes it to the live tree only if all gates pass.

## Release status

clanker is unreleased development software. The `0.1.0` package version is not
evidence of a published release; published releases are identified by an
immutable `vMAJOR.MINOR.PATCH` Git tag and a matching entry in
[CHANGELOG.md](CHANGELOG.md). Until `1.0.0`, minor releases may contain breaking
changes, but patch releases remain backward compatible. See
[RELEASES.md](RELEASES.md) for the compatibility, deprecation, and support
policy.

## Quick start

```sh
zig build          # build the clanker binary
zig build tools    # build the WASM tools
zig build test     # run the test suite
./zig-out/bin/clanker init   # create config.local.toml + state/
./zig-out/bin/clanker gate   # run the full deterministic gate (build/test/tools/fmt/lint)
```

Set the API key env var for your chosen provider (see [config.toml](config.toml)), then:

```sh
./zig-out/bin/clanker providers check
./zig-out/bin/clanker run "hello"
```

## Configuration

clanker loads **[config.toml](config.toml)** (committed example) and merges **`config.local.toml`** on top when present (gitignored, for machine-local overrides). TOML is the only supported config format. API keys are never stored in config: each provider points at an env var via `api_key_env`. Copy **[.env.example](.env.example)** to `.env` and fill in the keys for the providers you use; it is loaded automatically when `modules.dotenv` is enabled.

| Key | Purpose |
|-----|---------|
| `default_provider` | Name of the active entry under `providers` |
| `providers` | Map of named backends (`kind`, `base_url`, `api_key_env`, `default_model`, `models` — a map of model name to `max_tokens` / `context_window` / `reasoning_effort` / etc.; per-model settings on the provider itself are rejected, see below) |
| `agent` | Loop limits, paths, sandbox root, and compaction |
| `improve` | Self-improvement iteration and context size caps |
| `instance` | This agent's `name` and `id` |
| `peers` | Other instances (`name` + `url`) for notify / phonebook |
| `notify` | Peer notification topic / enable |
| `chatrooms` | Default room subscriptions (`rooms`, `max_history`) — separate from the `modules.chatrooms` on/off flag |
| `modules` | Feature flags (`mcp`, `peers`, `a2a`, `webui`, `graphs`, `sessions`, `goal`, `token_budget`, `streaming`, `dotenv`, `hot_reload`, `autolearn`, `subagents`, `rlm`, `multimodal`, `chatrooms`, `token_stats`) |

Agent instructions are layered: device-wide `$HOME/.agents/AGENTS.md`, shared repository `AGENTS.md`, then ignored project-local `.agents/AGENTS.md`. Put personal, checkout-specific additions such as a Git workflow in the last file; it supplements the shared conventions rather than replacing them. Instruction files also support Claude-style `@path` imports (missing files soft-skip), so a shared root `AGENTS.md` can contain `@.agents/AGENTS.md` for tools that only read the root file.

Provider `kind` is `openai_compat`, `anthropic`, or `vertex_anthropic` (Anthropic models via Google Vertex AI; requires `project` + `location`, and either `api_key_env` or `service_account_file`). See the full field list and HTTP/CLI reference in [docs/README.md](docs/README.md#configuration).

## Features

- **WASM tools** – sandboxed tool execution via zwasm with an explicit ABI
- **MCP server** – stdio JSON-RPC server exposing tools to MCP clients
- **Peer notifications + phonebook** – send messages to other clanker instances and list agent cards
- **A2A agent cards** – `.well-known/agent.json` discovery
- **`/goal`** – persistent structured goals steering agent runs
- **REPL with streaming** – interactive session with live token output, plus slash commands (`/help`, `/tools`, `/sessions`, `/graph`, `/status`) served by internal WASM tools
- **Inline shell escape** – `!git log --oneline -5` in the REPL runs there and then, printing into the transcript instead of going to the model. Not a shell: one fixed argv through the same `ck_exec` gate the tools go through, so no pipes, globs or `$VAR`, and the child never sees your API keys. Bare `!` lists what it may run
- **Execution graphs** – every run is recorded to `state/runs/`; replay it with `/graph` or `clanker graph <run-id>`
- **Arena** – `clanker arena "<question>" --for X --against Y` runs a judged debate between two positions, or a 3-8 way battle royale with repeated `--position`; ends in a verdict traceable to the transcript, viewable as a pixel battle in the web UI
- **Blind model comparison** – `clanker compare "<prompt>" --with a --with b@model` asks 2-8 configured models the same thing concurrently (`ck_llm_many`) and shows the answers as A, B, C with nothing saying which model wrote which; a judge model or `--pick <letter>` decides, `--synthesize` merges them
- **Plugin toggles** – `/plugins` lists every WASM tool and switches the optional ones on or off; core tools stay on
- **Transform chains** – plugins that rewrite another tool's input or output, in order, each knowing which tool it wraps
- **Plugins that call the model** – `ck_llm` plus a per-plugin `config` for provider, model, and its own settings (see the `translate` plugin)
- **Token budget** – `compact_threshold_bytes` and `max_total_tokens` controls
- **Web UI** – internal WASM tool served at `GET /`

For full documentation, see [docs/README.md](docs/README.md).

## Web UI and `clanker serve`

The Web UI is a browser interface to the agent: a real multi-turn chat backed
by the same sessions, providers, tools and execution graphs as the CLI. It is
served by the internal `webui` WASM tool when `modules.webui` is on (default).
A run's private checklist shows up live in its turn card as the agent adds,
claims and closes items, so a multi-step plan is visible while it is worked
rather than only in the answer.

Start it with `clanker serve` (default port `17921`, `--port` to change it),
then open the URL it prints (`http://127.0.0.1:17921/webui`):

```sh
./zig-out/bin/clanker serve
```

The server also exposes the peer/chatroom/board/goal/stats APIs over HTTP and
an A2A agent card at `/.well-known/agent.json`. See the HTTP server section in
[docs/README.md](docs/README.md#http-server).

## Command reference

`clanker` (no command) drops you into the REPL. `clanker <command>` runs one
task; `clanker --help` prints usage.

| Command | Description |
|---------|-------------|
| `help` / `--help` | Print usage |
| `version` / `--version` | Print the version |
| `init` | Create `config.local.toml` + `state/` |
| `providers <check\|models\|catalog\|fill> [name]` | Verify connectivity, list models, or query the models.dev catalog |
| `run "<task>"` | Run the agent on a task |
| `repl` | Interactive multi-turn chat (streams tokens); the default |
| `sessions` | List saved sessions |
| `tools list` | List registered WASM tools |
| `eval [name] [--tasks]` | Run evals |
| `improve-self [--iters N] [--dry-run] "<instructions>"` | Self-improvement loop |
| `revert <id>` | Revert a promoted improvement |
| `git <args...>` | Git passthrough |
| `mcp` | Serve tools over MCP (stdio) |
| `goal "<intent>"` | Design and persist a structured goal |
| `notify <peer> "<message>"` | Send a notification to a peer |
| `chat send <room> "<text>"` | Send a message to a chatroom |
| `chat history <room> [after]` | Read chatroom history (newest first) |
| `chat rooms` | List chatrooms + subscriptions |
| `chat subscribe <room> [on]` | Join/leave a chatroom |
| `stats` | Token usage per provider/model |
| `phonebook` | List peer agent cards |
| `serve [--port N]` | HTTP server + web UI (default port 17921) |
| `graph [run-id]` | List runs, or render one as an ASCII timeline |
| `gate` | Run the full deterministic gate (build/test/tools/fmt/lint) |
| `autolearn` | Aggregate usage into roadmap items |
| `setup` | Guided first run: check config, keys and tools |
| `doctor` | Diagnose config, credentials and build outputs |
| `janitor [--yes]` | Sweep up what old runs left behind (also `clanker prune`) |

For full documentation, see [docs/README.md](docs/README.md).
