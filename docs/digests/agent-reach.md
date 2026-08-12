# Digest: Agent-Reach

Source: <https://github.com/Panniantong/Agent-Reach> (MIT, Python), read at
depth on 2026-08-13. A CLI that gives any shell-capable agent "internet
reach": 15 platforms (YouTube, Twitter/X, Reddit, Bilibili, XiaoHongShu,
GitHub, LinkedIn, RSS, web search via Exa, ...), zero API fees, installed and
configured by the agent itself. GitHub trending #1; the interesting part is
not the platform list but the operational design around inevitably-breaking
integrations.

## What it actually is

A selector, installer, health checker and **router** — deliberately never a
wrapper. `agent-reach install` sets up upstream open-source tools (yt-dlp,
twitter-cli, bili-cli, rdt-cli, gh, OpenCLI, mcporter/Exa); after that the
agent calls those tools directly. The package's own surface is small:
`install`, `doctor --json`, `configure <thing>`, `check-update`.

## The five ideas worth stealing

### 1. Ordered multi-backend routing, because platforms WILL break

Every channel declares `backends` as an ordered candidate list; `backends[0]`
is preferred, the rest are fallbacks. A health check sets `active_backend` to
whichever candidate actually works right now. Switching backends when a
platform blocks one route "means reordering this list, not rewriting code";
users can force one via `<channel>_backend` config. Their changelog carries
the proof case: Bilibili blocked yt-dlp in 2026-06, they swapped bili-cli in
as preferred, users did nothing.

**Clanker relevance: this is exactly how our youtube_transcript died.** One
hardcoded route (watch-page scrape) silently rotted twice over. The fix
(commit 8693056) hardcodes a better route — innertube ANDROID — but it is
still one route. A network tool that matters should carry an ordered strategy
list inside the tool ("innertube android, then watch-page scrape, then a
reader proxy") and report WHICH strategy served the request, so breakage of
the preferred one degrades instead of failing, and the log shows the rot
starting.

### 2. Health means executing, not existing

Their base class is explicit: `shutil.which()` alone is NOT proof of health —
a stale venv shim passes `which()` but cannot execute. Channels must run a
real, lightweight command before claiming a backend active. `agent-reach
doctor --json` is the machine-readable version an agent is told to run
*before* using any login-gated platform.

**Clanker relevance:** our `clanker doctor` checks that files exist and
config parses; our capability evals execute tools but only at improve-gate
time. The gap is a *live network-tool probe*: `doctor` (or a `doctor --net`)
that actually calls youtube_transcript/fetch_web/context7 against known-good
inputs and reports per-tool which route worked. The evals we added
(alarm.task.json etc.) are this idea applied at promotion time; doctor would
apply it at "why is my run failing" time.

### 3. Documentation addressed to the agent, not the human

Install is one pasteable line: "帮我安装 Agent Reach: <url-of-install.md>" —
the install doc's audience *is the agent* ("For AI Agents: Goal / Boundaries
/ steps"), with a "For Humans" section that just says what to paste. Same for
update. `llms.txt` at the repo root is a manifest pointing agents at the
right docs. Per-credential setup guides (`guides/setup-twitter.md`, ...) are
written so "tell the agent: help me configure X" works with no human doc
reading.

**Clanker relevance:** our docs are human-first; the agent-facing surface is
tool descriptions and the system prompt. Cheap adoptions: an `llms.txt` at
repo root pointing at docs/README.md, docs/configuration.md and AGENTS.md;
and writing future runbooks (provider setup, peer setup) with an explicit
"For AI Agents" contract section, since peers ARE agents and already read our
repo.

### 4. A skill with operating rules, not just a tool list

Their SKILL.md front-loads MUST-USE trigger phrases (multilingual), then
standing rules: run `doctor --json` before login-gated platforms; *declare
which backend you are using* before working; on failure follow the
documented retry chain for that platform, "do not invent commands"; for
broad research tasks, fan out across platforms in parallel then merge; after
any large task, run `check-update` (one API call) and mention new versions
in the wrap-up. Detail lives in per-category `references/*.md` loaded on
demand — the skill body is a router.

**Clanker relevance:** our tool descriptions say what a tool does, rarely how
to recover when it fails. The youtube incident run wasted iterations
guessing (retried the same call, then tried fetch_web against a denied
host). Tool descriptions for network tools should name the retry chain and
the giving-up condition; the repeat-guard that stopped the flailing is the
harness-side half of this, the doc-side half is missing.

### 5. Config tiers as honest capability labels

Channels carry `tier: 0` (works after install), `1` (needs a free key), `2`
(needs real setup: cookies, browser session). The README's platform table is
organized around "works immediately" vs "unlocked after configuring" vs "how
to configure", and the how is always "tell the agent".

**Clanker relevance:** `clanker tools list` and the web UI Tools view show
every tool as equally available, but a tool whose `network_allow` hosts need
keys (context7) or whose module is off is not. Tagging tools with the same
three tiers (works now / needs env var / needs setup) in the manifest and
surfacing it in doctor + the Tools view would answer "why did this tool
fail" before the run instead of after.

## Security stances worth noting

- Cookies stay local, never uploaded; the project refuses to automate logins
  for the platforms that forbid it (XiaoHongShu), and only reuses browser
  sessions the user already owns and controls.
- Install is safe-by-default: the plain install only inspects and lists
  missing dependencies; `--system` writes require explicit user approval.
- Doctor deliberately does NOT live-verify backends whose check would touch
  browser cookies or perform remote writes; `active_backend: null` is
  documented as "not verified", not "not working". A health check that
  itself has side effects is treated as a bug.

That last one is a subtle contract our own doctor already mostly follows
(read-only checks) and should keep following as it grows network probes:
probe with GETs against known-good public inputs, never with credentialed or
mutating calls.

## What we deliberately do differently

Agent-Reach trusts upstream CLIs with full process authority; its safety is
policy and documentation. Clanker runs tools as sandboxed WASM with
host-enforced network allowlists — the youtube incident showed that working
(fetch_web was denied youtube.com and the denial was correct). Multi-backend
routing for us therefore lives INSIDE a tool (strategy list within the
sandbox, hosts within `network_allow`), not as a menu of external binaries.
That is more work per channel and strictly stronger isolation; the lesson to
import is the routing discipline, not the architecture.

## Concrete follow-ups (roadmap-sized, none started)

1. youtube_transcript: add watch-page scrape back as fallback strategy two,
   report the serving strategy in the output.
2. `clanker doctor --net`: live-probe each network tool against a pinned
   public input; read-only probes only.
3. Retry-chain sentences in the descriptions of every network tool
   (youtube_transcript, fetch_web, web_search, context7, peers).
4. Tier field in tool manifests (`"tier": 0|1|2` + what unlocks it),
   surfaced in `tools list`, doctor, and the web UI Tools view.
5. `llms.txt` at repo root for agents reading this repo (peers already do).
