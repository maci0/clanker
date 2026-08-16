# Configuration — providers, models, and `config.toml`

Everything clanker needs to reach a model and run lives in two TOML files at
the working directory root. This is the complete reference; the authoritative
schema is `src/config.zig`, and if a claim here disagrees with that file, the
code wins.

## Where config lives

- **`config.toml`** — the committed configuration: providers, models, module
  toggles, agent settings.
- **`config.local.toml`** — checkout-private overrides (gitignored), merged on
  top of `config.toml` key by key. Put machine-specific endpoints, a different
  `default_provider`, or a local vLLM URL here. See `config.local.toml.example`.
- **`.env`** — API keys. clanker loads it at startup (the `dotenv` module) into
  the process environment; a provider names the variable to read with
  `api_key_env`. Keys never go in the TOML.

TOML is the only supported format (there is no JSON config). A missing key
takes its default; an unknown key logs a warning and is ignored (so a typo like
`mx_iterations` does not silently misbehave, it warns and uses the default).

## Configuration errors

Configuration validation stops at the first bad setting. Its error names the
file and one-based TOML line, the fully qualified setting, what that setting
accepts, the TOML value type (and a non-sensitive value), and a corrected TOML
example. For example, a quoted integer in a local override reports
`config.local.toml:4`, `agent.max_iterations`, `expected an unsigned integer`,
`got string "50"`, and `correct it with max_iterations = 50`.

Use the line as the source of truth: `config.local.toml` is parsed separately
before it overrides `config.toml`, so a valid base setting cannot hide an
invalid local value. Values that could expose credentials, such as a key or
token setting, show their TOML type but redact the value.

Common corrections are to remove quotes from numeric and boolean values
(`max_tokens = 2048`, `enabled = true`), use a TOML array rather than a
comma-separated string (`serve_as = ["clanker.lan"]`), and move model settings
into `[models."<provider>/<model>"]` rather than `[providers.<name>]`.

## The two-part provider/model model

A provider is *an endpoint plus how to talk to it*. A model is *a set of
per-model settings* that names which provider serves it. They are configured in
two separate tables:

```toml
[providers.<name>]          # one endpoint
...

[models."<provider>/<model>"]   # one model, linked to a provider by the `provider` key
provider = "<name>"
...
```

`default_provider` (top-level) picks which provider is used when nothing else
is specified; each provider's `default_model` picks its active model. On the
command line, `--provider <name>` and `--model <name>` or
`--model <provider>/<model>` override both per run.

A configured provider is not the same thing as a reachable one: `config.toml`
ships stanzas for several backends and a given machine usually has a key for one
or two of them. `clanker providers check` is what tells the two apart, and
`clanker compare` puts their answers side by side once they do. `compare`'s own
`judge = "auto"` default resolves to `default_provider` for exactly this reason,
rather than hunting for a provider that is not an entrant and finding an
unconfigured one.

## `[providers.<name>]`

| Key | Type | Meaning |
|---|---|---|
| `kind` | string | Wire format: `openai_compat` (default), `anthropic`, `vertex_anthropic`, `vertex`, `azure_openai`, or `gemini`. See below. |
| `base_url` | string | Endpoint base. `openai_compat` appends `/chat/completions`, `anthropic` appends `/v1/messages`, `azure_openai` builds `/openai/deployments/<model>/chat/completions`, `gemini` builds `/models/<model>:generateContent`, unless `path` overrides. |
| `api_key_env` | string | Name of the `.env` variable holding the credential. Omit for a keyless local endpoint (ollama, vLLM). |
| `auth` | string | Credential-acquisition strategy: `api_key`, `oauth_static` or `oauth_refresh`. Optional — each `kind` auto-detects where the credential types are distinguishable. See below. |
| `default_model` | string | Which of this provider's models is active by default. |
| `path` | string | Override the endpoint path (rarely needed). |
| `check_timeout_seconds` | int | How long `providers check` waits for this endpoint before giving up, overriding the global `agent.provider_check_timeout_seconds`. `0` = no ceiling. |
| `rpm` | int | Self-imposed requests per minute for every model on this provider. Omit or `0` = no cap. A model's own `rpm` is a separate cap on that name, not an override. |
| `project`, `location`, `service_account_file` | string | `vertex` and `vertex_anthropic` (see below). `service_account_file` is optional when gcloud ADC is present. |
| `api_version` | string | `azure_openai` only. The `api-version` query. Empty uses `2024-10-21`. |

### `kind = "openai_compat"`

Any OpenAI-compatible `/chat/completions` endpoint: OpenAI, DeepSeek, Moonshot
(Kimi), OpenRouter, Together, a local ollama or vLLM, etc. The credential rides
`Authorization: Bearer <key>`.

```toml
[providers.deepseek]
kind = "openai_compat"
base_url = "https://api.deepseek.com"
api_key_env = "DEEPSEEK_API_KEY"
default_model = "deepseek-v4-pro"

[providers.ollama]                       # keyless local endpoint
kind = "openai_compat"
base_url = "http://127.0.0.1:11434/v1"
```

### `kind = "anthropic"`

Anthropic's native `/v1/messages` API. A plain API key goes on `x-api-key`; an
OAuth access token (one that starts `sk-ant-oat`, from `ant auth login`) is
auto-detected and sent as `Authorization: Bearer` with the OAuth beta header
instead. Same provider entry, either credential.

```toml
[providers.anthropic]
kind = "anthropic"
base_url = "https://api.anthropic.com"
api_key_env = "ANTHROPIC_API_KEY"
```

### `kind = "vertex_anthropic"`

Anthropic models served through Google Vertex AI. The model name goes in the
URL and auth is a GCP OAuth token, minted in-process and refreshed
automatically (no `gcloud` subprocess). Credential, first match:

1. `service_account_file` (service-account JSON or an ADC `authorized_user` file)
2. `GOOGLE_APPLICATION_CREDENTIALS`
3. `gcloud auth application-default login`
   (`$HOME/.config/gcloud/application_default_credentials.json`, or
   `$CLOUDSDK_CONFIG/...`)
4. a short-lived token in `api_key_env` (wins over minting when set)

User ADC sends `x-goog-user-project` from `project`.

```toml
[providers.vertex]
kind = "vertex_anthropic"
base_url = "https://<location>-aiplatform.googleapis.com"
project = "my-gcp-project"
location = "us-east5"
# service_account_file = "/path/to/service-account.json"
# or omit the file and use: gcloud auth application-default login
# or paste a short-lived token:
# api_key_env = "VERTEX_ACCESS_TOKEN"
default_model = "claude-opus-5"
```

### `kind = "vertex"`

Google Vertex AI. Same GCP auth as `vertex_anthropic` (service account, gcloud
ADC, or a pasted token). Gemini models use generateContent on
`publishers/google`. A model id that starts with `claude` (or names the
Anthropic publisher) uses the Anthropic Vertex wire instead, so one
`[providers.vertex]` table can hold both families.

```toml
[providers.vertex]
kind = "vertex"
project = "my-gcp-project"
location = "us-east5"
# service_account_file = "/path/to/service-account.json"
default_model = "gemini-3.6-flash"

[models."vertex/gemini-3.6-flash"]
provider = "vertex"

[models."vertex/claude-opus-5@default"]
provider = "vertex"
```

`vertex_anthropic` remains the Anthropic-only kind if you want a provider that
never routes to Gemini.

### `kind = "azure_openai"`

Azure OpenAI chat completions. Same body as `openai_compat`. The deployment is
the model name in the URL, and the credential rides `api-key` (not Bearer).
`base_url` is the resource host.

```toml
[providers.azure]
kind = "azure_openai"
base_url = "https://contoso.openai.azure.com"
api_key_env = "AZURE_API_KEY"
default_model = "gpt-5.6"
# api_version = "2024-12-01-preview"   # optional; default 2024-10-21
```

### `kind = "gemini"`

Google Gemini generateContent (AI Studio). The key rides `x-goog-api-key`.
`base_url` defaults in the adapter if you paste the public host.

```toml
[providers.google]
kind = "gemini"
base_url = "https://generativelanguage.googleapis.com/v1beta"
api_key_env = "GOOGLE_API_KEY"
default_model = "gemini-3.6-flash"
```

### `auth` — the credential axis

Auth is a separate axis from the wire format, so `kind` says how the request is
*shaped* and `auth` says where the credential *comes from*:

| Value | Meaning |
|---|---|
| `api_key` | Read `api_key_env` and present it the way the wire kind wants (`Bearer` for `openai_compat`/`vertex_anthropic`, `x-api-key` for `anthropic`, `api-key` for `azure_openai`, `x-goog-api-key` for `gemini`). |
| `oauth_static` | A pasted OAuth access token in `api_key_env`, presented as `Authorization: Bearer` plus any provider beta header. |
| `oauth_refresh` | A token minted and renewed in-process. `vertex` and `vertex_anthropic` support it (service-account JWT or gcloud ADC refresh); other kinds reject it rather than downgrade silently. |

Leave it unset unless you need it. Each kind auto-detects: `anthropic` reads an
`sk-ant-oat` prefix as `oauth_static` and anything else as `api_key`;
`vertex` and `vertex_anthropic` pick `oauth_refresh` when no token is in
`api_key_env` (the credentials file is resolved at mint time);
`openai_compat` defaults to `api_key` and does *not* guess, because an API
key and an OAuth token are indistinguishable across the vendors it serves
— set `auth = "oauth_static"` explicitly there.

```toml
[providers.xai]
kind = "openai_compat"                   # the wire format
base_url = "https://api.x.ai/v1"
api_key_env = "XAI_TOKEN"
auth = "oauth_static"                    # ...and where the credential comes from
```

On `openai_compat` that line is documentation today rather than behaviour: an
API key and an OAuth token both ride `Authorization: Bearer` there, so the two
strategies produce the same request. It is the acquisition side (obtaining and
refreshing the token) that an OAuth provider will hang off it, which is
precisely the point of splitting the axes.

An unrecognised value is an error at load, not a fallback: guessing wrong sends
the secret on the wrong header. The design is
[ADR 0005](adrs/0005-auth-is-a-strategy-axis-separate-from-wire-kind.md); the
implementation is `src/llm/auth.zig` plus each provider's `authHeaders`.

## `[models."<provider>/<model>"]`

One table per model. The table key is `"<provider>/<name>"`; the `provider`
field inside links it to a `[providers.<name>]` entry. The name after the slash
is the local id (`--model xai/grok4.6-coding`, the picker). It is also the
API `model` field unless `id` names a different wire SKU. `display` only
changes how it is shown, never what is sent.

Context window, max output, cost, display, and capabilities are filled from
the local models.dev snapshot (`state/models-dev.json`) when omitted. Load
never downloads that file. A value written in the table always wins, so an
alias can keep its own `max_tokens` while inheriting the SKU's window.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `provider` | string | required | Which provider serves this model. |
| `id` | string | unset | Wire SKU. Omit to send the table-key name. Set this to give one SKU two local names with different sampling (`grok4.6-coding` and `grok4.6-general` both `id = "grok-4.6"`). |
| `context_window` | int | models.dev `limit.context`, else 131072 | Total context in tokens; sizes compaction and the improve context budget. Omit to take the snapshot; a written value wins. |
| `max_tokens` | int | models.dev `limit.output`, else 1024 | Per-request output-token cap. Omit to take the snapshot; a written value wins. |
| `temperature` | float | unset | Sampling temperature. |
| `top_p` | float | unset | Nucleus cutoff; best set *instead of* temperature, not alongside. |
| `reasoning_effort` | string | unset | For reasoning models, sent as `reasoning_effort` on the OpenAI-compatible wire (Ollama, DeepSeek, OpenAI, …). One of `"none"`/`"low"`/`"medium"`/`"high"`/`"max"`; keeps chain-of-thought short so `content` stays populated. Unset omits the field; `"none"` disables reasoning explicitly. Invalid values are rejected at load. |
| `display` | string | models.dev `name` | UI label when the wire id is not what a person calls it (e.g. `kimi-k3` shown as `moonshotai/kimi-k3`). Display only. Omit to take the snapshot. |
| `cost_per_1m_input` | float | models.dev `cost.input` | USD per 1M input tokens, for run cost accounting. Omit to take the snapshot. |
| `cost_per_1m_output` | float | models.dev `cost.output` | USD per 1M output tokens. Omit to take the snapshot. |
| `capabilities` | string[] | models.dev reasoning/tool_call/modalities | `"tool_use"`, `"image_in"`, `"video_in"`, `"audio_in"`, `"thinking"`, `"always_thinking"`. Self-documents what the model supports. A model that declares its capabilities but omits `image_in` is treated as non-vision: the webui refuses image attachments to it up front (instead of sending `image_url` blocks that a text-only endpoint such as DeepSeek v4-flash rejects), so declare `image_in` on any model that accepts images. An empty list is filled from the snapshot; a written list is kept as-is. |
| `category` | string | `""` | Free-form grouping (`"flagship"`, `"fast"`, `"reasoning"`, `"cheap"`, ...) used to sort/group the model list in the webui picker, the TUI's `/model` picker, and the CLI. Purely presentational, never sent to a provider. Empty sorts last within its provider. |
| `rpm` | int | unset | Self-imposed requests per minute for this local name. Omit or `0` = no cap. Independent of the provider's `rpm`; both apply when set. |

```toml
[models."deepseek/deepseek-v4-pro"]
provider = "deepseek"
context_window = 1000000
max_tokens = 16384
reasoning_effort = "medium"
cost_per_1m_input = 0.435
cost_per_1m_output = 0.87
capabilities = ["thinking", "tool_use"]

[models."moonshotai/kimi-k3"]
provider = "moonshotai"
context_window = 1048576
max_tokens = 16384
reasoning_effort = "high"
cost_per_1m_input = 3.0
cost_per_1m_output = 15.0
capabilities = ["thinking", "tool_use", "image_in", "video_in"]

[models."xai/grok4.6-coding"]
provider = "xai"
id = "grok-4.6"
temperature = 0.2
rpm = 40

[models."xai/grok4.6-general"]
provider = "xai"
id = "grok-4.6"
temperature = 0.7
```

### Auto-populating model specs

`clanker providers catalog <query>` searches a local snapshot of the
[models.dev](https://models.dev) directory (`state/models-dev.json`), and
`clanker providers fill <name>` prints ready-to-paste `[models."..."]`
tables (context window, costs, capabilities) for a configured provider's
models, so most of the model section can be generated rather than
hand-typed. The snapshot is downloaded the first time something needs it,
then only when `clanker providers refresh` (or Refresh catalog in the
Models view) is asked. Serve start does not contact models.dev.
Only providers whose API and auth clanker implements appear in catalog
search: OpenAI-compatible (Bearer API key), Anthropic Messages (API key
or OAuth by token shape), Vertex Anthropic (GCP `oauth_refresh`), Gemini
AI Studio (`x-goog-api-key`), and Azure OpenAI (`api-key` plus a
resource host). Amazon Bedrock is not in that map.
The table is `src/llm/catalog.zig`.
`clanker providers check` pings every configured provider and reports
latency/cost; `clanker providers models <name>` lists a provider's models.

## `[agent]`

Run-loop and path settings. The commonly-touched keys:

| Key | Default | Meaning |
|---|---|---|
| `max_iterations` | 50 | Tool-call rounds per turn before the run stops. Hitting it errors the turn, so keep it generous for multi-file work. |
| `max_goal_turns` | 50 | Completed agent turns a `/goal` loop may start before it reports a blocked budget outcome. This is separate from `max_iterations`, which applies inside each turn. |
| `provider_check_timeout_seconds` | 10 | Global ceiling for `providers check`; override per provider with `check_timeout_seconds`. |
| `ask_timeout_seconds` | 120 | How long a serve-side `ask_user`/confirm question waits for the browser before giving up. |
| `confirm_writes` | `never` | Gate write-capable tool calls on a human's allow/deny. `browser` asks streaming web runs; `always` also opens the REPL's allow/deny modal. Runs with no human channel are never gated. |
| `fallback_provider` / `fallback_providers` | (unset) | Ordered fallbacks after the selected provider cannot serve a request. A string or an array; later entries are tried in order. Also the preferred vision-routing target. |
| `auto_thinking` | `false` | Per-turn classifier that selects a sampling-profile `reasoning_effort` row. Opt-in. |
| `thinking_classifier_model` | (unset) | `provider` or `provider/model`. Empty = cheapest configured provider. |
| `thinking_classifier_timeout_ms` | 3000 | Wall-clock classifier deadline; timeout aborts its HTTP connection and fails open. |
| `compact_threshold_bytes` | 24000 | Compact conversation history past this size (`0` uses the model window). |
| `tool_result_prune_bytes`, `tool_result_prune_head_bytes`, `tool_result_prune_tail_bytes` | 8192, 4096, 1024 | Request-only head/tail pruning for oversized tool results. Threshold `0` disables it; saved transcripts remain exact. |
| `repeat_tool_thresholds`, `repeat_tool_exclude` | `[3, 5, 8]`, todo tools | Advisory reminders for consecutive canonical-equivalent tool calls. Excluded name patterns (with optional `*`) neither increment nor reset a chain. |
| `max_total_tokens`, `max_tokens_per_turn`, `max_history_tokens` | -, 4096, 16000 | Token budgets that drive compaction. `max_history_tokens` is lifted for a run when it sits below what compaction cannot remove — see [History budget and compaction](#history-budget-and-compaction). |
| `tool_catalog` | true | Send full schemas only for hot tools; let the model request the rest by name (saves thousands of tokens/request with many tools). |
| `hot_tools` | 10 | How many most-used tools keep their schemas loaded unasked. |
| `tools_dir` | `tools/manifests` | One directory or a list. Later-listed wins on a tool `name` collision. |
| `skills_dir`, `workflows_dir`, `chains_dir`, `state_dir`, `sandbox_root` | see defaults | Where the harness reads skills/state. |
| `sandbox_follow_symlinks` | `false` | Allow a component of an already-granted sandbox path to be a symlink. Following a link out of the sandbox root is a known security risk, so it is off unless asked for; turn it on when a granted prefix deliberately lives elsewhere, such as a `state/` symlinked into backed-up storage, where leaving it off refuses every guest read and write under `state/`. It never widens which prefixes a tool is granted. Deliberate and opt-in: read [ADR 0017](adrs/0017-sandbox-symlink-traversal-is-opt-in.md) before treating its existence as a security finding — what to audit is the default, not the flag. |
| `system_prompt_file`, `learnings_file`, `global_instructions_file` | see defaults | Prompt-assembly inputs. |
| `git_remote_ops` | false | Whether the `git` tool may run `push`/`merge`/`checkout` (the rest of the deny list still applies). |
| `git_commit` | true | Commit promoted self-improvements with git. |
| `exec_pattern_allow` | `[]` | Extra `ck_exec` command patterns to permit. |
| `repl_exec_allow` | `[]` | Extra commands the REPL's `!cmd` escape may run, on top of the union of every tool's `exec_allow`. Widens the escape only, never a tool; the deny tokens and git's verb allowlist still apply. |
| `worktree` | `auto` | Default worktree isolation for a plain `clanker run` when neither `--worktree` nor `--no-worktree` is given. `yes`/`no` force a default for typed runs; `auto` keeps them unisolated. An explicit flag still wins. |
| `goal_worktree` | `auto` | Same, but for `--goal` runs and scheduled (`unattended`) runs. `auto` keeps those isolated by default; `yes`/`no` force a default. |
| `git_worktree_on` | `[]` | Session modes that default to a private worktree: any of `run`, `goal`, `tui`, or `webui`. An explicit `--worktree`/`--no-worktree` or Web UI checkbox still wins. |
| `isolated_cli` | `false` | Plain `clanker run` calls use a private worktree and do not implicitly attach the newest active goal. |
| `isolated_tui` | `false` | The terminal REPL starts in a private worktree for the whole session. |
| `isolated_webui` | `false` | Web UI chat runs use a private worktree and do not implicitly attach the newest active goal. |
| `seed` | 0 | RNG seed for reproducibility (`0` = time-seeded). |

### History budget and compaction

Compaction keeps the system message and the last six messages and replaces
everything between them with a summary. Those kept parts are immovable: no
setting makes compaction able to drop them.

That matters when the budget is set below what they cost. `max_history_tokens`
is an absolute number, not a share of the model's window, so a 16000-token
default applies unchanged to a model with a 1M-token window — and a system
prompt of 14000 tokens (a large `AGENTS.md` plus a grown `state/learnings.md`
will do it) leaves almost nothing for the conversation. Compaction would then be
demanded on every iteration and free nothing on any of them.

A run therefore lifts its own threshold when the configured one sits below that
floor, with headroom, and never past what the model's context window allows. It
says so once:

```
[WARN] history threshold 16000 is below the 20774 tokens compaction cannot remove
       (system prompt plus the 6 kept messages); using 31161 for this run
```

Treat that line as a prompt to set the budget properly: the lift keeps the run
alive, it does not make 16000 a sensible cap for a large-window model.

A run that still needs to compact on five consecutive iterations ends with
`error.CompactionStalled` rather than continuing to the iteration cap, and prints
both ceilings — the configured cap and what the model's window leaves compaction
— because raising the cap only helps when the model has the room. The recovery
is [the compaction thrash runbook](runbooks/agent-run-compaction-thrash.md).

## `[hooks]`

Claude Code-compatible lifecycle hooks. Disabled by default; when disabled,
the hook file is not read. Commands receive the event payload as JSON on
stdin and run under the same scrubbed environment, command allowlist, argv
denials, and worktree root as the TUI's `!` escape.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Load and run lifecycle hooks for newly constructed agents. |
| `config_path` | `hooks.json` | Claude Code `hooks.json`, or a settings JSON object containing a `hooks` key. |
| `default_timeout_ms` | 60000 | One wall-clock deadline per command; a hook entry's `timeout` seconds overrides it. |

Supported events are `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, and `Stop`. Exit code 2 blocks with stderr as its reason;
Claude-style JSON decisions and `additionalContext` are also honored.

## `[advisor]`

Post-turn second-model critique. Off by default. Distinct from
`improve.arena_advisory`.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Review each completed tool batch and inject any note into the next agent iteration. |
| `provider` | (unset) | Provider name; falls back to `default_provider`. |
| `model` | (unset) | Model name on that provider. |
| `scope` | `turn` | `turn` = last user turn; `session` = last `context_turns` user turns. |
| `context_turns` | 3 | How many user turns `scope = "session"` sends. |
| `timeout_ms` | 5000 | Wall-clock review deadline; timeout aborts the request and fails open. |

## `[kernel]`

Python/JS eval kernels. Off by default. The Python path runs under a real
WASI sandbox when `./scripts/setup-python-wasi.sh` has fetched the
interpreter; without it, calls fall back to an unsandboxed `python3`
subprocess and log a deprecation warning (ADR 0010). Do not flip `enabled`
on in a recommended config while relying on that fallback, until cgroups
quotas exist for it — the WASI path needs no such quotas, it has its own
fuel/memory/timeout limits.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Start kernels. Off = the tool returns a disabled error. |
| `max_output_bytes` | 65536 | Cap on returned stdout/stderr/result. |
| `cleanup_delay_ms` | 5000 | Delay before deleting `state/kernels/<session>/` after SIGTERM. |
| `python_wasi_binary` | `vendor/python-wasi/bin/python-3.12.0.wasm` | Vendored WASI interpreter path; absent means the unsandboxed fallback. |
| `python_wasi_stdlib` | `vendor/python-wasi/usr/local/lib` | Stdlib directory, preopened read-only into the guest at `/usr/local/lib`. |
| `python_wasi_fuel` | 5000000000 | Instruction budget (engine-specific units, not wall-clock). |
| `python_wasi_timeout_ms` | 30000 | Wall-clock deadline; a timeout traps the sandboxed cell. |
| `python_wasi_max_memory_bytes` | 268435456 | Guest linear-memory cap. |

## `[debug]`

Debug Adapter Protocol client. Off by default — an adapter is an
unsandboxed subprocess (ADR 0010 / 0011 carve-out). Do not flip
`enabled` on in a recommended config.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Start adapters. Off = the tool returns a disabled error. |
| `disconnect_timeout_ms` | 3000 | How long to wait after `disconnect`/`terminate` before SIGTERM. |
| `launch_timeout_ms` | 15000 | How long to wait for the adapter's `initialized` event. |
| `adapters.<name>.command` | (unset) | argv to spawn. v1 requires an explicit `adapter` on `launch`. |

## `[modules]`

Feature toggles, all boolean. All default `true` except `acp` and `mesh`, which
default `false`. Turning
one off removes its tools, endpoints, and prompt surface: `mcp`, `peers`,
`a2a`, `webui`, `graphs`, `sessions`, `goal`, `goal_auto_steer`,
`token_budget`, `streaming`, `dotenv`, `hot_reload`, `autolearn`, `subagents`,
`rlm`, `multimodal`, `chatrooms`, `token_stats`, `acp`, `mesh`.
`mesh` is the TCP cluster (`clanker mesh`, `/api/mesh/*`); it is not the
HTTP `[[peers]]` list. Off until you turn it on and restart serve.

`goal_auto_steer` is the one that is not a whole subsystem: off, the goal module
stays on — explicit `--goal`, `goal`, `/goal`, `write-goal`, `add-goal`, and
tracking all still work — but a run
with no goal named stops attaching itself to whatever goal is newest.

`goal` and `/goal` start a multi-turn goal loop; `--goal <id>` starts that
same loop from a saved goal. They are not aliases for one ordinary agent turn.

```toml
[modules]
mcp = true
peers = false        # single-instance: no peer HTTP, no phonebook
chatrooms = false
mesh = false         # TCP cluster; clanker mesh talks to local serve
```

## `[mesh]`

TCP peer-to-peer cluster (PRD 0011). Serve owns the sockets.
`clanker mesh` is a loopback HTTP client of that serve. `--webui-port`
selects which local serve when several run on one host. Same-host
processes use the same join/leave/status as two machines; they need
distinct `instance.id`, `listen_port`, web UI port, and `agent.state_dir`.

Empty `instance.id` is a startup error for the listener. Default bind is
loopback so turning the module on is not a LAN socket.

| Key | Default | Meaning |
|---|---|---|
| `listen_host` | `"127.0.0.1"` | Mesh TCP bind, independent of `[serve].host` |
| `listen_port` | `7420` | Mesh TCP port |
| `ping_interval_seconds` | `15` | Liveness ping |
| `admission` | `"allowlist"` | `allowlist`, `prompt` (queue for `clanker mesh admit`/`deny`), or `open` |
| `max_members` | `32` | Cap on admitted members |
| `max_pending_joins` | `8` | Prompt-mode queue depth |
| `prompt_timeout_seconds` | `120` | Pending JOIN timeout (refuse) |
| `max_frame_bytes` | `1048576` | Incoming frame cap |
| `max_file_bytes` | `33554432` | Phase 3 file-share cap |
| `file_chunk_bytes` | `32768` | Phase 3 chunk size |

```toml
[instance]
id = "main"

[modules]
mesh = true

[mesh]
listen_host = "127.0.0.1"
listen_port = 7420
admission = "allowlist"
```

A second process on the same host uses another `id`, `listen_port`,
`[serve].webui_port`, and `agent.state_dir`, then
`clanker mesh join 127.0.0.1:7420 --webui-port 17922`.

## Other sections

- **`[instance]`** — `name` and `id`. Mesh addresses members by `id`,
  not `name`. Empty `id` refuses to bind the mesh listener.
- **`[serve]`** — what `clanker serve` binds, for a deployment that cannot pass
  flags: `host` (interface, default `127.0.0.1`), `webui_port` (default
  `17921`), and `serve_as` (a TOML array of hostnames the server may present
  itself as). `proxy` (default false) mounts an OpenAI/Anthropic compatibility
  surface at `/proxy/v1` on the same socket; `proxy_port` is an optional second
  listener with `/v1` at the root. `proxy_token_env` names an env var holding
  a local token (never a secret in TOML); `proxy_aliases` maps client-facing
  model names to configured `provider/model` ids. `proxy_first_byte_timeout_s`
  and `proxy_idle_timeout_s` default to 300 and 60 seconds respectively; `0`
  disables either ceiling. The weakest of three layers —
  `CLANKER_HOST` / `CLANKER_WEBUI_PORT` / `CLANKER_PROXY_PORT` override it, and
  `--host` / `--webui-port` / `--serve-as` / `--proxy` / `--no-proxy` /
  `--proxy-port` override those. Field-merged, so a `config.local.toml` that
  only sets `host` keeps a base `proxy = true`. With no proxy enabled, the
  process opens exactly one socket; a distinct `proxy_port` opens the only
  second listener.

  ```toml
  [serve]
  host = "0.0.0.0"
  webui_port = 17921
  serve_as = ["clanker.lan"]
  proxy = true
  proxy_token_env = "CLANKER_PROXY_TOKEN"
  ```
- **`[[peers]]`** — repeated tables of `name` + `url`, other `clanker serve`
  instances this one can notify and share chatrooms/board with. Optional `id`
  is the mesh allowlist key (PRD 0011). Outbound only: a peer URL is
  something this process connects to, never a port it opens, so nothing
  here is exposed by binding `serve` more widely.
- **`[chatrooms]`** — `on`, `rooms` (default subscriptions), `max_history`.
- **`[memory]`** — RAG backend. One key at the top level, `backend`
  (`hybrid`/`vector`/`keyword`); everything else lives in a sub-table, so the
  spellings are `[memory.chunk]` `size`/`overlap`/`strategy`,
  `[memory.embedding]` `provider`/`model`, and `[memory.vector]`
  `backend`/`top_k`/`threshold`. (Note: several fields here are parsed but not
  yet honored by the WASM memory tool — see `docs/prds/0007-memory.md` Known
  issues.)

  | Key | Default |
  | --- | --- |
  | `backend` | `"hybrid"` |
  | `chunk.size` | `800` |
  | `chunk.overlap` | `120` |
  | `chunk.strategy` | `"markdown"` |
  | `embedding.provider` | `""` (unset) |
  | `embedding.model` | `""` (unset) |
  | `vector.backend` | `"builtin"` |
  | `vector.top_k` | `5` |
  | `vector.threshold` | `0.35` |

  ```toml
  [memory]
  backend = "hybrid"

  [memory.chunk]
  size = 800
  overlap = 120
  strategy = "markdown"

  [memory.vector]
  backend = "builtin"
  top_k = 5
  threshold = 0.35
  ```
- **`[web]`** — `allow`: hostnames the research tools (`web_fetch`,
  `web_search`) may reach, added to their sandbox `network_allow` at load. A
  research site is a config edit, not a manifest edit. Entries may use `*` and
  `?` globs, and a bare `"*"` allows any host.
- **`[ttsr]`** — turn-time self-repair: watch the stream for a pattern and
  inject a correction instead of letting the turn fail on a known-shaped
  mistake. `max_retries_per_turn`, `buffer_bytes`, and repeated
  `[[ttsr.rules]]` tables of `name` / `pattern` / `inject` / `max_fires`. No
  rules by default, which leaves the whole thing inert.
- **`[improve]`** — self-improvement loop gates: `capability_gate`,
  `inert_gate`, `plan_phase`, `max_consecutive_test_only`, `eval_provider`,
  `max_cache_bytes`, `arena_advisory`, and more. See `src/config.zig` `Improve`
  and `AGENTS.md`.
- **`[tui]`** — REPL appearance. Only the mascot lives here so far; the colour
  theme is still `CLANKER_THEME` plus the session-scoped `/theme`, because
  moving it would change behaviour rather than just add a key.

  `mascot` is an opt-in easter egg: a small robot animated from an eleven-frame
  run cycle. The renderer is chosen from the terminal's own answer to a
  capability query — kitty graphics first, then sixel, then unicode
  half-blocks — and never from `$TERM` or a terminal name, because ssh and
  multiplexers change what reaches the process. There is no key to force one:
  a terminal that claims a protocol it cannot do would leave the mascot
  invisible.

  | Key | Default | Values |
  | --- | --- | --- |
  | `mascot` | `"off"` | `off`, `type`, `loop`, `place`, `input` |
  | `mascot_size` | `""` (= per mode) | `mini`, `xsmall`, `small`, `medium`, `large` |
  | `mascot_facing` | `""` (= per mode) | `default`, `inverted` |
  | `mascot_speed` | unset (= `5`) | Integer `0` through `10`; `0` never moves, `10` is fastest |

  The modes differ in where the robot lives and what moves it:

  - `type` — position tracks the composer, one column per byte typed. Stands
    still between keystrokes, and mirrors horizontally while you backspace.
  - `loop` — runs across the width, off the right edge, back in from the left,
    ignoring what you are doing.
  - `place` — runs on the spot, bottom right above the box, facing left by
    default.
  - `input` — runs on the spot *inside* the box, at its bottom right. At its
    default size the box keeps the three rows it has with no mascot at all; a
    larger size grows it. Either way the text field is narrowed by the robot's
    width, so a long line can never run underneath it. The only mode that costs
    no transcript rows.

  `mascot_size` picks a 6x1, 7x2, 8x4, 10x5 or 21x10 cell grid, needing a
  terminal of at least 8x9, 9x10, 10x12, 12x13 or 23x18 respectively; below
  that the mascot is skipped rather than clipped.

  Unset means "per mode", not "medium": `input` defaults to `mini`, the one
  size that fits the ordinary composer, and every other mode defaults to
  `medium`, where the rows come out of the transcript and shrinking the robot
  buys nothing. Below `small` the robot is a silhouette and its eye — the
  generator drops its emptiness threshold and leans harder on the eye to keep
  even that (`src/tui/mascot/gen_frames.py`).

  `mascot_facing` applies in every mode: `inverted` mirrors whatever the
  mode's natural orientation is, so it flips `type`'s travel, reverses `loop`,
  and faces `place` and `input` the other way.

  `mascot_speed` is an integer setting: write an unquoted value from `0`
  through `10`. Unset is the regular pace (`5`); `0` freezes movement, and
  `10` is the fastest. `--mascot-speed <0..10>` overrides it for one REPL
  session.

  `--mascot[=<mode>]`, `--mascot-size`, `--mascot-facing`, and
  `--mascot-speed` override these settings for one session; a bare `--mascot`
  means `loop`. An invalid command-line value — or an unparseable `mascot`,
  `mascot_size`, or `mascot_facing` from config — is reported on the transcript
  and falls back rather than refusing to start the REPL; only an out-of-range
  `mascot_speed` in config is rejected while loading the configuration.

  ```toml
  [tui]
  mascot = "input"
  mascot_size = "small"
  mascot_speed = 6
  ```

## Minimal working config

The smallest useful `config.toml`: one keyless local model.

```toml
default_provider = "ollama"

[providers.ollama]
kind = "openai_compat"
base_url = "http://127.0.0.1:11434/v1"
default_model = "qwen3.5"

[models."ollama/qwen3.5"]
provider = "ollama"
context_window = 32768
```

Add a hosted provider by giving it an `api_key_env` and putting the key in
`.env`:

```toml
# config.local.toml
default_provider = "deepseek"

[providers.deepseek]
kind = "openai_compat"
base_url = "https://api.deepseek.com"
api_key_env = "DEEPSEEK_API_KEY"
default_model = "deepseek-v4-pro"

[models."deepseek/deepseek-v4-pro"]
provider = "deepseek"
context_window = 1000000
max_tokens = 16384
```

```bash
# .env
DEEPSEEK_API_KEY=sk-...
```

Then `clanker providers check` confirms it answers, and `clanker "hello"` runs
against it.
