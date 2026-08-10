# Roadmap

## Done

- **REPL/TUI** — `clanker repl` with slash commands (`/help`, `/tools`, `/sessions`, `/graph`, `/plugins`, `/status`, `/goal`), stateful sessions, and live token streaming.
- **Live status UX** — animated spinner + `⚙ tool` / `↳ ms` status lines cover the gap while the LLM or a tool is running, in both `clanker repl` and `clanker run` (`Agent.on_tool_call` / `on_tool_result` hooks); `clanker run` keeps stdout pipe-clean and puts status on stderr.
- **Streaming** — SSE client with tool-call accumulation and `Agent.on_token` hook; the REPL streams tokens live.
- **Web UI plugin** — internal `webui` WASM tool served at `GET /` by `clanker serve`; real multi-turn chat via a `session` id, and a `\x01{"type":...}` event protocol on `/api/run`'s stream for live tool status.
- **Token budget + compaction** — `compact_threshold_bytes` and `max_total_tokens` (plus per-turn/per-session caps) in agent config; conversation compaction runs before and after turns in the REPL, one-shot runs, and the improve engine.
- **Self-improvement gates** — `zig build`, `zig build test`, `zig build tools`, `zig fmt`, and lint run on every staged change before promotion; exposed as `clanker gate` and reused by `improve-self`.
- **Parallel tools / registry** — heterogeneous tool sources (Zig + AssemblyScript) with `clanker tools list`.
- **Multi-instance peers** — peers in config, `clanker serve` (HTTP), `clanker notify <peer> "<msg>"`, `clanker phonebook`, agent cards at `/.well-known/agent.json`, A2A message handler.
- **MCP server** — `clanker mcp`: stdio JSON-RPC server exposing the tool registry.
- **Execution graphs** — every run recorded to `state/runs/`; ASCII timeline via `clanker graph [run-id]` and `/graph`.
- **Plugins & transforms** — every tool is a WASM plugin; descriptors gate `internal`, `enabled`, `llm`, `config`, `transform`; `after`/`before` transform chains rewrite tool I/O; `/plugins` toggles them.
- **`/goal`** — persistent structured goals steering agent runs; `clanker goal`.
- **Autolearn** — usage aggregation from `state/autolearn.jsonl` + `state/runs/`, roadmap upsert via `clanker autolearn`.
- **Subagents** — `subagent` WASM tool: nested agent runs on a dedicated thread with bounded iterations (`ck_subagent` host fn), gated by `modules.subagents`.
- **RLM / reasoning** — `rlm` WASM tool (recursive sub-LM over input chunks, bounded depth) and the `reasoning` tool; traces persisted to `state/reasoning.jsonl`.
- **Self-review tools** — `std_api` (Zig 0.16 std signature lookup via `ck_std_api`), `symbols` (declaration-site extraction), `zig_check` (per-file `ast-check`/`fmt`), `test_file` (`zig test <file>`), `history` (improve-history review), `roadmap` (planned-items reader), `learnings` (read `state/learnings.md`).
- **Docs** — this roadmap, `README.md`, and `docs/README.md` (reference) maintained in-repo.
- **Chatrooms** — clankers subscribe to named rooms and talk to each other: `chat_*` WASM tools, `clanker chat` CLI, `/api/chat/*` HTTP endpoints, subscription overrides, and per-run inbox injection (`modules.chatrooms`).
- **Token usage stats** — every completion recorded to `state/token_stats.jsonl` at the client choke point; `model_stats` WASM tool, `clanker stats` table, and `GET /api/stats` aggregate per provider/model (calls, tokens, cache hit rate, tok/s, cost).

## Planned

- **Plugin manifest SDK** — a formal manifest format for third-party tool packaging and distribution.
- **LSP integration** — `lsp` WASM tool wrapping a zls client (hover/diagnostics/completions) over stdio JSON-RPC.
- **Shared todo lists across rooms** — collaborative task management between agents in a chatroom.
- **Remaining eval coverage** — more `evals/` definitions and graded examples.
- **Other ideas** — more advanced sandbox policies (fuel metering hardening, syscall-level denials), multi-tenant deployments.

## Autolearn

Automatically observed from usage patterns (`state/autolearn.jsonl` + `state/runs/`). Refresh with `clanker autolearn`.

- Optimize the most-used tools: git, calculator (usage tracked in state/autolearn.jsonl).
- Fix 'git' tool errors (1 failure(s), last: ).
- Build a dedicated tool or skill for the recurring task 'Summarize the last 3 git commits' (seen 2 time(s)) — automate it so future runs are one tool call instead of a full agent loop.
