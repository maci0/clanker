# clanker — Reference Documentation

External-project digests (what we can learn from them) live in [docs/digests/](digests/).


## Architecture

clanker is a self-improving AI agent harness written in Zig 0.16. It runs tools as sandboxed WebAssembly modules via zwasm and improves its own source through a gated loop.

### Agent loop (`src/agent/loop.zig`)

The agent loop is a think-act-observe cycle:
1. *Think*: call the LLM with the conversation and available tool definitions.
2. *Act*: if the response contains tool calls, execute them in the sandbox.
3. *Observe*: feed the tool results back into the conversation.

Sessions are stateful: messages persist across turns and can be saved/restored via `state/sessions/*.json`. Token usage is tracked cumulatively per run. The `Agent.on_token` hook streams content deltas as they arrive; `Agent.on_tool_call` / `Agent.on_tool_result` fire around each tool batch so a caller can show live status instead of going silent while tools run. `Agent.on_todos` fires after a batch that changed the run's private todo list (`src/agent/private_todos.zig`), and only then, so a viewer can watch the run's own checklist without polling it.

### Interactive UX (REPL, `clanker run`)

Both `clanker repl` and `clanker run` render the same live status while a turn is in flight, so there is never a silent gap between hitting enter and seeing output:
- a dim animated braille spinner (`⠋⠙⠹…`) while waiting on the LLM or a tool,
- a `⚙ <tool names>` line when a tool batch starts, and a `↳ <ms>` line when it finishes,
- a bold `›` gutter marking where the model's actual answer begins,
- the answer itself rendered live: `**bold**`, `*italic*`, `` `inline code` ``, fenced blocks, and `- ` bullets turn into real ANSI styling as tokens stream in (`MdStream` in `src/cli.zig`; a marker split across two deltas, e.g. `**` arriving as two 1-byte chunks, is buffered and resolved once the rest arrives),
- a dim stats footer per turn: `[turn: 1234 in / 567 out · 4.2s · 135.1 tok/s · cache 82% · $0.0031 · ctx 12.3k/128k (10%)]`. One formatter behind both surfaces (`src/tui/stats.zig`): `clanker run` prints it on stderr, `clanker repl` appends it to the transcript as the last line of the turn. A model with no `cost_per_1m_input`/`cost_per_1m_output` in the catalogue drops the `$` segment rather than claiming the turn was free, and a provider that reported no cache accounting drops `cache` rather than showing 0%.

The vaxis REPL adds two things `clanker run` has no use for, since a one-shot run has no history to lose:
- a running `ctx <used>/<window> (<pct>%)` meter, the tokens the session has spent, and its cost so far, in the status bar next to the provider/model,
- a line whenever history is actually dropped. `[history compacted: dropped 12 messages, freed 48 KB]` is the save-time trim against `max_session_tokens`; `[context compacted: N earlier messages replaced by a summary to fit the model window]` is the mid-turn compaction `agent.compact_threshold_bytes` triggers inside the agent loop. Both used to happen silently, which meant a long session could lose the exchange it was about to be asked to remember with nothing on screen.

`clanker run` keeps stdout content-only (safe to pipe: identical bytes whether or not it's a terminal, markdown rendering included — a redirected run gets plain, unstyled text) and puts the spinner/tool status and the per-turn stats footer on stderr, both gated on `stderr` being a real TTY; the gutter and markdown styling on stdout are gated on `stdout` being a real TTY. So `clanker run "…" > out.txt` stays byte-clean while an interactive shell gets the full live view.

### LLM providers (`src/llm/`)

A provider is a **native vtable**, not a WASM module: one struct of function
pointers (`buildRequest`, `parseResponse`, `parseErrorDetail`,
`parseStreamEvent`, `authHeaders`, `endpointUrl`) declared in
`src/llm/providers/api.zig`, implemented by exactly one file under
`src/llm/providers/`, and listed in the single `registry` table in
`src/llm/providers.zig`. Keys must not enter the sandbox and the transport is
on the per-token hot path, which is what rules WASM out:
[docs/adrs/0004](adrs/0004-providers-are-a-native-vtable-not-wasm.md).

`src/llm/client.zig` is the shared HTTP / SSE / retry / token-counting core.
It is deliberately one module for every provider and contains no
`switch (provider.kind)`: it resolves the vtable once per call
(`providers.forKind`) and calls through it. The codec halves are pure
functions of their inputs — no I/O, no credentials — so each provider's
request building and response/stream parsing is unit-tested on the host beside
its own file.

**Adding a provider** is three edits, in fixed places: a new
`src/llm/providers/<name>.zig`, a row in `registry`, and a `ProviderKind` tag
in `src/config.zig` (which is the `kind = "..."` config surface, so it has to
live there; `fromStr` is reflective and needs no change). Nothing else in the
tree learns about it. Where a new provider mostly matches an existing one,
re-export that provider's function pointers rather than copying the codec —
`vertex.zig` does exactly this with `anthropic.zig` and differs only in a body
header, the URL verb and the credential.

- **openai_compat** (`src/llm/providers/openai.zig`): works with any OpenAI-compatible endpoint.
- **anthropic** (`src/llm/providers/anthropic.zig`): Anthropic's native Messages API.
- **vertex_anthropic** (`src/llm/providers/vertex.zig`): the Anthropic codec on Google Vertex AI (details below).
- **deepseek**: OpenAI-compatible provider at `https://api.deepseek.com`.
- **kimi-k3**: OpenAI-compatible provider at `api.moonshot.ai/v1`, supports reasoning.
- **muse-spark** / **muse-spark-1.1**: Anthropic-compatible providers for Muse Spark models.
- **ollama**: local OpenAI-compatible endpoint at `http://127.0.0.1:11434/v1`.
- **vllm-local**: OpenAI-compatible endpoint for a local vLLM server.
- **openai** / **anthropic**: first-party API endpoints.
- **vertex_anthropic**: Anthropic models served by Google Vertex AI. The model name goes in the URL (`.../publishers/anthropic/models/<model>:rawPredict`, `:streamRawPredict` when streaming) and the body carries `anthropic_version` instead of `model`. Set `project`, `location`, and either an access token in `api_key_env` or a `service_account_file`; tokens are minted in-process and cached until they near expiry. `std.crypto.Certificate.rsa` only verifies signatures, so the RS256 assertion Google requires is signed in `src/llm/gcp_jwt.zig` on std primitives: `der` parses the PKCS#8 key, `std.crypto.ff` does the constant-time modular exponentiation, and the RSASSA-PKCS1-v1_5 padding is built by hand. No gcloud, no Python, no subprocess. Tokens renew automatically: the cache is checked on every request and re-mints five minutes before Google's stated expiry, so a long-running `serve` or REPL session never hits an expired token.

**Auth is a separate axis from the wire format**
([docs/adrs/0005](adrs/0005-auth-is-a-strategy-axis-separate-from-wire-kind.md)),
and the split is real in the code: `src/llm/auth.zig` owns **credential
acquisition** — where the secret comes from — while **header application** —
how it rides the request — stays each provider's `authHeaders`. Three
strategies:

- `api_key` — read `api_key_env` and present it the wire kind's way.
- `oauth_static` — a pasted OAuth access token, presented as `Bearer`.
- `oauth_refresh` — a token minted and renewed in-process.

Each provider declares an `auth.Spec` in its registry entry saying which is the
default, how to recognise an OAuth token by shape, and how to mint one.
Anthropic stays zero-config that way: a token starting `sk-ant-oat` (an OAuth
access token from `ant auth login`) is detected as `oauth_static` and sent as
`Authorization: Bearer` with an `oauth-2025-04-20` beta header, while any other
value is `api_key` and goes on `x-api-key`. Vertex is the one `oauth_refresh`
today, minting a GCP token from `service_account_file` — an access token in
`api_key_env` still wins over it. openai_compat is `api_key` by default and
declares no shape detection, because an API key and an OAuth token are not
distinguishable across the many vendors it serves.

Where detection cannot be safe, say so: the optional per-provider
`auth = "api_key" | "oauth_static" | "oauth_refresh"` config key overrides it,
and an unknown value is rejected at load rather than guessed. For an
OpenAI-compatible provider that offers both (xAI, say), the API-key path works
with `api_key_env` alone because both credentials ride `Bearer` there; adding
OAuth is a credential-acquisition concern, not a new header path or a new wire
kind.

Streaming is split the same way. Each provider's `parseStreamEvent` is a pure
`(chunk_arena, payload) -> ?StreamEvent` function; `null` means "ignore this
frame". One `StreamAccumulator` in `client.zig` folds those neutral events into
a `ChatResponse` — text, per-index tool-call fragments, usage and the finish
reason — so the two event vocabularies share one accumulation and one token
accounting path instead of two that can drift. The Anthropic vocabulary:
`content_block_delta` carries `text_delta` for prose and `input_json_delta`
fragments for tool arguments, and usage arrives split across `message_start`
(input, cache reads) and `message_delta` (output, cumulative). Unknown event
types, including `thinking_delta` and `signature_delta`, are ignored rather
than treated as errors.

Providers and models are configured in `config.toml` / `config.local.toml`; the complete field-by-field reference, with per-kind examples and a minimal working config, is [docs/configuration.md](configuration.md).

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
| `ck_llm_many` | One prompt to several provider/model targets at once, each on its own thread, joined before returning: `{"prompt","system","max_tokens","targets":[{"provider","model"}]}` in, a JSON array of `{provider,model,ok,text\|error,ms,tokens}` in target order out. A guest is single-threaded, so a loop of `ck_llm` costs the sum of the models' latencies and this costs the slowest one. One failing target is a failing element, never a failing call. Same `"llm": true` grant and same session token budget as `ck_llm`; capped at 8 targets |
| `ck_subagent` | Nested bounded agent run; needs a parent agent run to attach to |
| `ck_swarm` | Fan-out: run multiple sub-agent tasks concurrently (capped at `max_swarm_tasks`); needs a parent agent run to attach to |
| `ck_tool` | Invoke another WASM tool from within a tool; denied for recursive calls and depth > 0 |
| `ck_ask` | Put a multiple-choice question to the human, when one is attached |
| `ck_chat` | Send to or read a chatroom |
| `ck_stats` | Token usage recorded so far |
| `ck_std_api` | Look up a symbol in the Zig standard library source |
| `ck_config` | Return this tool's `config` object from its descriptor |
| `ck_harness_config` | Return the calling tool's allowlisted slice of clanker's effective config as JSON. Unknown tools are denied; shipped callers receive only providers, peers, or their configured workflow/chain directory as needed |
| `ck_result` | Write the tool result into the host arena |

Host functions write results into the host arena, and the guest reads them back via `ck_result`. Tool definitions in `tools/manifests/*.tool.json` control network and filesystem access.

A guest is single-threaded, so anything a tool wants to do concurrently has to be one host call that fans out, not a loop in the guest. That is what `ck_swarm` (nested agents) and `ck_llm_many` (completions) both are; the reasoning, and the alternatives that were weighed, is [docs/adrs/0006](adrs/0006-fan-out-concurrency-belongs-to-the-host.md).

The tool target is `wasm32-freestanding` (not `wasip1`).

### Isolating a run

Every path a tool touches resolves under one directory, the run's root: `ck_fs_*`
paths are joined onto `agent.sandbox_root`, and `ck_exec` children run there too,
so `git status`, `gate` and `edit_file` all describe the same tree. That single
root is what makes isolation work, and it is the reason the agent is never asked
to keep track of two trees at once.

`clanker run --worktree` isolates a run by moving it: it creates a worktree on a
fresh branch cut from the current one, chdirs into it, and runs there. The
worktree becomes the root, so cwd-relative paths need no prefix and
`git rev-parse --show-toplevel` reports the worktree. `improve-self` takes the
same isolation by default (`src/improve/worktree.zig`). Worktrees live in
`.clanker-worktrees/<id>`, which is gitignored.

Runs cannot read or write each other's worktrees. `ck_exec` refuses a `cwd` and
any argument that names a `.clanker-worktrees` path or steps above the run's root
with `..`, both of which reach a sibling run's tree; a run addresses its own tree
as `.`. The argument half matters as much as the `cwd` half: `worktree` is an
allowed git verb and `remove` is not on the deny list, so
`git worktree remove .clanker-worktrees/<other>` would otherwise have deleted
another run's tree and its commits.

The worktree and its branch are **kept** when the run ends — the commits are the
deliverable. Remove it with `git worktree remove` once the work has landed.
(`improve-self` differs: it merges its branch back at the ref level and only then
removes the worktree.)

#### What is private and what is shared

Isolation covers **git-tracked files only**. Those are the run's own, because
editing them without disturbing anyone else is the entire point.

Everything git does *not* track belongs to the checkout, and an isolated run
reaches it exactly as it would without isolation — same files, same writes, no
snapshot:

| | Resolves to |
|---|---|
| `src/`, `docs/`, `tools/`, `build.zig`, `AGENTS.md`, … (tracked) | the worktree |
| `state/` — sessions, goals, learnings, stats, run graphs | the checkout |
| `.local/`, `.agents/` | the checkout |
| `.env`, `config.local.toml`, `config.local.json` | the checkout |
| `zig-out/`, `.zig-cache/` | the worktree (see below) |

A snapshot would quietly cripple the run: no goal to be steered by, no session to
resume, and its notes and token accounting written where nothing reads them —
each of which looks like a broken tool rather than a missing directory.

Two mechanisms, because two different readers resolve these paths, and both are
needed:

- **Sandboxed tools** go through `Sandbox.shared_root` and the `shared_prefixes`
  list in `src/sandbox/host.zig`, which joins those prefixes onto the checkout
  instead of the run's root. Deliberately not symlinks: `safeJoinSecure` refuses
  to traverse a symlinked component (that is what stops `allowed/link/secret`
  escapes), so a linked `state/` would *deny* every tool that touched it.
- **The harness itself** reads roughly 44 hardcoded relative `state/...` paths
  against the process cwd, so `linkCheckoutState` symlinks these entries into the
  worktree and native I/O follows them. The sandbox never traverses those links,
  because its half routes around them.

`zig-out/` and `.zig-cache/` are untracked but stay per-worktree: builds *write*
there, and a shared `zig-out` lets a worktree's build clobber the binaries the
checkout is using — including the running `clanker`. The part a run needs to
*read*, the guest wasm modules, is pinned to the harness's own build
(`Registry.rebaseWasmPaths`), which is read-only and cannot collide.

`improve-self` provisions its worktree differently (`linkSharedState`): a real
local `state/` with individual entries linked or copied in. Its staging directory
has to be its own, and copying is what keeps a proposal's learnings from escaping
before the proposal is promoted.

What does *not* work is an agent isolating itself: adding a worktree from inside
a run relocates nothing, because the run's root does not move with it. Edits keep
landing in the root while `git -C <worktree> status` reports that worktree clean,
and both halves look like they succeeded. Isolation is a property of how the run
was started, not something the agent can opt into mid-run.

### Self-improvement engine (`src/improve/`)

`clanker improve-self "<instruction>"` runs a gated loop:

1. Collect relevant source files as context. With `improve.plan_phase` on
   (default) the model first proposes a short plan of ideas for the run and
   each iteration implements one, with ideas deduplicated against the run's
   own plan and against past history (`plan.zig`).
2. Ask the model for a patch proposal (JSON with `summary`, `rationale`, `changes`).
   The context is a byte-budgeted slice of a much larger tree, so the model may
   instead answer `{"need": ["src/cli.zig", "docs/ROADMAP.md"], "reason": "..."}`
   and be asked again with those files pinned in for the rest of the run. That
   round does not consume a retry; `improve.max_context_requests` (default 3,
   0 disables) caps how many a run gets. The readable surface is wider than the
   writable one — the gate machinery, `docs/`, and `AGENTS.md` can be read but
   not patched — and excludes `state/`, `.env` and `config.local.*` entirely.
3. Validate and apply the proposal to `state/staging/<id>` inside an isolated
   Git worktree (or the current checkout if worktree creation fails).
4. Run gates: `zig build`, `zig build test`, `zig build tools`, `zig fmt`,
   lint, and (with `improve.capability_gate` on) the deterministic capability
   evals, which `improve.eval_provider` can aim at a cheaper/faster provider
   than the one writing patches. Textual invariants (`gate_invariants` in
   `engine.zig`) additionally assert that load-bearing code — the gate call
   sites themselves, the worktree's shared-state arrays — survives in the
   staged text, so a patch cannot quietly remove its own safety net.
5. On green, promote and commit the changes in that worktree, then merge the
   commit back into the original checkout as `clanker: <summary> [imp-<id>]`.

The history is stored in `state/history/` and can be reverted with `clanker
revert <id>`. Human reverts are a feedback channel, not just an undo: at
startup the loop detects promoted improvements that a person later reverted,
records them as reverted in `state/improvements.jsonl`, and renders them with
their revert reasons in the planning prompt so the same idea is not proposed
again. Hand-written `"class": "veto"` records in the same file work the same
way for features rejected on sight.

### Evals and gates (`src/evals/`, `src/gate/checks.zig`)

Deterministic evals live in `src/evals/` (harness) with task definitions in `evals/*.task.json`, and run with `clanker eval`. The gates are used both for self-improvement and CI. They include:
- `selfhost_build`: `zig build`
- `selfhost_tests`: `zig build test`
- `selfhost_tools`: `zig build tools`
- plus `zig fmt`, a lint check, and — in the improve loop — the capability
  evals (`evals/*.task.json` run against the staged binary) and a
  git-deny-guard that parses staged `config.toml`/`config.local.toml` changes
  and rejects any that would let `exec_pattern_allow` name a git command.

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
  `docs/adrs/0002-private-todos-vs-shared-board.md`). `kanban_add`, `kanban_move`,
  `kanban_claim`, `kanban_update`, `kanban_log`, `kanban_subtask`, `kanban_depend`,
  `kanban_cost`, `kanban_list`, `kanban_delete` (`tools/zig/board.zig`, one
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

Each tool is a WebAssembly module compiled to `wasm32-freestanding` with these
exports:

- `scratch(need) -> u32`: reserve guest memory for the JSON input and return
  its address.
- `host_arena() -> u32`: return the address of the guest's host-result arena.
- `run(ptr, len) -> u64`: process the input bytes and return the output address
  and length packed as `(out_ptr << 32) | out_len`.

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
| `state/` | — | Runtime only, gitignored: `exports/`, `history/`, `logs/`, `runs/`, `sessions/`, `staging/`, `schedule.json` + `schedule/` |

Under `src/`, subsystem code lives in subsystem directories. The executable
entry points and cross-cutting operator commands—`main.zig`, `cli.zig`,
`config.zig`, and `doctor.zig`—sit directly under `src/`. Build
output (`zig-out/`) and `.zig-cache/` are generated and gitignored; Zig's
dependency cache location is controlled by the Zig installation/environment.

## Tool layout

- `tools/zig/` — Zig tool sources.
- `tools/ts/` — AssemblyScript tool sources.
- `tools/manifests/*.tool.json` — tool descriptors, with optional `"internal": true` flag for internal tools (like `webui`). Full field reference: [docs/manifest.md](manifest.md).
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
| `web_search` | none | No-key web search: tries DuckDuckGo Lite first, transparently falls back to Bing Search RSS when DDG is unreachable, bot-challenged, or empty. Input: `{"query", "max_results" (1-20, default 8), "region"}`; returns `{ok, backend, query, count, results:[{title,url,snippet}]}` |
| `git` | none | Sandboxed git: `status`, `diff`, `log`, `show`, `add`, `commit`, `ls-files`, `rev-parse`, `branch`, plus the PR-lifecycle verbs `push`, `merge`, `checkout` when `agent.git_remote_ops` is set in `config.local.toml`. `reset`, `rebase`, `clean`, `rm`, `fetch`, `revert`, `stash` are always denied. Runs at the run's root, the directory the file tools resolve against, so plain `add`/`commit` stage what the agent edited. Value-taking global options (`-C <path>`, `--git-dir <path>`, `--work-tree <path>`) are honored only for paths inside the run's own tree — an argument naming `.clanker-worktrees`, or stepping above the root with `..`, is refused as another run's worktree — and they do not relocate the agent's work: see [Isolating a run](#isolating-a-run) |
| `docker` | none | Query the local Docker daemon over its Unix socket |
| `peers` | none — reads clanker's own config through the host (ck_harness_config) | Scan peer agent cards (up/down) or post a message to one peer |
| `opencv` | none | Image analysis: size/brightness/sharpness, Canny edges, contours, faces, grayscale, resize |
| `zig_check` | `.` | Fast per-file `zig ast-check` and format check, without the full gate |
| `test_file` | `.` | Run one Zig test file, optionally with `--test-filter` |
| `config_view` | `config.toml` via direct file read for the whole-dump path; structured fields via ck_harness_config | Dump the effective config: providers, models, modules, budgets |
| `roadmap` | `docs/` | Read the roadmap and list the planned (unchecked) items |
| `history` | `state/` | Review the improve history: successes, failures, summaries |
| `learnings` | `state/learnings.md` | Read the persisted learnings |
| `write_note` | `state/` | Append a learning to `state/learnings.md`, included in later system prompts |
| `edit_skill` | `skills/` | Write or replace a markdown skill file, changing the agent's own instructions |
| `goal` | `state/` | Design and persist a structured goal that steers later runs |
| `subagent` | none | Delegate a task to a nested sub-agent run (own context, bounded iterations, dedicated thread) |
| `rlm` | none | Recursive Language Model: recursively call a sub-LM over input chunks with bounded depth |
| `arena` | `state/arena/` | Run a bounded, judged debate between two positions, or a 3-8 way Battle Royale, and return a verdict traceable to the move transcript. Rules live in `tools/zig/arena_match.zig` (host-tested); turns go through `ck_llm`, one bounded completion per move |
| `compare` | `state/compare/` | Put one prompt to 2-8 configured models at once and show the answers unlabeled, so a winner is picked on the answer rather than the badge. The entrant calls go through `ck_llm_many`, so they run concurrently; the display order is derived from the comparison id and each model's own names are struck out of its own answer. Rules live in `tools/zig/compare_blind.zig` (host-tested) |
| `reasoning` | `state/` | Read recent reasoning traces recorded from reasoning models (`state/reasoning.jsonl`) |
| `kanban_add`, `kanban_move`, `kanban_claim`, `kanban_update`, `kanban_log`, `kanban_subtask`, `kanban_depend`, `kanban_cost`, `kanban_list`, `kanban_delete` | none | Work the shared Kanban board (folded from the board room's chat log, not a file): add, move, claim, edit, log progress, manage subtasks/dependencies/cost, list, or delete a card |

Internal tools, never offered to the model:

| Tool | Filesystem | Purpose |
|------|------------|---------|
| `cmd_help` | none | Slash-command reference |
| `cmd_tools` | `tools/manifests/` | List registered tools |
| `cmd_sessions` | `state/sessions/` | List saved sessions |
| `cmd_graph` | `state/runs/` | Render the latest execution graph |
| `cmd_status` | none — reads clanker's own config through the host (ck_harness_config) | Show this instance and its peers |
| `cmd_plugins` | `tools/manifests/`, `state/` | List plugins, toggle the optional ones |
| `cmd_autolearn` | `state/autolearn.jsonl`, `docs/ROADMAP.md` | Aggregate usage observations into roadmap items (`clanker autolearn`) |
| `webui` | none | Serve the self-contained web UI (no external scripts or fonts) at `GET /` |
| `translate` | none | Transform plugin, off by default: translates tool results through `ck_llm` |
| `board` | none | The whole board operation surface behind one entry point, used by `/api/board`; agents use the `board_*` tools instead (same wasm, one op each) |

`tools/manifests/examples/` holds descriptors that are not loaded, such as `calc_ts.tool.json` (the AssemblyScript build of the calculator).

## Plugins

Every tool is a WASM plugin; the descriptor decides how much of the harness it gets. **[docs/manifest.md](manifest.md) is the full field reference** — every key the harness honors, what happens when one is wrong, and how to package a plugin that does not live in this repo. The table below is the shortlist.

| Descriptor key | Meaning |
|----------------|---------|
| `manifest_version` | Schema version. Absent means 1; a version this build does not know is refused rather than read under v1 rules |
| `internal` | Hidden from the model's tool catalog (slash commands, the web UI, transforms) |
| `enabled` | Default on/off state; ships `false` for anything that spends tokens on its own |
| `llm` | May call the model through `ck_llm`; forces sequential execution |
| `tool_call` | May call another tool through `ck_tool` (used by `chain`); denied unless true and `tool_allow` allows the target |
| `config` | Free-form settings object, returned to the guest by `ck_config` |
| `transform` | Marks the tool as a chain link: `{ "phase": "before"\|"after", "tools": ["*"], "order": 50 }` |
| `network_from_config` | `"peers"` or `"providers"`: the harness adds those configured hosts to `network_allow` at load |
| `exec_allow` | Commands this tool may run through `ck_exec`, matched against `argv[0]` exactly. Empty is no exec at all, not a default set |
| `fs_prefixes` / `network_allow` | Filesystem and network authority |
| `fuel` | Instruction budget for one call (wasm fuel). Tightens the sandbox default (10B); values above it are clamped down, so a descriptor can never raise its own ceiling |

Check a manifest against all of it with `clanker plugins validate` (one file, or
every `*.tool.json` in a directory), and start a new tool with `clanker plugins
new <name>`, which writes a manifest and a Zig guest that build and validate as
they stand.

### Switching plugins on and off

`/plugins` in the REPL lists every tool with its state; `/plugins off <name>` and `/plugins on <name>` toggle one. The choice is written to `state/plugins.json` (`{"disabled": [...], "enabled": [...]}`, machine-local, gitignored) and the running REPL reloads its registry immediately.

Core tools cannot be switched off: those are the `internal` tools with no `transform`, since they back the REPL slash commands and the HTTP routes. Transforms are internal too, but toggling them is the point, so they stay switchable.

### Tools that reach outside the sandbox

Two descriptor keys widen a tool's reach, both opt-in per tool:

`network_from_config` solves a problem a descriptor cannot: peer and provider hosts live in `config.toml`, so no static `network_allow` can name them. A tool that sets `"network_from_config": "peers"` gets the configured peer hosts added to its allowlist at load, and adding a peer to config is enough. The `peers` tool uses this to scan agent cards and post notifications.

`exec_allow` is the complete list of commands a tool may run through `ck_exec`, matched against `argv[0]` exactly. There is no default set to narrow: a tool that names nothing gets no exec at all (`host.execAllowed`). The `opencv` tool declares `"exec_allow": ["uv"]`, so it can run exactly one binary and not, say, `git`.

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

The shipped `translate` plugin combines all of it: an `after` transform on every tool, off by default, that asks its configured model to translate the human-readable text in a tool result into `config.lang` before the next layer sees it. It validates that the answer is still JSON and declines rather than passing on corrupted output. `mutate` generalizes it with a configurable `instruction`/`lang`/`mode` (`json`|`text`) so one plugin covers translate/summarize/extract/redact. `chain` is the pipeline runner: one call runs N `tool` steps via `ck_tool` interleaved with inline `mutate` reshapes, with `{{prev}}`/`{{prev.field}}`/`{{vars.key}}` substitution and named chains in `chains/*.json` (configurable via `agent.chains_dir`). Workflows may embed a chain pipeline via frontmatter `chain: '[{"tool":"..."}]'`, flagged `[chain]` in the workflows catalog; the `workflows` tool surfaces it with `{"name":"x","chain":""}` and the agent can invoke it through `chain`.

## REPL slash commands

A line starting with `!` is a shell escape (see below), a line starting with `/` is a command, and anything else is sent to the agent as a task. The command set is one table in the source, `command_registry` in `src/tui/repl_vaxis.zig`, which is also what `/help` and Tab-complete are generated from. Some entries dispatch to the internal WASM tool `cmd_<name>`; the rest run in-process, either handling the line themselves or turning it into an agent task. A bare `exit` or `quit` also leaves the REPL.

| Command | Runs as | Description |
|---------|---------|-------------|
| `/help` | `cmd_help` | List these commands |
| `/tools` | `cmd_tools` | List registered tools |
| `/sessions` | `cmd_sessions` | List saved sessions |
| `/graph` | `cmd_graph` | Show the latest execution graph |
| `/plugins [on\|off <name>]` | `cmd_plugins` | List plugins and switch the optional ones on or off |
| `/status` | `cmd_status` | Show instance and peers |
| `/goal <intent>` | in-process | Design and persist a goal (runs the agent) |
| `/arena "<question>" --for X --against Y` | in-process | Run a judged debate (runs the agent, which calls the `arena` tool). `--position` x3-8 for a Battle Royale |
| `/compare "<prompt>" [--with <p[@model]>]...` | in-process | Put one prompt to 2-8 models at once and show the answers unlabeled (runs the agent, which calls the `compare` tool) |
| `/compare --list`, `/compare --show <id> [--pick <letter>]` | `compare` | Read stored comparisons back, and record a pick. Calls the tool directly, with no model in the loop |
| `/quit`, `/exit`, `/q`, `exit`, `quit` | in-process | Leave the REPL |

### `!cmd` — the inline shell escape

A line starting with `!` is a third input mode, checked before the command table above: it runs right there and its output lands in the transcript, and nothing about it is sent to the model.

```
!git log --oneline -5
!rg "fn parseShellEscape" src
```

It is not a shell. The line is split into one fixed argv — whitespace separates arguments, `'…'` or `"…"` groups one argument that contains spaces, there are no backslash escapes — and that argv goes through the same `ck_exec` gate a WASM tool's exec call goes through (`host.execUnderPolicy` → `host.execDenial`). So there are no pipes, redirections, globs or `$VAR` expansion, because there is no shell to expand them; the child also gets the same filtered environment a tool's subprocess gets, which is why an allowed binary cannot print this project's API keys.

The commands it may run are the union of every registered tool's `exec_allow` (`ast-grep`, `gh`, `git`, `rg`, `semcode`, `uv`, `zig`, `zls` as shipped) plus anything in `agent.repl_exec_allow`. A bare `!` prints usage and that list. The rest of the policy still applies: `git` is limited to its local verbs, the deny tokens (`reset`, `rebase`, `rm`, `-f`, …) still refuse, and a refusal is printed as a transcript line saying which token tripped it. A non-zero exit is reported as `[! exit N]`; output is control-stripped like every other untrusted string and capped at 500 lines.

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
| `init` | Create `config.local.toml` and `state/` |
| `providers <check\|models\|catalog\|fill> [name]` | Verify connectivity, list models, search the models.dev catalog, or print catalog specs for configured models |
| `run "<task>"` | Run the agent on a task |
| `repl` | Interactive REPL with streaming (vaxis-backed; the default for a bare `clanker`) |
| `sessions` | List saved sessions |
| `session export <id> [path]` | Write one saved session as a self-contained HTML transcript. Defaults to `state/exports/<id>.html`; a second positional names the file instead. One document, no scripts and no external stylesheet, font or image, so it opens from `file://` with no network. A session's text is model and tool output, so every field is HTML-escaped on the way in (`tools/zig/session_export.zig`) and markup in a transcript renders as the characters that were typed. There is deliberately no upload and no public URL: sharing is copying the file |
| `graph [run-id]` | List recorded runs, or render one as an ASCII timeline |
| `tools list` | List registered tools |
| `plugins [list\|validate [path]\|new <name>]` | List plugins, check a manifest, or scaffold a new tool |
| `eval [name]` | Run evals |
| `improve-self [--provider P] [--model M] [--iters N] [--dry-run] "<instructions>"` | Run the self-improvement loop |
| `revert <id>` | Revert a promoted improvement |
| `gate` | Run the full deterministic gate (build/test/tools/fmt/lint) on the current checkout |
| `autolearn` | Aggregate usage from `state/autolearn.jsonl` + `state/runs/` and update the ROADMAP's Autolearn section |
| `git` | Git passthrough (everything after `git` is passed through) |
| `mcp` | Start the MCP server |
| `goal` | Design and persist a structured goal |
| `arena "<question>" --for X --against Y` | Run a judged debate between two positions; repeated `--position` (3-8) runs a Battle Royale instead. `--judge third` pays a provider that is not fighting to score every move; `--defend <text|file> --alternative <text|file>` runs a design review instead, seeding both sides with a real artifact and returning a review finding; `--match <id>` prints a stored match |
| `compare "<prompt>" --with a --with b@model` | Ask 2-8 models the same prompt concurrently and show the answers unlabeled. Repeated `--with <provider>` or `--with <provider@model>`, or none at all to use every configured provider. `--judge <provider>` names the scorer (default: the configured default provider, with a caveat on the verdict when it is itself an entrant), `--judge none` leaves the pick to you; `--synthesize` merges the answers, `--reveal` prints the label-to-model key with no verdict, `--show <id>` prints a stored comparison and `--show <id> --pick <letter>` records your pick. The web UI's Compare tab is the same thing in a browser: the answers side by side and a pick button per column, reading blind and recording through the same tool op |
| `autoresearch [--target F] [--harness C]` | Measurement-driven research loop: the agent edits targets, the harness scores, the best result wins. `--metric`, `--direction min\|max`, `--pattern`, `--budget`, `--iters`, `--dry-run` |
| `workflow [list\|show <name>\|run <name> [args]]` | List, inspect, or run reusable prompt workflows from `workflows/` |
| `notify <peer> "<message>"` | Send a notification to a peer |
| `phonebook` | List peer agent cards |
| `chat send <room> "<text>"` | Send a message to a chatroom |
| `chat history <room> [after]` | Read a chatroom's history (newest first) |
| `chat rooms` | List chatrooms and this instance's subscriptions |
| `chat subscribe <room> [on]` | Join or leave a chatroom (`on` = true/false) |
| `schedule [list\|add\|remove\|enable\|disable\|run\|run-due\|log]` | Recurring agent runs from `state/schedule.json`; see [Scheduled runs](#scheduled-runs) |
| `stats` | Token usage per provider/model |
| `serve [--host A] [--serve-as N]... [--port N]` | HTTP server + web UI (loopback, port 17921 by default) |
| `setup` | Guided first run: check config, keys and tools |
| `doctor` | Diagnose config, credentials and build outputs (read-only, offline) |
| `janitor [--yes]` | Sweep up staging copies, old run graphs and improve logs left behind by killed runs (also `clanker prune`) |

### `providers check`

A bare `clanker providers check` sweeps every configured provider in config order and reports as it goes, so nothing has to be inferred from silence:

- The `default provider: <name> (from <path>)` line comes first, whatever happens below it.
- A provider that cannot possibly answer — no `base_url`, or an `api_key_env` that is not set in the environment — is reported as `not configured — …, nothing sent` before any socket work, so it costs the sweep nothing.
- Every other provider is announced (`<name>: checking <base_url> — <model> — timeout <n>s`) *before* the request goes out, then gets its result line.
- Each attempt is capped by `agent.provider_check_timeout_seconds` (default 10, `0` disables) or the provider's own `check_timeout_seconds`. A provider that has not answered by then is canceled and reported as timed out, and the sweep moves on.
- The sweep ends with a summary table on stdout: one row per provider with name, status, model, latency, and `*` in the `default` column. Statuses are a closed set — `OK`, `not configured`, `failed` (it answered, with an error status — a model the endpoint does not serve looks like this), `unreachable` (nothing answered: refused, DNS, TLS), `timed out`.

`clanker providers check <name>` checks one provider: the same provenance line and `default=true`/`default=false` marker, no summary table. It exits non-zero when the named provider is unknown (`UnknownProvider`) or did not come back OK (`ProviderCheckFailed`); a full sweep does not fail on a provider that is down.

### Scheduled runs

Recurring agent runs, kept in `state/schedule.json` and recorded in `state/schedule/log.jsonl`. Code: `src/schedule/` (`cron.zig` the dialect, `store.zig` the two files, `runner.zig` the due/claim/fire logic, `command.zig` the operator surface). Full design in [docs/prds/0009-schedule.md](prds/0009-schedule.md).

| Subcommand | What it does |
|---|---|
| `schedule list` | Every entry with its next fire time (the default with no subcommand) |
| `schedule add "<cron>" "<task>"` | Schedule a task. The first run is the first window *after* the add, never immediately |
| `schedule remove <id>` | Drop an entry; its ledger history stays |
| `schedule enable <id>` / `disable <id>` | A disabled entry is never due. Re-enabling counts the next window from now, not from the pause |
| `schedule run <id>` | Fire one entry now, whatever its schedule says — the way to test an entry. Counts as a real run: it advances the window and lands in the ledger marked `manual` |
| `schedule run-due` | Fire everything whose window has passed. What cron calls |
| `schedule log` | The last 20 ledger records, newest first |

Flags: `--provider <p>` / `--model <m>` are recorded on the entry by `add`, so a scheduled run can use a cheaper backend than the default; `--tz-offset <±HH:MM>` sets the fixed offset the cron fields are read at (also `UTC`, or a plain minute count).

**Nothing fires on its own.** There is no background loop and no scheduling thread in `clanker serve` — the system's own cron (or a systemd timer, or launchd) is the clock, which is the decision recorded in [ADR 0008](adrs/0008-the-scheduler-is-cron-driven-not-a-daemon.md):

```
* * * * * cd /path/to/clanker && ./zig-out/bin/clanker schedule run-due
```

`run-due` is built for that: it holds a non-blocking exclusive lock for the whole sweep, so a per-minute cron overlapping a run that takes longer than a minute prints `another 'schedule run-due' is still working` and exits 0 rather than stacking sweeps. It exits non-zero only when an entry it fired came back an error.

**Cron dialect.** Five fields — `minute hour day-of-month month day-of-week` — each `*`, a number, `a-b`, `*/n`, `a-b/n`, or a comma-separated list of those. Sunday is `0` or `7`. Deliberately not accepted, because guessing at a dialect is worse than an error at the point the mistake was made: names (`MON`, `JAN`), `@nicknames` (`@daily`), a seconds field, `L`/`W`/`#`, wrapping ranges (`55-5`), and a step on a bare number (`5/10` — write `5-59/10` or `*/10`). When *both* day fields are restricted the entry fires when **either** matches, as in Vixie cron: `0 0 13 * 5` is "the 13th, and every Friday", not "Friday the 13th". A field counts as unrestricted when it is written `*` or `*/n`; `*/2,15` is a set the writer chose and is treated as one. A spec that parses but can never come around (`0 0 30 2 *`) is refused by `add`.

**Time zones.** Fields are read in UTC, shifted by the entry's own fixed `--tz-offset`. There is no time zone database in the binary and therefore no DST handling: an entry at `+01:00` stays at `+01:00` all year, so a wall-clock-sensitive job needs its offset edited twice a year. The reasoning is in [ADR 0009](adrs/0009-schedule-fires-on-fixed-utc-offsets.md); the payoff is that `src/schedule/cron.zig` is pure and every awkward case (leap years, month lengths, an offset crossing a UTC date boundary) is a host unit test.

**Missed runs fire once and are never backfilled.** An entry's `last_run` records the moment it *ran*, not the slot it ran *for*, so the next window is computed from wake time. A machine that slept through a day of a `*/5` entry fires it exactly once on waking, counts the 286 windows in between into the ledger's `skipped`, and resumes on the normal grid. Backfilling would mean 288 agent runs and a real bill for answers that stopped being interesting hours ago.

`run-due` claims a window — writes `last_run` and `runs += 1` — *before* it calls the model, then re-opens the store afterwards to record the outcome. A sweep killed halfway therefore leaves the entry looking fired (at-most-once, rather than a crash loop that bills per iteration), and an `enable`/`disable` that landed while the model was working survives the write.

**Ledger.** `state/schedule/log.jsonl`, one JSON object per line, the same shape `state/arena/log.jsonl` uses: `{ts, id, cron, task, trigger, due_at, skipped, ok, duration_ms, err}`. `trigger` is `due` or `manual`; `due_at` is the window that made the entry due, which differs from `ts` because cron granularity is a minute and `run-due` may be seconds late. Trimmed oldest-first at 4 MiB.

The shell scripts `clanker-improve.sh` and `clanker-review.sh` are still driven from outside the binary; nothing in them has moved into `schedule`. What `schedule` replaces is a crontab line calling `clanker run "<prompt>"`.

## Configuration

`config.toml` is the global config; `config.local.toml` overrides it, provider by provider. Other sections, including `web`, are replaced as whole sections when the local file names them. TOML is the only supported config format; a leftover pre-migration `.json` file is ignored entirely (and `clanker doctor` warns about it) rather than half-supported.

A provider declares its backend once (`[providers.<name>]`); its models live in a separate, top-level `[models."<provider>/<model>"]` table, keyed by that composite id, each entry naming its own `provider` — inspired by Kimi Code's config.toml shape. Per-model settings (`context_window`, `max_tokens`, `temperature`, `reasoning_effort`, `cost_per_1m_input`, `cost_per_1m_output`, `capabilities`) belong to the model rather than the provider, because they differ between models sharing one endpoint:

```toml
[providers.kimi-k3]
kind = "openai_compat"
base_url = "https://api.moonshot.ai/v1"
api_key_env = "KIMI_API_KEY"
default_model = "kimi-k3"

[models."kimi-k3/kimi-k3"]
provider = "kimi-k3"
context_window = 1048576
max_tokens = 16384
reasoning_effort = "high"
capabilities = ["thinking", "tool_use"]

[models."kimi-k3/kimi-k2.7-code"]
provider = "kimi-k3"
context_window = 1048576
max_tokens = 16384
```

`default_model` is only needed when a provider declares more than one model; with a single model it is inferred, so naming it twice is unnecessary. `capabilities` (e.g. `"tool_use"`, `"image_in"`, `"video_in"`, `"audio_in"`, `"thinking"`, `"always_thinking"`) self-documents what the model supports. It is mostly informational, but one thing gates on it: a model that declares its capabilities while omitting `image_in` is treated as non-vision, so the webui refuses image attachments to it up front (DeepSeek v4-flash's endpoint rejects `image_url` blocks with an opaque deserialize 400), and a model with no `capabilities` declared is left unknown and the attachment is attempted. `clanker providers fill <name>` prints a ready-to-paste `[models."<provider>/<name>"]` block per configured model, including `capabilities`, from the [models.dev](https://models.dev) catalog (`limit.context` → `context_window`, `cost.input`/`cost.output` → `cost_per_1m_input`/`cost_per_1m_output`, `reasoning`/`tool_call`/`modalities` → `capabilities`); it never writes the file, so a human stays in the loop for the merge.

Providers do not store API keys directly — `api_key_env` names an environment variable instead, loaded from `.env` (`modules.dotenv`) or the process environment.

The pre-`models`-table form is **rejected**, not silently accepted:

| In the file | Result |
|-------------|--------|
| `model` on the provider | `ProviderLegacyModelFields` — declare the model in the top-level `models` table instead |
| `max_tokens` / `context_window` / `temperature` / `reasoning_effort` on the provider | `ProviderLegacyModelFields` — move it into the model |
| `models` nested under the provider (the pre-Kimi-restructure shape) | `ProviderLegacyModelFields` — move it to the top-level `models` table |
| a `models."<provider>/<model>"` entry naming no `provider`, or whose key doesn't start with `"<provider>/"` | `MissingField` / `ModelKeyProviderMismatch` |
| a `models` entry naming a `provider` that isn't declared under `providers` | `ModelUnknownProvider` |
| a provider ending up with no models at all | `ProviderMissingModel` |
| `default_model` naming an absent entry | `ProviderDefaultModelUnknown` |
| `default_provider` naming a provider that isn't defined | `DefaultProviderUnknown` |

Each names the provider (or model key) and the fix. All fail at startup rather than on the first request, and a settings key on the provider is an error rather than a silent default, because a config that reads one way and behaves another is worse than one that refuses to load.

A key that doesn't belong in its section (a typo like `mx_iterations`) doesn't fail the load — it logs `unknown key '<name>' in <section> (ignored — check spelling)` and falls back to that field's default, so a misspelling is visible in the startup log instead of silently taking effect as "unset."

Internally, `Config.load` distributes the top-level `models` table into each `Provider`'s own `models` map at load time (`distributeModels` in `src/config.zig`), so everything downstream — `Provider.activeModel()`, `resolveProvider`, the LLM client, the agent loop's context budgeting — still sees the same per-provider model map it always has. Only the on-disk shape changed; wasm guest tools that need structured config fields (`peers`, `providers`, `cmd_status`, `ask_user`) go through a `ck_harness_config` host function rather than reading `config.toml` themselves, since a `wasm32-freestanding` guest carries no TOML parser — `config_view` is the exception, since its whole-file dump only needs the raw bytes, not structured fields.

Full example:

```toml
default_provider = "deepseek"

[providers.deepseek]
kind = "openai_compat"
base_url = "https://api.deepseek.com"
api_key_env = "DEEPSEEK_API_KEY"
default_model = "deepseek-chat"

[providers.muse-spark]
kind = "anthropic"
base_url = "https://api.musespark.ai/v1"
api_key_env = "MUSE_SPARK_API_KEY"
default_model = "spark-v3"

[models."deepseek/deepseek-chat"]
provider = "deepseek"
max_tokens = 2048

[models."muse-spark/spark-v3"]
provider = "muse-spark"

[agent]
max_iterations = 12
compact_threshold_bytes = 30000
max_total_tokens = 100000
tools_dir = "tools/manifests"
sandbox_root = "state/sandbox"

[[peers]]
name = "peer1"
url = "http://127.0.0.1:17922"

[web]
allow = ["github.com", "raw.githubusercontent.com"]

[instance]
name = "clanker-1"
id = "abc"

[notify]
topic = "updates"

[improve]
capability_gate = true
arena_advisory = false
```

Fields:
- `providers`: map of provider name → connection settings.
  - `kind`: `"openai_compat"`, `"anthropic"`, or `"vertex_anthropic"` (Anthropic models via Google Vertex AI: requires `project` + `location`, and either `api_key_env` or `service_account_file`; an env var wins over the service account if both are set).
  - `base_url`, `api_key_env`, `path` (endpoint path override; defaults per `kind`), `default_model` (only needed with more than one model).
  - `check_timeout_seconds`: how long `providers check` waits for this endpoint before reporting it as timed out, overriding `agent.provider_check_timeout_seconds` for this provider alone. Unset takes the global default; `0` means no ceiling. For a LAN endpoint that either answers instantly or is switched off, a second or two is plenty, while a hosted provider wants the longer global default.
  - `kimi-k3` supports reasoning (returns `reasoning` field).
- `models`: top-level map of `"<provider>/<model>"` → model settings: `provider` (required — which entry under `providers` this belongs to), `context_window`, `max_tokens`, `temperature`, `top_p`, `reasoning_effort`, `display`, `cost_per_1m_input`, `cost_per_1m_output`, `capabilities`.
- `agent`:
  - `max_iterations`: max agent loop iterations.
  - `compact_threshold_bytes`: if conversation exceeds this, compact history.
  - `max_total_tokens`: total token budget across the run.
  - `max_tokens_per_turn`, `max_history_tokens`: per-turn input cap and total history budget before compaction kicks in.
  - `tools_dir`, `skills_dir`, `system_prompt_file`, `learnings_file`, `state_dir`: paths the agent reads/writes at runtime.
  - `global_instructions_file`: optional path to device-global operator instructions. When empty (default), clanker loads `$HOME/.agents/AGENTS.md` if present. Missing or empty files are skipped.
  - `sandbox_root`: the run's root. `ck_fs_*` paths resolve under it and `ck_exec`
    children run in it, so the file tools and the commands agree on one tree
    (see [Isolating a run](#isolating-a-run)).
  - `git_commit`: commit promoted improvements with git (default true).
  - `git_remote_ops`: when true, let the `git` tool run the PR-lifecycle verbs it otherwise cannot — `push`, `merge`, `checkout` (default false). Scoped to the `git` command only; `reset`, `rebase`, `clean`, `rm`, `fetch`, `-f`, … stay denied. This is the machine-local flip that lets the agent open and merge PRs unaided; set it in `config.local.toml`, not the committed example.
  - `exec_pattern_allow`: whole-command-line glob patterns a tool may run through `ck_exec`, e.g. `"gh pr create*"` or `"gh pr merge*"`. When a pattern names a command, that command becomes strict: only an argv matching one of its patterns runs, and the match also overrides the deny tokens for the args it grants (`"gh pr merge"` legitimately contains `"merge"`). Commands with no pattern stay under the deny-list check, so a pattern for `gh` does not widen `git` or anything else. `*` matches any run of characters, including across spaces and empty. The `gh` tool refuses to run at all unless a matching pattern is configured.
  - `repl_exec_allow`: extra commands the REPL's `!cmd` escape may run, e.g. `["ls", "cat"]`. Empty (default) means `!` runs exactly the union of every registered tool's `exec_allow` and nothing more, so the escape starts with no authority the harness did not already have. Nothing but the REPL reads this, so widening it never widens a tool, and the rest of the policy — the deny tokens, `git`'s verb allowlist, `exec_pattern_allow` — still applies to whatever is named here.
  - `seed`: sampling seed.
  - `ask_timeout_seconds`: how long a serve-side `ask_user` question waits for the browser before giving up (default 120). Confirm questions share the timeout.
  - `provider_check_timeout_seconds`: how long `providers check` waits for one provider before reporting it as timed out and moving on (default 10). Without a ceiling a single unreachable endpoint costs the whole sweep the OS connect timeout (~75s on macOS). `0` disables the ceiling; `[providers.<name>] check_timeout_seconds` overrides it per provider.
  - `confirm_writes`: gate write-capable tool calls (exec or filesystem access in the descriptor, or `"confirm": true`) on a human's allow/deny. `"never"` (default) asks nobody; `"browser"` asks streaming web runs. `"always"` is reserved for also asking interactive REPL sessions, but `src/tui/repl_vaxis.zig` has no prompt-rendering path to answer it yet, so today `"always"` behaves exactly like `"browser"` — the REPL runs write-capable tools ungated whatever this is set to (tracked in `docs/ROADMAP.md`, "vaxis REPL: close the gap left by the deleted REPL"). Runs with no human channel — headless one-shots, the improve loop, nested sub-agents — are never gated. Read-only tools opt out with `"confirm": false` in their manifest.
  - `tool_catalog`: when true (default), send full schemas only for hot tools and let the model ask for the rest by name.
  - `hot_tools`: how many of the most-used tools keep their schemas loaded without being asked for (default 10).
- `peers`: list of peer agents with `name` and `url`.
- `web`: research-host allowlist for `fetch_web` and `web_search` only.
  - `allow`: hostnames or glob patterns — no scheme, path, or port. Each entry matches the exact hostname or a `*`/`?` glob (e.g. `"*.github.com"` matches any subdomain, and a bare `"*"` allows every host). These are appended to each tool's descriptor `network_allow`, so the static hosts remain available. Put machine-specific grants in `config.local.toml`.
- `instance`: identity of this agent.
- `notify`: `on` / `topic` for peer notifications.
- `chatrooms`: default room subscriptions (`rooms`, `max_history`) — separate from the `modules.chatrooms` on/off flag.
- `modules`: feature on/off flags (`mcp`, `peers`, `a2a`, `webui`, `graphs`, `sessions`, `goal`, `token_budget`, `streaming`, `dotenv`, `hot_reload`, `autolearn`, `subagents`, `rlm`, `multimodal`, `chatrooms`, `token_stats`). All default to `true`.
- `improve`: settings for self-improvement.
  - `max_context_bytes`: byte budget for the proposal context slice.
  - `max_context_requests`: how many `{"need": [...]}` context refills a run gets (default 3, 0 disables).
  - `capability_gate`: run the deterministic capability evals as a promotion gate (default true).
  - `arena_advisory`: run an advisory Arena match ("promote this proposal" vs "reject this proposal") before the capability evals (default false). Advisory only by construction: the verdict is logged and can ride along with a real gate failure's feedback, but no gate consults it and it cannot reject a proposal. Costs several model calls per attempt, which is why it is off.
  - `eval_provider`: provider name the staged capability-eval agents run on, so a fast/cheap model can score capability while a stronger one writes patches. Unset uses the loop's own provider.
  - `plan_phase`: plan-then-patch — propose a deduplicated idea list once per run, then implement one idea per iteration (default true).
  - `inert_gate`: reject changes classified as doing nothing observable (default true).
  - `max_consecutive_test_only`: how many test-only changes may land in a row before one must touch behavior (default 3).
  - `max_cache_bytes`: cap on the staging build cache before it is dropped.

### Environment variables

- `CLANKER_ENV_FILE`: path to the `.env`-style file `dotenv.load` reads (default `./.env`; gated by `modules.dotenv`). Real environment variables always win over values loaded from this file. See `.env.example` for the keys providers reference via `api_key_env`.
- `CLANKER_LOG_LEVEL`: `debug` | `info` | `warn` | `error` (default `info`). Lets a headless deployment (systemd, docker) set the log level without editing the invocation. `--verbose`/`-v` still overrides it to `debug` when both are given.
- `CLANKER_THEME`: palette name for the REPL and `clanker run` output (`mocha`/`catppuccin`, `latte`, `frappe`, `macchiato`, `tokyonight`, `storm`, `day`, `mono`, `default`). An env var because a theme is a property of the terminal, not of one invocation. `/theme <name>` overrides it per session.
- `CLANKER_DEBUG_BODY`: set to any value to log provider name and request byte count on each LLM call (to stderr). Only metadata is printed, never request content.
- `NO_COLOR`: standard ([no-color.org](https://no-color.org)) opt-out of colored output. When set to any non-empty value, forces the `mono` theme.

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

`clanker serve` starts an HTTP server on `127.0.0.1:17921` (override the interface with `--host`, the port with `--port`). Endpoints:

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
| `/api/arena` | GET | List past arena matches |
| `/api/arena/<id>` | GET | One match: combatants, HP, per-round moves and the verdict. The arena view polls this while a match is running and stops on the verdict |
| `/api/compare` | GET | List past blind comparisons. Read blind: each row says whether a judge reached a verdict, never whose, since a winning provider name beside a verdict letter is the key to a two-way comparison |
| `/api/compare/<id>` | GET, POST | GET reads one comparison blind — the answers in their stored order under `A`/`B`/`C`, with no provider or model anywhere in the reply. POST `{"pick":"<letter>"}` records the human's pick through the same tool op `clanker compare --show <id> --pick <letter>` uses, and the reply is revealed |
| `/api/sessions/search?q=` | GET | Every saved conversation with a message containing `q`, newest first, one row each: the first match in context plus a count of the others in that conversation. Case-insensitive substring, not the fuzzy match the sidebar filter uses on titles, because fuzzy over whole transcripts matches nearly everything. Queries under 3 characters return an empty result rather than an error, and the list is capped at 50 with `truncated` set |
| `/api/schedule` | GET | Every scheduled entry with its next fire time, plus the last 20 ledger records. The next-fire reading is the one `clanker schedule list` prints, and it is omitted rather than zeroed when an entry can never fire (disabled, or a spec that parses to nothing) |
| `/api/schedule/<id>` | POST | `{"enabled":true\|false}` pauses or resumes one entry, writing the same `state/schedule.json` `clanker schedule enable\|disable` writes. Resuming re-dates the window from now, so an entry parked for a month does not come back owing a run. Firing is deliberately not here: that is `run`/`run-due`, from cron or a terminal |
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

### Binding and the trust model

There is no authentication. The server exposes the full agent: `/api/run` runs a task, tools exec and write, and `/api/ask` answers write confirmations. Anyone who can reach the port can do all of it. Two things keep that from being a network-facing surface by default, and only the first is about the network:

- **What it binds.** `--host` sets the interface, default `127.0.0.1`, so out of the box nothing off this machine can connect at all. `--host 0.0.0.0` (or `::`) makes it reachable from the LAN. That is opt-in and still unauthenticated: past loopback, the access control is a firewall or a network you trust, not clanker.
- **Which authority it answers to.** Binding loopback stops remote connections but not DNS rebinding: a hostile name can resolve to `127.0.0.1` and make a browser treat this control plane as its own origin. So every request, GET included, is checked against the authority in its `Host` header (`unexpectedHost` in `src/cli.zig`) and refused with `421 Misdirected Request` when it does not match. The same rule gates the `Origin` header on state-changing requests, as CSRF protection.

The authority rule is:

| Authority | Served |
|-----------|--------|
| `127.0.0.1:17921`, `192.168.1.5:17921`, `[::1]:17921`, any IP literal at the listen port | yes |
| `localhost:17921` | yes |
| a name passed to `--serve-as`, at the listen port or with no port | yes |
| any other name, e.g. `attacker.example:17921` | no |
| any authority at a different port, or missing/duplicate `Host` | no |

An IP literal is accepted because DNS rebinding needs a *name* whose resolution the attacker controls, and there is no resolution step to subvert in a literal. That is what makes `--host 0.0.0.0` usable on its own: a LAN client browsing to `http://192.168.1.5:17921/` is served. A name is not accepted on the same reasoning, so reaching the server through a real hostname (a reverse proxy, a `.lan` entry, a tailnet name) means naming it:

```sh
clanker serve --host 0.0.0.0 --serve-as clanker.lan
```

`--serve-as` is repeatable, matched case-insensitively, and takes `--serve-as x` or `--serve-as=x`. Hot reload re-execs with the same `--host`, `--port` and `--serve-as` set, so a rebuild does not quietly narrow the policy.

### `POST /api/run`

Body: `{"task": "...", "stream": bool, "session": "<id>", "goal": "<id>", "images": [...]}`. `session` is optional; when set (and `modules.sessions` is on) the prior transcript is loaded before the turn and saved after. `goal` is optional: when set, that entry from `state/goals.json` is prepended as an `## Active goal` preamble, and an empty `task` becomes a default work order for the goal (what the web UI **Work on this** button sends). When `goal` is omitted and `modules.goal` is on, the newest active goal steers the run automatically.

`images` is an optional array of `{"mime", "b64"}` image attachments (the webui composer's paste/drop path, and the `image` tool's result). Each decoded image is capped at 4 MB and at most 4 per message. Attaching images requires `modules.multimodal` to be on: a run with images while it is off returns a 400 naming the flag, rather than silently dropping the attachment. A model that declares its capabilities without `image_in` is refused image attachments with a 400 naming the model (its endpoint, like DeepSeek v4-flash's, rejects the `image_url` blocks with an opaque deserialize error); a model with no `capabilities` declared is attempted and a provider 400 on an image-bearing run is surfaced with the provider name and a hint that the model may not support vision. The provider request carries the images in each provider family's native format — OpenAI-compatible sends `image_url` data URIs; Anthropic/Vertex send base64 `image` content blocks.

With `"stream": true`, the response body is `text/plain` and framed line-by-line: plain lines are answer content, verbatim; a line prefixed with byte `0x01` is an out-of-band JSON event instead of content:

```
\x01{"type":"tool_call","names":"git"}
\x01{"type":"tool_result","ms":9}
...plain answer text streams here, unprefixed...
\x01{"type":"done","prompt_tokens":8437,"completion_tokens":185,"cost":0.0281,"ms":10763}
```

With `"stream": true` the run can also ask: when the agent calls `ask_user`, an `{"type":"ask","id":n,"question":"...","options":[...]}` event goes down the stream and the run blocks until `POST /api/ask` with `{"id": n, "answer": "<one of the options>"}` resolves it — any other answer is refused with 400. An unanswered question times out after `agent.ask_timeout_seconds` (default 120) and the tool gets the same "nobody attached" answer a headless run gets, so a closed tab degrades to the model deciding for itself.

With `agent.confirm_writes` set to `"browser"` or `"always"`, a streaming run also confirms: before a write-capable tool call runs, a `{"type":"confirm","id":n,"tool":"git","args_preview":"...","options":["allow","deny"]}` event goes down the stream and the run blocks until `POST /api/ask` answers `"allow"` or `"deny"` (the same endpoint and the same byte-for-byte option check as `ask`). The preview is the call's arguments truncated to 400 bytes. Anything short of an explicit `"allow"` — a deny, a timeout, a closed tab — refuses the call, and the model is told the user declined rather than left hanging.

A streaming run also reports its own checklist. Whenever a `todo_*` call changes the run's private todo list, a `{"type":"todos","todos":[{"todo":"p1","title":"...","status":"open|claimed|closed"}]}` event goes down the stream and the web UI renders it as a checklist in the turn card. It is the whole list every time, not a delta, so a client that missed an event is never out of step. Nothing is persisted and there is no endpoint to fetch it from: the list lives in memory for the duration of the run (see [prds/0003-run-todos.md](prds/0003-run-todos.md)), and reading it with `todo_list` is not a change, so a run that polls its own list does not emit an event per poll. Shared, durable work is the board (`/api/board`), not this.

`error` events (`{"type":"error","message":"..."}`) can appear instead of `done` if the run fails mid-stream. A client must buffer on `\n` and only treat a *complete* line starting with `0x01` as an event — a naive per-chunk check can split an event across two reads. The web UI's line splitter (`tools/zig/webui/index.html`) is the reference implementation.

With `"stream": false`, the response is `{"ok": true, "content": "..."}` (or `{"ok": false, "error": "..."}`) once the run finishes.

## Streaming

The LLM client supports SSE streaming (`client.chatStream`). The agent parses the stream, accumulates tool-call deltas, and invokes `Agent.on_token` for each content token. The REPL and `clanker run` use this to display tokens live; `clanker serve` relays the same deltas over `/api/run`'s `stream: true` framing above.

## Self-improvement loop

1. **Proposal**: model returns JSON `{summary, rationale, changes[]}`.
2. **Isolation**: create a temporary Git worktree and branch. If that is not
   possible, continue in the current checkout.
3. **Staging**: copy the project to `state/staging/<id>` within that checkout
   and apply changes through the sandboxed `patch_apply` tool.
4. **Gates**: run `zig build`, `zig build test`, `zig build tools`, `zig fmt`, lint.
5. **Promote**: if all pass, copy staged files into the worktree checkout.
6. **Commit**: commit there as `clanker: <summary> [imp-<id>]`, merge the
   commit back into the original checkout, and remove the temporary worktree.
7. **History**: store snapshots in `state/history/` for revert.

Gate failures give feedback to retry.
