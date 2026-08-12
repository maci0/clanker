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

## `[providers.<name>]`

| Key | Type | Meaning |
|---|---|---|
| `kind` | string | Wire format: `openai_compat` (default), `anthropic`, or `vertex_anthropic`. See below. |
| `base_url` | string | Endpoint base. `openai_compat` appends `/chat/completions`, `anthropic` appends `/v1/messages`, unless `path` overrides. |
| `api_key_env` | string | Name of the `.env` variable holding the credential. Omit for a keyless local endpoint (ollama, vLLM). |
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

Auth is a separate axis from the wire format; the full picture (and the target
`api_key` / `oauth_static` / `oauth_refresh` design) is in the LLM-providers
section of `docs/README.md` and
[ADR 0005](adrs/0005-auth-is-a-strategy-axis-separate-from-wire-kind.md).

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
| `reasoning_effort` | string | unset | For reasoning models: `"low"`/`"medium"`/`"high"`, keeps chain-of-thought short so `content` stays populated. |
| `display` | string | unset | UI label when the wire id is not what a person calls it (e.g. `kimi-k3` shown as `moonshotai/kimi-k3`). Display only. |
| `cost_per_1m_input` | float | unset | USD per 1M input tokens, for run cost accounting. |
| `cost_per_1m_output` | float | unset | USD per 1M output tokens. |
| `capabilities` | string[] | `[]` | Informational: `"tool_use"`, `"image_in"`, `"video_in"`, `"audio_in"`, `"thinking"`, `"always_thinking"`. Self-documents what the model supports. |

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
- **`[[peers]]`** — repeated tables of `name` + `url`, other `clanker serve`
  instances this one can notify and share chatrooms/board with.
- **`[chatrooms]`** — `on`, `rooms` (default subscriptions), `max_history`.
- **`[memory]`** — RAG backend: `backend` (`hybrid`/`vector`/`keyword`),
  `chunk_strategy`/`chunk_size`/`chunk_overlap`, `vector_top_k`,
  `vector_threshold`. (Note: several fields here are parsed but not yet honored
  by the WASM memory tool — see `docs/prds/0007-memory.md` Known issues.)
- **`[web]`** — `allow`: hostnames the research tools (`fetch_web`,
  `web_search`) may reach, added to their sandbox `network_allow` at load. A
  research site is a config edit, not a manifest edit.
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
