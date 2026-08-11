# Web UI roadmap and implementation plan

Status: proposal. Nothing here is built unless `docs/ROADMAP.md` says so.

The web UI is a co-equal surface with the CLI (`PRODUCT.md`), and six audit
rounds have taken its accessibility, layout and honesty-of-state to a good
place. What it lacks is not polish. It lacks *interaction*: the harness can do
things the browser cannot ask for, and does things the browser cannot see.

## 1. Where it stands

Built: tabbed views (Chat, Runs, Rooms, Goals, Tools, System) with hash
routing and keyboard navigation; multi-session switch/rename/delete; the run
graph; chatrooms and DMs; token usage and cost; goals; the tool list with
toggles, per-plugin settings and a detail panel showing sandbox policy.

Three capabilities exist in the harness and are unreachable from the browser:

| Capability | Evidence | Consequence |
|---|---|---|
| `ask_user` | `src/sandbox/host.zig:92` — `ask_fn: ?AskFn = null`, *"null outside the REPL"*; `ckAsk` returns `not_found` | A tool built for the moments where guessing is expensive is dead in half the product. The model guesses. |
| Image input | `RunRequestBody` carries `task`, `stream`, `session` only; `src/agent/loop.zig:543` builds `ImagePart`s; `image` and `opencv` tools exist | The harness is multimodal. The composer is a text box. You cannot paste the screenshot you are asking about. |
| Subagent detail | `src/agent/subagent.zig:105` returns `resp.message.content` — one string | A nested run's steps are not recorded. When it hits its iteration cap the parent cannot see how far it got. |

## 2. What the research says

### pixelagents.dev

A pixel-art office floor for Claude Code: tiny agents at desks, animated by
tool events. Reading is a nose in a book (Read/Grep/Glob), Bash is hammering
the terminal, Edit/Write is pounding the keyboard, spawning a subagent pops a
helper up at the desk, waiting for input is an orange glow, and an agent dozes
off after five quiet minutes. Installed as hooks; dashboard on `localhost:4242`.
It captures tool names, file paths and truncated commands — never file
contents, prompts, or env values — and keeps everything in `~/.pixelagents`.

What transfers: the event→animation vocabulary, the privacy line (metadata,
never content), and the "watch it work" framing. What clanker adds that the
original cannot: **it is already multi-instance.** Peers, chatrooms and DMs
mean a floor with several desks is the truthful picture, not a metaphor.

### Kimi Code

Read-only operations run automatically; file edits and shell commands ask
first. Plan mode (`Shift-Tab` / `--plan`) produces a research plan before
touching files. `/fork` makes an experimental branch you can abandon.
`/compact` compresses context. Subagents are dispatched as named roles
(`coder`, `explore`, `plan`) working in parallel in isolated contexts. Plugin
installs surface their trust level up front.

What transfers: the permission model, plan mode, fork, and surfacing trust.
clanker already shows a plugin's sandbox policy in the tool detail panel, which
is the same instinct.

### Open WebUI

Model switching mid-conversation to compare backends and route tasks. Agents
as configuration wrappers binding a base model, system prompt, tools and
knowledge. RAG with citations back to source documents. A Workspace for
material that outlives any single conversation.

What transfers: mid-conversation provider/model switching (clanker has
multiple providers configured and no way to pick one from the browser), and
citations — clanker records what every tool returned and could link an answer
back to the run node that produced it.

## 3. Constraints that shape every item

These are not preferences. Breaking one breaks the build or the product.

1. **The page is one comptime-embedded file.** `tools/zig/webui/index.html` is
   JSON-encoded through `lib.zig`'s `out_cap` (256 KiB). A build-time check in
   `tools/zig/webui.zig` fails the build if it no longer fits. Current headroom
   is roughly 120 KB. **Anything large is a vendored asset**, served from
   `/webui/vendor/` the way `d3-dag` and `highlight.js` already are — those get
   long immutable caching and gzip, and are fetched only on first use.
2. **Strict CSP, offline-capable.** `default-src 'none'`; no third-party
   origin, ever. Assets are vendored into the repo, not linked.
3. **No sockets.** The server closes every connection after one response, so
   live updating is polling — except the `/api/run` stream, which is the one
   long-lived channel and already carries `\x01`-prefixed control events
   (`tool_call`, `tool_result`, `error`, `done`).
4. **Guest buffers are 64 KiB** for scratch and host arena. Anything larger is
   handled natively rather than through a WASM tool.
5. **The improve loop rewrites this tree while you work.** Every change lands
   in a file something else may be editing.

## 4. Phase 1 — make it interactive

The highest-value phase. Each item uses mechanism that already exists.

### 1.1 Bridge `ask_user` to the browser

**Why.** `ckAsk` currently reports "nobody attached" and the model decides
alone. This is also the foundation for 1.2, so it comes first.

**Mechanism.** `AskFn` is `*const fn (question, options) anyerror![]const u8`
(`host.zig:59`). The serve path installs one; it must block the run thread
until the browser answers. The `/api/run` stream is already open and already
carries control events, so the question travels down it.

**Build.**
- `src/cli.zig`: a `PendingAsk` keyed by run — question, options, a
  `std.Thread.Condition` (or a futex-backed wait) and an answer slot.
- Install `ask_fn` in `handleRun`'s sandbox. It writes
  `\x01{"type":"ask","id":…,"question":…,"options":[…]}` to the run's stream
  socket (already `threadlocal`), then waits with a timeout.
- New `POST /api/ask` `{id, answer}` resolves the wait. Answer must be one of
  the offered options; anything else is refused.
- Timeout returns the same "nobody answered" path the REPL-less case takes
  today, so a closed tab degrades to current behaviour rather than hanging a
  run forever.
- Page: render an `ask` event as a question with option buttons inside the
  turn card, in the existing live region. Focus the first option.

**Risks.** A blocked run holds a connection thread — bounded by
`max_connection_threads` (64). The timeout is what keeps that safe; make it a
config value.

**Verify.** A run that calls `ask_user` shows buttons; clicking one continues
the run with that answer; closing the tab times out and the run proceeds.

### 1.2 Confirm before write

**Why.** Kimi's model: reads run free, writes and shell commands ask. It is the
difference between a viewer and something you can safely leave running.

**Mechanism.** The tool dispatch loop at `src/agent/loop.zig:470`. A tool's
descriptor already declares what it can reach (`fs_prefixes`, `exec_allow`,
`network_allow`), and the tool detail panel already displays it.

**Build.**
- Descriptor gains `confirm: bool` (default derived: true when `exec_allow` is
  non-empty or `fs_prefixes` grant write access).
- A `confirm_fn` on the sandbox, same shape and same channel as 1.1, carrying
  the tool name and a truncated argument preview.
- Config: `agent.confirm_writes` — `never` | `browser` | `always`. Default
  `never` so existing headless runs and the improve loop are unaffected.

**Risks.** The improve loop must never be gated on a human. Defaulting to
`never` and opting the browser in is what prevents that.

### 1.3 Image input

**Why.** The harness is multimodal and the composer is not.

**Build.**
- `RunRequestBody` gains `images: []struct { mime, b64 }`.
- Feed into the existing `ImagePart` path (`loop.zig:543`).
- Page: paste and drag-drop onto the composer, with a thumbnail strip and a
  size cap stated up front. Encode client-side; refuse anything over the cap
  in bytes, in the units the server counts.

## 5. Phase 2 — session and context control

### 2.1 Fork a conversation

Sessions are already files (`state/sessions/<id>.json`), so fork is
copy-with-new-id and a title of "fork of <title>". One endpoint
(`POST /api/sessions/<id>/fork`), one button next to Rename/Delete. Cheapest
item in this document relative to what it gives: an abandonable branch.

### 2.2 Plan mode

A run that stops before applying anything. Needs a run flag threaded to the
system prompt and a UI toggle beside Run. The output is a proposal, rendered
as one; "Apply" then runs it for real. Depends on nothing else here.

### 2.3 Compact, visibly

`compact_threshold_bytes` is `0` and compaction is invisible. Surface the
session's current token weight next to the conversation picker and offer an
explicit Compact action, so the thing that silently reshapes context becomes
something you can see and trigger.

### 2.4 Provider and model switching

Open WebUI's most transferable idea. `config.json` has ten models across seven
providers; the browser cannot pick one. Add an optional `provider`/`model` to
`RunRequestBody` (the plumbing exists — `providers.zig` `Params` already takes
overrides) and a picker in the composer. Per-turn, so a conversation can
compare backends.

## 6. Phase 3 — see what the agents are doing

### 3.1 Record subagent runs as their own graphs

**Prerequisite for 3.2 and for the pixel floor's helper sprites.** Today a
nested run returns one string. Give it a run id and a graph, parented to the
caller's node, so the parent's graph can link into it.

### 3.2 Cross-agent view

Peers, their A2A cards from `/.well-known/agent.json`, DM channels, and — once
3.1 lands — a nested run's own timeline. This is the view that answers "what is
this fleet doing".

### 3.3 Todo lists

Two lists, one vocabulary (already specced in `docs/ROADMAP.md`):
- **Shared, per room.** Rides the chatroom log so a claim is just another
  message every subscriber receives. Needs a claim rule that survives two
  agents claiming at once, because the log has no locking.
- **Private, per subagent.** Scoped to a nested run, discarded when it returns,
  summarised into its result.

## 7. Phase 4 — `webui_pixelagents`

An optional view: a pixel-art floor where each clanker instance is an agent at
a desk, animated by what it is actually doing.

**Why it fits.** clanker records every run as a graph, streams tool events
live, and is genuinely multi-instance. A floor with one desk per peer is the
truthful picture, not decoration.

**Data.**
- Live: the `/api/run` `\x01` event stream already carries `tool_call` and
  `tool_result`. Phase 1 adds `ask`, which is the orange glow.
- Peers: `/api/status`.
- Replay: `state/runs/*.json` graphs, so you can watch a past run.
- **Privacy line, taken from the original: tool names, file paths and truncated
  commands only. Never file contents, prompts, or environment values.** The
  graph's `output_preview_cap` of 4000 bytes is already a truncation boundary;
  the floor should use metadata only and not the preview.

**Animation vocabulary.** Map by tool category, which descriptors already
carry:

| Agent state | Trigger |
|---|---|
| reading | `read_file`, `search_code`, `code_search`, `symbols`, `history` |
| typing at a terminal | `exec`-capable tools (`git`, `gate`, `zig_check`, `test_file`) |
| editing | `write_note`, `edit_skill`, patch application |
| helper appears | `subagent`, `rlm` |
| orange glow | an `ask` event awaiting an answer |
| dozing | no event for five minutes |
| thinking | between `tool_result` and the next `tool_call` |

**Art.** [Kenney](https://kenney.nl) publishes 30,000+ assets under **CC0 1.0**
— public domain, commercial use fine, no attribution required. His pixel
platformer and RPG packs carry characters, desks and interior tiles in one
consistent style, which matters more than any single sprite.
[OpenGameArt's CC0 collection](https://opengameart.org/content/cc0-resources)
and [itch.io's CC0 asset tag](https://itch.io/game-assets/assets-cc0) are the
fallbacks. **Verify the licence of each file before vendoring**, record
provenance in `tools/zig/webui/vendor/ART.md`, and prefer CC0 over CC-BY so the
page never owes an attribution it does not display. Even where CC0 requires no
credit, the provenance file is how a future reader knows what may be
redistributed.

**Serving.** The sprite sheet is a vendored asset under `/webui/vendor/`,
alongside `d3-dag` and `highlight.js`: gzipped, immutably cached, and fetched
only when the view opens. It must not be inlined — the page has ~120 KB of
budget left and a sprite sheet would eat it. Render to a `<canvas>` with
`image-rendering: pixelated`.

**Accessibility.** The floor is decorative and duplicative: everything it shows
is already in the run graph and the transcript. Mark the canvas
`aria-hidden="true"`, keep a text status beside it, and give it a
`prefers-reduced-motion` still-frame mode. It is an addon and ships disabled by
default.

## 8. Phase 5 — remaining CLI parity

`providers check`, `gate`, `eval`, `improve-self` history, `revert`. All are
long-running, so they need a progress model the page does not have. Once
Phase 1's event channel exists, they can reuse it: run the operation, stream
its progress, render it. Do them after Phase 1, not before.

## 9. Order and reasoning

1. **1.1 ask bridge** — unlocks 1.2, the pixel floor's glow, and Phase 5's
   progress channel. Everything leans on it.
2. **1.2 confirm before write** — the change that most alters what the web UI
   *is*.
3. **1.3 images**, **2.1 fork** — small, independent, high ratio.
4. **3.1 subagent graphs** — prerequisite for 3.2 and the helper sprites.
5. **2.4 model switching**, **2.2 plan mode**, **2.3 compact**.
6. **3.2, 3.3** — the fleet views.
7. **Phase 4** — the floor, once there are real events to animate.
8. **Phase 5** — parity.

## 10. What would make this fail

- **Inlining the sprite sheet.** The build-time size check will catch it, but
  the instinct to inline is what to resist. Vendor it.
- **Gating the improve loop on a human.** Confirm-before-write must default to
  off and opt the browser in.
- **A blocked ask with no timeout.** It holds a connection thread and, with
  enough of them, the server.
- **Letting the floor become the product.** It is an addon over data that must
  remain fully legible without it.
