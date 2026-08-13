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
git config core.hooksPath .githooks   # enable the fast pre-commit checks (fmt, shellcheck, manifests, secrets)
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
| `providers` | Map of named backends: `kind`, `base_url`, `api_key_env`, optional `auth`, `default_model` |
| `models` | Top-level map of `"<provider>/<model>"` → per-model settings (`context_window`, `max_tokens`, `reasoning_effort`, …), each naming its `provider`. Per-model settings on a provider entry, or a `models` table nested inside one, are rejected at load |
| `agent` | Loop limits, paths, sandbox root, and compaction |
| `improve` | Self-improvement iteration and context size caps |
| `instance` | This agent's `name` and `id` |
| `serve` | What `clanker serve` binds: `host`, `webui_port`, `serve_as` |
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
- **A2A agent cards** – `.well-known/agent.json` discovery (`modules.a2a`)
- **`/goal`** – persistent structured goals steering agent runs
- **REPL with streaming** – interactive session with live token output, plus slash commands (`/help`, `/model`, `/workflows`, `/workflow`, `/sessions`, `/graph`, `/status`, `/plugins`, `/theme`, `/goal`, `/autoresearch`, `/arena`, `/compare`) with Tab-complete; some run in-process, the rest dispatch to an internal WASM tool
- **Visible cost and context** – every turn closes with `[turn: 1234 in / 567 out · 4.2s · 135.1 tok/s · cache 82% · $0.0031 · ctx 12.3k/128k (10%)]` in the REPL and on `clanker run`'s stderr, the status bar carries a running context meter and session cost, and compaction announces itself instead of quietly dropping the exchange you were about to ask about
- **Inline shell escape** – `!git log --oneline -5` in the REPL runs there and then, printing into the transcript instead of going to the model. Not a shell: one fixed argv through the same `ck_exec` gate the tools go through, so no pipes, globs or `$VAR`, and the child never sees your API keys. Bare `!` lists what it may run
- **Execution graphs** – every run is recorded to `state/runs/`; replay it with `/graph` or `clanker graph <run-id>`
- **Arena** – `clanker arena "<question>" --for X --against Y` runs a judged debate between two positions, or a 3-8 way battle royale with repeated `--position`; ends in a verdict traceable to the transcript, viewable as a pixel battle in the web UI
- **Blind model comparison** – `clanker compare "<prompt>" --with a --with b@model` asks 2-8 configured models the same thing concurrently (`ck_llm_many`) and shows the answers as A, B, C with nothing saying which model wrote which; a judge model or `--pick <letter>` decides, `--synthesize` merges them; the web UI's Compare tab shows the same answers side by side with a pick button per column, and stays blind until you choose
- **Plugin toggles** – `clanker plugins`, `/plugins` in the REPL, and the web UI list every WASM tool and switch optional ones on or off; core tools stay on
- **Plugin manifest SDK** – a plugin is one `*.tool.json` manifest plus a WASM module, and the manifest is the whole sandbox policy. `clanker plugins new <name>` scaffolds a working pair, `clanker plugins validate` checks a manifest or a directory of them and names the offending key, and a manifest whose `wasm` is a bare filename resolves beside itself, so `{name.tool.json, name.wasm}` in one directory is a portable plugin. Field reference: [docs/manifest.md](docs/manifest.md)
- **Transform chains** – plugins that rewrite another tool's input or output, in order, each knowing which tool it wraps
- **Plugins that call the model** – `ck_llm` plus a per-plugin `config` for provider, model, and its own settings (see the `translate` plugin)
- **Scheduled runs** – `clanker schedule add "0 9 * * 1-5" "review yesterday's runs"` puts a recurring task in `state/schedule.json`; the system's own cron calls `clanker schedule run-due` to fire what is due (see below)
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

Start it with `clanker serve` (loopback and port `17921` by default, `--host`
and `--webui-port` to change them), then open the URL it prints
(`http://127.0.0.1:17921/webui`):

```sh
./zig-out/bin/clanker serve
```

`--host` is the interface the process binds; `--webui-port` is the port the
web UI and its same-origin API answer on. Ports are named per surface so that
a surface added later gets its own name rather than a rename of this one.
`--port` is still accepted as an alias for `--webui-port`.

`--host 0.0.0.0` makes it reachable from the LAN by IP. There is no
authentication, so anyone who can reach the port gets full agent and tool
access; past loopback the access control is your firewall, not clanker.
Requests are still refused unless the `Host` header names this listener: an IP
literal at the listen port or `localhost` always passes, and a real hostname
(a reverse proxy, a tailnet name) has to be listed with the repeatable
`--serve-as`, because a name is what DNS rebinding needs and an IP literal
cannot be rebound.

```sh
./zig-out/bin/clanker serve --host 0.0.0.0 --serve-as clanker.lan
```

**One port, whatever you bind.** `serve` opens exactly one listening socket
and multiplexes every surface onto it. Configured `[[peers]]` are outbound
URLs this process connects to, never anything it listens on, so a peer
pointed at `127.0.0.1` is not reachable through this server and `--host` does
not widen it. The shipped `dummy-down` peer is exactly that: a URL on the
discard port, deliberately dead, with nothing bound behind it.

For a service file or a container that cannot pass flags, the same three
settings can come from `[serve]` in `config.toml` or from the environment.
Weakest first, each overriding the one above it:

| Layer | Host | Port | Names |
| --- | --- | --- | --- |
| `[serve]` in `config.toml` / `config.local.toml` | `host` | `webui_port` | `serve_as` (array) |
| environment | `CLANKER_HOST` | `CLANKER_WEBUI_PORT` | — |
| flags | `--host` | `--webui-port` | `--serve-as` |

A flag always beats the environment, which always beats the file, matching how
`--verbose` beats `CLANKER_LOG_LEVEL` and `--provider` beats
`default_provider`.

```toml
[serve]
host = "0.0.0.0"
webui_port = 17921
serve_as = ["clanker.lan"]
```

The server also exposes the peer/chatroom/board/goal/stats APIs over HTTP and
an A2A agent card at `/.well-known/agent.json`. See the HTTP server section in
[docs/README.md](docs/README.md#http-server).

## Scheduled runs

`clanker schedule` keeps a list of recurring tasks in `state/schedule.json` and
records every fire in `state/schedule/log.jsonl`, so a recurring run is
something the harness knows about rather than a line in someone's crontab.

```sh
./zig-out/bin/clanker schedule add "0 9 * * 1-5" "summarize yesterday's commits"
./zig-out/bin/clanker schedule list
```

Nothing fires on its own. The system's own cron is the clock:

```
* * * * * cd /path/to/clanker && ./zig-out/bin/clanker schedule run-due
```

`run-due` is safe to call every minute: it holds a lock for the duration of a
sweep, so a run that takes longer than a minute is not stacked on top of
itself. Fire one entry ahead of its schedule with `clanker schedule run <id>`.

The spec is five fields — `minute hour day-of-month month day-of-week` — each
`*`, a number, `a-b`, `*/n`, `a-b/n`, or a comma-separated list. Sunday is `0`
or `7`; names (`MON`) and `@nicknames` are not accepted. When both day fields
are restricted, the entry fires when *either* matches, as in Vixie cron. Fields
are read in UTC unless the entry carries a fixed `--tz-offset` (`+02:00`,
`-05:00`); there is no DST handling, on purpose.

**A missed window fires once.** A machine that slept through a day of a `*/5`
entry runs it once on waking and resumes on the normal grid — the windows it
slept through are counted into the ledger and dropped, not replayed. See
[docs/prds/0009-schedule.md](docs/prds/0009-schedule.md).

## Command reference

`clanker` (no command) drops you into the REPL. `clanker <command>` runs one
task; `clanker --help` prints usage.

| Command | Description |
|---------|-------------|
| `help` / `--help` | Print usage |
| `version` / `--version` | Print the version |
| `init` | Create `config.local.toml` + `state/` |
| `providers [check\|models\|catalog\|fill] [name]` | Verify connectivity, list models, query the models.dev catalog, or fill in model specs from it. Defaults to `check` |
| `run "<task>"` | Run the agent on a task |
| `repl` | Interactive multi-turn chat (streams tokens); the default |
| `sessions` | List saved sessions |
| `session export <id> [path]` | Write one saved session as a self-contained HTML transcript (default `state/exports/<id>.html`) |
| `tools list` | List registered WASM tools |
| `plugins [list\|on <name>\|off <name>\|validate [path]\|new <name>]` | List, switch, validate, or scaffold plugins |
| `eval [name] [--tasks]` | Run evals |
| `improve-self [--provider P] [--model M] [--iters N] [--dry-run] "<instructions>"` | Self-improvement loop |
| `revert <id>` | Revert a promoted improvement |
| `git <args...>` | Git passthrough |
| `mcp` | Serve tools over MCP (stdio) |
| `goal "<intent>"` | Design and persist a structured goal |
| `arena "<question>" --for X --against Y` | Judged debate between two positions, or a battle royale |
| `compare "<prompt>" [--with <provider[@model]>]...` | One prompt to several models at once, answers shown unlabeled |
| `autoresearch [--target F] [--harness C]` | Measurement-driven research loop |
| `workflow [list\|show <name>\|run <name> [args]]` | List, inspect, or run reusable prompt workflows |
| `notify <peer> "<message>"` | Send a notification to a peer |
| `chat send <room> "<text>"` | Send a message to a chatroom |
| `chat history <room> [after]` | Read chatroom history (newest first) |
| `chat rooms` | List chatrooms + subscriptions |
| `chat subscribe <room> [on]` | Join/leave a chatroom |
| `schedule [list\|add\|remove\|enable\|disable\|run\|run-due\|log]` | Run the agent on a cron-like schedule (see below). Defaults to `list` |
| `stats` | Token usage per provider/model |
| `phonebook` | List peer agent cards |
| `serve [--host <addr>] [--serve-as <name>]... [--webui-port <port>]` | HTTP API + web UI (loopback, port 17921 by default) |
| `graph [run-id]` | List runs, or render one as an ASCII timeline |
| `gate` | Run the full deterministic gate (build/test/tools/fmt/lint) |
| `autolearn` | Aggregate usage into roadmap items |
| `setup` | Guided first run: check config, keys and tools |
| `doctor` | Diagnose config, credentials and build outputs |
| `janitor [--yes]` | Sweep up what old runs left behind (also `clanker prune`) |

For full documentation, see [docs/README.md](docs/README.md).
