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
- [ ] **Remaining evals** — more self-evaluation tasks and example-graded evals beyond the current set.# Roadmap

## Done

- **REPL/TUI** — `clanker repl` command with `:help` / `:quit` and stateful sessions.
- **Streaming** — SSE client with tool-call accumulation and `Agent.on_token` hook; REPL streams tokens live.
- **Web UI plugin** — Internal `webui` WASM tool served at `GET /`.
- **Token budget** — `compact_threshold_bytes` and `max_total_tokens` in agent config.

## Planned

- **Plugin manifest SDK** — a formal manifest format for third-party tool plugins.
- **Remaining eval coverage** — add more eval tasks (eval-tasks/) and graded examples.
- **Peer group messaging with shared todos** — collaborative task management between agents.
- **Other ideas** — e.g. more advanced sandbox policies, multi-tenant deployments.

## Planned tools

- [x] **context7** (DONE: fetches library docs from context7.com, optional topic filter — e.g. ziglang/zig + std.http)
- [x] **code_search** (DONE: open-source code search via Sourcegraph — grep.app's API is Vercel-blocked for non-browser clients; returns repo/path/line snippets)


Tools that would most help clanker improve itself (implement as WASM tools in tool-src/zig/ + descriptors in tools.d/, internal:true when the agent must not see them as ordinary tools; see AGENTS.md for the ABI):

- [x] **std_api** (DONE: host fn ck_std_api + tool; greps installed std for symbol signatures) — look up a Zig 0.16 std symbol (e.g. readSliceShort) by grepping the installed std source (std.Io / std.process / std.posix / std.json); return the signature + doc comment. Kills the #1 proposal failure mode (wrong Zig API usage) before the gate.
- [x] **zig_check** (DONE: per-file `zig ast-check` / `zig fmt --check` via ck_exec zig) — per-file `zig ast-check` + `zig fmt --check` for fast self-review before proposing a patch.
- [x] **test_file** (DONE: `zig test <file> --test-filter`; note: works for self-contained files, project files with relative imports need `zig build test`) — run `zig test <file> [--test-filter <name>]` for a single module instead of the full gate.
- [ ] **lsp** — zls LSP client (hover/diagnostics/completions) via stdio JSON-RPC; src/lsp/client.zig slice already specified.
- [x] **symbols** (DONE: rg declaration-site extraction for fn/const/var/struct/enum/union) — structured declaration/reference extraction (fn/const/struct) via rg patterns.
- [x] **history** (DONE: reviews state/improvements.jsonl — status/summary/instruction) — review improve history (successes, failures, feedback tails) so clanker learns from its own past attempts.
- [ ] **autolearn** — run the usage aggregation + roadmap upsert as a tool.
- [ ] **model_stats** — aggregate tokens/cost/cache/tool usage from state/runs + state/autolearn.jsonl.
- [x] **config_view** (DONE: dumps config.json + config.local.json, optional section filter) — dump the effective config (providers, models, modules, budgets).
- [x] **roadmap** (DONE: lists planned items from docs/ROADMAP.md) — read the Planned section so tasks can pick the next item.
- [x] **learnings** (DONE: reads state/learnings.md) — read the persisted learnings file (write_note is write-only today).

## Autolearn

Automatically observed from usage patterns (state/autolearn.jsonl + state/runs/). Refresh with `clanker autolearn`.

- Optimize the most-used tools: git,calculator (usage tracked in state/autolearn.jsonl).
- Fix 'git' tool errors (1 failure(s), last: )
- Build a dedicated tool or skill for the recurring task 'Summarize the last 3 git commits' (seen 2 time(s)) — automate it so future runs are one tool call instead of a full agent loop.

