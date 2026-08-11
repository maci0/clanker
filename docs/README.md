# clanker — Reference Documentation

## Architecture

clanker is a self-improving AI agent harness written in Zig 0.16. It runs tools as sandboxed WebAssembly modules via zwasm and improves its own source through a gated loop.

### Agent loop (`src/agent/loop.zig`)

The agent loop is a think-act-observe cycle:
1. *Think*: call the LLM with the conversation and available tool definitions.
2. *Act*: if the response contains tool calls, execute them in the sandbox.
3. *Observe*: feed the tool results back into the conversation.

Sessions are stateful: messages persist across turns and can be saved/restored via `state/sessions/*.json`. Token usage is tracked cumulatively per run. The `Agent.on_token` hook streams content deltas as they arrive; `Agent.on_tool_call` / `Agent.on_tool_result` fire around each tool batch so a caller can show live status instead of going silent while tools run.

### Interactive UX (REPL, `clanker run`)

Both `clanker repl` and `clanker run` render the same live status while a turn is in flight, so there is never a silent gap between hitting enter and seeing output:
- a dim animated braille spinner (`⠋⠙⠹…`) while waiting on the LLM or a tool,
- a `⚙ <tool names>` line when a tool batch starts, and a `↳ <ms>` line when it finishes,
- a bold `›` gutter marking where the model's actual answer begins,
- the answer itself rendered live: `**bold**`, `*italic*`, `` `inline code` ``, fenced blocks, and `- ` bullets turn into real ANSI styling as tokens stream in (`MdStream` in `src/cli.zig`; a marker split across two deltas, e.g. `**` arriving as two 1-byte chunks, is buffered and resolved once the rest arrives),
- a dim stats footer per turn: prompt/completion tokens, wall time, tok/s, cache hit rate, cost.

`clanker run` keeps stdout content-only (safe to pipe: identical bytes whether or not it's a terminal, markdown rendering included — a redirected run gets plain, unstyled text) and puts the spinner/tool status on stderr, gated on `stderr` being a real TTY; the gutter and markdown styling on stdout are gated on `stdout` being a real TTY. So `clanker run "…" > out.txt` stays byte-clean while an interactive shell gets the full live view.

### LLM providers (`src/llm/`)

- **OpenAI-compatible** (`src/llm/client.zig`): works with any OpenAI-compatible endpoint.
- **Anthropic** (`src/llm/providers.zig`): supports Anthropic's native API.
- **deepseek**: OpenAI-compatible provider at `https://api.deepseek.com`.
- **kimi-k3**: OpenAI-compatible provider at `api.moonshot.ai/v1`, supports reasoning.
- **muse-spark** / **muse-spark-1.1**: Anthropic-compatible providers for Muse Spark models.
- **ollama**: local OpenAI-compatible endpoint at `http://127.0.0.1:11434/v1`.
- **vllm-local**: OpenAI-compatible endpoint for a local vLLM server.
- **openai** / **anthropic**: first-party API endpoints.
- **vertex_anthropic**: Anthropic models served by Google Vertex AI. The model name goes in the URL (`.../publishers/anthropic/models/<model>:rawPredict`, `:streamRawPredict` when streaming) and the body carries `anthropic_version` instead of `model`. Set `project`, `location`, and either an access token in `api_key_env` or a `service_account_file`; tokens are minted in-process and cached until they near expiry. `std.crypto.Certificate.rsa` only verifies signatures, so the RS256 assertion Google requires is signed in `src/llm/gcp_jwt.zig` on std primitives: `der` parses the PKCS#8 key, `std.crypto.ff` does the constant-time modular exponentiation, and the RSASSA-PKCS1-v1_5 padding is built by hand. No gcloud, no Python, no subprocess. Tokens renew automatically: the cache is checked on every request and re-mints five minutes before Google's stated expiry, so a long-running `serve` or REPL session never hits an expired token.

Streaming is the Anthropic event vocabulary, not OpenAI's: `content_block_delta` carries `text_delta` for prose and `input_json_delta` fragments for tool arguments, and usage arrives split across `message_start` (input, cache reads) and `message_delta` (output, cumulative). Unknown event types, including `thinking_delta` and `signature_delta`, are ignored rather than treated as errors.

Providers are configured in `config.json` / `config.local.json` (see below).

### Sandbox (`src/sandbox/`)

Tools run in a WebAssembly sandbox using the zwasm runtime. The guest exports `scratch`, `host_arena`, and `run`. Host functions (`env.ck_*`) provide:

The authority is whatever `src/sandbox/runtime.zig` registers with the linker;
a function that exists in `host.zig` and is not registered there is unreachable,
which has been true of eleven of them at once. To list what is actually wired:

```
rg -o 'defineFuncCtx\("env", "[a-z_0-9]+"' src/sandbox/runtime.zig | sort
```

| Function | Purpose |
|----------|---------|
| `ck_log` | Log a message |
| `ck_now` | Get current timestamp |
| `ck_random` | Generate random bytes |
| `ck_http` | Make an HTTP request |
| `ck_fs_read`, `ck_fs_read_range` | Read a file, or a byte range of one |
| `ck_fs_write`, `ck_fs_write_range` | Write a file, or patch a range of one |
| `ck_fs_write_if` | Compare-and-swap write: replace a file's contents only if its current SHA-256 matches the expected hex digest |
| `ck_fs_append` | Append to a file, creating it when absent; locked, so parallel tools cannot overwrite each other |
| `ck_fs_list`, `ck_fs_stat` | List a directory (directories come back with a trailing slash), stat a path |
| `ck_fs_find`, `ck_fs_grep` | Find files by name glob, search file contents |
| `ck_fs_copy`, `ck_fs_rename`, `ck_fs_delete`, `ck_fs_mkdir` | Copy, move, remove a file, create a directory |
| `ck_hash` | SHA-256 of a buffer |
| `ck_env`, `ck_getenv` | Read one environment variable, subject to `env_allow` |
| `ck_exec` | Execute a command in the sandbox |
| `ck_docker` | Run a Docker container (if allowed) |
| `ck_llm` | One-shot model call; denied unless the descriptor sets `"llm": true` |
| `ck_subagent` | Nested bounded agent run; needs a parent agent run to attach to |
| `ck_ask` | Put a multiple-choice question to the human, when one is attached |
| `ck_chat` | Send to or read a chatroom |
| `ck_stats` | Token usage recorded so far |
| `ck_std_api` | Look up a symbol in the Zig standard library source |
| `ck_config` | Return this tool's `config` object from its descriptor |
| `ck_result` | Write the tool result into the host arena |

Host functions write results into the host arena, and the guest reads them back via `ck_result`. Tool definitions in `tools/manifests/*.tool.json` control network and filesystem access.

The tool target is `wasm32-freestanding` (not `wasip1`).

### Self-improvement engine (`src/improve/`)

`clanker improve-self "<instruction>"` runs a gated loop:

1. Collect relevant source files as context.
2. Ask the model for a patch proposal (JSON with `summary`, `rationale`, `changes`).
3. Validate and apply the proposal to a staging copy of the project.
4. Run gates: `zig build`, `zig build test`, `zig build tools`, `zig fmt`, and lint.
5. On green, promote the changes to the live tree and commit as `clanker: <summary> [imp-<id>]`.

The history is stored in `state/history/` and can be reverted with `clanker revert <id>`.

### Evals and gates (`src/evals/`, `src/gate/checks.zig`)

Deterministic evals live in `src/evals/` (harness) with task definitions in `evals/*.task.json`, and run with `clanker eval`. The gates are used both for self-improvement and CI. They include:
- `selfhost_build`: `zig build`
- `selfhost_tests`: `zig build test`
- `selfhost_tools`: `zig build tools`
- plus `zig fmt` and a lint check.

### MCP server (`src/mcp/server.zig`)

`clanker mcp` starts a Model Context Protocol server over stdio (JSON-RPC). It exposes the tool registry to MCP clients.

### Peers (`tools/zig/peers.zig`)

`clanker notify <peer> "<message>"` sends a notification to a peer. `clanker phonebook` lists peer agent cards by fetching `/.well-known/agent.json` from each configured peer URL. Both CLI commands dispatch into the sandboxed `peers` WASM tool (`cmdNotify` in `src/cli.zig`, `cmdPhonebook` in `src/peers/phonebook.zig`) rather than a native HTTP client, so peer traffic is gated by that tool's `network_from_config` allowlist like any model-initiated call.

### Token usage stats (`src/stats/tokens.zig`)

Every LLM completion is recorded at the client choke point to
`state/token_stats.jsonl` and aggregated per (provider, model):
`clanker stats` (table), the `model_stats` WASM tool (so clanker can review
its own spending), and `GET /api/stats`. Each record carries prompt /
completion / total tokens, cache hit & miss, estimated USD cost (from the
model's `cost_per_1m_*`), and call duration. The log is capped at 32 MiB.
Module flag: `modules.token_stats`.

### Chatrooms (`src/peers/chatrooms.zig`)

Clankers can subscribe to named chatrooms and talk to each other. A room is
implicit — created on first message. Sending appends the message to the local
log and fans it out to every configured peer's `POST /api/chat/message`; each
peer keeps the message only when it subscribes to that room.

- State: `state/chatrooms.jsonl` (log), `state/chatrooms-sub.json` (runtime
  join/leave overrides), `state/chatrooms-cursor.json` (inbox cursor).
- Config: `"chatrooms": {"on": true, "rooms": ["dev"], "max_history": 500}`,
  module flag `modules.chatrooms`.
- CLI: `clanker chat send <room> "<text>"`, `clanker chat history <room> [after]`,
  `clanker chat rooms`, `clanker chat subscribe <room> [on]`.
- WASM tools: `chat_send`, `chat_history`, `chat_rooms`, `chat_subscribe`
  (one `chat.wasm` module; the descriptor `config` pins the op). They are
  marked `sequential` so concurrent tool calls never race on the log file.
- Shared board: room-scoped `todo_*` (a `room` param on the shared list) was
  removed once the board covered the same need (see
  `docs/adrs/0002-private-todos-vs-shared-board.md`). `board_add`, `board_move`,
  `board_claim`, `board_update`, `board_log`, `board_subtask`, `board_depend`,
  `board_cost`, `board_list`, `board_delete` (`tools/zig/board.zig`, one
  `board.wasm` module, one op each) work a shared Kanban board folded from
  the board room's chat log (see
  `docs/adrs/0001-board-is-a-chatroom.md`), with subtasks, dependencies, a
  work log and accrued cost per card. A move or claim is announced in the
  board's chatroom, so
  `todo_*` with a `room` set now fails with a pointer to the `board_*`
  replacement.
- Private sub-agent todos: `todo_*` tools called without a `room`
  operate on a per-nested-run in-memory list (`src/agent/private_todos.zig`),
  wired only by `subagent.runNested`. Nothing is logged or fanned out; the
  list is discarded when the run returns, and its final state is appended to
  the sub-agent's answer so the parent sees progress even when the run hits
  its iteration cap. Ids are `p1`, `p2`, ... to keep them distinct from
  shared-list message ids.
- Sub-agents can ask the parent: `ask_user {"parent": true}` in a nested run
  routes the question to the agent that spawned it. The answer is one bounded
  completion on the parent's provider over a snapshot of the parent's
  transcript (`answerAsParent`, `src/agent/loop.zig`) — safe because
  `ck_subagent` joins the nested thread, so the parent is parked with no tool
  of its own in flight while the question is answered.
- HTTP: `POST /api/chat/message` (delivery), `GET /api/chat/messages?room=..&after=..`,
  `GET /api/chat/rooms`.
- Inbox: each agent run injects a `[chatroom inbox]` user message with messages
  newer than the cursor, so a subscribed clanker notices what its peers said.

### Patch application (`tools/zig/patch_apply.zig`)

Proposals are applied via exact-match `old` → `new` replacements, through the sandboxed `patch_apply` WASM tool (`fs_prefixes: ["state/staging"]`). The first occurrence of each `old` is replaced. The improve engine (`src/improve/engine.zig`) decides what to apply and whether to promote the result; the tool only performs the text edits.

## WASM tool ABI

Each tool is a WebAssembly module compiled to `wasm32-freestanding` with these exports:
- `scratch`: a mutable memory region for scratch data.
- `host_arena`: a larger memory region for results.
- `run`: the entry point that takes input and writes output.

The guest imports `env.ck_*` functions listed above. The host writes the tool result into the host arena, and the guest reads it back via `ck_result`.

## Repository layout

One rule: a top-level directory holds the data the agent works with, and `src/<same-name>/` holds the harness code that runs it.

| Data | Code | Contents |
|------|------|----------|
| `tools/` | `src/tools/` | Tool sources, descriptors, and committed WASM |
| `evals/` | `src/evals/` | `*.task.json` eval definitions |
| `skills/` | — | Markdown skills folded into the system prompt |
| `docs/` | — | This reference, the roadmap, review prompts, assets |
| `tests/` | — | Fixtures; the tests themselves live in `test` blocks beside the code |
| `state/` | — | Runtime only, gitignored: `history/`, `logs/`, `runs/`, `sessions/`, `staging/` |

Under `src/`, every module lives in a subsystem directory; only `main.zig`, `cli.zig`, and `config.zig` sit at the top. Build output (`zig-out/`), the fetched dependency cache (`zig-pkg/`), and `.zig-cache/` are generated and gitignored.

## Tool layout

- `tools/zig/` — Zig tool sources.
- `tools/ts/` — AssemblyScript tool sources.
- `tools/manifests/*.tool.json` — tool descriptors, with optional `"internal": true` flag for internal tools (like `webui`).
- `zig-out/tools/` — built WASM binaries from `zig build tools`.
- `tools/bin/` — committed AssemblyScript artifacts (compiled JS/WASM).

Tools are discovered by the registry (`src/tools/registry.zig`) from the configured `tools_dir` (default `tools/manifests`).

## Build and test

| Command | What it does |
|---------|--------------|
| `zig build` | Build the `clanker` binary for the host (musl ABI on linux); `-Dtarget=` cross-compiles |
| `zig build tools` | Compile `tools/zig/*.zig` to `zig-out/tools/*.wasm` |
| `zig build test` | Run the unit and integration tests |
| `zig fmt --check src/ tools/zig/` | Verify formatting |
| `clanker gate` | Run all of the above the way the self-improvement gate does |
| `tools/ts/verify.sh` | Rebuild `tools/ts/*.ts` into a scratch dir and diff against the committed `tools/bin/*.wasm`, to catch drift `clanker gate` cannot see (requires node) |

All of them must pass before a change is promoted, so a tool source that fails to compile blocks the whole loop, not just its own tool. `tools/ts/verify.sh` is not part of `clanker gate` (a node toolchain is not guaranteed) and must be run by hand after editing `tools/ts/`.

## Tool catalog

Every entry in `tools/manifests/` is one WASM module plus its descriptor. `internal: true` hides the tool from the model's tool list: it is reachable only through a REPL slash command or an HTTP route, never chosen by the agent. `fs_prefixes` is the complete filesystem authority the sandbox grants that tool; a tool with no prefixes cannot read or write anything.

Tools the model can call. `clanker tools list` prints the live set; this table
names the ones worth knowing about rather than every entry, since the set
changes as tools are added.

| Tool | Filesystem | Purpose |
|------|------------|---------|
| `calculator` | none | Arithmetic, either `{"a","b","op"}` or `{"expr": "2+3*4"}` (`+ - * / ^`, parentheses, standard precedence) |
| `read_file` | `.` | Read a file by line (`start_line`, `line_count`) or by byte (`offset`, `limit`). Whole lines either way, and a short result says where to resume |
| `list_files` | `.` | What is in a directory, optionally recursive, with a `suffix` filter |
| `find_files` | `.` | Find files by name anywhere under a directory; a pattern with no wildcard matches any name containing it, and a path is split into directory and name |
| `edit_file` | source dirs | Replace an exact, unique piece of a file's text, or create a new file. Refuses a match that is absent or ambiguous, and refuses to create over an existing file unless `overwrite` is set |
| `file_ops` | source dirs | move, copy, delete, mkdir, stat, append and hash. move and copy refuse an existing destination unless `overwrite` is set |
| `lsp` | `.` | Resolve a Zig symbol through zls: where it is defined, or everywhere it is referenced |
| `image` | `.` | Read an image file and return it as a multimodal part, so the model can see it |
| `ask_user` | none | Put a multiple-choice question to the human, to another clanker instance, or (in a sub-agent run) to the parent agent via `{"parent": true}` |
| `forget_note` | `state` | Remove learnings matching a substring, with `dry_run` to see what would go |
| `search_code` | none | Search this project via `{"engine": "rg" \| "ast-grep" \| "semcode", "query", "path"}` |
| `symbols` | none | Find the Zig declaration site of a fn, const, struct, enum, or union |
| `std_api` | none | Look up a Zig 0.16 std signature and docs before writing code against it |
| `code_search` | none | Search open-source code through Sourcegraph |
| `context7` | none | Fetch library documentation (markdown plus examples) from context7.com |
| `fetch_web` | none | HTTP GET a URL and return a truncated body; the host must be allowlisted |
| `web_search` | none | DuckDuckGo HTML search, up to 8 results with title, url, snippet |
| `git` | none | Sandboxed git: `status`, `diff`, `log`, `show`, `add`, `commit`, `ls-files`, `rev-parse`, `branch`. Destructive verbs (`push`, `reset`, `rebase`, `checkout`, `clean`, `rm`, `fetch`, `merge`, `revert`, `stash`) are denied |
| `docker` | none | Query the local Docker daemon over its Unix socket |
| `peers` | `config.json` | Scan peer agent cards (up/down) or post a message to one peer |
| `opencv` | none | Image analysis: size/brightness/sharpness, Canny edges, contours, faces, grayscale, resize |
| `zig_check` | `.` | Fast per-file `zig ast-check` and format check, without the full gate |
| `test_file` | `.` | Run one Zig test file, optionally with `--test-filter` |
| `config_view` | `config.json`, `config.local.json` | Dump the effective config: providers, models, modules, budgets |
| `roadmap` | `docs/` | Read the roadmap and list the planned (unchecked) items |
| `history` | `state/` | Review the improve history: successes, failures, summaries |
| `learnings` | `state/learnings.md` | Read the persisted learnings |
| `write_note` | `state/` | Append a learning to `state/learnings.md`, included in later system prompts |
| `edit_skill` | `skills/` | Write or replace a markdown skill file, changing the agent's own instructions |
| `goal` | `state/` | Design and persist a structured goal that steers later runs |
| `subagent` | none | Delegate a task to a nested sub-agent run (own context, bounded iterations, dedicated thread) |
| `rlm` | none | Recursive Language Model: recursively call a sub-LM over input chunks with bounded depth |
| `reasoning` | `state/` | Read recent reasoning traces recorded from reasoning models (`state/reasoning.jsonl`) |
| `board_add`, `board_move`, `board_claim`, `board_update`, `board_log`, `board_subtask`, `board_depend`, `board_cost`, `board_list`, `board_delete` | none | Work the shared Kanban board (folded from the board room's chat log, not a file): add, move, claim, edit, log progress, manage subtasks/dependencies/cost, list, or delete a card |

Internal tools, never offered to the model:

| Tool | Filesystem | Purpose |
|------|------------|---------|
| `cmd_help` | none | Slash-command reference |
| `cmd_tools` | `tools/manifests/` | List registered tools |
| `cmd_sessions` | `state/sessions/` | List saved sessions |
| `cmd_graph` | `state/runs/` | Render the latest execution graph |
| `cmd_status` | `config.json`, `config.local.json` | Show this instance and its peers |
| `cmd_plugins` | `tools/manifests/`, `state/` | List plugins, toggle the optional ones |
| `cmd_autolearn` | `state/autolearn.jsonl`, `docs/ROADMAP.md` | Aggregate usage observations into roadmap items (`clanker autolearn`) |
| `webui` | none | Serve the self-contained web UI (no external scripts or fonts) at `GET /` |
| `translate` | none | Transform plugin, off by default: translates tool results through `ck_llm` |
| `board` | none | The whole board operation surface behind one entry point, used by `/api/board`; agents use the `board_*` tools instead (same wasm, one op each) |

`tools/manifests/examples/` holds descriptors that are not loaded, such as `calc_ts.tool.json` (the AssemblyScript build of the calculator).

## Plugins

Every tool is a WASM plugin; the descriptor decides how much of the harness it gets.

| Descriptor key | Meaning |
|----------------|---------|
| `internal` | Hidden from the model's tool catalog (slash commands, the web UI, transforms) |
| `enabled` | Default on/off state; ships `false` for anything that spends tokens on its own |
| `llm` | May call the model through `ck_llm`; forces sequential execution |
| `config` | Free-form settings object, returned to the guest by `ck_config` |
| `transform` | Marks the tool as a chain link: `{ "phase": "before"\|"after", "tools": ["*"], "order": 50 }` |
| `network_from_config` | `"peers"` or `"providers"`: the harness adds those configured hosts to `network_allow` at load |
| `exec_allow` | Commands this tool may run through `ck_exec`; replaces the harness default set |
| `fs_prefixes` / `network_allow` | Filesystem and network authority |
| `fuel` | Instruction budget for one call (wasm fuel). Tightens the sandbox default (10B); values above it are clamped down, so a descriptor can never raise its own ceiling |

### Switching plugins on and off

`/plugins` in the REPL lists every tool with its state; `/plugins off <name>` and `/plugins on <name>` toggle one. The choice is written to `state/plugins.json` (`{"disabled": [...], "enabled": [...]}`, machine-local, gitignored) and the running REPL reloads its registry immediately.

Core tools cannot be switched off: those are the `internal` tools with no `transform`, since they back the REPL slash commands and the HTTP routes. Transforms are internal too, but toggling them is the point, so they stay switchable.

### Tools that reach outside the sandbox

Two descriptor keys widen a tool's reach, both opt-in per tool:

`network_from_config` solves a problem a descriptor cannot: peer and provider hosts live in `config.json`, so no static `network_allow` can name them. A tool that sets `"network_from_config": "peers"` gets the configured peer hosts added to its allowlist at load, and adding a peer to config is enough. The `peers` tool uses this to scan agent cards and post notifications.

`exec_allow` replaces the harness's default `ck_exec` set (`git`, `rg`, `ast-grep`, `semcode`, `zig`) with a narrower one. The `opencv` tool declares `"exec_allow": ["uv"]`, so it can run exactly one binary and not, say, `git`.

The `opencv` tool is the shape to copy when a capability has no in-process WASM binding: a `wasm32-freestanding` guest cannot link OpenCV, so the tool shells out to `tools/py/opencv_tool.py` and `uv run --with` supplies `cv2` in a throwaway environment, leaving the host untouched. Path traversal is refused in the guest before the script ever sees the path, and written images land under `state/opencv/`.

### Execution graphs in the web UI

The **Runs** panel picks any recorded run and draws its graph: one row per node, grouped by iteration, with a bar whose width is that node's share of the slowest node in the run. LLM rows carry prompt/completion tokens, tool rows the result size, and the closing `final` row the answer size. The `final` node repeats the duration of the LLM call that produced it, so it is deliberately drawn without a bar rather than counting that time twice.

The panel reads `GET /api/runs` and `GET /api/runs/<run-id>`, both answered by the `cmd_graph` plugin's `json` modes. The harness never reads `state/runs/` itself: run ids are validated as `run-<digits>` before they reach the plugin, and the graph is parsed and re-emitted rather than passed through, so a hand-edited file under `state/runs/` cannot become a response body verbatim.

### Transform chains

A transform plugin wraps other tools instead of being called by the model. `before` transforms rewrite the arguments going into a tool; `after` transforms rewrite the result coming out, in ascending `order`, before it reaches the agent. Each transform receives:

```json
{ "tool": "fetch_web", "phase": "after", "payload": "<the tool's JSON>", "prior": ["redact"] }
```

so a chained plugin knows which tool it is wrapping and which transforms already ran. It answers `{"ok": true, "payload": "<rewritten>"}`, or anything else to decline. A transform that errors, denies, or returns no payload is skipped with a warning and the original payload continues down the chain: a broken filter never takes the tool with it.

### Calling the model from a plugin

A descriptor with `"llm": true` may call `ck_llm(prompt)` and get completion text back. Without it the call is denied. By default the plugin borrows the provider the agent is running on; `config` can aim it elsewhere:

```json
"config": { "provider": "kimi-k3", "model": "kimi-k2.7-code", "max_tokens": 2048 }
```

The harness reads `provider`, `model`, and `max_tokens` to build that call; every other key is the plugin's own and reaches it verbatim through `ck_config`.

The shipped `translate` plugin combines all of it: an `after` transform on every tool, off by default, that asks its configured model to translate the human-readable text in a tool result into `config.lang` before the next layer sees it. It validates that the answer is still JSON and declines rather than passing on corrupted output.

## REPL slash commands

A line starting with `/` is a command; anything else is sent to the agent as a task. Except for the in-process quit commands, `/<name>` dispatches to the internal WASM tool `cmd_<name>` (`src/cli.zig`), so the command set is exactly the `cmd_*` tools in `tools/manifests/`. A bare `exit` or `quit` also leaves the REPL.

| Command | Runs as | Description |
|---------|---------|-------------|
| `/help` | `cmd_help` | List these commands |
| `/tools` | `cmd_tools` | List registered tools |
| `/sessions` | `cmd_sessions` | List saved sessions |
| `/graph` | `cmd_graph` | Show the latest execution graph |
| `/plugins [on\|off <name>]` | `cmd_plugins` | List plugins and switch the optional ones on or off |
| `/status` | `cmd_status` | Show instance and peers |
| `/goal <intent>` | in-process | Design and persist a goal (runs the agent) |
| `/quit`, `/exit`, `/q`, `exit`, `quit` | in-process | Leave the REPL |

### `/graph`

Every agent run records an execution graph and writes it to `state/runs/run-<timestamp>.json` on exit (`src/agent/graph.zig`), unless `modules.graphs` is `false`. `/graph` reads the lexically last of those files, which is the most recent run since the ids sort chronologically, and prints a header plus one line per node grouped by iteration:

```
run-1786365428 — summarize the config
  (kimi-k3, 8421ms, prompt=3190 completion=412)
iter 1
  llm  kimi-k3  3190/180 tok, 5120ms
  tool search_code  2048 B
iter 2
  llm  kimi-k3  3402/232 tok, 3301ms
  done 512 B, stop
```

`llm` lines carry prompt/completion tokens and latency, `tool` lines the result size, and the closing `done` line the final answer size and stop reason. With no runs recorded yet it prints `(no runs yet — clanker run creates one)`. To read an older run, pass its id to the CLI: `clanker graph <run-id>`.

## CLI commands

| Command | Description |
|---------|-------------|
| `help` | Print usage; `--help` / `-h` anywhere does the same |
| `version` | Print the version; `--version` anywhere does the same |
| `init` | Create `config.local.json` and `state/` |
| `providers <check\|models\|catalog\|fill> [name]` | Verify connectivity, list models, search the models.dev catalog, or print catalog specs for configured models |
| `run "<task>"` | Run the agent on a task |
| `repl` | Interactive REPL with streaming (vaxis-backed; the default for a bare `clanker`) |
| `sessions` | List saved sessions |
| `graph [run-id]` | List recorded runs, or render one as an ASCII timeline |
| `tools list` | List registered tools |
| `eval [name]` | Run evals |
| `improve-self "<instructions>"` | Run the self-improvement loop |
| `revert <id>` | Revert a promoted improvement |
| `gate` | Run the full deterministic gate (build/test/tools/fmt/lint) on the current checkout |
| `autolearn` | Aggregate usage from `state/autolearn.jsonl` + `state/runs/` and update the ROADMAP's Autolearn section |
| `git` | Git passthrough (everything after `git` is passed through) |
| `mcp` | Start the MCP server |
| `goal` | Design and persist a structured goal |
| `notify <peer> "<message>"` | Send a notification to a peer |
| `phonebook` | List peer agent cards |
| `chat send <room> "<text>"` | Send a message to a chatroom |
| `chat history <room> [after]` | Read a chatroom's history (newest first) |
| `chat rooms` | List chatrooms and this instance's subscriptions |
| `chat subscribe <room> [on]` | Join or leave a chatroom (`on` = true/false) |
| `stats` | Token usage per provider/model |
| `serve [--port N]` | HTTP server + web UI (default port 17921) |
| `setup` | Guided first run: check config, keys and tools |
| `doctor` | Diagnose config, credentials and build outputs (read-only, offline) |
| `janitor [--yes]` | Sweep up staging copies, old run graphs and improve logs left behind by killed runs (also `clanker prune`) |

## Configuration

`config.json` is the global config; `config.local.json` overrides it, provider by provider. Other sections, including `web`, are replaced as whole sections when the local file names them.

A provider declares its backend once and its models in a map. Per-model settings (`context_window`, `max_tokens`, `temperature`, `reasoning_effort`, `cost_per_1m_input`, `cost_per_1m_output`) belong to the model rather than the provider, because they differ between models sharing one endpoint:

```json
"kimi-k3": {
  "kind": "openai_compat",
  "base_url": "https://api.moonshot.ai/v1",
  "api_key_env": "KIMI_API_KEY",
  "default_model": "kimi-k3",
  "models": {
    "kimi-k3": { "context_window": 1048576, "max_tokens": 16384, "reasoning_effort": "high" },
    "kimi-k2.7-code": { "context_window": 1048576, "max_tokens": 16384 }
  }
}
```

`default_model` is only needed when a provider declares more than one model; with a single model it is inferred, so naming it twice is unnecessary.

The pre-`models` form is **rejected**, not silently accepted:

| In the file | Result |
|-------------|--------|
| `"model": "x"` on the provider | `ProviderLegacyModelFields` — use `"models"` |
| `max_tokens` / `context_window` / `temperature` / `reasoning_effort` on the provider | `ProviderLegacyModelFields` — move it into the model |
| no `"models"` at all | `ProviderMissingModel` |
| `default_model` naming an absent entry | `ProviderDefaultModelUnknown` |
| `default_provider` naming a provider that isn't defined | `DefaultProviderUnknown` |

Each names the provider and the fix. All five fail at startup rather than on the first request, and a settings key on the provider is an error rather than a silent default, because a config that reads one way and behaves another is worse than one that refuses to load.

A key that doesn't belong in its section (a typo like `mx_iterations`) doesn't fail the load — it logs `unknown key '<name>' in <section> (ignored — check spelling)` and falls back to that field's default, so a misspelling is visible in the startup log instead of silently taking effect as "unset."

Full example:

```json
{
  "default_provider": "deepseek",
  "providers": {
    "deepseek": { "kind": "openai_compat", "base_url": "https://api.deepseek.com", "api_key_env": "DEEPSEEK_API_KEY", "default_model": "deepseek-chat", "models": { "deepseek-chat": { "max_tokens": 2048 } } },
    "muse-spark": { "kind": "anthropic", "base_url": "https://api.musespark.ai/v1", "api_key_env": "MUSE_SPARK_API_KEY", "default_model": "spark-v3", "models": { "spark-v3": {} } }
  },
  "agent": {
    "max_iterations": 12,
    "compact_threshold_bytes": 30000,
    "max_total_tokens": 100000,
    "tools_dir": "tools/manifests",
    "sandbox_root": "state/sandbox"
  },
  "peers": [
    { "name": "peer1", "url": "http://127.0.0.1:17922" }
  ],
  "web": {
    "allow": ["github.com", "raw.githubusercontent.com"]
  },
  "instance": { "name": "clanker-1", "id": "abc" },
  "notify": { "topic": "updates" },
  "improve": { "capability_gate": true }
}
```

Fields:
- `providers`: map of provider name → config.
  - `kind`: `"openai_compat"`, `"anthropic"`, or `"vertex_anthropic"` (Anthropic models via Google Vertex AI: requires `project` + `location`, and either `api_key_env` or `service_account_file`; an env var wins over the service account if both are set).
  - `base_url`, `api_key_env`, `path` (endpoint path override; defaults per `kind`), `default_model` (only needed with more than one model), `models` (map of model name → `context_window`, `max_tokens`, `temperature`, `top_p`, `reasoning_effort`, `display`, `cost_per_1m_input`, `cost_per_1m_output`).
  - `kimi-k3` supports reasoning (returns `reasoning` field).
- `agent`:
  - `max_iterations`: max agent loop iterations.
  - `compact_threshold_bytes`: if conversation exceeds this, compact history.
  - `max_total_tokens`: total token budget across the run.
  - `max_tokens_per_turn`, `max_history_tokens`: per-turn input cap and total history budget before compaction kicks in.
  - `tools_dir`, `skills_dir`, `system_prompt_file`, `learnings_file`, `state_dir`: paths the agent reads/writes at runtime.
  - `global_instructions_file`: optional path to device-global operator instructions. When empty (default), clanker loads `$HOME/.agents/AGENTS.md` if present. Missing or empty files are skipped.
  - `sandbox_root`: base directory for file operations in tools.
  - `git_commit`: commit promoted improvements with git (default true).
  - `seed`: sampling seed.
  - `ask_timeout_seconds`: how long a serve-side `ask_user` question waits for the browser before giving up (default 120). Confirm questions share the timeout.
  - `confirm_writes`: gate write-capable tool calls (exec or filesystem access in the descriptor, or `"confirm": true`) on a human's allow/deny. `"never"` (default) asks nobody; `"browser"` asks streaming web runs. `"always"` is reserved for also asking interactive REPL sessions, but `src/tui/repl_vaxis.zig` has no prompt-rendering path to answer it yet, so today `"always"` behaves exactly like `"browser"` — the REPL runs write-capable tools ungated whatever this is set to (tracked in `docs/ROADMAP.md`, "vaxis REPL: close the gap left by the deleted REPL"). Runs with no human channel — headless one-shots, the improve loop, nested sub-agents — are never gated. Read-only tools opt out with `"confirm": false` in their manifest.
  - `tool_catalog`: when true (default), send full schemas only for hot tools and let the model ask for the rest by name.
  - `hot_tools`: how many of the most-used tools keep their schemas loaded without being asked for (default 10).
- `peers`: list of peer agents with `name` and `url`.
- `web`: research-host allowlist for `fetch_web` and `web_search` only.
  - `allow`: hostnames only — no scheme, path, or port. These hosts are appended to each tool's descriptor `network_allow`, so the static hosts remain available. Put machine-specific grants in `config.local.json`.
- `instance`: identity of this agent.
- `notify`: `on` / `topic` for peer notifications.
- `chatrooms`: default room subscriptions (`rooms`, `max_history`) — separate from the `modules.chatrooms` on/off flag.
- `modules`: feature on/off flags (`mcp`, `peers`, `a2a`, `webui`, `graphs`, `sessions`, `goal`, `token_budget`, `streaming`, `dotenv`, `hot_reload`, `autolearn`, `subagents`, `rlm`, `multimodal`, `chatrooms`, `token_stats`). All default to `true`.
- `improve`: settings for self-improvement (`max_context_bytes`, `capability_gate`, `max_cache_bytes`).

### Layered agent instructions

At prompt construction and refresh, clanker appends these instruction files as separate sections, from broadest to narrowest:

1. `$HOME/.agents/AGENTS.md` (or `agent.global_instructions_file`) for device-wide operator rules.
2. `AGENTS.md` for repository-wide shared conventions.
3. `.agents/AGENTS.md` for one developer's additions in this checkout.

The project-local file is gitignored. It is additive: use it for instructions such as a personal Git workflow without editing or replacing the repository's `AGENTS.md`. Missing or blank files are omitted.

Create the local directory before adding the file:

```bash
mkdir -p .agents
```

#### `@path` imports

Instruction files support Claude-compatible `@path` imports. Relative paths resolve against the file that contains the `@` (not necessarily cwd); `~/…` expands with `$HOME`. Nested imports are allowed up to four hops. Missing imports are a soft skip (the `@ref` is dropped), so a shared root `AGENTS.md` can pull in checkout-private rules without breaking clones that lack that file:

```markdown
# Project conventions
…

# Local operator rules (optional; gitignored)
@.agents/AGENTS.md
```

Tools that already understand Claude-style imports (Claude Code, and others that copy it) can expand the same line when they read `AGENTS.md`. Clanker expands imports in all three instruction layers. If root `AGENTS.md` already inlined `.agents/AGENTS.md` via `@`, the dedicated local section is not appended again. Imports inside `` `code spans` `` or fenced code blocks are left literal.

For the authoritative field list and defaults, see the doc comments on each struct in `src/config.zig` — this section is kept in sync by hand and can lag.

## HTTP server

`clanker serve` starts a local HTTP server on port 17921 (override with `--port`). Endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Web UI (rendered by the internal `webui` WASM tool) |
| `/.well-known/agent.json` | GET | Agent card for A2A discovery |
| `/api/status` | GET | Instance + peers status (JSON) |
| `/api/peers` | GET | Every configured peer's live A2A agent card, via the sandboxed `peers` tool (JSON) |
| `/api/runs` | GET | Recorded runs, newest first (JSON) |
| `/api/runs/<run-id>` | GET | One execution graph, node by node (JSON) |
| `/api/notify` | POST | Receive a notification (JSON) |
| `/api/a2a/message` | POST | A2A message handler |
| `/api/run` | POST | Run an agent task and return the response |
| `/api/ask` | POST | Answer an `ask` or `confirm` event a streaming run raised |
| `/api/stats` | GET | Aggregated token usage per provider/model (JSON) |
| `/api/providers` | GET | Configured providers and models (JSON) |
| `/api/goals` | GET, POST | Read or write the persisted structured goal |
| `/api/plugins` | GET, POST | List plugins, or toggle one on/off |
| `/api/plugins/config` | POST | Update a plugin's `config` object |
| `/api/board` | GET, POST | Read or mutate the shared Kanban board |
| `/api/janitor` | GET | How much litter (staging copies, run graphs, improve logs) is reclaimable; read-only, never deletes |
| `/api/logs` | GET | Tail the instance's log output |
| `/api/webui/plugins` | GET, POST | List web UI plugin assets, or toggle one |
| `/webui/plugins/<name>` | GET | Serve a web UI plugin's static asset |
| `/api/chat/message` | POST | Receive a chatroom message fanned out from a peer |
| `/api/chat/messages` | GET | Read a room's message log after a cursor |
| `/api/chat/rooms` | GET | List subscribed chatrooms |
| `/api/chat/send` | POST | Send a message to a chatroom |
| `/api/chat/subscribe` | POST | Join or leave a chatroom |

`GET /` loads the `webui` tool from the registry and renders its output as HTML. It is a real multi-turn chat, not a one-shot form: the page holds a `session` id in `localStorage` and sends it on every `/api/run` call, so replies stay in context (backed by the same `state/sessions/*.json` store as the CLI/REPL `--session`) until "New chat" starts a fresh id.

### `POST /api/run`

Body: `{"task": "...", "stream": bool, "session": "<id>", "goal": "<id>"}`. `session` is optional; when set (and `modules.sessions` is on) the prior transcript is loaded before the turn and saved after. `goal` is optional: when set, that entry from `state/goals.json` is prepended as an `## Active goal` preamble, and an empty `task` becomes a default work order for the goal (what the web UI **Work on this** button sends). When `goal` is omitted and `modules.goal` is on, the newest active goal steers the run automatically.

With `"stream": true`, the response body is `text/plain` and framed line-by-line: plain lines are answer content, verbatim; a line prefixed with byte `0x01` is an out-of-band JSON event instead of content:

```
\x01{"type":"tool_call","names":"git"}
\x01{"type":"tool_result","ms":9}
...plain answer text streams here, unprefixed...
\x01{"type":"done","prompt_tokens":8437,"completion_tokens":185,"cost":0.0281,"ms":10763}
```

With `"stream": true` the run can also ask: when the agent calls `ask_user`, an `{"type":"ask","id":n,"question":"...","options":[...]}` event goes down the stream and the run blocks until `POST /api/ask` with `{"id": n, "answer": "<one of the options>"}` resolves it — any other answer is refused with 400. An unanswered question times out after `agent.ask_timeout_seconds` (default 120) and the tool gets the same "nobody attached" answer a headless run gets, so a closed tab degrades to the model deciding for itself.

With `agent.confirm_writes` set to `"browser"` or `"always"`, a streaming run also confirms: before a write-capable tool call runs, a `{"type":"confirm","id":n,"tool":"git","args_preview":"...","options":["allow","deny"]}` event goes down the stream and the run blocks until `POST /api/ask` answers `"allow"` or `"deny"` (the same endpoint and the same byte-for-byte option check as `ask`). The preview is the call's arguments truncated to 400 bytes. Anything short of an explicit `"allow"` — a deny, a timeout, a closed tab — refuses the call, and the model is told the user declined rather than left hanging.

`error` events (`{"type":"error","message":"..."}`) can appear instead of `done` if the run fails mid-stream. A client must buffer on `\n` and only treat a *complete* line starting with `0x01` as an event — a naive per-chunk check can split an event across two reads. The web UI's line splitter (`tools/zig/webui/index.html`) is the reference implementation.

With `"stream": false`, the response is `{"ok": true, "content": "..."}` (or `{"ok": false, "error": "..."}`) once the run finishes.

## Streaming

The LLM client supports SSE streaming (`client.chatStream`). The agent parses the stream, accumulates tool-call deltas, and invokes `Agent.on_token` for each content token. The REPL and `clanker run` use this to display tokens live; `clanker serve` relays the same deltas over `/api/run`'s `stream: true` framing above.

## Self-improvement loop

1. **Proposal**: model returns JSON `{summary, rationale, changes[]}`.
2. **Staging**: copy project to `state/staging/<id>` and apply changes.
3. **Gates**: run `zig build`, `zig build test`, `zig build tools`, `zig fmt`, lint.
4. **Promote**: if all pass, copy staged files into the live tree.
5. **Commit**: `git commit -m "clanker: <summary> [imp-<id>]"`.
6. **History**: store snapshot in `state/history/` for revert.

Gate failures give feedback to retry.
