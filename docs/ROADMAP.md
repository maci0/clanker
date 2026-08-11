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
- **Shared todo lists across rooms** — collaborative task management between agents in a chatroom: a `todo` WASM tool over a per-room list that any subscriber can add to, claim, and close. Rides the existing chatroom pipeline rather than a second transport (append-only `state/chatrooms.jsonl` with the same fan-out to peers in `src/peers/chatrooms.zig`), so a claim is just another message every subscriber already receives. Needs a claim rule that survives two agents claiming at once, since the log has no locking.
- **Subagents can ask the parent** — a nested run puts a specific question back up to the agent that spawned it, instead of guessing or burning iterations rediscovering something the parent already knows. Reuses the `ask_user` surface rather than adding a channel: it already routes a question plus options to the human, or with `"peer"` to another instance, so the parent is a third target (`ck_ask` in `src/sandbox/host.zig`). The hard part is not the transport: the parent is mid-`a.run()` on another thread when the question arrives, so it needs either a re-entrant answer path or a queue that resolves at the parent's next turn boundary. Decide that before the tool surface.
- **Per-subagent todo lists** — a nested run gets its own private list, scoped to that subagent and discarded when it returns. Today a subagent receives a `Brief` (`parent_task`, `context`, `files`) and hands back one final string, so a multi-step nested run has nowhere to track its own progress and the parent cannot see how far it got when it hits the iteration cap. Distinct from the shared list above: private to one run, never fanned out to peers, and summarized back into the parent's result rather than persisted. Same tool surface as the shared list where it can be, so an agent does not learn two vocabularies for the same idea.
- **Configurable RLM recursion depth** — `max_depth` is a hardcoded `const … = 3` at `tools/zig/rlm.zig:13`, so how far the recursive sub-LM may descend cannot be changed without a rebuild. The `depth` field in the tool's input is only the current counter, not the ceiling. Should come from the plugin's own `config` block the way `translate` already reads its settings (`lib.config()` parsed into a `Settings` struct, see `tools/zig/translate.zig:40`), defaulting to 3 so existing behaviour is unchanged. Worth a ceiling on the configured value too: each level multiplies model calls, so an unbounded setting is a bill, not a feature.
- **Remaining eval coverage** — more `evals/` definitions and graded examples.
- **Other ideas** — more advanced sandbox policies (fuel metering hardening, syscall-level denials), multi-tenant deployments.

## Autolearn

Automatically observed from usage patterns (`state/autolearn.jsonl` + `state/runs/`). Refresh with `clanker autolearn`.

- Optimize the most-used tools: git, calculator (usage tracked in state/autolearn.jsonl).
- Fix 'git' tool errors (1 failure(s), last: ).
- Build a dedicated tool or skill for the recurring task 'Summarize the last 3 git commits' (seen 2 time(s)) — automate it so future runs are one tool call instead of a full agent loop.
