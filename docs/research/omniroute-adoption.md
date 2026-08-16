# Research — OmniRoute ideas clanker could adopt

## Status

Current — searched 2026-08-16.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Which OmniRoute mechanisms would reduce clanker's token cost or failed-turn
rate without violating existing ADRs (native providers, native auth, host
fan-out), and in what impact order?

"Should we become OmniRoute" is not the question. OmniRoute is a Node/Next
gateway that sits in front of other coding agents. Clanker is the agent.
The useful comparison is mechanism-by-mechanism: what they run on the request
path that we do not.

## TL;DR

Ranked by impact on clanker (not by OmniRoute's marketing weight):

- **Command-aware tool-result filters beat our head/tail prune.** RTK keeps
  errors and drops progress bars, repeated test-pass lines, and ANSI noise.
  Their own docs say 78–95% only on *eligible* (redundant) traffic; clean
  greps save near zero. — `high` on the idea, `medium` on the headline
  number — [RTK](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/compression/RTK_COMPRESSION.md)
- **Resilience is three scopes, not one retry loop.** Provider circuit
  breaker, per-key cooldown, per-model lockout. We retry the same provider
  three times, then walk `fallback_providers`. A known-bad key still eats
  those three attempts on the next turn. — `high` —
  [resilience](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/architecture/RESILIENCE_GUIDE.md)
- **Fallback today is reactive.** We swap after a failed request. Their
  useful strategies (fill-first, headroom, reset-aware, last-known-good)
  pick the next target *before* the 429. Quota *telemetry* is still their
  own "next" item as of v3.8.50. — `high` idea, `medium` on live quota
  data — [AUTO-COMBO](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/routing/AUTO-COMBO.md)
- **Do not copy the 340-provider catalog, TLS stealth, or OAuth-CLI
  farming.** ADR 0004 already chose a native vtable plus `openai_compat`.
  Stealth impersonates official CLIs and terminates TLS for IDE hosts.
  Their own free-tier table marks many of those paths `caution`/`avoid`. —
  `high` —
  [STEALTH](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/security/STEALTH_GUIDE.md)
- **Cheapest full-stack option is already here:** point an
  `openai_compat` provider at a local OmniRoute. That is delegation, not
  adoption. — `high`

## Scope and method

- **Searched:** OmniRoute `release/v3.8.50` (default branch) primary docs
  and `llm.txt`; GitHub repo metadata; local tree (`fallback_providers`,
  `client.zig` retry, `prune.zig` / PRD 0031, `stats/tokens.zig`,
  `catalog.zig`, ADRs 0004/0005/0006, ROADMAP feature audits); existing
  note [free-llm-endpoints.md](free-llm-endpoints.md).
- **Not searched:** live OmniRoute install, their 25k test suite, HN
  threads, arXiv. Sweep snippets were treated as leads only; claims below
  are from opened files or this tree.
- **Freshness:** 2026-08-16. OmniRoute last push the same day. Provider
  counts, free-tier dollars, and ToS flags age in weeks. Routing and
  resilience *shapes* age slower.

## What OmniRoute is

A local-first MIT AI *gateway* (TypeScript, Next.js 16, SQLite,
Node 22/24). One OpenAI-compatible endpoint (`localhost:20128/v1`) in
front of a large provider catalog. v3.8.50 claims 340 providers / 1202
models, 19 combo strategies, RTK+Caveman compression, MCP, A2A, Electron.
Repo: 48,613 stars, 6,613 forks, 424 open issues, ~6,866 commits, created
2026-02-13, last push 2026-08-16 (`high`, GitHub API).

It is a different product. Clanker already *is* the agent, already has a
`clanker serve --proxy`, already has `fallback_providers`, already has
MCP/ACP, already has compare/arena. The overlap is the request path
between "this turn needs a model" and "a completion came back."

## Options found

One subsection per adoption slice, highest impact first. "Adopt" here
means take the *mechanism*, not the TypeScript.

### 1. Command-aware tool-result compression (RTK-shaped) — highest token win

- **What it is:** A filter catalog over tool/shell output. Detect the
  command class (`git diff`, pytest, npm install, docker logs, generic
  shell), then apply keep/drop/collapse/head-tail rules that preserve
  errors and summaries. Default stack is RTK then Caveman. 49 built-in
  filters, intensity `minimal`/`standard`/`aggressive`, trust-gated
  project filters, optional redacted raw-output recovery.
- **Maturity:** Shipped in OmniRoute 3.8.x. Upstream inspiration:
  [rtk-ai/rtk](https://github.com/rtk-ai/rtk) (command output) and
  [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman)
  (filler-word rewrite). OmniRoute documents the stacked math as
  `1 - (1-0.80)*(1-0.46) = 89.2%` on *eligible* payloads, and separately
  that a clean grep saves near zero because `validateCompression()`
  refuses to drop code, URLs, headings, versions, or ALL-CAPS ids.
- **Fit:** Pure transform, no credentials, no network. Can live as a
  host-tested helper next to `src/agent/prune.zig` (or a WASM guest the
  loop calls). Does not touch ADR 0004. Overlaps shipped PRD 0031
  (UTF-8 head/marker/tail once a result exceeds
  `agent.tool_result_prune_bytes`) but is *class-aware*: 0031 always
  keeps the first 4 KiB and last 1 KiB; RTK would keep the failure and
  drop the 800 passing tests in the middle.
- **Pros:** Hits the actual token bulk of a coding agent (tool dumps).
  Deterministic, unit-testable per filter. Complements hashline (output
  tokens) and snapcompact (history as image).
- **Cons:** Filter catalog is a new living surface. Aggressive
  intensity can hide context. Their 15–95% README range is marketing
  of the eligible band, not a session average.
- **Unknowns:** Whether a 10–20 filter Zig subset (git, zig build/test,
  pytest, rg, generic) captures most of *our* spend. No measurement on
  clanker transcripts yet.
- **Evidence:**
  [COMPRESSION_GUIDE.md](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/compression/COMPRESSION_GUIDE.md),
  [RTK_COMPRESSION.md](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/compression/RTK_COMPRESSION.md),
  [docs/prds/0031-tool-result-pruning.md](../prds/0031-tool-result-pruning.md).

### 2. Three-layer resilience — highest reliability win

- **What it is:** Three *different* scopes, documented as a thing
  operators must not conflate:
  1. **Provider circuit breaker** (whole provider). CLOSED / DEGRADED /
     OPEN / HALF_OPEN. Trips only on 408/500/502/503/504. OAuth opens
     at 8 failures / 60s reset; API-key at 12 / 30s.
  2. **Connection cooldown** (one key/account). 429 honors
     `Retry-After`. Exponential backoff. Terminal states
     (`banned`, `expired`, `credits_exhausted`) are *not* cooldowns.
  3. **Model lockout** (provider + connection + model). Opt-in, off by
     default. Success *decays* the failure count (halve on success)
     rather than only waiting out a timer. In-memory, lost on restart.
- **Maturity:** Shipped, with chaos/heap/k6 tests on a nightly workflow.
- **Fit:** Native, on the transport path (`src/llm/client.zig` +
  `chatWithFallbackChain`). Matches ADR 0004 (keys stay native). We
  already honor integer `Retry-After` (capped 30s) and retry 429/5xx
  three times on the *same* provider (`max_attempts = 3`).
- **Pros:** Stops burning retries on a provider we already know is
  down. Isolates one bad key or one missing model without disabling
  the rest. Small state (in-memory maps + optional persist).
- **Cons:** Wrong trip codes (treating 401 as a breaker trip) would
  hide a config bug. Need the same "do not conflate the three scopes"
  discipline they document.
- **Unknowns:** Whether we want persist-across-restart. Their lockout
  state is ephemeral on purpose.
- **Evidence:**
  [RESILIENCE_GUIDE.md](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/architecture/RESILIENCE_GUIDE.md),
  `src/llm/client.zig` `isRetryable` / `max_attempts`,
  `src/agent/loop.zig` `chatWithFallbackChain`.

### 3. Preemptive quota-aware pick (fill-first / headroom / reset-aware / LKGP)

- **What it is:** Combo strategies that choose a target using remaining
  quota, reset window, or last-known-good path, instead of failing first.
  `auto/cheap`, `auto/coding`, `auto/offline` are virtual combos built
  per request from live connections. 14-factor scoring (health, quota,
  inverse cost, inverse p95, task fit, …). Bandit exploration (5%)
  disabled in incident mode.
- **Maturity:** 19 strategies shipped and matrix-tested. **Live quota
  telemetry and quota-aware *scheduling* are listed as `v3.8.51+`
  "next" on their own README table.** What they have today is documented
  free-tier numbers plus some per-provider fetchers (OpenRouter
  `/api/v1/key`), not a uniform remaining-quota API.
- **Fit:** Extends `agent.fallback_providers` (ordered names, reactive)
  and the vision pre-emptive swap (capability known *before* send).
  Cost numbers already exist: `client.totalCost` from
  `cost_per_1m_input`/`cost_per_1m_output`, written to
  `state/token_stats.jsonl`. They do not steer the next call.
- **Pros:** Avoids the 429-then-swap latency tax. `lkgp` (sticky to last
  success) is a one-field policy. `fill-first` matches how people already
  *want* `fallback_providers` to behave (drain the cheap/free one).
- **Cons:** 14-factor auto-combo is a product, not a slice. Without
  real remaining-quota signals it becomes a dressed-up priority list.
  Task-fitness tables go stale.
- **Unknowns:** Which of our configured providers expose remaining
  quota on the wire. OpenRouter does; most `openai_compat` hosts do not.
- **Evidence:**
  [AUTO-COMBO.md](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/routing/AUTO-COMBO.md),
  [OmniRoute README growth table](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/README.md),
  [PRD 0025](../prds/0025-fallback-provider-chain.md),
  ROADMAP note that compare outcomes do not feed routing.

### 4. Cost/capability combo as a named route, not 19 strategies

- **What it is:** A combo is an ordered list of `provider/model` plus a
  strategy. Templates: Free Stack, High Availability, Cost Saver,
  Balanced. Per-request headers override mode/budget
  (`X-OmniRoute-Mode`, `X-OmniRoute-Budget`, hard 402 if `strict`).
- **Maturity:** Shipped. Fusion (parallel panel + judge) and pipeline
  (thread output into the next model) are two of the 19.
- **Fit:** We already have the expensive cousins: `clanker compare`
  (blind fan-out + optional synthesize) and `clanker arena` (adversarial
  rounds). ADR 0006 put that fan-out on the host (`ck_llm_many`). What
  we lack is a *cheap sequential* named chain used as the default
  route: "try kimi, then groq, then ollama" with a cost ceiling.
- **Pros:** Operators already think in this shape; they write it as
  `fallback_providers` today. A USD cap is a missing safety rail.
- **Cons:** Importing all 19 strategies is a gateway product. Fusion
  *is* compare. Pipeline is a workflow, and we have `workflow`/`chain`.
- **Unknowns:** Whether a per-request budget belongs in config or only
  on `serve --proxy` (the gateway-shaped surface).
- **Evidence:** AUTO-COMBO.md strategy table; ADR 0006; ROADMAP compare
  "nothing feeds a comparison's outcome back into routing."

### 5. Multi-key / connection pool per provider

- **What it is:** A provider has many *connections* (keys or OAuth
  sessions). Cooldown and lockout are per connection. Session affinity
  pins a client session to one account. Quota-share serializes
  concurrency against `max_concurrent` (GLM ~1, MiniMax ~2).
- **Maturity:** Shipped. Session affinity generalized beyond Codex in
  v3.8.x (#7274).
- **Fit:** Today one `[providers.X]` has one `api_key_env`. Adding
  keys is adding more stanzas and listing them in `fallback_providers`.
  Auth stays native (ADR 0005). A `keys = ["ENV_A", "ENV_B"]` (or a
  small pool file) would be a config change plus selection in
  `client.zig`.
- **Pros:** One 429'd Groq key would not fail the provider. Matches
  how people actually run free tiers.
- **Cons:** Single-operator harness may not need it. Pool files are a
  new secret surface (`.env` is already refused by `safeJoin`).
- **Unknowns:** Whether anyone running clanker actually rotates keys
  today.
- **Evidence:** `llm.txt` "Connection-based provider model";
  RESILIENCE_GUIDE.md §2 and §4; ADR 0005.

### 6. Free-tier catalog *method*, not their 340-row list

- **What it is:** A maintained catalog of documented free grants with
  honest accounting: pool-dedupe (Gemini Flash variants counted once),
  recurring vs one-time signup credit vs uncapped-no-published-cap,
  ToS flag as *advisory* not a routing gate. Headline ~1.51B tokens/mo
  across 42 pools; they publish why it dropped from earlier ~1.94B.
- **Maturity:** Re-audited about every two weeks; CI
  (`check:docs-counts`) fails if the docs drift from
  `computeFreeModelTotals()`. Still, the detailed per-provider table
  in FREE_TIERS.md is a 2026-06-05 snapshot with a 2026-06-17 delta
  list on top.
- **Fit:** We have `state/models-dev.json` (downloaded on miss or
  `providers refresh`) and [free-llm-endpoints.md](free-llm-endpoints.md)
  (NVIDIA build, Gemini AI Studio, Groq, plus unverified rows).
  `catalog.zig` maps models.dev npm packages onto `ProviderKind`.
  That is the right source for *what we can call*. Their catalog is
  the right *method* for *what is free and whether the ToS allows a
  proxy*.
- **Pros:** Stops over-claiming. ToS flags would have prevented us
  from recommending several of their keyless/OAuth "free" paths.
- **Cons:** Copying their numbers is instant rot. Many of their
  highest-count rows are ToS-caution for a self-hosted proxy.
- **Unknowns:** Whether models.dev already carries enough free-tier
  metadata to annotate our catalog view without a second store.
- **Evidence:**
  [FREE_TIERS.md](https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/reference/FREE_TIERS.md),
  `src/llm/catalog.zig`, this directory's free-endpoints note.

### 7. Upstream error classification (status restatement)

- **What it is:** Some gateways return 403/400 with a body that means
  temporary quota (`用户额度不足`) instead of 429. OmniRoute rewrites
  the status *before* classification so fallback treats it as retryable.
  Permanent "no access to this model" bodies are excluded. Classification
  rules have a scope (`model` / `connection` / `provider`) and are
  allowlisted per provider so the default path stays unchanged.
- **Maturity:** Shipped for `agentrouter` first; the restatement
  registry is designed to add rows.
- **Fit:** `isRetryable` is a closed status set. 401/403/404 are
  terminal and advance the fallback chain only after the same-provider
  attempts (and 401 is not retried). A lying 403 fails the turn
  unless the next fallback name is tried.
- **Pros:** Small table, testable, no new product surface.
- **Cons:** Body-text matching is provider-specific and language-
  specific. Easy to over-match.
- **Unknowns:** Whether any provider we actually use lies this way.
- **Evidence:** RESILIENCE_GUIDE.md §7; `src/llm/client.zig`
  `isRetryable`.

### 8. Session stickiness after a successful fallback

- **What it is:** Last-known-good path (`lkgp`) and session-affinity
  pins. Prompt-cache affinity (`cache-optimized`) tries the connection
  likeliest to already hold the prefix.
- **Maturity:** Shipped. Cache affinity weight defaults to 0.
- **Fit:** `chatWithFallbackChain` updates `current` so *later cost
  and stats in that run* stay honest. The *next* turn starts at the
  configured primary again. A sticky-until-healthy-primary policy is
  a few lines around that pointer, plus a TTL.
- **Pros:** Avoids ping-pong. Helps prompt-cache hit rates on
  Anthropic-class hosts.
- **Cons:** Can leave spend on a more expensive fallback after a
  transient blip.
- **Unknowns:** How long to stick. Their session affinity TTL is a
  global setting, 0 = off.
- **Evidence:** AUTO-COMBO.md `lkgp`; RESILIENCE_GUIDE.md session
  affinity; `loop.zig` comment on `current`.

### 9. Caveman-style prompt rewrite — lower than RTK

- **What it is:** Regex filler removal and phrase collapse on
  *natural language* (not tool output). Lite whitespace. Aggressive
  ages old turns. Ultra prunes by heuristic. Optional system-prompt
  "reply terse" output mode. Cache-aware path *downgrades* aggressive
  modes when `cache_control` is present so compression does not bust
  a prefix cache.
- **Maturity:** Shipped. Inspired by JuliusBrussee/caveman. Their
  validator refuses rewrites that drop protected tokens.
- **Fit:** Our token bulk is tool results, already targeted by 0031
  and by item 1. Filler-stripping operator text is a smaller slice.
  We already have `llm_description` to keep the catalog cheap, and
  compaction (LLM summary, planned snapcompact) for history.
- **Pros:** Cache-aware downgrade is a real gotcha we would hit if
  we compress prompts in front of Anthropic cache.
- **Cons:** Semantic risk on operator instructions. Overlaps the
  local "caveman" communication skill, which is a *style*, not a
  request filter.
- **Unknowns:** Measured savings on clanker system-prompt + history
  vs the damage rate on instruction-following evals.
- **Evidence:** COMPRESSION_GUIDE.md modes and "What 'eligible'
  actually means."

### Rejected leads (checked, not recommended)

These are real OmniRoute features. They fail the question.

- **340 first-class provider executors / format translators.**
  ADR 0004: one native vtable file plus a `ProviderKind` tag.
  `openai_compat` plus `catalog.zig` is how a new vendor lands.
  A 101-executor TypeScript tree is the opposite shape.
- **TLS stealth, CLI fingerprinting, MITM, zero-width obfuscation.**
  Impersonates Chrome/Firefox JA3, Claude Code CCH, official UAs;
  installs a local root CA and hijacks
  `daily-cloudcode-pa.googleapis.com`. Their own notice says this
  is for "user-owned official accounts"; their free-tier ToS table
  marks Antigravity/Kiro/OpenCode/Qwen-web `avoid`. Account bans
  on `ANTIGRAVITY_CREDITS=always` are documented. Out of scope and
  hostile to the sandbox story.
- **OAuth subscription farming** (Claude Code, Codex, Copilot,
  Cursor, Antigravity as backends). Same ToS problem. ADR 0005
  already split auth *acquisition* from wire kind; a generic
  `clanker auth login` is explicitly deferred until a provider
  requires refresh, not as a way to launder a consumer plan.
- **Electron / PWA / 43-language i18n / Next dashboard.** We have
  a TUI and a web UI guest. Not a token or reliability problem.
- **109 MCP tools, A2A skills, Cloud Agents (Devin/Jules),
  guardrails-as-a-framework, semantic cache as a product.** We
  serve MCP and ACP, have peers/mesh, have `confirm_fn` / hooks
  PRDs, have advisor. Semantic cache on a coding agent is a
  stale-answer risk; not measured.
- **Fusion / pipeline as routing strategies.** Covered by compare
  (ADR 0006) and workflow/chain.
- **Depending on OmniRoute as a library.** Node 22+, Next 16,
  better-sqlite3, 148 migrations. Clanker is one static Zig
  binary. Incompatible dependency budget.

## Out-of-the-box options

- **Already in the tree:** `fallback_providers` (reactive ordered
  chain), same-provider retry with `Retry-After`, vision pre-emptive
  swap, tool-result prune (0031), LLM compact + planned snapcompact,
  hashline (output tokens), `llm_description`, models.dev catalog,
  `token_stats.jsonl` with estimated `$` from config prices,
  `clanker serve --proxy`, compare/arena, MCP/ACP, hooks PRD.
  Using these *harder* (fill `cost_per_1m_*`, put a free
  `openai_compat` last in `fallback_providers`, turn prune on)
  is the zero-code move.
- **Standard library / OS primitive:** none of the high-impact
  slices need a new library. Circuit state is a map and a clock.
  RTK-like filters are regex + line keep/drop, which we already
  do in prune.
- **Do nothing:** every 429 still costs three same-provider
  attempts plus whatever context we re-send. Verbose `zig build
  test` / `rg` dumps still land in the next prompt at full size
  until they trip the 8 KiB prune. That is the monthly cost of
  waiting.
- **Adjacent domain:** load balancers have solved circuit
  breaking and P2C for decades. LLM gateways (LiteLLM, OpenRouter,
  Portkey) have cost routing. We should steal the *small* patterns,
  not a gateway identity.
- **Buy, host, or delegate:** run OmniRoute locally and set

  ```toml
  [providers.omni]
  kind = "openai_compat"
  base_url = "http://127.0.0.1:20128/v1"
  api_key_env = "OMNIROUTE_KEY"
  ```

  with `model = "auto/coding"`. That buys their router, compression,
  and free-tier pool *without* merging a Node monolith. Cost: a
  second process, their ToS/stealth surface, and a loss of
  sandbox-side visibility into which upstream actually answered.
- **Invert it:** shrink what we send (hashline, prune, compact,
  shorter `llm_description`) so routing and compression matter
  less. Already in progress; does not replace a breaker.

## Comparison

| Option | Maturity | Licence | Fit | Main risk |
|---|---|---|---|---|
| RTK-shaped tool filters | Shipped upstream; unmeasured here | MIT ideas, rewrite in Zig | High (extends 0031) | Over-filtering failures |
| 3-layer resilience | Shipped, well documented | n/a (pattern) | High (native client) | Wrong scope / hiding 401s |
| Preemptive quota pick | Strategies shipped; live quota "next" | n/a | Medium-high | Routing on stale numbers |
| Named cost combo + USD cap | Shipped | n/a | Medium (we have the chain) | 19-strategy sprawl |
| Multi-key pool | Shipped | n/a | Medium | New secret surface |
| Free-tier method | Living catalog, ages fast | MIT docs | Medium (we have models.dev) | Copying rotten rows |
| Error restatement | Shipped for one gateway | n/a | Medium-low | Over-matching bodies |
| Sticky fallback | Shipped | n/a | Medium-low | Stuck on expensive path |
| Caveman prompt rewrite | Shipped | inspired by MIT caveman | Low-medium | Instruction damage |
| Delegate to OmniRoute process | Product, 48k stars | MIT | High as an *option* | ToS/stealth, extra daemon |
| Import OmniRoute / 340 adapters / stealth | Product | MIT | Fail (ADR 0004/0005) | Identity + ToS |
| Do nothing | — | — | Always available | Keep paying the 429 tax |

## Evidence log

| Claim | Source | Read on | Confidence |
|---|---|---|---|
| OmniRoute v3.8.50, MIT, TypeScript/Next, 340 providers / 1202 models | [repo](https://github.com/diegosouzapw/OmniRoute), [llm.txt](https://raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/llm.txt), GitHub API | 2026-08-16 | high |
| 48,613 stars, 6,613 forks, 424 open issues, created 2026-02-13, pushed 2026-08-16 | GitHub API `GET /repos/diegosouzapw/OmniRoute` | 2026-08-16 | high |
| 19 routing strategies including fill-first, headroom, reset-aware, lkgp, fusion, pipeline | [AUTO-COMBO.md](https://raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/docs/routing/AUTO-COMBO.md) | 2026-08-16 | high |
| 14-factor scoring weights (health 0.20, quota 0.15, costInv 0.15, …) | same | 2026-08-16 | high |
| Quota-aware scheduling and quota telemetry still "next" after v3.8.50 | README growth table | 2026-08-16 | high |
| Circuit breaker / cooldown / lockout are distinct scopes; lockout off by default; success halves failure count | [RESILIENCE_GUIDE.md](https://raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/docs/architecture/RESILIENCE_GUIDE.md) | 2026-08-16 | high |
| RTK 60–90% on command output; stacked 78–95% only on eligible redundant traffic; clean greps ~0 | [COMPRESSION_GUIDE.md](https://raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/docs/compression/COMPRESSION_GUIDE.md), [RTK_COMPRESSION.md](https://raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/docs/compression/RTK_COMPRESSION.md) | 2026-08-16 | high (their wording), medium (we did not reproduce) |
| ~1.51B documented free tokens/mo, 42 pools, ToS advisory not a gate; many `caution`/`avoid` | [FREE_TIERS.md](https://raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/docs/reference/FREE_TIERS.md) | 2026-08-16 | medium (their audit date 2026-06-17) |
| Stealth impersonates official CLIs and can MITM Antigravity; `ANTIGRAVITY_CREDITS=always` has ban reports | [STEALTH_GUIDE.md](https://raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/docs/security/STEALTH_GUIDE.md) | 2026-08-16 | high |
| Clanker retries same provider 3× on 429/5xx + Retry-After, then walks `fallback_providers`; mid-stream content does not advance the chain | `src/llm/client.zig`, `src/agent/loop.zig` | 2026-08-16 | high |
| Tool-result prune is shipped (head/tail, no command class) | [PRD 0031](../prds/0031-tool-result-pruning.md), `src/agent/prune.zig` | 2026-08-16 | high |
| Providers are a native vtable; auth is a strategy axis; fan-out is a host function | ADRs 0004, 0005, 0006 | 2026-08-16 | high |
| Cost is estimated from config prices and logged; it does not pick the next provider | `src/llm/client.zig` `totalCost`, `src/stats/tokens.zig` | 2026-08-16 | high |
| Compare/arena already cover fusion-like multi-model; routing does not learn from them | ROADMAP compare entry, ADR 0006 | 2026-08-16 | high |
| "450+ contributors" / "~89% avg savings" README claims | README marketing | 2026-08-16 | unverified (not counted / not reproduced) |

## Open questions

1. **Measure, don't assume, RTK-shaped savings on clanker transcripts.**
   Take `state/sessions/` tool-role blobs, run a 10-filter prototype
   (git, zig test/build, pytest, rg, generic), report bytes kept vs
   dropped and whether any failure line was lost. That settles item 1.
2. **Which of our live providers expose remaining quota?** A one-hour
   spike: log response headers (`x-ratelimit-*`, `retry-after`) from
   `providers check` and a real 429. If none do, item 3 collapses to
   breaker + local `token_stats` vs configured monthly caps.
3. **Does anyone need multi-key?** If every install has one key per
   stanza, item 5 is YAGNI.
4. **Proxy vs agent loop.** A circuit breaker in `client.zig` helps
   every surface (`run`, REPL, serve, proxy). A combo DSL only on
   `serve --proxy` would copy OmniRoute's product without changing
   `clanker run`. Decide which surface before an RFC.

## What would change the answer

- OmniRoute ships uniform live quota telemetry (their own next item)
  and it is clean enough to reuse as a data format.
- A provider we depend on starts requiring CLI-fingerprint stealth
  (would still be rejected on ToS grounds, but the *pressure* changes).
- PRD 0031 prune + snapcompact already cut tool/history tokens enough
  that item 1's remaining juice is small.
- We take a dependency on a hosted router (OpenRouter etc.) and let
  *them* own fallback; then most of this note is "do nothing / delegate."

## References

### OmniRoute (primary, v3.8.50)

- https://github.com/diegosouzapw/OmniRoute
- https://raw.githubusercontent.com/diegosouzapw/OmniRoute/release/v3.8.50/llm.txt
- https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/ROADMAP.md
- https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/routing/AUTO-COMBO.md
- https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/architecture/RESILIENCE_GUIDE.md
- https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/compression/COMPRESSION_GUIDE.md
- https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/compression/RTK_COMPRESSION.md
- https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/reference/FREE_TIERS.md
- https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.50/docs/security/STEALTH_GUIDE.md

### Local tree

- [ADR 0004](../adrs/0004-providers-are-a-native-vtable-not-wasm.md)
- [ADR 0005](../adrs/0005-auth-is-a-strategy-axis-separate-from-wire-kind.md)
- [ADR 0006](../adrs/0006-fan-out-concurrency-belongs-to-the-host.md)
- [PRD 0025 fallback chain](../prds/0025-fallback-provider-chain.md)
- [PRD 0031 tool-result prune](../prds/0031-tool-result-pruning.md)
- [free-llm-endpoints.md](free-llm-endpoints.md)
- `src/llm/client.zig`, `src/agent/loop.zig`, `src/llm/catalog.zig`,
  `src/stats/tokens.zig`

### Upstream inspirations OmniRoute names

- https://github.com/rtk-ai/rtk
- https://github.com/JuliusBrussee/caveman
