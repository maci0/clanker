# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

One user: the developer who owns this repository, running clanker on their own
machine. The repository is public on GitHub (`github.com/maci0/clanker`) and
developed in the open, but other people's needs are not a design input — a
reader may learn from the code without their setup becoming a constraint.

Situation: a developer at a workstation with a terminal and a browser open at
the same time, supervising an agent that is editing this very codebase. The job
is to direct the agent, watch what it did, and judge whether to keep it.

## Product Purpose

clanker is a self-improving AI agent harness written in Zig 0.16. It runs its
tools as sandboxed WebAssembly modules (zwasm) and improves its own source code
through a gated loop: the agent proposes an exact-match patch, applies it to a
staging copy, verifies it with `zig build`, `zig build test`, `zig build tools`,
`zig fmt`, and lint, and promotes it to the live tree only if every gate passes.

Success is the agent making changes to itself that hold up — that build, pass
tests, and survive review — with enough of the run visible that the owner can
tell a good change from a plausible one.

## Positioning

The self-improvement loop is gated and self-hosting: clanker verifies its own
patches with the same deterministic gates a human would run, against a staging
copy, and only then promotes. It also enforces an anti-cheat boundary — clanker
cannot modify `src/improve/`, `src/evals/`, `src/tools/builder.zig`, or
`evals/` in a single pass, so it cannot weaken the thing that judges it.

Tools are sandboxed WASM modules with an explicit host ABI rather than
in-process code, so the agent's reach is a policy decision rather than an
accident of what the harness happens to link.

## Operating Context

- **Two surfaces, equal standing.** The CLI/REPL (`clanker run`, `clanker
  repl`) and the web UI (`clanker serve`, `GET /`) are both first-class ways to
  use clanker and are held to the same quality bar. Work landing in one should
  not leave the other behind.
- **The improve loop runs while you work.** `clanker-improve.sh` drives
  `improve-self` continuously and rewrites the working tree, including files
  someone is editing by hand. It is never to be paused for convenience. Any
  process editing this repo must expect concurrent writes, re-read before
  writing, and distinguish its own build breakage from the loop's.
- **Hot reload is live.** `clanker serve` restarts itself when the binary
  changes, so a rebuild during a session replaces the running server.
- **Multi-instance.** Instances discover each other through configured peers,
  exchange A2A agent cards at `/.well-known/agent.json`, notify each other, and
  talk in named chatrooms. Direct messages are chatrooms named `dm:<a>|<b>`,
  not a separate mechanism.
- **State on disk.** `state/runs/` (execution graphs), `state/sessions/`
  (conversations), `state/chatrooms.jsonl`, `state/learnings.md`,
  `state/token_stats.jsonl`, `state/reasoning.jsonl`. These are the record the
  UI reads.

## Capabilities and Constraints

Confirmed capabilities: WASM tool sandbox with explicit ABI; MCP stdio server;
peer notify and phonebook; A2A agent cards; persistent structured goals;
streaming REPL and web UI; execution graphs per run; plugin toggles and
transform chains; plugins that call the model; token budget and compaction;
sub-agents; recursive sub-LM reasoning; chatrooms and DMs; per-provider token
usage stats; multi-session conversations.

Constraints that future work must preserve:

- **The web UI is one self-contained file.** `tools/zig/webui/index.html` is
  embedded at comptime into a WASM tool and returned JSON-encoded through
  `lib.zig`'s shared output buffer (`out_cap`, currently 2 MiB). A
  build-time check in `tools/zig/webui.zig` fails the build if the encoded page
  exceeds it. There is no bundler and no build step for the page.
- **The page works offline and reaches no third party.** A strict CSP
  (`default-src 'none'`, `base-uri 'none'`, `form-action 'none'`) is served with
  it. Third-party JS is vendored and served from the same origin, never a CDN.
- **No sockets.** The HTTP server closes every connection after one response,
  so live updates are polling, not WebSocket or SSE-to-the-browser.
- **Tool guest buffers are small.** Scratch is 64 KiB and host arena is 1 MiB,
  so anything larger than that is handled natively rather than through a tool.
- **Zig 0.16 APIs only**, targeting `x86_64-linux-musl`. No new third-party
  dependencies.
- **Providers are configurable**, keyed by env var, never stored in config.
  The default is currently `kimi-k3`; the product is not tied to one vendor.

Explicitly undecided: whether clanker is ever licensed or released for others
to use. There is no LICENSE file, and that is the current state, not an
oversight to be fixed by assumption.

## Brand Commitments

Name: **clanker**, lowercase, including at the start of a sentence in docs and
UI. Instance names are generated adjective-noun pairs (e.g. `cobalt-otter`) and
appear throughout the UI as identity.

Asset: `docs/assets/mascot.jpg`, used in the README.

Voice, as established by the existing README, `docs/README.md`, and
`AGENTS.md`: terse, technical, declarative. States what a thing does and what it
costs. No marketing register.

## Evidence on Hand

Real material that exists in-repo and may be used:

- `README.md`, `docs/README.md` (reference), `docs/ROADMAP.md` (done/planned),
  `AGENTS.md` (conventions) — all maintained in-repo and current.
- `docs/assets/mascot.jpg`.
- Live runtime state under `state/` — real execution graphs, sessions,
  chatroom logs, and token stats from actual runs.
- 239 commits of real history, including the improve loop's own promotions.

Absences that future work must not invent: there are no users other than the
owner, no testimonials, no case studies, no benchmarks, no pricing, no
deployment or uptime claims, and no license. Do not manufacture any of these,
including as placeholder copy.

## Product Principles

1. **Show the work, not just the answer.** A run's tool calls, timings, token
   counts, cost, and recorded output are the product. Anything that hides what
   the agent actually did makes the harness less useful, not simpler.
2. **Honest state over reassuring state.** Truncated output says it was
   truncated; a stopped turn says it was stopped; a failed poll says it is
   retrying. Silence and plausible-looking placeholders are defects.
3. **Both surfaces, one system.** The CLI and the web UI describe the same runs,
   sessions, and rooms in the same terms. Divergence between them is a bug.
4. **Self-contained and offline.** No CDN, no external fetch, no build step for
   the page. The harness runs on a machine with no internet beyond the model
   provider.
5. **The verifier is not editable by the verified.** The gates and evals are
   protected from the loop that they judge; anything that erodes that boundary
   is a correctness problem, not a workflow inconvenience.

## Accessibility & Inclusion

WCAG 2.1 AA is a binding requirement for the web UI, and **full keyboard
operability is non-negotiable** given the developer audience: every action
reachable by pointer must be reachable and visible by keyboard, with a focus
indicator on each stop.

Already established and to be maintained: AA contrast in both light and dark
themes, correct and non-duplicated live regions for streaming and polling
surfaces, `prefers-reduced-motion` honored in both CSS and JS-initiated
scrolling, `forced-colors` support, 200% text scaling without overflow, skip
links to both main content and the composer, and interactive targets of at
least 44px.
