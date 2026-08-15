# Changelog

This file records consumer-visible changes. It follows Keep a Changelog; version
numbers follow the policy in [RELEASES.md](RELEASES.md).

## [Unreleased]

### Added

- A `[models."<provider>/<name>"]` entry can set `id` to the wire SKU so
  the table key is a local alias. Two names can share one SKU with
  different temperature (or other) settings:
  `grok4.6-coding` and `grok4.6-general` both `id = "grok-4.6"`.
- Omitted `context_window`, `max_tokens`, cost, display, and capabilities
  are filled from the models.dev snapshot at load. A written value always
  wins. Load does not download the snapshot.
- `rpm` on a `[providers.*]` or `[models."..."]` table is a self-imposed
  requests-per-minute cap. Clanker waits before sending so it does not
  exceed the window. A model cap and a provider cap both apply when set.
- `zig build proxy` builds `clanker-proxy`, the OpenAI/Anthropic
  compatibility proxy as a standalone binary: same `config.toml` /
  `config.local.toml`, `/v1` at the root, `[serve] proxy_token_env`
  auth, `--host` / `--port` flags with `CLANKER_HOST` /
  `CLANKER_PROXY_PORT` fallbacks (default 127.0.0.1:17922). No web UI,
  agent, TUI, or tool host is compiled in.
- Vertex (`vertex` and `vertex_anthropic`) accepts Application Default
  Credentials from `gcloud auth application-default login` or
  `GOOGLE_APPLICATION_CREDENTIALS`, in addition to a service-account JSON
  or a pasted access token. The refresh token is exchanged in-process;
  there is still no gcloud subprocess. User ADC sends
  `x-goog-user-project` from the provider's `project`.

### Fixed

- Web UI ES modules no longer 404 as `/webui/~tag/core/core/…`. Two
  stacked bugs: `run-metrics.js` reused `app.js`'s gzip slot, so a gzip
  client received `app.js` at the run-metrics URL and then resolved
  `./core/utils.js` under `/core/`; and the import map prefix `/webui/`
  also matched already-tagged URLs. `app.js` never ran, so the page was
  a rail with an empty main column.
- Isolated `clanker run` now provisions a checkout `state/` path that is a
  symlink to shared durable storage. Previously Zig reported `NotDir` before
  any shared paths were linked, leaving host-side state private to the
  worktree while sandboxed tools used the checkout state.
- Board no longer paints the leftover `#card-form` Add control. PatternFly
  `display: grid` on `.pf-v6-c-form` was beating the UA `[hidden]` rule;
  the form stays in the tree for the board module but stays hidden.
- Unmarked buttons (plugin filenames, crumbs, `#card-add`) are no longer
  styled as the accent Run pill. That look is `button.primary` and `#submit`
  only.
- Empty Chat hides Fork/Rename/Archive/Delete and find until a turn exists.
  Plan, Research, Long run, and Isolated worktree sit in one Run shape
  control. Submit is labeled Run.
- Board filters fold behind “Filter cards”; Only mine is a single checkbox.
  Creating a goal says it saves a Backlog card and does not start a run.
- Rooms’ selected channel is a cabinet lamp on surface-2, not a Slack
  accent slab. Board header is a plate, not a tinted Trello bar.
- Files ships on when `state/webui_plugins.json` is missing, and its
  toolbar uses Hidden / Refresh / Close.

### Changed

- The committed `config.toml` ships one default model per provider, not
  a catalog. Extra SKUs belong in `config.local.toml` or Discover.
- `clanker serve` greets a terminal with a startup card: robot badge,
  version, clickable Local URL, whether the network can reach it, the
  proxy mount when enabled, and how to stop. A piped stdout still gets
  the original bare `http://host:port/webui` line, so scripts that
  parsed it keep working; colors honor NO_COLOR.
- Provider defaults now point at the newest general-purpose catalog
  models: DeepSeek `deepseek-v4-pro`, OpenAI `gpt-5.6`, Anthropic
  `claude-opus-5`, Muse Spark `muse-spark-1.2`. Moonshot stays on
  `kimi-k3`.
  Local ollama/vLLM ids are unchanged. Specs (context, cost, capabilities)
  come from the models.dev snapshot.
- The models.dev catalog is a local snapshot (`state/models-dev.json`),
  not a 24-hour cache. Serve start and catalog search do not hit the
  network when that file exists. First use (or a missing file) downloads
  it once; `clanker providers refresh` and Refresh catalog on the Models
  view replace it. An older `state/cache/models-dev.json` is still read
  so an existing download is kept on upgrade.
- Discover and `providers catalog` only list models.dev providers
  clanker can run. Support is the catalog `npm` package plus a base URL,
  mapped in `src/llm/catalog.zig` to `openai_compat` (Bearer API key),
  `anthropic` (API key or OAuth by token shape), `vertex_anthropic`
  (GCP `oauth_refresh`), `gemini` (`x-goog-api-key`), or `azure_openai`
  (`api-key` plus a resource host). Vertex Gemini and Bedrock stay out.
  A missing `[providers.*]` table in a snippet is now filled from that
  mapping (kind, base_url, api_key_env) instead of a comment.
- `kind = "gemini"` talks to Google Gemini generateContent (AI Studio).
  `kind = "azure_openai"` talks to Azure OpenAI chat completions
  (deployment in the URL, optional `api_version`).
- `kind = "vertex"` is Google Vertex AI: Gemini generateContent by
  default, Anthropic `:rawPredict` when the model id is Claude. Same GCP
  project/location/ADC auth as `vertex_anthropic`, which stays the
  Anthropic-only kind.
- Web UI shell follows a session-first layout: conversations stay in the
  left rail, Watch and Set up fold away, and Chat is a header / transcript
  / docked-composer column. PatternFly page chrome and cabinet colors stay.
- Phone Chat header keeps More only so empty-state suggestions sit above
  the docked composer instead of under it. More holds the same Fork/Rename/
  Delete nodes and find-in-transcript on a phone.
- Operator web UI pages (Runs, Fleet, Models, Board, Rooms, and the rest)
  fill the main column instead of sitting in Chat's ~46rem centered
  measure. Chat keeps that reading width.
- Files view uses the full main column when no preview is open, and
  filename / crumb / sort controls are no longer painted as 40px accent
  pills by the host button rule.
- Muted text meets 4.5:1 contrast on every theme's raised surface: Latte,
  Frappé, and Tokyo Night Day each read under the WCAG AA floor on
  surface-2 and got a palette-native `--fg-muted` step.
- Touch targets grow to a 44px minimum on coarse-pointer (touch) devices;
  desktop keeps the 40px density.
- Vendored PatternFly CSS is subset to the twelve components the UI
  actually uses (1.8MB to 625KB); `scripts/subset-patternfly.py`
  regenerates it from a stock release file after an upgrade.
- The composer's Run and Stop controls are one circular icon spot, the
  send arrow / stop square convention of mainstream chat UIs. The
  keyboard-shortcut hint moved into the tooltip and accessible name, and
  the two buttons still hand focus to each other across a run.
- An empty conversation centers a greeting and the composer mid-screen
  with the suggestions underneath, the mainstream chat empty state; the
  first turn docks the composer back to the bottom. Turn actions (Copy
  answer, Run again, Edit & resend, Branch, Apply plan) already matched
  the convention and are unchanged.

### Added

- A run-metrics line under the composer, DeepSeek-harness style: turns,
  steps, LLM time vs tool-call time, average time-to-first-token,
  completion tok/s, cache hit rate, and input/output token counts. The
  strip ticks while a turn is running (wall clock and step count every
  200ms, client TTFT on the first stream delta) and accumulates across
  turns until New chat, a session switch, or reload. Token totals,
  cache hit rate, and tok/s wait for the server `done` event. TTFT is
  also measured server-side (`types.ChatResponse.ttft_ms`, streaming
  only) and folded into `RunStats` when that event arrives.
- The Models view can add, edit, and remove a configured model, not only
  save a catalog snippet: `POST /api/config/model/set` table-replaces a
  full field set (temperature, cost overrides, capabilities, etc.) into
  `config.local.toml`, and `POST /api/config/model/remove` deletes a
  model's table there. Both are surgical `config.local.toml` edits, same
  as the existing catalog-save path; a model only declared in the shared
  `config.toml` cannot be removed from the page. A catalog entry that
  supports a temperature parameter (models.dev only signals the
  capability, not a value) now fills in clanker's own chat default
  (0.7) instead of leaving the field for the provider's own default.
- `clanker add-goal` and `/add-goal` save a structured goal without starting
  work. The Goals board uses the same `add_goal` writer and tells the operator
  that a saved goal has not started.
- Persistent Python eval kernel (PRD 0016): a session-scoped `python3`
  supervisor keeps `__main__` across cells. `reset: true` restarts it;
  session end SIGTERMs via the shared subprocess registry. Still off
  unless `kernel.enabled = true`.
- DAP debug tool (PRD 0017): `debug` guest + `ck_debug` + `[debug]`
  adapters. Off unless `debug.enabled = true`. Host tests speak DAP
  to a stdio fake adapter (launch, breakpoints, continue, stack,
  variables, evaluate, disconnect).
- The `kernel` tool's Python path also has a WASI one-shot sandbox
  (`./scripts/setup-python-wasi.sh`) that is not the persist path.
- Fleet Mesh map: each clanker is a lamp on `/#fleet`. Wires appear
  after a talk; a live talk sends a directed glow along the wire.
  `GET /api/mesh/map` feeds it (even when `modules.mesh` is off).
- Web UI live bus: `GET /api/events` (SSE). Chat, mesh talk, and run
  working push to the page. HTTP `/api/*` stays the command API; polls
  are the fallback when the stream is down.
- Mesh chat pipe: `fanOut` writes a `CHAT` frame on a live mesh link
  when `modules.mesh` is on and the peer is connected, else HTTP. Serve
  listens when the module is on. `POST /api/mesh/join` dials.

## [0.1.0] - 2026-08-14

### Added

- Initial CLI, REPL, HTTP, MCP, peer, and sandboxed WASM tool surfaces.
- Plugin manifest SDK: `manifest_version` in `*.tool.json`, a validator
  (`clanker plugins validate`), a scaffolder (`clanker plugins new <name>`), and
  a written field reference at [docs/manifest.md](docs/manifest.md). A manifest
  whose `wasm` is a bare filename now resolves beside its own manifest, so a
  `{name.tool.json, name.wasm}` directory is a portable plugin.
- Optional per-provider `auth` key (`api_key` / `oauth_static` /
  `oauth_refresh`), selecting how a credential is acquired independently of the
  provider's `kind`. Unset keeps the existing auto-detection, so no existing
  config changes meaning.
- `clanker serve`'s listener can now be set without flags, for a service file
  or a container: a `[serve]` table (`host`, `webui_port`, `serve_as`) and the
  `CLANKER_HOST` / `CLANKER_WEBUI_PORT` environment variables. Precedence is
  config < environment < flags.
- `agent.tools_dir` accepts a list of directories as well as a string, so a
  third-party plugin can live beside the built-in tools instead of replacing
  them. Later-listed wins on a name collision; a missing directory warns and
  continues. Existing `tools_dir = "tools/manifests"` configs are unchanged.
- `agent.fallback_provider` is now an ordered list (`fallback_providers`
  also accepted). After the selected provider exhausts its own retries with
  no content delivered, the next configured name is tried. A bare string
  still means one fallback. Vision routing stays pre-emptive and unchanged.
- The Models view can save a catalog snippet (or set the default
  provider/model) into `config.local.toml`. Writes are surgical table/key
  replacements and take effect on the next `clanker serve` restart.
- `read_file` accepts `hashes: true` (4-hex xxHash per line) and
  `edit_file` accepts `op: "hashline"` so an edit can target those hashes
  instead of reproducing the exact text. A mismatch rejects the whole
  patch; success returns the new hashes for a follow-up edit.
- Optional `[advisor]` second-model critique after each completed turn.
  Off by default; fail-open. A `blocker` asks proceed/abort when a human
  is present and otherwise injects as a one-turn concern.
- Turns with no configured `temperature`/`top_p` now pick a use-case
  default (chat 0.7, tool-use 0.0). Thinking models get
  `reasoning_effort` (`medium`/`high`) instead. An explicit config or
  per-run value still wins.
- Optional `agent.auto_thinking` classifies each user turn and selects a
  `reasoning_effort` row. Off by default; fail-open.
- `[ttsr]` stream rules can abort an in-flight completion on a
  literal/`*` match, inject a note into the system prompt, and retry
  the turn. Off unless rules are configured.
- Session-scoped subprocess registry (`src/agent/subprocess.zig`) plus a
  `kernel` guest that stays off unless `kernel.enabled = true`. Python/JS
  supervisors are still landing; DAP will reuse the same registry.
- `gh_read` fetches GitHub issues/PRs via `gh://` URLs with an
  allowlisted `GITHUB_TOKEN`. Repeat reads within 5 minutes hit
  `state/gh_cache/`. `read_file` stays network-free.
- `clanker commit` / `smart_commit` groups a staged diff into
  conventional commits. A dense import cycle becomes one commit with a
  note instead of looping.
- `write_goal` drafts a structured goal without persisting it.
  `proof` and `stop_rule` now appear in the active-goal run preamble.
- An opt-in REPL mascot (`--mascot`, `[tui] mascot`), off by default. Five
  modes: it can track what you type, loop across the screen, run on the
  spot above the composer, or run inside the composer, which grows to make
  room. `--mascot-size` picks a 6x1, 7x2, 8x4, 10x5, or 21x10 cell grid and
  `--mascot-facing` mirrors it. Drawn with kitty graphics where the
  terminal supports it and unicode half-blocks everywhere else.

### Changed

- `clanker goal`, `/goal`, and `clanker run "/goal …"` start the supplied goal
  loop. The loop keeps taking turns until it reaches the condition or reports a
  blocker; it does not require a `write_goal` draft or persisted record. Use
  `run --goal <id>` to start the loop from a saved goal.
- `serve --webui-port` is the documented spelling for the web UI listen port.
  A second surface (`--proxy-port`) now has a peer name instead of overloading
  a generic `--port`.

### Deprecated

- `serve --port` is deprecated in favor of `--webui-port`. The old flag still
  works and logs a warning; migrate service files and scripts before it is
  removed in a future minor release.

### Fixed

- `clanker serve` and the REPL exited immediately with signal 12 (`SIGSYS`) on
  macOS and any other non-Linux host whenever `modules.hot_reload` was on (the
  default). The hot-reload watcher issued raw Linux `inotify` syscalls
  unconditionally, which trapped before the fallback that was supposed to
  handle inotify being unavailable could run. The watcher now uses inotify only
  on Linux and polls the binary's mtime elsewhere.
- Hot reload never fired on macOS even once the watcher survived: a rebuild was
  only recognised by an ELF header, which a Mach-O binary never has. The check
  is now per-platform.

### Compatibility notes

- This is the first tagged release. There is no prior version to be
  compatible with; the `0.MINOR.0` policy in [RELEASES.md](RELEASES.md)
  governs breaking changes from here on.
- `manifest_version` is optional and absence means version 1, so existing
  `*.tool.json` files load unchanged. A manifest declaring a version this build
  does not understand is refused rather than read under version 1 rules.

[0.1.0]: https://github.com/maci0/clanker/releases/tag/v0.1.0
