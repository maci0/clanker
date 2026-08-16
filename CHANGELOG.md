# Changelog

This file records consumer-visible changes. It follows Keep a Changelog; version
numbers follow the policy in [RELEASES.md](RELEASES.md).

## [Unreleased]

### Breaking

- The committed `config.toml` renames the Moonshot provider table
  `[providers.kimi-k3]` → `[providers.moonshotai]`, and the shipped
  `default_provider` value changes from `"kimi-k3"` to `"moonshotai"`.
  A `default_provider = "kimi-k3"` pinned in `config.local.toml` stops
  resolving after upgrade (`UnknownProvider`) unless a
  `[providers.kimi-k3]` table is still defined there. Migration: rename
  the pin to `"moonshotai"`; the `kimi-k3` model is unchanged.
- Provider default models move to the newest general-purpose catalog
  models: DeepSeek `deepseek-v4-flash` → `deepseek-v4-pro`, OpenAI
  `gpt-4o-mini` → `gpt-5.6`, Anthropic `claude-sonnet-5` →
  `claude-opus-5`, Muse Spark `muse-spark-1.2-contributor` →
  `muse-spark-1.2`. Local ollama/vLLM ids are unchanged. An upgrade that
  did not pin a model now talks to a different model, with different
  behavior and cost. Migration: pin the previous default in
  `config.local.toml` before upgrading, e.g.

  ```toml
  [providers.deepseek]
  default_model = "deepseek-v4-flash"

  [models."deepseek/deepseek-v4-flash"]
  provider = "deepseek"
  ```

  One `default_model` + `[models."<provider>/<old-model>"]` pair per
  provider reproduces the 0.1.0 behavior exactly. Specs (context, cost,
  capabilities) come from the models.dev snapshot.

### Added

- HTTP endpoints for the five record stores on `clanker serve`:
  `GET|POST /api/reports`, `/api/rfc`, `/api/adr`, `/api/prd` and
  `/api/research`. Each relays the tool of the same name, so the CLI, the
  agent and HTTP share one implementation and one set of field names — the
  request fields are the tool's own `input_schema`. `GET` serves the reads
  (`list`, `search`, `open`, plus `checklist` on `rfc`/`prd` and `plan` on
  `research`), taking its fields from the query string and defaulting
  `action` to `list`; `POST` serves the writes (`create`, `append`,
  `update`, `status`, plus `recommend` on `rfc`), taking the guest's input
  object as its JSON body. One endpoint per *tool*, not per store: `reports`
  covers `docs/reports/` and `docs/runbooks/` both.
  - A write action named on `GET`, a read action named on `POST`, and a
    `POST` with no `action` are refused with 400 before the guest runs, so no
    safe method can change a record; any other method is 405.
  - Refusals keep the neighbouring endpoints' mapping: a missing record is
    404 and every other refusal is 400. A write against text the record no
    longer has comes back as the guest's own "open it again and retry"
    refusal, never a silent overwrite and never a 500.
  - `research sweep` is not exposed: it performs network egress and can run
    for tens of seconds. It stays on `clanker research sweep` and the agent.
  - No new `modules.*` flag, matching the ungated `/api/skills`,
    `/api/logs`, `/api/knowledge` and `/api/prompts`. The web UI view over
    these endpoints is a separate follow-up.
- `clanker adr` and `clanker prd`, plus the `adr` and `prd` tools behind them:
  the two record stores that had no verb and were maintained by hand. `adr`
  covers `list`, `search`, `open`, `create`, `append`, `update` and `status`
  over `docs/adrs/`; `prd` adds `checklist` over `docs/prds/`. Both allocate
  the next number, render the store's `TEMPLATE.md` and maintain its index, so
  the CLI, the web UI and the agent share one implementation. `adr search`
  spans the ADRs, RFCs and PRDs together and `prd search` the PRDs and ADRs,
  because which store a hit lands in is the answer: an ADR means the question
  is settled, an RFC means it is still open, a PRD means a feature already
  specifies around it.
  - `adr create` requires consequences, and `adr status ... superseded`
    requires a note naming the replacement — a decision record that only
    argues for itself, or that is reversed by editing its history out, is
    worthless to whoever later asks whether to revisit it.
  - `prd status ... shipped` requires a note naming the source files that are
    now the single source of truth, and `prd list` groups by status with the
    unfinished work first.
  - New: `docs/adrs/README.md` (the store had no index), inventory markers in
    `docs/prds/README.md`, and `{{placeholder}}`s in both `TEMPLATE.md` files
    so the tools can render them.
- `clanker research`: the `research` tool on the CLI, with `list`, `plan`,
  `sweep`, `search`, `open`, `create`, `append`, `update` and `status`. It
  calls the same sandboxed tool the agent uses, so the notes in
  `docs/research/`, their inventory and the compare-and-swap writes are shared
  rather than reimplemented.
- Brave Search and Marginalia as the research sweep's fourth and fifth web
  backends. Brave is keyed on `BRAVE_SEARCH_KEY` (sent as a header, so it stays
  out of any log that records the URL) and runs its own crawl rather than
  reselling another index. Marginalia is the public API, needs no key at all,
  and is last so a sweep always has one more thing to try however little is
  configured; its index is independent and biased towards small non-commercial
  pages, so it surfaces what the mainstream engines rank away.
- Scraped titles and snippets have their internal whitespace collapsed. A
  title laid out for a browser arrives carrying newlines — Marginalia returns
  ziglang.org as "Home\n  ⚡\n  Zig Programming Language" — which printed as
  three ragged lines in the middle of a result list.
- Google as the research sweep's third web backend, after DuckDuckGo Lite and
  Bing, reached through the Programmable Search JSON API and enabled by setting
  both `GOOGLE_SEARCH_KEY` and `GOOGLE_SEARCH_CX`. With either unset the
  backend is skipped and the sweep says so once. It is the API rather than a
  scraper because `www.google.com/search` answers a plain HTTP client with a
  "turn on JavaScript" page carrying no result links, whatever user agent it is
  asked with, including the legacy `gbv=1` no-JavaScript parameter. The same
  holds for Baidu (百度安全验证, its security-verification page, with a browser
  user agent and Chinese `Accept-Language` alike), Ecosia, Startpage, Mojeek
  and the public searx instances, none of which publish a usable web search
  API either — which is why the mainstream backends are keyed APIs.
- `clanker reports status <path> <state> <note>` and a matching `status` action
  on the `reports` tool: `open`, `investigating`, `resolved`, `reopened` or
  `closed` on a bug report or investigation. It rewrites the record's `## Status`
  section and its `docs/reports/README.md` inventory line in one call.
  `resolved` requires a note naming the fix and what verified it.
- A bare `--` ends flag parsing on every command; everything after it is a
  positional. Markdown content routinely begins with `-`, which previously made
  `clanker reports append <path> "- new evidence"` a parse error rather than an
  append.
- `rfc create` reports the research notes it could have linked, as
  `research_available`, when it was given no `research` path.
- `agent.sandbox_follow_symlinks` (default `false`): allow a component of an
  already-granted sandbox path to be a symlink. Following a link out of the
  sandbox root is a known security risk, so it stays off unless the operator
  asks for it, and it never widens which prefixes a tool is granted. Without
  it, a checkout whose `state/` is a symlink into external storage had every
  guest read and write under `state/` refused — `clanker schedule` failed and
  run graphs were never persisted. See
  [ADR 0017](docs/adrs/0017-sandbox-symlink-traversal-is-opt-in.md).
- `clanker rfc [list|search|open|checklist|create|append|update|recommend|status]`:
  the requests for comment under `docs/rfcs/` from a terminal, over the same
  sandboxed `rfc` tool the agent calls. `list` reads each status from the
  document rather than the index and prints the next free number; `search`
  covers the RFCs and the ADRs together, so a decision already recorded
  surfaces before it is re-litigated; `recommend` takes a confidence from 0
  to 10. Previously the store was reachable only through the agent.
- `symbolic_regression` compute tool: search a closed-form expression that
  fits numeric data and return a Pareto front of `{expr, complexity, mse}`.
  For discovering a formula. `calculator` still evaluates a known one.
- Mesh web UI plugin (`ui/plugins/mesh/`): identity (id, listen, admission),
  copyable listen address, join, leave, members, and pending admit/deny.
  On by default. Fleet's map shows listen/admission, a pending-join
  banner that opens Mesh, and a Manage mesh control. Membership and
  pending JOINs publish `t:mesh` on `GET /api/events`.
- `zig build e2e` covers two-process loopback join/leave, prompt
  admit and deny, the CLI when serve is down or mesh is off, plus
  operator journeys `add-goal` (persist without running) and
  `schedule add` then list.
- `ck_fs_write_if` creates missing parent directories before the
  compare-and-swap lock, so `clanker schedule add` works in a fresh
  checkout that has no `state/` yet.
- `clanker mesh` talks to local serve over loopback HTTP: `status`,
  `join <host:port>`, `leave [<peer-id>]`, `pending`, `admit <id>`,
  `deny <id>`. `--webui-port` selects which serve when several run on
  one host. Serve grows matching `/api/mesh/leave` and
  `/api/mesh/pending`. The CLI never opens a mesh socket.
  `mesh.admission = "prompt"` is accepted: unknown JOINs wait for
  `admit`/`deny` or time out. Reference, config, PRD 0011, and the
  roadmap describe the shipped control plane.
- Tool-result spill: when the request pruner omits a tool middle, the
  original is stored under `state/spills/<session>/` and the request
  carries `[spill id=........]`. The `spill` guest reads it back. The
  saved transcript is unchanged.
- `session_search` guest, `clanker session search <query>`, and REPL
  `/search`. Linear scan of saved conversations (min 3 characters).
- Background `jobs` guest (`start`/`list`/`wait`/`kill`) plus
  `subagent {"background":true}` so a long child does not park the
  parent turn.
- `run_plan`: Code Mode v1, a bounded list of existing tool calls in
  one turn (max 12, cannot nest run_plan/chain).
- Human feedback sidecar (`state/feedback.jsonl`, `POST /api/feedback`,
  Up/Down on a turn). Never injected into the model.
- Composer `@file` mentions attach workspace paths as chips
  (`[File: path]` on submit).
- Desktop notification when a turn finishes and the tab is hidden.
- Checkpoint rewind: a `git stash create` snapshot before a mutating
  tool, listed/restored by the `rewind` guest.

### Changed

- `GET /api/stats` relays the `model_stats` guest. The CLI table stays
  native (`src/stats` cannot be imported from WASM).
- `GET /api/catalog` and `clanker providers catalog` share one search
  (`catalog.collectHits`).
- Web UI plugin assets honor `inherit_on`: an older
  `state/webui_plugins.json` that only listed files+music no longer
  404s Schedule, Search, or Compare.
- `GET /api/providers` relays the `providers` guest list. A live
  `/models` fill for a provider with no static models stays native.
- Advisor parse/summarize/inject is a host-tested helper
  (`advisor_logic`); the `advisor` guest runs the same review via
  `ck_llm`. The auto-thinking classifier has the same split:
  `thinking_logic` plus a `thinking` guest via `ck_llm`.
- The Schedule, Search, and Compare web views are disk plugins
  (`ui/plugins/schedule/`, `ui/plugins/search/`, `ui/plugins/compare/`),
  not part of `app.wasm`. They stay on after a pre-migration
  `state/webui_plugins.json` that only listed files+music.
- Web UI themes are data files under `themes/*.json`. Drop one in and
  `GET /webui/themes/catalog.json` lists it; the page applies the tokens
  instead of shipping a `:root[data-theme]` block per palette.
- Composer slash commands are `commands/slash.json`. Adding one is a
  data edit; the page loads `/webui/commands/slash.json`.

- Guests and web UI plugins can emit onto the serve live bus. A descriptor
  with `"live_publish": true` may call `ck_publish`; a view may call
  `api.emit(data)` (`POST /api/live`). Both land on the `plugin` topic
  as `{"t":"plugin","from":...,"data":...}` and cannot pick chat, run,
  or metrics.

- Fenced code in chat bubbles follows the active theme. The well used
  to stay GitHub-dark (`#0d1117`) while highlight tokens used the page
  palette, so light / Latte / Tokyo Night Day painted dark-on-dark.
  Each theme now sets `--code-bg` / `--code-fg`, and the inline-code
  pill no longer paints over a fenced `pre`.
- The web UI view formerly labelled Board is Kanban: rail tab, page
  heading, Tools category, and `#kanban` / `#kanban/<card>`. `#board`
  and `#goals` still open it.

- Opening the web UI starts a new conversation instead of replaying the
  last session. The old chats stay in the sidebar. A `#chat?session=`
  link still opens that conversation.

- User chat bubbles render the prompt as markdown (lists, bold, fences)
  instead of dumping the raw marks as a single pre-wrap text node. The
  source stays on the bubble so Edit, Copy and export are unchanged.
  Rooms messages sit under the name row, not beside it, so a heading or
  list is not crushed into the leftover width.

- Chat fills the main column instead of a 46rem stripe: header,
  transcript and composer share that width, and rendered markdown
  (lists, tables, code) is no longer re-capped at 70ch. Rooms uses the
  same markdown renderer as the agent transcript (`**bold**`, fences,
  lists) and the message log fills the pane instead of a leftover 24rem
  box.

- Tool categories are a closed vocabulary (`agent`, `chat`, `code`,
  `compute`, `harness`, `kanban`, `knowledge`, `media`, `transform`,
  `web`, `other`). The Tools view groups in that work-first order
  (Kanban for `kanban`) and no longer repeats the group name in the
  detail header. `knowledge` holds notes, memory, research, rfc,
  reports, and roadmap. `peers` sits with the harness (phonebook and
  machine notifications, not chat), `todo_*` with the agent (private
  run lists, not the board), `jobs` with the agent, `patch_apply` with
  code. `clanker plugins validate` warns on an unknown category and on
  a prefix in the wrong group (`chat_*` must be `chat`).
- Tool names: the multiplexed Kanban guest is `kanban` (was `board`);
  JSON pretty/validate is `json` (was `json_tool`); self-improve
  history is `improve_history` (was `history`, which collided with
  `clanker history` / `/history` for conversations). `/api/board`
  still calls the multiplexed guest. Zig helpers are one family:
  `zig_check`, `zig_std` (was `std_api`), `zig_test` (was `test_file`).
  Identifier generation is `ids` (was `id_gen`). Multi-op families are
  `noun_verb`: `web_fetch` (was `fetch_web`, pair with `web_search`),
  `goal_write` / `goal_add` / `goal_update` (were `write_goal` /
  `add_goal` / `update_goal`; CLI stays `write-goal` / `add-goal`),
  `skill_edit` (was `edit_skill`), `config` (was `config_view`).
  `note_write` / `note_forget` (were `write_note` / `forget_note`).
  `clanker plugins validate` also expects `goal_*`/`skill_*` in agent,
  `note_*` in knowledge, and `web_*` in web (`webui*` is harness).

### Added

- `GET /api/sessions` relays to the `sessions` guest (`format=json`).
  The picker and the agent catalog share one 4 KiB header walk
  (`sessions_logic.zig`). Mutations and a full transcript stay native.

- The OpenAI/Anthropic proxy reads route/protocol policy from each
  provider's vtable (`Provider.proxy`) instead of switching on
  `provider.kind`. Vertex quota project is `auth.Spec.quota_from_project`.

- A `schedule` guest lists and edits recurring agent runs
  (`state/schedule.json`). `GET /api/schedule` and
  `POST /api/schedule/<id>` relay to it, so the Schedule view and the
  agent catalog share one store. Cron arithmetic lives in
  `schedule_cron.zig` (host-tested) and is the same dialect
  `clanker schedule run-due` uses. Firing stays native.

- A `skills` guest lists, shows, searches, and enables/disables the
  markdown files under `agent.skills_dir`. `GET /api/skills` and
  `POST /api/skills` relay to it. Optional YAML frontmatter
  (`title`, `description`, `enabled`) plus `state/skills.json` is the
  enable/disable store. The system prompt inlines title and description
  only; the `skills` tool reads a full body. Discovery filters live in
  `skills_logic.zig`.

- The Health view subscribes to a `metrics` live-bus topic instead of
  polling `GET /api/metrics` on a timer. The endpoint still answers a
  snapshot (and Refresh still uses it). Snapshots are published at most
  once per second.

- Web UI plugins can POST, subscribe to the live bus, open the page's
  dialogs, read the current workspace, use the page icons, and store
  namespaced `localStorage` through `pluginApi()`. `plugin.json` now
  declares a `capabilities` list against that surface.

- `chat_dm` is the catalog tool for talking to another clanker instance
  (`{"to":"<name>","text":"..."}`). It is another descriptor over
  `chat.wasm` (same `ck_chat` send as `chat_send` with `to`), so the
  message lands in the canonical `dm:<you>|<to>` room and fans out like
  any other chat. The `peers` tool's `notify` action stays the machine
  notification ledger (`POST /api/notify` → `state/notifications.jsonl`);
  its description no longer teaches that path as "post a message".

- `clanker reports` puts the operational reports and runbooks on the CLI:
  `list` (the default) prints the whole index with each record's status and
  path, `search <query>` runs one literal search across `docs/reports/` and
  `docs/runbooks/` with `--kind` to narrow it to one store, `open <path>`
  prints a record, and `create`, `append` and `update` write one. It calls the
  same sandboxed `reports` tool the agent uses, so there is one store, one
  inventory and one set of compare-and-swap writes rather than a second
  implementation beside them — a refused write exits 1 and says which record to
  reopen. Until now the records were reachable only from inside an agent run.

- Two tools for the work that precedes a decision, independent of each other.
  `research` plans a search (the angles a single query misses: alternatives,
  failure reports, production experience, standards, and the out-of-the-box
  candidates nobody advertises), sweeps web search, GitHub repositories,
  Hacker News, and arXiv in one deduplicated call, and keeps what survives as
  a note under `docs/research/`. `rfc` opens a numbered request for comment
  under `docs/rfcs/`: options with short, medium, and long term implications,
  a recommendation whose confidence is a bounded 0–10 score, open questions,
  next steps, references, and an appendix. Both render a committed template
  (`docs/research/TEMPLATE.md`, `docs/rfcs/TEMPLATE.md`), keep their index
  current, and write compare-and-swap. `rfc create` optionally links a
  research note and lifts its option headings in as stubs marked unverified;
  nothing else couples the two, and neither is required for the other.
  Hosts named in `web.allow` extend the research sweep as they already do
  `fetch_web` and `web_search`.

- The REPL mascot renders as a SIXEL raster on terminals that support SIXEL
  but not kitty graphics, at the same cell footprint and in every existing
  mode, size, facing and speed. The renderer is chosen automatically from the
  terminal's own capability answer — kitty graphics, then SIXEL, then unicode
  half-blocks — never from `$TERM` or a terminal name, and a SIXEL failure
  falls back to half-blocks for the rest of the session. Requires
  `patches/vaxis-sixel-graphics.patch`; an unpatched build keeps the previous
  two renderers.

- MCP integrations are configurable: `[mcp_servers.<name>]` stanzas
  (stdio: command/args/env/cwd; http: url/headers; timeout) parse and
  validate at load, System -> MCP servers in the web UI adds, edits,
  and removes them through the validated config pipeline (secret env
  and header values never round-trip to the page), and the `mcp` skill
  teaches the agent to manage them by editing `config.local.toml`. The
  client bridge that actually connects is PRD 0032 and stays behind
  `modules.mcp_client`. `POST /api/config/table/remove` deletes any
  table from `config.local.toml` with the same refuse-or-write
  validation as every other config write.

- Hitting the iteration budget lands the run instead of erroring it: a
  wrap-up warning is injected three iterations out, and the final
  iteration goes to the model with tools disabled so it must answer in
  text — the result, or a handoff summary of what was done and what
  remains. A goal loop then continues on its next turn with a fresh
  budget rather than dying as `MaxIterationsExceeded` (which stays only
  as a backstop).
- Ad-hoc web UI addons from chat. Ask for a view ("build me a music
  player") and the `webui_addon` tool writes `ui/plugins/<name>/` and
  can enable it. System → Web UI plugins is the on/off switch. A
  shipped Music addon plays local files or URLs, with a dock that stays
  up while the addon is on. `registerView` now has an optional `boot`
  hook for that kind of persistent chrome.
- The Office whiteboard shows goal work at a glance: each line carries
  an IEC status lamp (green working — breathing while a clanker is on
  it, amber in review, red blocked), working goals lead the board with
  a live count, and review/blocked goals appear greyed instead of
  vanishing. Reduced motion stills the breath.
- Config hot reload: `clanker serve` watches `config.toml` /
  `config.local.toml`. A change that loads cleanly restarts the server
  into it (the same idle-aware exec a binary rebuild uses); a broken
  edit logs a warning and the server keeps running on its last known
  good config. `GET /api/config/status` reports the last verdict.
- The System view gains a raw config editor with TOML syntax
  highlighting for both files. Saving validates first via
  `POST /api/config/raw`: a config that does not load is refused with
  the reason and nothing is written, so a save can never take the
  server from good to broken.
- The Models edit panel gains a TOML mode (the OpenShift-console
  YAML-tab pattern): the same model, editable as its raw
  `[models."..."]` table with highlighting. `POST /api/config/table/set`
  splices the block into `config.local.toml` and validates the whole
  candidate before writing, through the same refuse-or-write pipeline
  as the raw editor.
- Workspaces are first-class: create any number of them, each a folder on
  disk with its own chat history. The rail picker switches folder and
  conversation list; New chat and `/api/run` inherit the current workspace;
  the files browser and the agent sandbox root at that folder. Registry is
  `state/workspaces.json`. The serve cwd remains the default workspace.
- `reasoning_format` on a provider or model overrides how reasoning is
  read out of a response: `auto` (the kind's native field), `think_tag`
  (pull a leading `<think>...</think>` out of the content — the local
  vLLM DeepSeek shape, vs the API's `reasoning_content` field), or
  `none` (discard). An unclosed tag leaves the content untouched.
- A model entry can override its endpoint: `base_url` and `path` on a
  `[models."..."]` table point that one model at a different host or
  route (a local vLLM beside the hosted API on the same provider entry).
  URL only; auth still comes from the provider.
- `tool_schema` and `thinking_schema` on a provider or model override the
  wire encoding for endpoints that deviate from the flat OpenAI shape:
  tools can be the standard array or omitted entirely (`"none"`), and the
  reasoning knob can go out as `reasoning_effort` (default), the
  OpenRouter `"reasoning": {"effort": ...}` nest, the GLM
  `"thinking": {"type": "enabled"}` toggle, or nothing. A model's setting
  wins over its provider's.
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
- A run-metrics line under the composer, DeepSeek-harness style: turns,
  steps, LLM time vs tool-call time, average time-to-first-token,
  completion tok/s, cache hit rate, and input/output token counts. The
  strip ticks every animation frame while a turn is running (wall clock,
  steps, live tokens from mid-run `usage` events plus a chars/4 estimate
  until the next official snapshot) and accumulates across turns until
  New chat, a session switch, or reload. The vaxis REPL paints the same
  strip on its last row, under the composer, and redraws it on the
  stream tick (~33ms). TTFT is also measured server-side
  (`types.ChatResponse.ttft_ms`, streaming only) and folded into
  `RunStats` when that event arrives.
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

### Fixed

- `clanker repl` copy (mouse-drag release and Ctrl-Shift-C) now also pipes
  the text into the host clipboard tool (`wl-copy`, `xclip`, `xsel`, or
  `pbcopy`, chosen from the desktop session) as a fallback to OSC 52, so a
  terminal that ignores OSC 52 clipboard writes still receives the copy.
  The keys help documents that Shift+drag uses the terminal's own selection
  and that the hosting terminal may intercept Ctrl-Shift-C.
- `agent.sandbox_follow_symlinks` now also applies when a turn issues two or
  more tool calls. The parallel tool path builds its own sandbox and omitted
  the flag, so symlinked granted paths (`state/`, `.local`) were still
  refused there while single-call turns worked.
- The `file_ops` tool can now reach `zig-out/gate-failure.txt`, so a model
  can inspect why a gate run failed instead of being refused by sandbox
  policy.
- `clanker autolearn` no longer fails with "no observations to synthesize"
  (with `--model`) or silently aggregates nothing (without) once
  `state/autolearn.jsonl` exceeds 1 MiB. The guest read the whole log with a
  single `ck_fs_read`, which returns TooLarge past the 1 MiB host arena, and
  a `catch null` turned that into an empty log. It now tails the newest
  256 KiB via `ck_fs_read_range`, like the `reasoning` and `improve_history`
  guests.
- TUI: Ctrl+C is no longer swallowed while the model/theme picker, command
  palette (Ctrl+P), or transcript search (Ctrl+R) is open. It now closes the
  modal like Escape, and with a turn streaming it also interrupts the turn —
  previously those two modals consumed every unmatched key, so a streaming
  turn could not be stopped until the modal was dismissed by hand. The ask
  modal already handled this.
- `clanker commit` works again. It called the `smart_commit` guest through a
  helper that wraps its argument as `{"args": "<string>"}` and requires a
  `text` field in the reply; the guest emits neither, so the verb always
  failed with "the internal tool returned unreadable output" — after paying
  for the grouping model call — and never received `dry_run` or `scope`, which
  made the post-confirmation write a second dry run that reported success.
  The command now sends a structured body and renders the reply host-side
  through `commit_logic.renderPlan`, with different wording for a proposal and
  an applied commit so it cannot claim a write it did not make.
- `improve-self` reclaims its own worktree when a run promotes nothing.
  `cleanup` used to keep every unmerged worktree "for manual recovery",
  but the `merged` flag is only ever set by the promotion path, so a run
  that promoted nothing left behind a worktree whose branch was
  byte-identical to its base. Those accumulated indefinitely and
  `clanker janitor` will not remove them. `cleanup` now asks git whether
  the branch holds commits the base lacks, and keeps the worktree only
  when it does.
- `improve-self` folds commits made inside its worktree outside the
  promotion path back into the base branch at the end of a run, instead
  of stranding them on an abandoned branch. Conditioned on a fully
  passing final gate — the same bar a promotion clears — and on
  `agent.git_commit`; a run that ends on a failing gate still keeps its
  worktree for manual recovery.
- Lifecycle hooks that never read stdin (`printf`, `echo`) no longer fail
  the hook when the child exits before the payload write finishes. The
  decision on stdout still applies.
- `GET /api/goals` no longer 500s on a valid store. The list guest wrote
  `"goals"` then the array without a colon (`{"ok":true,"goals"[...]}`),
  so the HTTP handler rejected it as bad JSON.
- Plugin `app.js` / `app.css` responses are logged as 200. The handler
  already sent 200 but never set `request_status`, so every load looked
  like a status-0 error.
- `GET /webui/core/slash.js` no longer serves `app.js`. The slash module
  was on the asset list but reused `app.js`'s render/gzip slot, so a
  gzip client executed `app.js` at the slash URL and then requested
  `/webui/core/core/*.js`. Each first-party module now has its own
  cache kind; the default slot is only `app.js`.
- A run can no longer spend itself compacting a history it cannot shrink.
  Compaction preserves the system message and the last six messages, so when
  those alone exceeded `agent.max_history_tokens` it was asked to compact on
  every iteration and freed nothing on any of them — a run seen doing this past
  iteration 173, printing throughout, was making no progress at all. The
  threshold is now lifted for the run when it falls below what compaction cannot
  remove (with headroom, never past what the model's window allows) and says so
  once; a run that still needs to compact five iterations in a row ends with
  `CompactionStalled`, reported as an outcome with partial work rather than a
  crash, naming both the configured cap and what the model's window leaves
  compaction, since raising the cap only helps when the model has room. The
  16000 default is unchanged and is still small for a large-window model —
  `docs/configuration.md` and a new
  `docs/runbooks/agent-run-compaction-thrash.md` cover setting it.

- The compaction summary no longer fails on every compaction on a thinking
  model. Its 512-token budget was the combined allowance for reasoning and
  answer, and reasoning runs first, so a real transcript spent the whole budget
  before a single content token: the LLM summary was replaced by the extractive
  fallback every time, at the price of a round trip each. The call now asks for
  a budget that fits both and the least reasoning the model will do, uses the
  model's own reasoning text when content comes back empty, distinguishes a
  summary truncated at the budget from an empty one, and stops asking after two
  failures in a run rather than paying for the same failure per compaction.

- HTTP API status codes now distinguish client mistakes from missing
  resources. Tool-backed routes (`/api/board`, `/api/knowledge`,
  `/api/prompts`, `/api/compare`, `/api/arena`) map `no such …` / `not
  found` refusals to 404 instead of 400. `POST /api/notify` with unreadable
  JSON is 400, not 500. `POST /api/sessions` without `import_chat` is 400
  instead of listing chats; `DELETE /api/sessions` is 405. A query string
  is no longer treated as part of a session, run, log, or knowledge id.
  Chat edit/delete/react answer 404 for a missing message and 403 when
  the caller is not the sender (reacting to a missing message used to
  look like a successful un-react). `GET /api/files` on a missing
  directory is 404 instead of silently listing the workspace root. A
  malformed body on `POST /api/compare/<id>` or `POST /api/prompts` is
  400, not 405.
- Web UI ES modules no longer 404 as `/webui/~tag/core/core/…`. Two
  stacked bugs: `run-metrics.js` reused `app.js`'s gzip slot, so a gzip
  client received `app.js` at the run-metrics URL and then resolved
  `./core/utils.js` under `/core/`; and the import map prefix `/webui/`
  also matched already-tagged URLs. `app.js` never ran, so the page was
  a rail with an empty main column.
- The model picker sat under PatternFly's main column (`z-index: 100`)
  so clicking the model chip opened a panel nobody could see.
- `GET /webui/` (trailing slash) serves the same HTML as `/webui`.
- Opening the phone rail no longer focus-scrolls Work (Chat/Board) off
  the top of the drawer. Picking a section closes the drawer.
- Rooms `#chat-log` is no longer a live region. New messages are
  announced once through `#chat-status`. Theme is a picker, not an
  11-click cycle. Channel list first paint says Loading channels.
- Phone suggestions and attachment remove are 44px. Fleet/Arena canvas
  and mesh lamps read computed theme tokens only. `HEAD /webui` returns
  the same headers as GET with an empty body. Health tiles use a lamp
  dome instead of a left-edge tab.
- System `#progress-log` is no longer a live region (status goes through
  `#progress-status`). The header model chip is not live either. The
  Runs graph flushes layout once, then reads node heights.
- Chat run metrics tick every frame and update tokens, cache and tok/s
  mid-turn from stream `usage` events plus a live output estimate.
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

### Fixed

- A status change now carries the store's README inventory with it, in the
  `research`, `rfc` and `reports` tools alike. Previously only `create` ever
  wrote the inventory's copy of the status, so every research note stayed
  `Draft` and every RFC stayed `Draft` however often its own status moved, and
  the reports inventory listed resolved bugs as `Open` indefinitely. All three
  now share one helper, and each reports whether the index write landed.

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
