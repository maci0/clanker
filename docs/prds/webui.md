# PRD — Web UI

## Status

Shipped, core surface with one open phase (the pixel floor) and one open
parity gap (long-running CLI commands). Source of truth: `tools/zig/webui/*`
(`index.html`/`app.css`/`app.js` + `core/*`/`lib/*`/`features/*` ES modules),
comptime-embedded via `tools/zig/webui.zig`, routed in `src/cli.zig`
(`handleConnection`/`handleRun`/`handleWebuiAsset`/`handleWebuiPeers`/etc).
Surface: `clanker serve`, served at `GET /`. Co-equal product surface with
the CLI (`PRODUCT.md`). Turn-by-turn audit trail of the module-split and
accessibility work lives separately in `docs/WEBUI_REVIEW.md` — that
document is a working log, this one is the spec.

## Problem

The harness can do things the browser could not ask for, and does things the
browser could not see. Three capabilities existed server-side and were
unreachable from `clanker serve` before this work: `ask_user` (a tool built
for the moments where guessing is expensive was permanently dead in the
browser — `ckAsk` returned `not_found` with the ask function null outside the
REPL), image input (the harness is multimodal; the composer was a text box),
and subagent detail (a nested run returned one string; when it hit its
iteration cap the parent couldn't see how far it got).

## Goals

1. Make the harness's async/interactive capabilities (`ask_user`,
   confirm-before-write, image input) reachable from the browser without
   adding a socket or breaking the strict CSP.
2. Session and context control matching what the CLI already offers: fork,
   plan mode, visible compaction, provider/model switching.
3. Visibility into multi-instance behavior (peers, subagents) that a browser
   can show better than a terminal can.
4. Keep the page a single comptime-embedded static asset: no bundler, no
   build step, no new dependency beyond vendored files.

## Non-goals

- A server-push/socket transport. The server closes every connection after
  one response; the `/api/run` `\x01`-event stream is the one long-lived
  channel, everything else is polling.
- A framework rewrite (see Design → Framework choice).
- The pixel floor (Phase 4) becoming a primary surface — it must stay
  optional, decorative, and fully redundant with data shown elsewhere.

## Design

**Constraints, not preferences.** Breaking any of these breaks the build or
the product:

1. **One comptime-embedded file.** `index.html` is JSON-encoded through
   `lib.zig`'s `out_cap` (2 MiB); `tools/zig/webui.zig`'s comptime loop fails
   the build if any asset no longer fits. Anything large is a vendored
   asset served from `/webui/vendor/` (immutable cache + gzip, fetched only
   on first use), the way `d3-dag` and `highlight.js` already are.
2. **Strict CSP, offline-capable.** `default-src 'none'; script-src 'self'`;
   no third-party origin, ever; assets vendored into the repo, not linked.
3. **No sockets.** Live updating is polling except the one `/api/run`
   stream, which already carries `\x01`-prefixed control events
   (`tool_call`, `tool_result`, `ask`, `confirm`, `error`, `done`).
4. **Guest WASM buffers are 64 KiB** for scratch and host arena — anything
   larger is handled natively, not through a sandboxed tool.
5. **The improve loop rewrites this tree while you work.** Smaller, dumber,
   greppable files (one module per concern) survive automated rewriting
   better than framework idioms or one giant file.

**Framework choice: stay on vanilla JS.** Weighed VanJS, Alpine.js,
petite-vue, htmx, Preact, and React/Vue/Svelte/Solid against the constraints
above. Vanilla wins because the real problem was never "no framework" — it
was that `app.js` had become one 178 KB, ~4,300-line file. Alpine and
petite-vue solve sprinkling interactivity onto server-rendered HTML, not a
stateful SPA with streaming events and graph rendering; htmx assumes the
server returns HTML fragments, and ours returns JSON; React-class frameworks
need a build step, which constraint 1 rules out outright. Two escape hatches
are pre-decided for if a future view (the pixel floor, or a ground-up
composer) needs reactive binding: **VanJS** (~1 KB min+gzip, MIT, vendorable,
copy-in VanUI components) for a small state-driven view, or **Preact + htm**
(no JSX, tagged templates, no compile step) for a view that wants a real
component tree. Neither justifies rewriting a working vanilla view just to
use it. Full survey with sources: see the commit history of this document —
folded in here as the design rationale it is, not kept as a separate file.

**ES module split.** The actual fix for the one-giant-file problem: native
`<script type="module">`, no bundler, one file per concern, embedded and
routed the same way `app.css`/`app.js` already were —
`tools/zig/webui.zig`'s `assetFor` is a lookup table, adding a module is
mechanical. `app.js` went from 5,511 lines to roughly 3,500 across this
split; `core/utils.js`, `core/chat.js`, `core/labels.js`, `core/goals.js`,
`core/stream.js`, `core/theme.js`, `core/overlay.js`, `core/search.js`,
`core/composer.js`, `core/scroll.js`, `core/dialog.js`, `core/usage.js`,
`core/status.js`, `core/attachments.js`, `core/logs.js`, `core/plugins.js`,
`core/palette.js`, `core/modelpicker.js`, `core/tools.js` plus
`lib/markdown.js`, `lib/graph.js`, `lib/board.js`, `features/fleet.js` are
now real modules with real `import`/`export`, not `window.ck*` bridge
globals. `app.js` itself is a native ES module (`type="module"`), not a
classic deferred script. Every module needs three things wired together or a
request 404s or hits the wrong cache: an `@embedFile` + comptime `encodedLen`
guard in `tools/zig/webui.zig`, a `<script type="module">` tag in
`index.html`, and both an `is_webui` allow-list entry *and* a dedicated
`RenderCache`/`GzipCache` pair in `src/cli.zig`'s `handleWebuiAsset` — a
module missing the last part silently shares the generic `render_js`/
`gzip_js` slot with whatever else falls through, a real cache-aliasing bug
that shipped and was later caught and fixed.

**Ask bridge (`ask_user`).** A streaming run writes
`\x01{"type":"ask","id":…,"question":…,"options":[…]}` down its own
`/api/run` stream and blocks; the page renders the question as option
buttons in the turn card, and `POST /api/ask` resolves the wait (the answer
must be one of the offered options, byte for byte). An unanswered question
times out after `agent.ask_timeout_seconds` (default 120) and degrades to
the same "nobody attached" answer a headless run gets, so a closed tab never
hangs a run indefinitely — a blocked run holds one of `max_connection_threads`
(64), which is what bounds the exposure.

**Confirm before write.** Rides the ask bridge. With `agent.confirm_writes`
opted in (`browser`, or `always` for the REPL too; default `never`), a call
to a write-capable tool — exec or filesystem access in its descriptor, or an
explicit `"confirm": true` — blocks in the dispatch loop until the human
allows or denies it, traveling as a `\x01{"type":"confirm",…}` event with a
400-byte argument preview and fixed `allow`/`deny` options. Anything short of
an explicit allow (deny, timeout, closed tab, piped stdin) refuses the call
and tells the model the user declined. Headless runs, the improve loop, and
nested sub-agents never install a channel, so no config value can gate them
on an answer nobody is there to give — the improve loop must never be gated
on a human, and defaulting `confirm_writes` to `never` is what guarantees
that rather than relying on every caller remembering to opt out.

**Image input.** `RunRequestBody` carries `images: []struct { mime, b64 }`,
fed into the existing `ImagePart` path (`loop.zig`). The composer refuses an
image over 4 MB client-side; the server enforces the same cap on each
attachment's decoded size (`max_image_bytes`) plus a hard cap of 4 images per
message (`max_run_images` / `core/attachments.js`'s `max_images`) — both
caps exist because a hand-written request bypasses the page's own limits.
The raw HTTP body-size ceiling (`rawhttp.max_body_bytes`, 24 MiB) is sized to
fit four maximum-sized images after base64 expansion (~21.4 MiB) plus JSON
framing; the socket reader in `handleConnection` enforces this same limit
and returns 413, not a silent truncation.

**Fork.** Sessions are files (`state/sessions/<id>.json`), so fork is
copy-with-new-id and a title of "fork of \<title\>" —
`POST /api/sessions/<id>/fork`.

**Plan mode.** `{"plan": true}` on `/api/run` sets `Agent.plan_mode`, which
threads a plan-mode block into the system prompt *and* hard-refuses
write-capable tool calls in the dispatch loop through the same `needsConfirm`
predicate confirm-before-write gates on — what a viewer would be asked about
and what plan mode refuses can never drift apart, because they're the same
check. Read-only research runs free; the answer is a numbered plan. The page
has a Plan toggle beside Run, badges the proposal turn, and offers "Apply
plan," which re-runs in the same session with plan mode off.

**Visible compaction.** A Compact button and a confirming dialog
(`el.sessionCompact`) surface what used to be a silent, invisible
`compactMessages` call — the token weight next to the conversation picker,
an explicit user-triggered action rather than something that reshapes
context on its own with nothing shown.

**Provider/model switching.** `RunRequestBody` takes an optional
`provider`/`model` (the plumbing already existed in `providers.zig`'s
`Params`); `/api/providers` emits `cost_per_1m_input`/`cost_per_1m_output`
per model. The composer's visible search box (`#model-search`/
`#model-list`, `core/modelpicker.js`) is a second view onto the pre-existing
hidden `<select>`, which stays the one thing `runOptions()`/localStorage/
`renderContextMeter()` read — selecting an entry sets its value and
dispatches `change`, so nothing downstream needed to change.

**Subagent graphs and the Fleet view.** A nested run always recorded its own
graph, but under the same second-resolution `run-<ts>` id as everything
else, so a sub-agent spawned in the parent's second could silently collide
with a sibling. Nested runs now get a nanosecond `sub-<ns>` id
(`Agent.run_id_override`); the link runs both ways — the child's graph
carries `parent_run_id`, and the child's answer carries a trailing
`[subagent run: sub-<ns>]` line that lands in the parent's tool-node output
preview, so a viewer can walk from the parent's timeline into the nested
one. The Fleet view (`features/fleet.js`) renders this as roster + DM
channels + runs grouped `parent_run_id` → children, with peer agent cards
from `GET /api/peers` (which dispatches the same sandboxed `peers` tool
`clanker phonebook` uses — the page's CSP allows no other origin, so the
browser never asks a peer anything itself).

## Known issues

None currently known. The cache-aliasing bug mentioned above under ES module
split (modules missing their dedicated `RenderCache`/`GzipCache` pair) was
caught and fixed; if a new module split lands without wiring all three
pieces, it reproduces the same class of bug.

## Failure modes

| Condition | Behaviour |
|---|---|
| `ask_user` question unanswered past `ask_timeout_seconds` | Degrades to the headless "nobody attached" default |
| Confirm-before-write denied, timed out, or tab closed | Refuses the call, tells the model the user declined |
| Request body over `rawhttp.max_body_bytes` + 64 KiB headers | `413 Content Too Large`, connection dropped |
| More than 4 images attached | `400 Bad Request` server-side; composer refuses client-side first |
| A single image over 4 MB decoded | Refused, client and server both |
| `session` id on `/api/run` fails `validSessionId` | `400 Bad Request` — closes a traversal bypass unique to this route, since the dedicated session routes validate the same fragment but `/api/run` didn't inherit that check for free |
| Headless run / improve loop / nested subagent | No ask/confirm channel installed at all — no config value can gate them on an answer nobody is there to give |
| A webui asset missing its `RenderCache`/`GzipCache` pair | Falls through to the generic `render_js`/`gzip_js` slot shared with whatever else also falls through — wrong content can be served for a different path (known-fixed instance, watch for recurrence) |

## Acceptance criteria

Phase 1 — make it interactive:

- [x] 1.1 `ask_user` bridge
- [x] 1.2 Confirm before write
- [x] 1.3 Image input

Phase 2 — session and context control:

- [x] 2.1 Fork a conversation
- [x] 2.2 Plan mode
- [x] 2.3 Visible compaction
- [x] 2.4 Provider/model switching

Phase 3 — see what the agents are doing:

- [x] 3.1 Subagent runs recorded as their own graphs
- [x] 3.2 Cross-agent view (Fleet: roster, DMs, nested-run grouping)
- [ ] 3.3 Shared/private todo lists surfaced in the web UI (todos exist
      server-side — `docs/prds/run-todos.md`, `docs/prds/chatrooms.md` — but
      have no dedicated web UI view yet)

Phase 4 — `webui_pixelagents` (not started):

- [ ] Pixel-art floor, one desk per peer, animated by tool events

Phase 5 — remaining CLI parity (not started):

- [ ] `providers check`, `gate`, `eval`, `improve-self` history, `revert`
      reachable from the browser with a progress model

Infrastructure:

- [x] ES module split (`app.js` 5,511 → ~3,500 lines; all `core/*`/`lib/*`/
      `features/*` modules embedded, routed, and individually cached)
- [x] `lib.out_cap` comptime guard passes with headroom
- [x] Strict CSP verified live (`curl -si`), no inline script/style
- [x] Accessibility: 0 critical / 0 serious across all views (axe-core,
      `docs/assets/webui/axe.json`)

## Open questions / future work

- **Phase 4 (pixel floor).** Design is fully spec'd but unbuilt: live data
  from the existing `\x01` event stream plus `ask` for the orange-glow
  state; peers from `/api/status`; replay from `state/runs/*.json`. Privacy
  line carried over from the design this was inspired by (pixelagents.dev):
  tool names, file paths, and truncated commands only — never file contents,
  prompts, or environment values; the graph's `output_preview_cap` (4000
  bytes) is already a truncation boundary the floor should respect by using
  metadata only, not the preview. Art: Kenney's CC0 packs (or OpenGameArt/
  itch.io CC0 as fallback) — verify each file's licence before vendoring and
  record provenance in `tools/zig/webui/vendor/ART.md`. Must ship
  `aria-hidden="true"` with a text status alongside and a
  `prefers-reduced-motion` still-frame mode, disabled by default, since
  everything it shows already exists in the run graph and transcript.
- **Phase 5 parity** needs a progress-streaming model; the natural move is
  reusing Phase 1's `/api/run` event channel rather than inventing a second
  one, but the shape of "progress" for `gate`/`eval`/`improve-self` history
  hasn't been designed yet.
- **Remaining `app.js` decomposition** — `features/board.js`, `features/
  goals.js`, and other view-specific logic not yet split out, now cheaper
  than when this was first scoped because the import graph is real instead
  of window-bridge globals.
- **3.3 todo lists in the browser** — the data and claim semantics exist
  server-side; only the web UI view is missing.
