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
  `default_provider`, or a local vLLM URL here.
- **`.env`** — API keys. clanker loads it at startup (the `dotenv` module) into
  the process environment; a provider names the variable to read with
  `api_key_env`. Keys never go in the TOML.

TOML is the only supported format (there is no JSON config). A missing key
takes its default; an unknown key logs a warning and is ignored (so a typo like
`mx_iterations` does not silently misbehave, it warns and uses the default).

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
| `kind` | string | Wire format: `openai_compat` (default), `anthropic`, or `vertex_anthropic`. See below. |
| `base_url` | string | Endpoint base. `openai_compat` appends `/chat/completions`, `anthropic` appends `/v1/messages`, unless `path` overrides. |
| `api_key_env` | string | Name of the `.env` variable holding the credential. Omit for a keyless local endpoint (ollama, vLLM). |
| `auth` | string | Credential-acquisition strategy: `api_key`, `oauth_static` or `oauth_refresh`. Optional — each `kind` auto-detects where the credential types are distinguishable. See below. |
| `default_model` | string | Which of this provider's models is active by default. |
| `path` | string | Override the endpoint path (rarely needed). |
| `check_timeout_seconds` | int | How long `providers check` waits for this endpoint before giving up, overriding the global `agent.provider_check_timeout_seconds`. `0` = no ceiling. |
| `project`, `location`, `service_account_file` | string | `vertex_anthropic` only (see below). |

### `kind = "openai_compat"`

Any OpenAI-compatible `/chat/completions` endpoint: OpenAI, DeepSeek, Moonshot
(Kimi), OpenRouter, Together, a local ollama or vLLM, etc. The credential rides
`Authorization: Bearer <key>`.

```toml
[providers.deepseek]
kind = "openai_compat"
base_url = "https://api.deepseek.com"
api_key_env = "DEEPSEEK_API_KEY"
default_model = "deepseek-v4-flash"

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
URL and auth is a GCP OAuth token, minted in-process from a service account and
refreshed automatically (no `gcloud`, no subprocess).

```toml
[providers.vertex]
kind = "vertex_anthropic"
base_url = "https://<location>-aiplatform.googleapis.com"
project = "my-gcp-project"
location = "us-east5"
service_account_file = "/path/to/service-account.json"
default_model = "claude-sonnet-5"
# or, instead of service_account_file, paste a short-lived token:
# api_key_env = "VERTEX_ACCESS_TOKEN"
```

### `auth` — the credential axis

Auth is a separate axis from the wire format, so `kind` says how the request is
*shaped* and `auth` says where the credential *comes from*:

| Value | Meaning |
|---|---|
| `api_key` | Read `api_key_env` and present it the way the wire kind wants (`Bearer` for `openai_compat`/`vertex_anthropic`, `x-api-key` for `anthropic`). |
| `oauth_static` | A pasted OAuth access token in `api_key_env`, presented as `Authorization: Bearer` plus any provider beta header. |
| `oauth_refresh` | A token minted and renewed in-process. Only `vertex_anthropic` supports it today (from `service_account_file`); other kinds reject it rather than downgrade silently. |

Leave it unset unless you need it. Each kind auto-detects: `anthropic` reads an
`sk-ant-oat` prefix as `oauth_static` and anything else as `api_key`;
`vertex_anthropic` picks `oauth_refresh` when `service_account_file` is set and
no token is in `api_key_env`; `openai_compat` defaults to `api_key` and does
*not* guess, because an API key and an OAuth token are indistinguishable across
the vendors it serves — set `auth = "oauth_static"` explicitly there.

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

One table per model. The table key is `"<provider>/<model>"`; the `provider`
field inside links it to a `[providers.<name>]` entry. The model name (the part
after the slash) is what gets sent as the API `model` field, unless `display`
overrides how it is *shown* (never what is *sent*).

| Key | Type | Default | Meaning |
|---|---|---|---|
| `provider` | string | required | Which provider serves this model. |
| `context_window` | int | 131072 | Total context in tokens; sizes compaction and the improve context budget. |
| `max_tokens` | int | 1024 | Per-request output-token cap. |
| `temperature` | float | unset | Sampling temperature. |
| `top_p` | float | unset | Nucleus cutoff; best set *instead of* temperature, not alongside. |
| `reasoning_effort` | string | unset | For reasoning models, sent as `reasoning_effort` on the OpenAI-compatible wire (Ollama, DeepSeek, OpenAI, …). One of `"none"`/`"low"`/`"medium"`/`"high"`/`"max"`; keeps chain-of-thought short so `content` stays populated. Unset omits the field; `"none"` disables reasoning explicitly. Invalid values are rejected at load. |
| `display` | string | unset | UI label when the wire id is not what a person calls it (e.g. `kimi-k3` shown as `moonshotai/kimi-k3`). Display only. |
| `cost_per_1m_input` | float | unset | USD per 1M input tokens, for run cost accounting. |
| `cost_per_1m_output` | float | unset | USD per 1M output tokens. |
| `capabilities` | string[] | `[]` | `"tool_use"`, `"image_in"`, `"video_in"`, `"audio_in"`, `"thinking"`, `"always_thinking"`. Self-documents what the model supports. A model that declares its capabilities but omits `image_in` is treated as non-vision: the webui refuses image attachments to it up front (instead of sending `image_url` blocks that a text-only endpoint such as DeepSeek v4-flash rejects), so declare `image_in` on any model that accepts images. A model with no `capabilities` declared is left unknown and the attachment is attempted. |
| `category` | string | `""` | Free-form grouping (`"flagship"`, `"fast"`, `"reasoning"`, `"cheap"`, ...) used to sort/group the model list in the webui picker, the TUI's `/model` picker, and the CLI. Purely presentational, never sent to a provider. Empty sorts last within its provider. |

```toml
[models."deepseek/deepseek-v4-flash"]
provider = "deepseek"
context_window = 1048576
max_tokens = 8192
temperature = 0.2
reasoning_effort = "low"
cost_per_1m_input = 0.14
cost_per_1m_output = 0.28
capabilities = ["thinking", "tool_use"]

[models."kimi-k3/kimi-k3"]
provider = "kimi-k3"
context_window = 1048576
max_tokens = 16384
reasoning_effort = "high"
cost_per_1m_input = 3.0
cost_per_1m_output = 15.0
display = "moonshotai/kimi-k3"
capabilities = ["thinking", "tool_use", "image_in", "video_in"]
```

### Auto-populating model specs

`clanker providers catalog <query>` searches the public
[models.dev](https://models.dev) directory, and `clanker providers fill <name>`
prints ready-to-paste `[models."..."]` tables (context window, costs,
capabilities) for a configured provider's models, so most of the model section
can be generated rather than hand-typed. `clanker providers check` pings every
configured provider and reports latency/cost; `clanker providers models <name>`
lists a provider's models.

## `[agent]`

Run-loop and path settings. The commonly-touched keys:

| Key | Default | Meaning |
|---|---|---|
| `max_iterations` | 50 | Tool-call rounds per turn before the run stops. Hitting it errors the turn, so keep it generous for multi-file work. |
| `provider_check_timeout_seconds` | 10 | Global ceiling for `providers check`; override per provider with `check_timeout_seconds`. |
| `ask_timeout_seconds` | 120 | How long a serve-side `ask_user`/confirm question waits for the browser before giving up. |
| `confirm_writes` | `never` | Gate write-capable tool calls on a human's allow/deny. `browser` asks streaming web runs; `always` is reserved for the REPL and behaves like `browser` today. |
| `fallback_provider` | (unset) | Provider to route image-bearing work to when the selected provider has no vision-capable model. |
| `compact_threshold_bytes` | 24000 | Compact conversation history past this size (`0` uses the model window). |
| `max_total_tokens`, `max_tokens_per_turn`, `max_history_tokens` | -, 4096, 16000 | Token budgets that drive compaction. |
| `tool_catalog` | true | Send full schemas only for hot tools; let the model request the rest by name (saves thousands of tokens/request with many tools). |
| `hot_tools` | 10 | How many most-used tools keep their schemas loaded unasked. |
| `tools_dir`, `skills_dir`, `workflows_dir`, `chains_dir`, `state_dir`, `sandbox_root` | see defaults | Where the harness reads tools/skills/state. |
| `system_prompt_file`, `learnings_file`, `global_instructions_file` | see defaults | Prompt-assembly inputs. |
| `git_remote_ops` | false | Whether the `git` tool may run `push`/`merge`/`checkout` (the rest of the deny list still applies). |
| `git_commit` | true | Commit promoted self-improvements with git. |
| `exec_pattern_allow` | `[]` | Extra `ck_exec` command patterns to permit. |
| `repl_exec_allow` | `[]` | Extra commands the REPL's `!cmd` escape may run, on top of the union of every tool's `exec_allow`. Widens the escape only, never a tool; the deny tokens and git's verb allowlist still apply. |
| `seed` | 0 | RNG seed for reproducibility (`0` = time-seeded). |

## `[modules]`

Feature toggles, all boolean, all default `true` (except where noted). Turning
one off removes its tools, endpoints, and prompt surface: `mcp`, `peers`,
`a2a`, `webui`, `graphs`, `sessions`, `goal`, `token_budget`, `streaming`,
`dotenv`, `hot_reload`, `autolearn`, `subagents`, `rlm`, `multimodal`,
`chatrooms`, `token_stats`.

```toml
[modules]
mcp = true
peers = false        # single-instance: no peer HTTP, no phonebook
chatrooms = false
```

## Other sections

- **`[instance]`** — `name` and `id`, this clanker's identity to peers.
- **`[serve]`** — what `clanker serve` binds, for a deployment that cannot pass
  flags: `host` (interface, default `127.0.0.1`), `webui_port` (default
  `17921`), and `serve_as` (a TOML array of hostnames the server may present
  itself as). `proxy` (default false) mounts an OpenAI/Anthropic compatibility
  surface at `/proxy/v1` on the same socket; `proxy_port` is an optional second
  listener with `/v1` at the root. `proxy_token_env` names an env var holding
  a local token (never a secret in toml). The weakest of three layers —
  `CLANKER_HOST` / `CLANKER_WEBUI_PORT` / `CLANKER_PROXY_PORT` override it, and
  `--host` / `--webui-port` / `--serve-as` / `--proxy` / `--no-proxy` /
  `--proxy-port` override those. Field-merged, so a `config.local.toml` that
  only sets `host` keeps a base `proxy = true`. Without `--proxy` the process
  opens exactly one socket.

  ```toml
  [serve]
  host = "0.0.0.0"
  webui_port = 17921
  serve_as = ["clanker.lan"]
  # proxy = true
  # proxy_token_env = "CLANKER_PROXY_TOKEN"
  ```
- **`[[peers]]`** — repeated tables of `name` + `url`, other `clanker serve`
  instances this one can notify and share chatrooms/board with. Outbound only:
  a peer URL is something this process connects to, never a port it opens, so
  nothing here is exposed by binding `serve` more widely.
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
- **`[web]`** — `allow`: hostnames the research tools (`fetch_web`,
  `web_search`) may reach, added to their sandbox `network_allow` at load. A
  research site is a config edit, not a manifest edit. Entries may use `*` and
  `?` globs, and a bare `"*"` allows any host.
- **`[improve]`** — self-improvement loop gates: `capability_gate`,
  `inert_gate`, `plan_phase`, `max_consecutive_test_only`, `eval_provider`,
  `max_cache_bytes`, `arena_advisory`, and more. See `src/config.zig` `Improve`
  and `AGENTS.md`.

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
default_model = "deepseek-v4-flash"

[models."deepseek/deepseek-v4-flash"]
provider = "deepseek"
context_window = 1048576
max_tokens = 8192
```

```bash
# .env
DEEPSEEK_API_KEY=sk-...
```

Then `clanker providers check` confirms it answers, and `clanker "hello"` runs
against it.
