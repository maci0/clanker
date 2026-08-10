# clanker

clanker is a self-improving AI agent harness written in Zig 0.16. It wraps LLM APIs and executes tools as WebAssembly modules via the zwasm sandbox. The agent can modify its own source code through a gated improvement loop, then commit the changes with git.

## Architecture

- `src/agent/loop.zig` — the main agent loop: builds the message stream, calls the model, executes tool calls, and repeats until the task is done.
- `src/llm/providers.zig` — provider abstraction for OpenAI-compatible and Anthropic chat APIs. Each provider is configured in JSON and references an API key from the environment.
- `src/sandbox/` — zwasm WebAssembly runtime. Tools are compiled to `wasm32-wasip1-threads` and run inside a sandbox that exposes `ck_*` host functions.
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

The engine also snapshots the original files in `state/history/` and records the outcome so a failed improvement can be retried with error feedback.