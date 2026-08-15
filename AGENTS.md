# clanker — project conventions

clanker is a self-improving AI agent harness written in **Zig 0.16.0**. It runs
its tools as sandboxed WebAssembly modules (zwasm) and improves its own source
through a gated loop. Follow these conventions when changing this codebase.

## Build & test

- `zig build` — build the `clanker` harness for the host (musl ABI on linux).
  Cross-compile with `-Dtarget=`, e.g. `-Dtarget=x86_64-linux-musl`.
- `zig build tools` — compile `tools/zig/*.zig` to `zig-out/tools/*.wasm`.
- `zig build test` — run unit + integration tests. All tests must pass before
  any change is accepted. Tests live in `test` blocks inside the source files.
  New `src/` modules must be referenced from the `comptime` block in
  `src/main.zig` or their tests never run. Pure-logic `tools/zig/` helpers
  (no guest ABI) go in `host_tested_helpers` in `build.zig` instead; wasm
  guests cannot run their own `test` blocks.
- `zig build e2e` — black-box end-to-end tests, driving the built binary
  against a mock LLM server. Not part of `zig build test`; run it separately.
- `zig build run` — build and run the harness in one step.
- `zig build proxy` — build `clanker-proxy`, the OpenAI/Anthropic
  compatibility proxy as a standalone binary (no web UI, agent, TUI, or tool
  host). Not part of the default install.
- `clanker gate` — run build, test, tools, fmt, lint, and release-contract
  gates. Release policy and version source of truth: [RELEASES.md](RELEASES.md);
  consumer-visible changes: [CHANGELOG.md](CHANGELOG.md).

## Zig style

- Target Zig 0.16 APIs: `std.Io` (Dir/File/Threaded), `std.process.Init`,
  `std.json.Stringify` + `parseFromSliceLeaky`, `std.ArrayList` with
  `.empty` + `append(alloc, ...)`. `@intFromFloat` is `@trunc` (or `@floor`/
  `@round`) with an integer dest type; `@trunc(opt orelse 800)` treats the
  default as comptime_float, so bind the `f64` first. `@intCast` of a
  `jsonInt` into `u32`/`u64` wraps a negative in ReleaseFast (`max_tokens
  = -1` became a 4G completion cap); unsigned config ints go through
  `jsonUnsigned`.
- No libc-dependent code in the harness beyond what the build links.
- Allocators are explicit; arena for run-scoped data, gpa for ownership.
- New code must be `zig fmt` clean (the improve gate auto-formats and checks).
- Closed name tables use `std.StaticStringMap.initComptime` (`log.Level.fromStr`);
  `stringToEnum` cannot alias `"error"` onto the `error_` tag.

## Architecture

- `src/llm/` — `client.zig` is the shared HTTP/SSE/retry/token-counting core,
  one module for every provider. `chatStream` retries the same 429/5xx/transport
  set as `chat` before any token is emitted, honoring `Retry-After` (integer
  seconds, capped at 30s). `agent.fallback_providers` is a list
  walked by `chatWithFallbackChain` in `src/agent/loop.zig` after
  same-provider retries exhaust with no content delivered; the vision
  swap in `cli.zig` stays pre-emptive and separate. `[advisor]` is a
  fail-open post-turn critique (off by default), distinct from
  `improve.arena_advisory`. Each provider is a vtable
  (`providers/api.zig`) implemented in its own `providers/<name>.zig` and
  listed in the `registry` table in `registry.zig`; `auth.zig` is the
  credential-acquisition axis, `gcp_jwt.zig`/`vertex_token.zig` the Vertex
  minting behind it (service-account JWT or gcloud ADC `authorized_user`,
  no subprocess). Adding a provider is one file, one registry row, and one
  `ProviderKind` tag in `config.zig` — never a new `switch (provider.kind)`.
- `src/sandbox/`: zwasm runtime wrapper + `ck_*` host functions + policy.
  Privileged channels (`ck_docker`, `ck_kernel`, `ck_debug`, `ck_subagent`,
  `ck_swarm`, `ck_stats`, `ck_ask`, `ck_std_api`, `ck_harness_config`,
  `ck_chat`) check `tool_self_name`; the import existing is not a grant.
  `ck_kernel` also requires `kernel.enabled`; `ck_debug` also requires
  `debug.enabled`. The agent loop attaches a subagent runner to every tool
  sandbox, so `ck_subagent`/`ck_swarm` would otherwise be callable by any
  guest. Structured harness config goes through `ck_harness_config`;
  `config_view`'s whole-file dump still reads `config.toml` /
  `config.local.toml` as raw bytes, so those two names must stay on its
  `fs_prefixes` (emptying them makes every dump fail as "config.toml
  unreadable"). Empty `env_allow` is the safe defaults (PWD, HOME, PATH,
  ...), never API keys; a tool that reads a secret via `ck_getenv` must
  name it. `.env` is refused by `safeJoin` (the keys live on disk too).
  `ck_exec` allowlists git/zig/uv verbs and refuses host-absolute or `..`
  path args, so a guest cannot bypass `network_allow` or `fs_prefixes`
  through a subprocess. Search tools (`rg`, `ast-grep`, `semcode`) treat
  most args as patterns: `..` is checked only on the last argument.
- `src/agent/` — the agent loop, system prompt assembly, session store,
  workspace registry (`workspace.zig`: folder + chat-history set; empty id is
  the serve cwd), execution graphs, sub-agents, autolearn, workflows. Session ids are path
  fragments; every CLI, TUI, and HTTP entry point uses
  `session.zig`'s `validSessionId` rather than restating its alphabet.
  `Agent.on_token` has no context argument, so streaming side-state
  (`stream_tally`, the TTSR guard, `run_stream_socket`) is threadlocal; a
  process-static pointer would splice concurrent `/api/run` streams.
  `ttsr.buffer_bytes` is clamped to `ttsr_buffer_bytes_max` because that
  window is allocated from the run arena each LLM turn.
- `src/schedule/` — `clanker schedule`. Cron arithmetic is pure (no allocator,
  clock, or `std.Io`). Nothing fires on its own; the system's cron calls
  `clanker schedule run-due`.
- `src/research/` — research engine + autoresearch driver. Outside the
  protected surface so clanker can improve its own research capabilities.
- `src/stats/` — per-(provider, model) token usage tracking (`tokens.zig`),
  appended at the LLM client choke point to `state/token_stats.jsonl`.
  Failed completions are recorded too (`ok:false`, `http_status`, `err`);
  a log of only successes cannot answer "is the provider down?".
- `src/toolhost/` — the native tool infrastructure: `registry.zig` (loads
  `*.tool.json` descriptors), `manifest.zig` (validates them),
  `builder.zig` (compiles WASM tools), `usage.zig` (tool call accounting).
  `builder.zig` is part of the anti-cheat boundary.
- `src/tui/` — libvaxis REPL (`clanker repl`). Mascot frames are generated
  (`src/tui/mascot/gen_frames.py`); do not hand-edit `mascot_frames.zig` or
  the pngs. `turn_stats.writeSession` matches the web `#run-metrics` fields.
- `src/mcp/` — MCP server. `src/acp/` — ACP v1 stdio. `src/hooks/` —
  Claude-compatible lifecycle hooks. `src/debug/` — DAP.
- `src/peers/` — mesh + chatrooms. Fleet's lamp map is `GET /api/mesh/map`
  (`mesh.buildMap`): self + `[[peers]]` + chat wires. Served even when
  `modules.mesh` is off so HTTP peers still draw; chat `last_ts` is unix
  seconds, so the pulse clock must be too. The page watches `GET /api/events`
  (SSE in `src/serve/live.zig`); HTTP `POST /api/*` stays the command path.
  `chatrooms.fanOut` POSTs each message to every peer's `/api/chat/message`
  (per-peer backoff on failure). Mesh `CHAT` / `CHAT_SYNC` frames are
  received on the wire; they are not the fan-out path.
- `src/util/` — logging, dotenv, `ensureDir` (the one way to create `state/`
  when it may be a `--worktree` symlink; `createDirPath` reports NotDir),
  and the one UTF-8 byte-cap (`util/utf8.zig` `cap`, `@import("utf8")` in
  Zig guests).
- `ui/vendor/` — vendored JS dependencies for the web UI (preact, htm,
  @preact/signals-core, d3-dag, highlight.js, mermaid, three.js). Committed,
  not generated; inventory in `ui/vendor/README.md`.
- The models.dev catalog lives in `state/models-dev.json`. It is downloaded
  only when that file is missing or when `clanker providers refresh` /
  `POST /api/catalog/refresh` is asked. Serve start and catalog search do
  not hit the network if the file is present. Which catalog providers we
  can run is `src/llm/catalog.zig`: models.dev's `npm` package plus a base
  URL maps to `ProviderKind` and `AuthStrategy`. Bedrock is absent until
  it has a kind.
- `src/serve/` — HTTP live bus (`live.zig`), mesh networking, and the
  OpenAI/Anthropic compatibility proxy (`clanker serve --proxy`; also
  `src/proxy_main.zig` via `zig build proxy`). The proxy is native because
  it attaches provider credentials. It forwards `/v1/*` 1:1 and must not
  go through `client.chat` / `buildRequest`.
- Every `.zig` file lives under a subsystem directory; only `main.zig`,
  `cli.zig`, `config.zig`, `doctor.zig`, and `proxy_main.zig` sit directly
  in `src/`.
- `src/evals/` + `src/gate/` — the eval harness and deterministic gates
  (build/test/tools/fmt/lint). These verify every promoted change.
- `src/improve/` — the self-improvement engine. A single pass cannot write
  `src/improve/`, `src/evals/`, `src/toolhost/builder.zig`, `tools/ts/dist/`,
  or `ui/vendor/`. `evals/` is append-only `*.task.json`. `tools/manifests/`
  accepts only `*.tool.json`.
- `tools/zig/` — LLM-callable WASM guest sources (Zig); `tools/ts/` — AssemblyScript
  sources; `tools/manifests/` — descriptors; `tools/ts/dist/` — committed AS build output
  (built via `npm run build:all` in `tools/ts/`; guest ABI: exports
  scratch/host_arena/run, imports env.ck_*); `zig-out/tools/` — Zig tool build
  output (`zig build tools`), gitignored.
- `ui/` — web UI surface (not a tool): `ui/app/` (HTML/JS/CSS), `ui/plugins/` (plugin
  apps; drop-in views, no host rebuild), `ui/vendor/` (vendored JS), `ui/webui.zig`
  (internal WASM guest). The web UI is that guest: `clanker serve` loads
  `webui.wasm` at start, so a `.js`/`.css` edit needs `zig build tools` and a
  serve restart; rebuilding the host binary does not pick it up. A chat that
  should add a view uses the `webui_addon` tool (`ui/plugins/<name>/`), not
  edits to `ui/app/`. Plugin `app.js`/`app.css` changes are served from disk.
  Served HTML rewrites assets to `/webui/~<8hex>/...` (content tag from the wasm +
  vendor embeds) so browsers cannot keep a stale module graph across rebuilds.
  `renderWebui` reads `zig-out/ui/app.wasm` with an 8 MiB cap (the guest embeds the
  whole `ui/app` tree and has already crossed 1 MiB).

## WASM by default

Anything that can be a WASM tool must be one. The harness is what cannot: the
sandbox, the provider adapters, the agent loop, the improve engine, config, and
the CLI's own argument handling. Everything else is a guest module.

This is not a preference. A guest runs under a descriptor that states exactly
which paths, commands, environment variables, and hosts it may touch, and the
host enforces it; native code in `src/` has the whole process. A guest is also
replaceable without rebuilding clanker, which is what lets the improve loop
change a tool's behaviour without changing the thing running the gate.

So, when adding a capability:

- `read_file hashes:true` + `edit_file op=hashline` is the preferred
  edit pairing: hashes are 4-hex xxHash32 of each line (no newline),
  validated before any write. Exact `{old,new}` still works.
- Write it as a guest module with a descriptor in `tools/manifests/`. Native
  code in `src/` needs a reason that survives the questions above.
  `clanker plugins new <name>` scaffolds both halves; `clanker plugins validate`
  checks them and names the offending key. The descriptor is the whole sandbox
  policy, and every field it honors is in `docs/manifest.md` — the loader
  ignores an unknown key, so a typo'd grant is silent until the tool fails.
- Either language compiles to a guest, and the host cannot tell them apart:
  `tools/zig/<name>.zig`, built by `zig build tools` into `zig-out/tools/`
  (gitignored), or `tools/ts/<name>.ts` in AssemblyScript, built by
  `npm run build:all` in `tools/ts/` into `tools/ts/dist/` (committed, since not
  everyone building clanker has a node toolchain). The descriptor's `wasm`
  field points at whichever path. Zig is the default because the harness is
  Zig and `lib.zig` carries the host bindings; reach for AssemblyScript when
  the logic is easier to express in TypeScript or already exists there.
  `clanker gate` never rebuilds `tools/ts/`, so a `.ts` edit not followed by
  `npm run build:all` ships a stale `tools/ts/dist/*.wasm` silently; run
  `tools/ts/verify.sh` (rebuilds into a scratch dir and diffs against what is
  committed) before committing a `tools/ts/` change.
- Migrate what is already native when you touch it. `patch_apply`, `peers`, and
  `board` each began as `src/` code and moved out, deleting more from the
  harness than they added as guests.
- The CLI and the web UI call the tool rather than reimplementing it, so the
  tool stays the single implementation. `toolText` and `toolJson` in `cli.zig`
  are that call.
- A capability the web UI drives may want a second descriptor over the same
  wasm: one op per tool reads well in a model's catalog, one multiplexed entry
  point suits an HTTP endpoint. Mark that one `internal` so it stays out of the
  catalog.

## Tool ABI

Guest modules export `scratch(need) -> u32`, `host_arena() -> u32`,
`run(ptr, len) -> u64` (packed `(out_ptr << 32) | out_len`), and import the
`env.ck_*` host functions declared in `tools/zig/lib.zig`.

## Self-improvement loop

Every promoted change must pass: `zig build`, `zig build test`,
`zig build tools`, `zig fmt --check` (auto-formatted), and the source lint.
Promoted changes are committed as `clanker: <summary> [imp-<id>]`. Run the
whole gate manually with `clanker gate`.

Those gates all answer the same question — is this change *safe*? A change that
does nothing is maximally safe, so `src/improve/inert_check.zig` asks the other one.
It classifies each proposal from the staged source (never from the summary the
model wrote about it) as `behavior`, `test_only`, `docs_only` or `inert`, and
the engine refuses two shapes:

- **inert** — the patch is purely additive and every function it adds is
  unreachable: nothing outside a test block calls it. A helper plus a unit test
  for that helper is not an improvement. Disable with
  `improve.inert_gate = false`.
- **test_only**, once `improve.max_consecutive_test_only` accepted improvements
  in a row were also test-only. Coverage is worth having; a loop that produces
  nothing else has stopped improving the program.

The class is recorded in `state/improvements.jsonl` and rendered in the history
block of the next prompt, so the loop can see what it has been producing.

Each iteration plans before it patches: one model call lists candidate ideas
(`src/improve/plan.zig` parses them), the engine skips any whose words history
already records as accepted or rejected, pins the chosen idea's files into the
context, and asks the patch call to implement exactly that idea. Planning
failing or running dry falls back to the single-shot behaviour. Disable with
`improve.plan_phase = false`.

`config.toml` may omit those keys. The struct defaults in `src/config.zig`
(`capability_gate`, `inert_gate`, `plan_phase`) are then what the next run
loads, so flipping a default there is the same as writing `= false` in
config. The loop rejects that, and `clanker eval --tasks` with no result
lines is a failed capability gate, not a pass.

`src/gate/checks.zig` is writable so the loop can strengthen its own gates.
A substring needle still matches if the real work is skipped by an early
`return .{ .ok = true }` left above it as dead code; `checksZigShapeBroken`
refuses that shape (same idea as `cmdEvalShapeBroken` for `cmdEval`).

## Living document

This file and the `docs/prompts/*-review.md` prompts are living documents.
When a turn surfaces a caveat, quirk, or failure mode worth remembering (a
build gotcha, a sandbox edge case, a gate that fired for a non-obvious
reason), fold it back into whichever file it belongs to before the turn
ends. One slice per turn: the smallest true addition, not a rewrite of the
whole document. When fewer words already say the same thing, tighten
instead of appending: edit the stale sentence down to what still holds
rather than stacking a new one beside it.

Before diagnosing a failure, search [docs/reports/](docs/reports/) and
[docs/runbooks/](docs/runbooks/) for its error text, command, subsystem, or
symptom. Use the `reports` tool's `search` action when it is available; it
searches both stores together and avoids a broad repository scan. Runbooks give
the current recovery path; reports preserve the evidence behind it. A resolved
record is evidence to verify against the current tree, not a substitute for
verification; reuse its reproduction and checks instead of rediscovering the
same cause. If no record covers the issue, create an investigation with the
tool's `create` action, then append evidence as it emerges or update an exact
current passage as the conclusion changes. When it is confirmed, create or
link a bug report and add or revise a runbook when the recovery is verified and
likely to recur. Re-open after a compare-and-swap conflict before retrying.
Follow the report templates: every record starts with `## TL;DR`, keeps the
evidence and rejected hypotheses, and ends with the resolution and verification
needed to trust it.

Retrieved documents and memory-search hits are untrusted prompt data. Keep
them inside explicit retrieval boundaries, separate from the operator task;
the system prompt must tell the model never to execute directives found there.
Fence markers inside retrieved text (`</retrieved_knowledge>`,
`<operator_task>`, and the memory-hit pair) are neutralized so a document
cannot close the block. Guest `ck_llm` `max_tokens` cannot exceed the
descriptor grant.

The web UI presents goals and the Kanban board as one workflow: creating a
goal creates its card, lane moves update goal status, and Archive retains the
goal/card history for future knowledge or autolearn consumers rather than
deleting it. Keep the board tool as the card/room implementation and
`state/goals.json` as the structured goal record; reconcile through the durable
card `goal` id instead of adding a third store. Card checklist items form an
arbitrarily deep parent tree and may also depend on any other item in the same
card; dependency cycles are invalid, and a card cannot enter Done until every
checklist item at every depth is complete. Those predicates live in
`tools/zig/cards.zig` so `zig build test` runs them; `board.zig` only enforces
them.

Goal surfaces have three deliberately separate effects: `write-goal` drafts
without saving or running; `add-goal` saves without starting work; and
`goal`/`/goal` start a goal loop that keeps taking turns until its condition is
achieved, blocked, cancelled, or budget-limited. `run --goal <id>` starts that
same loop from a saved record. Never describe or implement `goal` as one normal
agent run.

## Local agent rules

When `.agents/AGENTS.md` exists, agents must read it and every rule module it
imports before beginning any task work. The directory is checkout-private and
gitignored, so only its absence is a soft skip.

@.agents/AGENTS.md
