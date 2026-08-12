# PRD — Web UI

## Status

Shipped — Board (Trello) and Rooms (Slack) polished + callgraph navigation (Codex/Kimi/Qwen): search/kind filters with dim, `↗` sub-run jump + `↑ Parent`, deep-link `#runs/<id>?node=<label>` with pinned selection, minimap with dots+edges+viewport drag, path highlight on hover/focus, `/`→search/`n`/`F`/`j`/`k`/arrows/`+/-` keyboard, breadcrumb sync, `Copy link` pins node, inline `+` quick-add per lane,
Archive toggle for done, `Drop here — or Add card` empty slots, card cover strip +
member avatar + `✔ 50%` progress bar, priority `filled` due labels, Slack grouped
messages / day `— YYYY-MM-DD —` / hover gutter + `#` composer / `/me` `/shrug`
+ link unfurl + hover action bar + room `· 3 new` badges. ChatGPT/Cursor/Claude
theme also live. Source of truth: `tools/zig/webui/*`
(`index.html`/`app.css`/`app.js` + `core/*`/`lib/*`/`features/*` ES modules),
comptime-embedded via `tools/zig/webui.zig`, routed in `src/cli.zig`
(`handleConnection`/`handleRun`/`handleWebuiAsset`/`handleWebuiPeers`/etc).
Surface: `clanker serve`, served at `GET /`. Co-equal product surface with
the CLI (`PRODUCT.md`). Turn-by-turn audit trail of the module-split and
accessibility work lives separately in `docs/WEBUI_REVIEW.md` — that
document is a working log, this one is the spec.
Phase 6 — Chat UX parity against the Kimi Code web UI — also live: per-turn
Branch (server `branchSession` + per-turn Branch button), run-ref citation
chips → `openRun`, the composer model pill, and the collapsed icon rail.

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

**Theme / chrome (2026-08-12).** Light `#ffffff`/`#f7f7f8` and dark `#212121`/`#171717` aligned to ChatGPT/Cursor/Claude — `14px` antialiased body, pill composer `24px→20px` (focus `accent 22%`), user bubble `18–20px` right-aligned `min(30–42rem,68–78%)`, pill buttons/inputs `999px` (`sans 13px`), header `sticky ghost` (`92% surface`, `blur 10px`, `rule 70%`), `session-title` `14px/500 muted`, `session-actions` `30px/12px`, ghost `chip-btn`, `header-model` `999px` clickable → composer, rail `14–15rem` on `surface` (collapsed `56px`), `turn-events` `sans 12px` chips, `event-ask` `14px` card, `code-block` dark-sink `--code-bg/--code-fg`, `skeleton` shimmer, `turn-foot` hover-reveal, composer placeholder `13px/0.65`, toolbar `11px` meta, plus ChatGPT-density tweaks (`46rem` column, centered `6vh` hero `clamp(20–26px)`, `2× 18rem` suggestion grid `44px 10px` cards, `d3`/`hljs` vendor blurs preserved).

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
- [x] 3.3 Board filtered view — text/assignee/blocked/priority filters on the existing board (board *is* the todo surface, per `docs/prds/kanban-board.md`); no second data store

Phase 4 — `webui_pixelagents`:

- [x] Minimal pixel floor canvas in Fleet — decorative `fleet-floor` with `image-rendering:pixelated`, `aria-hidden` + text status, respects `prefers-reduced-motion`, data already from Fleet roster/runs

Phase 5 — remaining CLI parity:

- [x] Progress streaming under System — `Run gate` / `Run eval` / `Check providers` streaming over `/api/run` `\x01` events (`tool_call`/`tool_result`/`error`/`done`) with Abort stop

Phase 6 — Chat UX parity (Kimi Code web UI):

- [x] 6.1 Per-turn Branch — a Branch button on each turn cuts the conversation at that turn (`POST /api/sessions/<id>/branch/<n>`, `session.branchSession`/`turnCutoff`) and continues in a copy
- [x] 6.2 Citation chips → openRun — run references in answers (`run-…`/`sub-…`, `[subagent run: …]`) render as chips that open the run graph (`RUN_RE`/`appendRunRefs` in `lib/markdown.js`, `window.clankerOpenRun` bridge)
- [x] 6.3 Model pill inside composer — the active model as a pill button beside the run controls, opening the same picker the header chip opens
- [x] 6.4 Collapsed icon rail — rail collapses to a 3.5rem icon strip (`data-collapsed`, `data-short`, persisted); collapse toggle hidden under 60rem where the rail is a drawer
- [x] 6.5 Mermaid diagrams — `mermaid` fences render as diagrams (vendored `mermaid@11`, lazy `loadMermaid`, `buildMermaidBlock` + `renderMermaidBlocks` in `lib/markdown.js`), themed by `.md-mermaid` rules riding the app's palette variables; the SVG's inline `<style>` is stripped for the CSP and `style-src` gained `'unsafe-inline'` for the vendored renderer only (`script-src` stays `'self'`)
- [x] 6.6 Run changes — file-edit tool nodes record their arguments (`Node.arguments`, `arguments_preview_cap` 8000) and the run detail renders a per-file diff card (`✎ path  +N −M`, context lines, create = all-added) for `path`/`old`/`new` and `create`/`content` shapes
- [x] 6.7 Preview pane — `html`/`svg` fences render in a sandboxed blob-URL iframe (Preview toggle, `sandbox=""`, no scripts, opaque origin), with `frame-src 'self' blob:` added to the CSP; untrusted markup's scripts/external resources stay blocked

Infrastructure:

- [x] ES module split (`app.js` 5,511 → ~3,500 lines; all `core/*`/`lib/*`/
      `features/*` modules embedded, routed, and individually cached)
- [x] `lib.out_cap` comptime guard passes with headroom
- [x] Strict CSP verified live (`curl -si`): no inline script, and inline style only from the vendored mermaid renderer (`style-src 'self' 'unsafe-inline'`, `script-src 'self'` unchanged)
- [x] Accessibility: Phase 6 + mermaid additions 0 violations across views
      (axe-core 4.13, live sweep 2026-08-12 — see `docs/WEBUI_REVIEW.md`);
      pre-existing composer/rail/board/goals/runs contrast and structure
      items from the concurrent board/run-compare/workspace work logged there
      as the handoff for that surface

## Open questions / future work

- **Pixel floor** now ships as a minimal decorative canvas (see Design above); richer art (Kenney CC0, `vendor/ART.md` provenance) and live `\x01` glow can be layered later without changing the contract (`aria-hidden` + status text, `prefers-reduced-motion` still frame).
- **Phase 5 progress** now streams over the existing `/api/run` `\x01` channel; history/revert detail can be added per-run without a new transport.
- **Remaining `app.js` decomposition** — `features/board.js`, `features/
  goals.js`, and other view-specific logic not yet split out, now cheaper
  than when this was first scoped because the import graph is real instead
  of window-bridge globals.
