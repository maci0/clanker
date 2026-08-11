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
- **Shared todo lists across rooms** — `todo_add` / `todo_claim` / `todo_close` / `todo_list` WASM tools over a per-room list any subscriber can add to, claim, and close. A todo action is just a chat message (`@todo {...}` text in `state/chatrooms.jsonl`) riding the existing append + peer fan-out; state is derived by an order-independent fold (`src/peers/todos.zig`), and two agents claiming at once resolve deterministically — lowest (ts, id) wins on every replica, and `todo_claim` reports the actual winner.
- **LSP integration** — `lsp` WASM tool answering definition/references questions through zls (one stateless zls session per call over stdio JSON-RPC).
- **Configurable RLM recursion depth** — `max_depth` read from the rlm plugin's `config` block (default 3, clamped to a ceiling of 8 so a misconfigured value stays a setting, not a bill).
- **Per-subagent todo lists** — a nested run gets its own private list (`src/agent/private_todos.zig`): the same `todo_add` / `todo_claim` / `todo_close` / `todo_list` tools called without a `room` (ck_chat routes on the missing field), so an agent keeps one vocabulary for both kinds of list. In-memory, single-owner, never fanned out to peers, discarded when the run returns; the final state is appended to the sub-agent's answer, so the parent sees how far a multi-step run got even when it hit the iteration cap.
- **Subagents can ask the parent** — `ask_user {"parent": true}` in a nested run puts the question to the agent that spawned it, as the third target next to the human and `"peer"`. The concurrency decision the plan called for went to the *re-entrant answer path*, not a queue at the parent's next turn boundary: `ck_subagent` joins the nested thread, so the parent never reaches a turn boundary while its sub-agent waits (a queue deadlocks by construction) — and that same join means the parent is parked with no tool of its own in flight (the subagent tool is `llm: true`, hence sequential), so its transcript is a stable snapshot. The answer is one bounded completion on the parent's provider over that snapshot (`answerAsParent` in `src/agent/loop.zig`, wired as `host.ParentAsk` through `Sandbox.own_ask` → `ck_subagent` → the nested run's `parent_ask`).

- **Web UI ask bridge** — `ask_user` works from the browser (webui-plan 1.1): a streaming run writes `\x01{"type":"ask","id":…,"question":…,"options":[…]}` down its own `/api/run` stream and blocks; the page renders the question as option buttons in the turn card and `POST /api/ask` resolves the wait (the answer must be one of the offered options, byte for byte). An unanswered question times out after `agent.ask_timeout_seconds` (default 120) and degrades to the same "nobody attached" answer a headless run gets, so a closed tab never hangs a run.

- **Confirm before write** — Kimi's permission model, riding the ask bridge (webui-plan 1.2): with `agent.confirm_writes` opted in (`browser`, or `always` for the REPL too; default `never`), a call to a write-capable tool — exec or filesystem access in its descriptor, both of which grant writes, or an explicit `"confirm": true` like `subagent`'s, whose nested run is itself ungated — blocks in the dispatch loop until the human allows or denies it. The question travels as a `\x01{"type":"confirm",…}` stream event with a 400-byte argument preview, answered through the same `POST /api/ask` slot machinery with fixed `allow`/`deny` options; read-only tools carry `"confirm": false` so reads keep running free. Anything short of an explicit allow (deny, timeout, closed tab, piped stdin) refuses the call and tells the model the user declined. Headless runs, the improve loop, and nested sub-agents never install a channel, so no config value can gate them on an answer nobody is there to give.

- **Eval definitions under the gate** — `evals/` grew cases for the self-review tools (`std_api`, `zig_check`, `symbols`), each asserting the shape of the answer rather than toolchain- or content-sensitive text. And the definitions themselves are now tested: `Eval.loadAll` skips a file it cannot parse (`catch continue`), so a malformed eval silently stopped being run — `zig build test` now parses every shipped `*.task.json`, rejects a task eval with no prompt or no criteria, and cross-checks each `requires_tool` against the shipped manifests so a tool rename can no longer strand an eval at a permanent score of 0.

- **`recent_commits` tool** — the Autolearn item asking for a dedicated tool for the recurring "summarize the last 3 git commits" task: one read-only call (`git log` with a fixed argv, `{"count": N}` clamped to 1..50) returning one `hash  date  subject  (author)` line per commit, instead of a full agent loop over the general `git` tool.

## Planned

- **Plugin manifest SDK** — a formal manifest format for third-party tool packaging and distribution.
- **Web UI: interaction, fleet views, pixel floor** — a phased plan lives in [docs/webui-plan.md](webui-plan.md). The ask bridge (1.1), confirm-before-write (1.2), image input (1.3), fork (2.1), visible compact (2.3) and model switching (2.4) have landed; still open: plan mode (2.2), subagent runs recorded as their own graphs (3.1) — a nested run still returns one string — the cross-agent view (3.2), and the `webui_pixelagents` floor.
- **Web UI: split `app.js` into ES modules** — framework research in [docs/webui-framework-research.md](webui-framework-research.md) concluded: stay on vanilla JS (no build step, JSON-not-HTML server, CSP), with the escape hatches pre-decided — VanJS (+copy-in VanUI components) for a small state-driven view, Preact + htm for a real component tree. The real debt is one 178 KB `app.js`; native `<script type="module">` needs no build step and `webui.zig`'s `assetFor` already maps paths to embedded assets.
- **Remaining eval coverage** — more `evals/` definitions and graded examples.
- **Other ideas** — more advanced sandbox policies (fuel metering hardening, syscall-level denials), multi-tenant deployments.

## Autolearn

Automatically observed from usage patterns (`state/autolearn.jsonl` + `state/runs/`). Refresh with `clanker autolearn`.

- Optimize the most-used tools: git, calculator (usage tracked in state/autolearn.jsonl).
- Fix 'git' tool errors (1 failure(s), last: ).
- Build a dedicated tool or skill for the recurring task 'Summarize the last 3 git commits' (seen 2 time(s)) — automate it so future runs are one tool call instead of a full agent loop.
