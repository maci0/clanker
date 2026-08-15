# Free LLM endpoints for testing

Where to get no-cost tokens for exercising clanker's provider kinds
without burning paid keys. Verified means a request from this repo
actually succeeded on the date noted; unverified rows are from vendor
docs and need a smoke test before relying on them.

Keys live in `~/.secrets/` (never in the repo). Wire them with
`api_key_env` pointing at an exported variable, not a file path.

## Verified

### NVIDIA build (integrate.api.nvidia.com) — verified 2026-08-15

- Endpoint: `https://integrate.api.nvidia.com/v1/chat/completions`,
  plain OpenAI wire (`kind = "openai_compat"`), `Authorization: Bearer`.
- Catalog: [build.nvidia.com](https://build.nvidia.com) hosts a long
  list of free hosted endpoints across vendors (NVIDIA Nemotron, Llama,
  Qwen, DeepSeek, GLM, Mistral, ...). Model ids are `vendor/model`
  composites with a slash (`z-ai/glm-5.2`,
  `nvidia/nemotron-3.5-lightning-30b-a3b`), which clanker's opaque
  slash-id handling already supports.
- Cost: free with a build.nvidia.com account (credit-based; hosted
  endpoints are metered generously for development, not production).
  Observed limit on this account: 40 requests/min.
- Key: `~/.secrets/nvidia-build`.

```toml
[providers.nvidia]
kind = "openai_compat"
base_url = "https://integrate.api.nvidia.com/v1"
api_key_env = "NVIDIA_API_KEY"

[models."nvidia/z-ai/glm-5.2"]
provider = "nvidia"
context_window = 131072
max_tokens = 16384
capabilities = ["thinking", "tool_use"]
```

### Google AI Studio (Gemini API) — free tier, no GCP billing

- `kind = "gemini"`, base
  `https://generativelanguage.googleapis.com/v1beta`, key on
  `x-goog-api-key` (the committed `[providers.google]` entry).
- The Gemini API has its own free tier through
  [AI Studio](https://aistudio.google.com): an API key with real free
  quota on flash-class models, rate-limited per minute/day. Separate
  from GCP billing entirely; explicitly NOT covered by the $300 GCP
  trial credit.

### Groq — free plan, verified from docs 2026-08-15

- OpenAI-compatible (`kind = "openai_compat"`), base
  `https://api.groq.com/openai/v1`.
- Free plan: ~30 requests/min, 6K-15K tokens/min across
  `llama-3.3-70b-versatile`, `llama-3.1-8b-instant`,
  `openai/gpt-oss-120b`, `qwen/qwen3.6-27b`, Whisper STT, and more.
  Fast inference, good for latency-path testing (TTFT, streaming).

## GCP free tier (for the Vertex kinds)

From [the free-tier docs](https://cloud.google.com/free/docs/gcp-free-tier):

- **`kind = "vertex"` (Gemini on Vertex)**: the $300 / 90-day trial
  credit applies to first-party Gemini models billed through GCP. Also
  exercises the `oauth_refresh` / service-account auth path.
- **`kind = "vertex_anthropic"` (Claude on Vertex)**: NOT covered; the
  credit excludes partner managed-API models. Costs real money.
- The always-free GCP items (Vision, NL API, STT minutes) are unrelated
  APIs clanker does not call.

## Unverified, worth a smoke test

- **Mistral La Plateforme**: a free "Experiment" tier exists (rate-limited
  access to open models), OpenAI-ish native API at
  `https://api.mistral.ai/v1`. Docs URL moves around; verify limits
  before use.
- **Cerebras Inference**: free tier with high tokens/s on Llama-class
  models, OpenAI-compatible at `https://api.cerebras.ai/v1`.
- **OpenRouter `:free` models**: `https://openrouter.ai/api/v1` lists
  models with a `:free` suffix (rate-limited community pool). One key,
  many vendors; useful for breadth tests of odd model ids.
- **GitHub Models**: free with a GitHub account,
  `https://models.github.ai/inference` (OpenAI wire, PAT auth); tight
  daily caps but zero setup for GPT/Llama/Phi-class smoke tests.
- **Cloudflare Workers AI**: 10K neurons/day free allocation, REST
  endpoint per account; not plain OpenAI wire everywhere, check before
  wiring a provider entry.

## What to test with what

| clanker kind | free source |
|---|---|
| `openai_compat` | NVIDIA build, Groq, Cerebras, OpenRouter free, GitHub Models |
| `gemini` | AI Studio free tier |
| `vertex` | GCP $300 trial credit |
| `vertex_anthropic` | none (paid only) |
| `azure_openai` | none free (Azure trial credit exists but needs an Azure account) |
| `anthropic` | none (paid only) |
