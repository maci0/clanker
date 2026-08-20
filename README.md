# clanker

<p align="center">
  <img src="docs/assets/mascot.jpg" alt="clanker mascot" width="280">
  <br>
  <strong><em>embrace the jank.</em></strong>
</p>

clanker is a self-improving AI agent harness written in Zig 0.16. It runs its tools as sandboxed WebAssembly modules via zwasm, and improves its own source code through a gated loop: the agent proposes an exact-match patch, applies it to a staging copy, verifies it with `zig build`, `zig build test`, `zig build tools`, `zig fmt`, and lint, and promotes it to the live tree only if all gates pass.

## Everything is a plugin

Not a tagline — a design pressure. Whatever can be a drop-in unit with
a declared surface, is one; whatever isn't yet is expected to justify
itself. And most plugins here ship as sandboxed WASM modules, so the
plugin boundary is also the security boundary: a plugin runs under a
descriptor naming exactly which paths, hosts, and environment it may
touch, not with the process's authority.

- **Tools?** Plugin. A WASM guest plus a `*.tool.json` manifest is the
  whole contract (`clanker plugins new <name>` scaffolds one).
- **Models and providers?** Plugin. One vtable file, one registry row,
  one `ProviderKind` tag — never a new `switch (provider.kind)`.
- **Web UI views?** Plugin. A directory under `ui/plugins/` with
  `plugin.json` + `app.js` is a live page surface, no rebuild; the
  `webui_addon` tool lets a chat write one.
- **Skills and prompts?** Plugin. Markdown in `skills/`, records in the
  prompts store — data the harness loads, not code it hardcodes.
- **Config?** Hot-loaded. A clean edit restarts the server into it; a
  broken one is refused and the last known good config keeps serving.
- **The improve loop itself?** Gated, not trusted: every self-change is
  a proposal that must survive build, tests, tools, fmt, and lint
  before it exists.

The core that remains core — the sandbox policy, the gates, the
credential handling — is small on purpose, and stays out of any
plugin's reach.

## Release status

clanker is unreleased development software. The `0.1.0` package version is not
evidence of a published release; published releases are identified by an
immutable `vMAJOR.MINOR.PATCH` Git tag and a matching entry in
[CHANGELOG.md](CHANGELOG.md). Until `1.0.0`, minor releases may contain breaking
changes, but patch releases remain backward compatible. See
[RELEASES.md](RELEASES.md) for the compatibility, deprecation, and support
policy.

## Quick start

Requirements: **Zig 0.16.x** and, for `zig build test`, **Node ≥ 20**. The Zig
release is pinned in `build.zig.zon`'s `minimum_zig_version` (CI installs
exactly that release from it) and the Node version in [.nvmrc](.nvmrc).
`zig build` and `zig build tools` need no Node — `tools/ts/dist/` is committed
so a checkout without a Node toolchain still builds and runs every tool — but
the test step drives its JS suites with `node --test`.

Build the binary, compile the WASM tools, run the test suite, create local
state, run the complete gate, and enable the repository hooks:

```sh
zig build
scripts/apply-patches.sh   # re-apply patches/*.patch to the fetched dependencies
zig build                  # rebuild against the patched dependencies
zig build tools
zig build test
./zig-out/bin/clanker init
./zig-out/bin/clanker gate
git config core.hooksPath .githooks
```

`patches/*.patch` are local fixes to pinned upstream dependencies (see
[patches/README.md](patches/README.md)); the first `zig build` fetches the
pristine upstream trees, and `scripts/apply-patches.sh` re-applies the
patches to them (idempotent, skips what is already applied). The SIGWINCH
patch is load-bearing: without it, resizing the terminal in `clanker repl`
aborts the process, and the e2e pty journeys fail. Run it again whenever a
fresh dependency fetch replaced the trees.

`zig build test` is the full suite (Zig + JS) and takes minutes, so the edit
loop has a single-test path: `zig build test -Dtest-filter="<substring>"`
compiles the Zig binary with only the matching tests registered (a filter
that matches nothing passes with 0 tests; the JS suites still run). For a
JS-only loop, run one suite directly, e.g. `node --test ui/app/core/scroll.test.mjs`.

`clanker gate` covers build/test/tools/fmt/lint and the self-integrity gates,
but CI also runs shellcheck, a Python syntax check, the SBOM generation, and
the AssemblyScript rebuild-and-diff. `scripts/verify.sh` mirrors every CI
step locally, so the full pre-push verification is one command instead of a
list of steps that live only in the CI workflow:

```sh
scripts/verify.sh
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
| `agent` | Loop limits, paths, sandbox, compaction, fallback, confirmation, and worktree defaults |
| `improve` | Self-improvement gates, iteration, context, and cache caps |
| `instance` | This agent's `name` and `id` |
| `serve` | What `clanker serve` binds, including proxy ports, credentials, aliases, and timeouts |
| `peers` | Other instances (`name` + `url`) for notify / phonebook |
| `notify` | Peer notification topic / enable |
| `chatrooms` | Default room subscriptions (`rooms`, `max_history`) — separate from the `modules.chatrooms` on/off flag |
| `memory` | Retrieval backend, chunking, embeddings, and vector search |
| `web` | Additional hosts the research tools may reach |
| `tui` | REPL appearance, including the mascot mode, size, and direction |
| `advisor`, `ttsr`, `kernel` | Post-turn critique, turn-time repair rules, and persistent eval kernels |
| `modules` | Feature flags (`mcp`, `peers`, `a2a`, `webui`, `graphs`, `sessions`, `goal`, `goal_auto_steer`, `token_budget`, `streaming`, `dotenv`, `hot_reload`, `autolearn`, `subagents`, `rlm`, `multimodal`, `chatrooms`, `token_stats`, `acp`, `mesh`). `acp` and `mesh` default off |

Agent instructions are layered: device-wide `$HOME/.agents/AGENTS.md`, shared repository `AGENTS.md`, then ignored project-local `.agents/AGENTS.md`. Put personal, checkout-specific additions such as a Git workflow in the last file; it supplements the shared conventions rather than replacing them. Instruction files also support Claude-style `@path` imports (missing files soft-skip), so a shared root `AGENTS.md` can contain `@.agents/AGENTS.md` for tools that only read the root file.

Provider `kind` is `openai_compat`, `anthropic`, `vertex_anthropic` (Anthropic-only on Vertex), `vertex` (Vertex AI: Gemini, plus Claude when the model id is Anthropic), `azure_openai` (Azure chat completions, `api-key` header), or `gemini` (Google AI Studio). Vertex kinds need `project` + `location`, and a credential: `service_account_file`, gcloud ADC (`gcloud auth application-default login` or `GOOGLE_APPLICATION_CREDENTIALS`), or `api_key_env`. See the full field list and HTTP/CLI reference in [docs/README.md](docs/README.md#configuration).

## Features

- **WASM tools** – sandboxed tool execution via zwasm with an explicit ABI
- **MCP server** – stdio JSON-RPC server exposing tools to MCP clients
- **Peer notifications + phonebook** – send messages to other clanker instances and list agent cards
- **Mesh** – `clanker mesh` joins, leaves, and inspects a TCP cluster of `clanker serve` processes (same host or LAN). Loopback HTTP to local serve; serve owns the sockets
- **A2A agent cards** – `.well-known/agent.json` discovery (`modules.a2a`)
- **Goal lifecycle** – `/write-goal` drafts without side effects, `/add-goal` saves without running, and `/goal` starts a goal loop that keeps working until its completion condition is met
- **REPL with streaming** – interactive session with live token output, plus slash commands (`/help`, `/model`, `/workflows`, `/workflow`, `/sessions`, `/graph`, `/status`, `/plugins`, `/theme`, `/preset`, `/effort`, `/research`, `/rfc`, `/websearch`, `/goal`, `/autoresearch`, `/arena`, `/compare`) with Tab-complete; some run in-process, the rest dispatch to an internal WASM tool. `/research` is the same note store as `clanker research` and `/rfc` the same RFC store as `clanker rfc`; the web-preference toggle is `/websearch`
- **Visible cost and context** – every turn closes with `[turn: 1234 in / 567 out · 4.2s · 135.1 tok/s · cache 82% · $0.0031 · ctx 12.3k/128k (10%)]` in the REPL and on `clanker run`'s stderr, the status bar carries a running context meter and session cost, and compaction announces itself instead of quietly dropping the exchange you were about to ask about
- **Inline shell escape** – `!git log --oneline -5` in the REPL runs there and then, printing into the transcript instead of going to the model. Not a shell: one fixed argv through the same `ck_exec` gate the tools go through, so no pipes, globs or `$VAR`, and the child never sees your API keys. Bare `!` lists what it may run
- **Execution graphs** – every run is recorded to `state/runs/`; list them with `/graph` or replay one with `/graph <run-id>` or `clanker graph <run-id>`
- **Arena** – `clanker arena "<question>" --for X --against Y` runs a judged debate between two positions, or a 3-8 way battle royale with repeated `--position`; ends in a verdict traceable to the transcript, viewable as a pixel battle in the web UI
- **Blind model comparison** – `clanker compare "<prompt>" --with a --with b@model` asks 2-8 configured models the same thing concurrently (`ck_llm_many`) and shows the answers as A, B, C with nothing saying which model wrote which; a judge model or `--pick <letter>` decides, `--synthesize` merges them; the web UI's Compare tab shows the same answers side by side with a pick button per column, and stays blind until you choose
- **Plugin toggles** – `clanker plugins`, `/plugins` in the REPL, and the web UI list every WASM tool and switch optional ones on or off; core tools stay on
- **Plugin manifest SDK** – a plugin is one `*.tool.json` manifest plus a WASM module, and the manifest is the whole sandbox policy. `clanker plugins new <name>` scaffolds a working pair, `clanker plugins validate` checks a manifest or a directory of them and names the offending key, and a manifest whose `wasm` is a bare filename resolves beside itself, so `{name.tool.json, name.wasm}` in one directory is a portable plugin. Field reference: [docs/manifest.md](docs/manifest.md)
- **Transform chains** – plugins that rewrite another tool's input or output, in order, each knowing which tool it wraps
- **Plugins that call the model** – `ck_llm` plus a per-plugin `config` for provider, model, and its own settings (see the `translate` plugin)
- **Operational reports and runbooks** – `clanker reports` lists every recorded bug, investigation and recovery procedure with its status and path, `clanker reports search "<text>"` searches them all before you start diagnosing, and `create`/`append`/`update` write one. Same sandboxed `reports` tool the agent calls, so both surfaces share one store, one inventory and one set of compare-and-swap writes
- **Open decisions** – `clanker rfc` lists every request for comment under `docs/rfcs/` with the status read from the document and the next free number, `clanker rfc search "<text>"` covers the RFCs and the ADRs together so a decision already made surfaces before it is re-litigated, and `create`/`recommend`/`status` write one. Same sandboxed `rfc` tool the agent calls
- **Decisions already made** – `clanker adr` lists every architecture decision under `docs/adrs/` with the status read from the document and the next free number, `clanker adr search "<text>"` spans the ADRs, RFCs and PRDs and says which store each hit fell in, and `create`/`status` write one. `create` requires the consequences and `status ... superseded` requires a note naming the replacement, so a decision is never reversed by editing its own history out. Same sandboxed `adr` tool the agent calls
- **Feature specifications** – `clanker prd` lists every PRD under `docs/prds/` grouped by status with the unfinished work first, `clanker prd checklist` says what a Draft has to pin down before it counts as planned, and `create`/`status` write one. Same sandboxed `prd` tool the agent calls
- **Record stores over HTTP** – `clanker serve` exposes each of those five stores at `/api/reports`, `/api/rfc`, `/api/adr`, `/api/prd` and `/api/research`. Each endpoint relays the same sandboxed tool the CLI and the agent call, so there is one implementation and one set of field names; `GET` serves the reads (`list`, `search`, `open`) and `POST` the writes (`create`, `append`, `update`, `status`)
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

For a service file or a container that cannot pass flags, listener and proxy
settings can come from `[serve]` in `config.toml` or from the environment.
Weakest first, each layer overrides the one above it:

| Layer | Host | Web UI port | Names | Proxy |
| --- | --- | --- | --- | --- |
| `[serve]` in `config.toml` / `config.local.toml` | `host` | `webui_port` | `serve_as` (array) | `proxy`, `proxy_port` |
| environment | `CLANKER_HOST` | `CLANKER_WEBUI_PORT` | — | `CLANKER_PROXY_PORT` |
| flags | `--host` | `--webui-port` | `--serve-as` | `--proxy`, `--no-proxy`, `--proxy-port` |

The proxy also ships standalone: `zig build proxy` builds `clanker-proxy`, a
binary carrying only the provider/auth/proxy code. It reads the same config
files, serves `/v1` at the root (default `127.0.0.1:17922`), and honors
`[serve] proxy_token_env`.

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
task; `clanker --help` lists commands. `clanker <command> --help` explains a
command, while `clanker <option> -h` explains that option (for example,
`clanker --mascot -h`).

| Command | Description |
|---------|-------------|
| `help` / `--help` | Print usage |
| `version` / `--version` | Print the version |
| `init` | Create `config.local.toml` + `state/` |
| `providers [check\|models\|catalog\|fill\|refresh] [name]` | Verify connectivity, list models, search the local models.dev snapshot, fill in model specs, or refresh that snapshot. Defaults to `check` |
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
| `write-goal "<intent>"` | Draft a structured goal without saving or running it |
| `add-goal "<objective>" "<completion criterion>"` | Save a structured goal without running it |
| `goal "<condition>"` | Start a goal loop that keeps working until the condition is met |
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
| `mesh [status\|join\|leave\|pending\|admit\|deny]` | Join or leave the mesh, or inspect it (`--webui-port` picks the local serve) |
| `serve [--host <addr>] [--serve-as <name>]... [--webui-port <port>]` | HTTP API + web UI (loopback, port 17921 by default) |
| `graph [run-id]` | List runs, or render one as an ASCII timeline |
| `graph answer [run-id]` | Print a recorded run's final answer |
| `gate` | Run the full deterministic gate (build/test/tools/fmt/lint/release-contract) |
| `autolearn` | Aggregate usage into roadmap items |
| `setup` | Guided first run: check config, keys and tools |
| `doctor` | Diagnose config, credentials and build outputs |
| `janitor [--yes]` | Sweep up what old runs left behind: staging copies, old run graphs and improve logs, compare-and-swap lock files unused for 12h, and spilled tool results (also `clanker prune`) |

For full documentation, see [docs/README.md](docs/README.md).
