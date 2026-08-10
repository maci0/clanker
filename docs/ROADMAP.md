# Roadmap

## Done

- **REPL/TUI** – `clanker repl` with `:help`/`:quit` and stateful sessions.
- **Streaming** – SSE client + `Agent.on_token` hook for live token output.
- **Web UI plugin** – internal `webui` WASM tool served at `GET /`.
- **Token budget** – `compact_threshold_bytes` and `max_total_tokens` controls.

## Planned

- Plugin manifest SDK for third-party tool packaging.
- Additional evals and coverage gaps.
- Peer-group messaging with shared todos.
- Other genuinely unimplemented ideas as they arise.


## Done

- [x] **Self-improvement gates** — `zig build`, `zig build test`, `zig build tools`, format, and lint gates run on staged changes before promotion. (DONE: gates are enforced in `src/improve/engine.zig`.)
- [x] **Parallel tools** — multiple tools can be defined and executed independently; the registry supports heterogeneous tool sources. (DONE: `tools list` and registry in `src/tools/registry.zig`.)
- [x] **Multi-instance peers, notify, phonebook** — peers are defined in config, notifications are posted to `/api/notify`, and agent cards are served at `/.well-known/agent.json` with a `phonebook` command to scan peers. (DONE: see `src/cli.zig`, `src/peers/notify.zig`.)
- [x] **Token accounting + compaction** — usage tracking and context compaction are handled in the agent loop. (DONE: session messages are compacted and token counts are reported.)

## Planned

- [ ] **REPL/TUI** — interactive shell and terminal UI for the agent. (Not yet implemented; `repl` currently returns `NotYetImplemented`.)
- [ ] **Webui plugin** — browser-based interface for managing sessions and watching improvements.
- [ ] **Plugin manifest SDK** — formalized developer SDK for building and shipping tools with a manifest-driven build.
- [ ] **Remaining evals** — more self-evaluation tasks and example-graded evals beyond the current set.