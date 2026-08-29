# PRD — Web UI

## Status

Shipped. Source of truth: `ui/app/*`
(`index.html`/`app.css`/`app.js` + `core/*`/`lib/*`/`features/*` ES modules),
comptime-embedded via `ui/webui.zig`, routed in `src/cli.zig`
(`handleConnection`/`handleRun`/`handleWebuiAsset`/`handleWebuiPeers`/etc).
Surface: `clanker serve`, served at `GET /`. Co-equal product surface with
the CLI. Turn-by-turn audit trail of the module-split and accessibility work
lives separately in `docs/reviews/webui.md` — that document is a working log,
this one is the spec. The shipped feature set (Board, Rooms, callgraph
navigation, ChatGPT/Cursor/Claude theme, Phase 6 chat parity, Compare,
goals↔board sync) is enumerated in Acceptance criteria below rather than
repeated here.

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
2. Session, workspace, and context control matching what the CLI already
   offers: fork, plan mode, visible compaction, provider/model switching,
   folder-backed workspaces, each a project with one or more named roots.
3. Visibility into multi-instance and per-run behavior (peers, subagents,
   run progress, and todos — the shared board view plus the private per-run
   checklist) that a browser can show better than a terminal can.
4. Keep the page a single comptime-embedded static asset under a strict,
   offline-capable CSP — no bundler, no build step, no new dependency
   beyond vendored files — and keep the shipped views accessible (no
   axe-core violations).
5. Chat UX parity with the Kimi Code web UI (branch, citation chips, model
   pill, icon rail, Mermaid, run diffs, preview pane, research toggle).
6. Kimi Code harness parity beyond chat: video input and the skills
   catalogue.
7. Goals↔board sync and mid-run steering.
8. Blind side-by-side model comparison (the Compare view).

## Non-goals

- Replacing the HTTP command API with a socket. `POST /api/*` stays how
  the page (and the CLI, A2A, curl) acts. The page *watches* over
  `GET /api/events` (SSE) so chat / mesh / run do not poll. `/api/run`
  is still its own stream.
- A framework rewrite (see Design → Framework choice).
- The pixel floor (Phase 4) becoming a primary surface — it must stay
  optional, decorative, and fully redundant with data shown elsewhere.

## Design

**Constraints, not preferences.** Breaking any of these breaks the build or
the product:

1. **One comptime-embedded file.** `index.html` is JSON-encoded through
   `lib.zig`'s `out_cap` (2 MiB); `ui/webui.zig`'s comptime loop fails
   the build if any asset no longer fits. Anything large is a vendored
   asset served from `/webui/vendor/` (immutable cache + gzip, fetched only
   on first use), the way `d3-dag` and `highlight.js` already are.
2. **Strict CSP, offline-capable.** `default-src 'none'; script-src 'self'`;
   no third-party origin, ever; assets vendored into the repo, not linked.
3. **HTTP commands, one watch channel.** `POST /api/*` is how the page
   acts. `GET /api/events` (SSE, same origin) is how it watches chat,
   mesh talk, and run working. `/api/run` keeps its `\x01` control
   events. Polling remains only as a fallback when the stream is down.
   No WebSocket: the browser does not need to send a high-rate stream.
4. **Guest WASM buffers are 64 KiB** for scratch and host arena — anything
   larger is handled natively, not through a sandboxed tool.
5. **The improve loop rewrites this tree while you work.** Smaller, dumber,
   greppable files (one module per concern) survive automated rewriting
   better than framework idioms or one giant file.

**Framework choice: vanilla core, Preact family for reactivity.** Weighed
VanJS, Alpine.js, petite-vue, htmx, Preact, and React/Vue/Svelte/Solid
against the constraints above. Vanilla stays the core because the real
problem was never "no framework" — it was that `app.js` had become one
219 KB, 4,998-line file. Alpine and petite-vue solve sprinkling
interactivity onto server-rendered HTML, not a stateful SPA with streaming
events and graph rendering; htmx assumes the server returns HTML fragments,
and ours returns JSON; compile-step frameworks are ruled out by constraint 1
outright. The reactive layer is the Preact family, all vendored ESM with no
build step: **@preact/signals-core** backs `core/ui.js`'s `state()`/`bind()`
and function-children (the VanJS-era `.val` API kept its spelling, VanJS
itself is gone), and **Preact + htm** (no JSX, tagged templates) is available
via `preact-boot.js` for any future view that wants a real component tree.
None of that justifies rewriting a working vanilla view just to use it. Full
survey with sources: see the commit history of this document — folded in
here as the design rationale it is, not kept as a separate file.

**ES module split.** The actual fix for the one-giant-file problem: native
`<script type="module">`, no bundler, one file per concern, embedded and
routed the same way `app.css`/`app.js` already were —
`ui/webui.zig`'s `assetFor` is a lookup table, adding a module is
mechanical. `app.js` dropped from 4,998 lines to 3,545 right after the
`board.js`/`goals.js` split, and sits at 6,499 today from later inline growth
(Phase 6, Kimi-parity); the Models/Schedule/Search views landed as real
modules (`features/models.js`, `features/schedule.js`, `features/search.js`,
each routed and individually cached in `src/cli.zig`); `core/icons.js`,
`core/ui.js`, `core/utils.js`, `core/vendor.js`, `core/chat.js`,
`core/labels.js`, `core/goals.js`, `core/stream.js`, `core/theme.js`,
`core/overlay.js`, `core/search.js`, `core/composer.js`, `core/scroll.js`,
`core/dialog.js`, `core/usage.js`, `core/status.js`, `core/attachments.js`,
`core/logs.js`, `core/plugins.js`, `core/palette.js`, `core/modelpicker.js`,
`core/tools.js` plus `lib/markdown.js`, `lib/graph.js`, `lib/board.js`,
`features/fleet.js`, `features/arena.js`, `features/board.js`,
`features/compare.js`, `features/goals.js`, `features/knowledge.js`,
`features/prompts.js`, `features/todos.js`, `features/models.js`,
`features/schedule.js`, `features/search.js` are now real modules with
real `import`/`export`, not `window.ck*` bridge globals. `app.js` itself is
a native ES module (`type="module"`), not a classic deferred script. Every
module needs three things wired together or a
request 404s or hits the wrong cache: an `@embedFile` + comptime `encodedLen`
guard in `ui/webui.zig`, a `<script type="module">` tag in
`index.html`, an entry in `src/cli.zig`'s `webui_asset_paths`, *and* a
dedicated `RenderCache`/`GzipCache` pair in `handleWebuiAsset` — a
module missing the last part silently shares the generic `render_js`/
`gzip_js` slot with whatever else falls through, a real cache-aliasing bug
that shipped and was later caught and fixed. `webui_asset_paths` is one list
because it used to be two: the module gate and the asset route were
hand-maintained copies of the same set, and `features/arena.js` appeared in
neither, so the Arena view's dynamic `import()` 404'd against a server that
held its bytes (hit twice independently in one day — see `644dc37` and
`docs/reviews/webui.md`). A test now walks `ui/app/{core,lib,features}`
and fails on any module the list has never heard of.

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
The raw HTTP body-size ceiling (`raw_http.max_body_bytes`, 24 MiB) is sized to
fit four maximum-sized images after base64 expansion (~21.4 MiB) plus JSON
framing; the socket reader in `handleConnection` enforces this same limit
and returns 413, not a silent truncation.

**Fork.** Sessions are per-session SQLite databases (`state/sessions/<id>.db`,
PRD 0044), so fork is
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
`provider`/`model` (the plumbing already existed in `registry.zig`'s
`Params`); `/api/providers` emits `cost_per_1m_input`/`cost_per_1m_output`
per model. The composer's visible search box (`#model-search`/
`#model-list`, `core/modelpicker.js`) is a second view onto the pre-existing
hidden `<select>`, which stays the one thing `runOptions()`/localStorage/
`renderContextMeter()` read — selecting an entry sets its value and
dispatches `change`, so nothing downstream needed to change.

**Theme / chrome.** The chrome follows the ChatGPT/Cursor/Claude idiom, all
plain CSS riding the app's palette variables (light `#ffffff`/`#f7f7f8`, dark
`#212121`/`#171717`), no theme engine: a 14px antialiased sans body, pill
shapes throughout (composer, buttons, inputs, the clickable `header-model`
chip, all `999px` radii), right-aligned user bubbles with a max-width clamp,
a sticky translucent header (mostly-opaque surface plus blur), a collapsible
rail on `surface`, chip-styled `turn-events`, a dark-sink code-block palette
(`--code-bg`/`--code-fg`), skeleton shimmer for loading, hover-revealed turn
footers, and a centered narrow-column hero with a suggestion grid. The
vendored `d3`/`hljs` view styling is preserved untouched.

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

**Todos in the browser (3.3).** Two layers, because "todos" was two questions.
Shared durable work is the Kanban board and always was, so that half is the
board's own filtered view — no second store. A run's *own* working plan is the
private per-run list (`src/agent/private_todos.zig`): in memory, capped,
discarded when the run returns, and until now invisible to the page. It rides
the one long-lived channel that already exists. `List.rev` counts real changes
(a `todo_list` read is not one, and neither is re-claiming an item the run
already holds); `Agent.on_todos` fires once per tool batch whose `rev` moved,
on the run thread after `executeCalls` has joined, so the unsynchronized list
has exactly one reader; `runStreamTodos` frames it as
`\x01{"type":"todos","todos":[…]}` — spliced, not re-encoded, because
`writeStreamEvent`'s 4 KiB stack buffer cannot hold 100 items of 512 chars.
The whole list travels every time rather than a delta, so a client that missed
an event is never out of step. `features/todos.js` renders it into the turn
card above the answer through a per-turn `state()`/`bind()` signal — per turn,
not per module, so a finished turn keeps the checklist its run ended with. Item
state is a CSS-drawn box off `data-status` plus the state in words, never a
glyph. Todo titles are model-written and therefore untrusted: they cross the
wire JSON-encoded and reach the DOM as text nodes through `T`, so there is no
interpolation step to escape.

**Compare view (9.1).** The browser half of `clanker compare` (see
`docs/ROADMAP.md`, "Blind side-by-side model comparison"): a Compare tab under
Watch listing past comparisons, one opened at a time, its answers side by side
in the order they were stored under nothing but `A`/`B`/`C`, and a pick button
per column. The pick posts to `POST /api/compare/<id>` with `{"pick":"B"}`,
which reaches the same `compare` tool op `clanker compare --show <id> --pick
<letter>` reaches — one recording path, not a second implementation of what a
pick means.

Blindness is the feature, and the view does not enforce it — it cannot. A page
that receives a provider name and declines to paint it is one devtools panel
from being un-blinded, so the enforcement is upstream: `/api/compare` asks the
tool for an un-revealed read (`"reveal": false`), and the tool answers with no
`provider` and no `model` anywhere in the reply. `features/compare.js` therefore
holds nothing to leak into a tooltip, a `data-` attribute, or JSON it keeps and
does not draw, and the columns are visually identical to each other on purpose:
any per-column decoration is a place to learn something before choosing. Three
things had to change in the tool for that to be true, all of which had been
correct for the caller it was written for — someone who had already watched the
blind view that minted the id: the read-one path revealed unconditionally, the
listing carried the ledger's winner *provider* (which, beside a verdict letter
the blind view does show, is the whole key for a two-way comparison, so an
un-revealed listing now says only "judged" or "no verdict"), and the blind
render named the judging provider beside the verdict while the caveat on the
next line said that provider may itself be an entrant. A recorded pick overrides
the ask and reveals, because being told who you picked is the point of having
picked blind.

Deliberately not in the view: starting a comparison. That is 2-8 concurrent
model calls against a server that answers one request per connection, the same
reason the Arena view links to `clanker arena` rather than starting a match.
The listing is ledger-derived like the tool's own (`state/compare/log.jsonl`),
so it cannot mark which comparisons you have already picked without reading
every document; "judged" is what a single ledger row can honestly say.

## Known issues

- **(Fixed) `respond` sent a body on HEAD and paid for it with keep-alive.**
  `AGENTS.md` states the invariant — every body-writing responder guards HEAD
  with `if (!request_head)` — and the asset, JSON and plugin responders do.
  `respond` (`src/cli.zig`) did not: it wrote the body unconditionally and set
  `request_keep_alive = false` on HEAD so the stray bytes died with the
  connection. Measured live, `HEAD /api/does-not-exist` returned a 404 plus all
  32 body bytes, and `HEAD /webui/plugins/<unknown>/app.js` — a webui path, so
  keep-alive eligible — answered `Connection: close` and dropped the socket.
  RFC 9110 9.3.2 forbids content on a HEAD response, and closing on every HEAD
  gave up the reuse the asset routes were made keep-alive for. The body write
  is now behind the same guard as the others and the keep-alive kill is gone;
  `Content-Length` still states what the GET would send. Filed as
  [respond sends a body on HEAD](../reports/bugs/2026-08-23-respond-sends-a-body-on-head.md).
- **(Fixed) A board card's hover actions were unreachable, and a third control
  was painted over.** `cardNode` (`ui/app/features/board.js`) built the card as
  a `<button>` and appended `Open card` and `Move to next column` into it. ARIA
  gives `role=button` presentational children, so the accessibility tree
  flattened both away and neither action could be reached at all; nesting
  interactive content in a button is also invalid HTML, and it is the
  `nested-interactive` count the 2026-08-12 axe sweep logged as a handoff item.
  They are a sibling of the card button inside the card's own `<li>` now, with
  `.board-card-item` as the positioning context, and each `aria-label` names its
  card. Separately, `.card-quick-edit-btn` (28px, `top:4px right:4px`) sat
  strictly inside `.card-quick-actions` (58x30, `top:2px right:2px`) at the same
  `z-index` and later in DOM order, both revealed by the same `:hover`, so it
  could never be clicked; its handler was identical to the bar's own `Open card`,
  so it is deleted. Still open on the same view: the card's member avatar is a
  `<span role="button">` inside the card button, which needs the card to stop
  being a button.
- **(Fixed) The composer's `@` and `#` suggestion lists bypassed
  `hidePromptList()`.** `#task` owns `#prompt-list` through `aria-expanded` and
  `aria-activedescendant`, and `hidePromptList()` is the one place that means
  "no list is open". `renderFileMentionList` and `renderKbMentionList`
  (`ui/app/app.js`) flipped `promptList.hidden` by hand instead, so the `@` list
  opened with `aria-expanded="false"` still on `#task` and a screen reader was
  never told a popup existed, and one `#` pick left `aria-expanded="true"` with
  an `aria-activedescendant` pointing at an option no longer shown, permanently:
  the composer's value is rewritten in code, so no `input` event follows to tidy
  up. Both close through `hidePromptList()` now, and there is exactly one
  `promptList.hidden = true` in the file. The same two functions also fired one
  listing per keystroke with no ordering, so a slow reply could repaint over a
  newer query, and ended in an empty `catch` that left a stale list open; each
  request takes a ticket now and a failure closes the list.

- **(Fixed) The keep-alive request budget was never in the `Connection`
  header.** `handleConnectionGuarded` loops while
  `requests < max_keep_alive_requests`, and nothing consulted `requests` when
  deciding the header, so the response that spent the budget said
  `Connection: keep-alive` and the server then closed. Measured live over one
  socket: response 99 keep-alive, response 100 keep-alive, and request 101 got
  an empty reply. A browser hides it by retrying an idempotent GET; a client
  that does not retry sees the close as a failure. The budget is part of
  eligibility now, so the last permitted response says `close` and the same
  measurement reads keep-alive through 99 and `close` on 100.
- **(Fixed) `POST /api/compare` with no id answered 400, documented as 405.**
  The Failure modes row below distinguishes it from the 400 for a pick with no
  letter precisely so a client can tell the two apart, and
  `compareRouteToToolInput` returns null for both, which the caller's single
  `orelse` turned into one `bad request`. There is a `compareCollectionPost`
  predicate before the mapping now; verified live, the collection POST is 405 and
  a blank pick against a real id is still 400.
- **Documentation drift: the Compare view is a plugin, not a page module.** Three
  passages here (Design, the blindness argument, and acceptance criterion 9.1)
  describe `ui/app/features/compare.js` with a dedicated
  `render_compare_view`/`gzip_compare_view` cache pair. There is no `compare` tag
  in `src/serve/webui_assets.zig` and no such path in the asset list: Compare
  ships as a disk plugin under `ui/plugins/compare/`, as `AGENTS.md` says. The
  behaviour the criterion claims is real and the file it names is not.
- The proxy's own two defects, both live-measured and both fixed, are recorded in
  `docs/prds/0026-llm-proxy.md`'s Known issues rather than here: every proxy
  response wrote a body on HEAD, and `writeEnvelope` truncated the 404 body
  mid-JSON on a client-supplied model name.
- **(Fixed) `HEAD` on an `/api` route answered 404 and closed.** The Failure
  modes row below says HEAD on *any* route answers the status and headers the GET
  would. Every `/api` route predicate compared the method to `GET` literally, and
  the keep-alive eligibility line used `isWebuiRead` (GET or HEAD) for `/webui`
  and a bare `GET` compare for `/api` on the very next line. Measured live,
  `HEAD /api/status` was a 404 with `Connection: close` where `GET /api/status`
  is 200. Fixed by rewriting a HEAD to the GET it mirrors once, ahead of the
  route chain, rather than teaching thirty predicates about it separately — the
  bug was two spellings of one idea drifting apart, and the responders already
  suppress the body from `request_head`. `GET /api/events` is excluded by
  `streamingReadRoute`, since an SSE stream has no fixed body to describe; the
  rewrite maps HEAD to GET and never to a write method, so `POST /api/run` needs
  no exclusion. Verified live: `HEAD /api/status` is 200 with the GET's
  `Content-Length` and keep-alive.
  [HEAD on api routes 404s and closes](../reports/bugs/2026-08-23-head-on-api-routes-404s-and-closes.md).
- **`RenderCache`'s `.failed` state is a permanent latch.** It falls through to
  rendering again, but the publish `cmpxchg` only accepts `.idle`, so a slot that
  ever reads `.failed` can never become `.ready`; one transient `gpa.dupe`
  failure pins that asset to the uncached path for the life of the process. Filed
  as [RenderCache failed is a permanent latch](../reports/bugs/2026-08-23-rendercache-failed-is-a-permanent-latch.md).
- **(Fixed) The saturation 503 was neither counted nor logged.** It was answered
  with `respond` on the accept thread, outside `handleConnection`, where the
  metric and completion-log defers live, so the one load condition an operator
  would grep `/api/metrics` for was the one the server did not record; and
  `respond` there read two threadlocals only `handleConnection` resets. Fixed by
  moving the refusal into `respondSaturated`, which resets those two flags,
  takes a fresh request id (so `X-Request-ID` is not the accept thread's last
  inline request), records the request and logs a warn line. It books under
  `errors_total`, not `client_errors_total` -- 503 is a 5xx, and the report's
  TL;DR named the wrong counter. The same change bounds the two spawn-failure
  fallbacks to one inline request (`inline_keep_alive_requests`) rather than the
  hundred `handleConnectionGuarded`'s keep-alive loop had silently given them.
  Reproduced live with 70 idle sockets: before, zero counters and zero log
  lines; after, `requests_total` and `errors_total` each +7. The stale-flag half
  is pinned by unit test, since a thread-spawn failure could not be forced.
  [connection limit 503 runs on the accept thread](../reports/bugs/2026-08-23-connection-limit-503-runs-on-the-accept-thread.md).

- **(Fixed) A saturation 503 was delivered over a reset connection.** Found
  while verifying the above, and untouched by it: the over-limit path never
  reads the request, so `stream.close` on a socket holding unread received data
  sent RST rather than FIN, and the RST could discard the response body.
  Measured live on a virgin server: the header block arrives,
  `Content-Length: 54`, zero body bytes, `ConnectionResetError`. Fixed by
  `drainThenClose` on both saturation sites: shutdown the send side, drain the
  unread request (bounded by a 1s receive timeout and a 64 KiB cap), then
  close a socket whose receive buffer is empty, so the close is a FIN and the
  body arrives by specification rather than by winning a race. Pinned by a
  socketpair unit test. Filed as
  [saturation 503 is reset before the client reads it](../reports/bugs/2026-08-24-saturation-503-is-reset-before-the-client-reads-it.md).

## Failure modes

| Condition | Behaviour |
|---|---|
| `ask_user` question unanswered past `ask_timeout_seconds` | Degrades to the headless "nobody attached" default |
| Confirm-before-write denied, timed out, or tab closed | Refuses the call, tells the model the user declined |
| Request body over `raw_http.max_body_bytes` + 64 KiB headers | `413 Content Too Large`, connection dropped |
| More than 4 images attached | `400 Bad Request` server-side; composer refuses client-side first |
| A single image over 4 MB decoded | Refused, client and server both |
| `session` id on `/api/run` fails `validSessionId` | `400 Bad Request` — closes a traversal bypass unique to this route, since the dedicated session routes validate the same fragment but `/api/run` didn't inherit that check for free |
| Headless run / improve loop / nested subagent | No ask/confirm channel installed at all — no config value can gate them on an answer nobody is there to give |
| A webui asset missing its `RenderCache`/`GzipCache` pair | Falls through to the generic `render_js`/`gzip_js` slot shared with whatever else also falls through — wrong content can be served for a different path (known-fixed instance, watch for recurrence) |
| A webui module missing from `webui_asset_paths` | `404`, even though the bytes are embedded and `assetFor` routes them (the `features/arena.js` case, fixed; the route list is now one list instead of two, and a test walks the source tree for modules it has never heard of) |
| `todos` event arriving for a turn that has already finished | Ignored: the panel is bound to that turn's own signal, so a later run cannot rewrite an earlier turn's checklist |
| `POST /api/compare/<id>` with a letter nobody answered under, or with no letter at all | `400 Bad Request`; the route refuses a blank or absent pick before the tool is loaded, and the tool refuses a letter that is not on the table rather than rounding it to A |
| `POST /api/compare` with no id | `405 Method Not Allowed` — a pick has to name the comparison it is a pick in, and "the newest one" would let a stale tab vote on a comparison it never read |
| A comparison id that could climb out of `state/compare/` | Carried to the tool as JSON data, never joined into a path, and refused there by the same `isSafeId` the CLI path uses |
| Mermaid fence fails to render / renderer fails to load | Fence box gets `md-mermaid-error` and an alert role; text names the failure (`Diagram failed to render: …` or `Could not load the diagram renderer.`) instead of a blank card |
| `POST /api/steer` when no run is working that goal/session | `404` with `"no run is currently working that goal or session"`; nothing is queued |
| `HEAD` on any route | The status and headers the `GET` would send, `Content-Length` included, and no body; a keep-alive eligible HEAD keeps the connection |
| A connection that has already served `max_keep_alive_requests` responses | The last of them says `Connection: close`, because it is the last one; a `keep-alive` there is a promise broken in the same breath it is made |

## Acceptance criteria

Goal traceability: Goal 1 → Phase 1 · Goal 2 → Phase 2 · Goal 3 → Phases 3–5 · Goal 4 → Infrastructure · Goal 5 → Phase 6 · Goal 6 → Kimi Code harness parity · Goal 7 → Goals↔board sync + mid-run steering · Goal 8 → Compare view.

Phase 1 — make it interactive:

- [x] 1.1 `ask_user` bridge
- [x] 1.2 Confirm before write
- [x] 1.3 Image input

Phase 2 — session and context control:

- [x] 2.1 Fork a conversation
- [x] 2.2 Plan mode
- [x] 2.3 Visible compaction
- [x] 2.4 Provider/model switching
- [x] 2.5 Project-backed workspaces — any number of `{name, roots:[{name,path}]}` rows in `state/workspaces.json`; rail picker scopes chats; files + run sandbox root at the project's primary root

Phase 3 — see what the agents are doing:

- [x] 3.1 Subagent runs recorded as their own graphs
- [x] 3.2 Cross-agent view (Fleet: roster, DMs, nested-run grouping)
- [x] 3.3 Todos in the browser, both layers. Shared durable work: the board's filtered view — text/assignee/blocked/priority filters on the existing board (the board *is* the shared todo surface, per `docs/prds/0002-kanban-board.md`); no second data store. A run's own working plan: the private per-run checklist rendered live in the turn card from `todos` events on the run's own `/api/run` stream (`features/todos.js`); the private-todo lifecycle itself is specified by `docs/prds/0003-run-todos.md`, not here

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
- [x] 6.8 Research toggle — composer checkbox beside Plan; `/api/run` carries `research`, threaded to `Agent.research_mode`, which appends `research_mode_suffix` (consult `web_search`/`fetch_web` for current, sourced facts) to the system prompt — a directive, not a gate

Kimi Code harness parity (open-source CLI — `MoonshotAI/kimi-code`):

- [x] 7.1 Video input — a dropped/pasted recording is sampled client-side to ≤4 JPEG frames (blob `<video>` + canvas, ≤640px, ~7 kB each) and rides the existing image path; `media-src blob:` added to the CSP
- [x] 7.2 Skills catalogue — `GET /api/skills` mirrors the system prompt's skill discovery (same dir/filters/sort; title + first paragraph + bytes only), rendered as a Skills section under the Tools view's rows

Goals ↔ board sync + mid-run steering (#91):

- [x] 8.1 Durable goal→card link — a mirror card carries its goal's id in its own `goal` field (`cards.zig` fold, last-writer-wins, `""` unlinks; `board`/`kanban_add`-visible), so the link survives reloads and other browsers; title matching remains only to adopt cards from before the field existed, and only unlinked ones
- [x] 8.2 Mirror waits for the board — `boardIsLoaded()` gates `mirrorGoalsToBoard`, ending the duplicate card minted on every Goals-view visit against a never-fetched (empty) card list; goal-driven card moves post with `goal_sync: false` so they cannot bounce back as board→goal writes
- [x] 8.3 `review` goal status — `validGoalStatus` grew `review` ("waiting for review" in the UI); a completed `/api/run` carrying a goal flips it active → review server-side (`setGoalStatusIf`), so a closed tab cannot leave finished work marked active
- [x] 8.4 Transient `running` — a registry of in-flight goal runs (one slot per connection thread, freed with the connection) reported as `"running":[ids]` by `GET /api/goals`; running goals pin their mirror card to Doing, and a crash can never leave a stale "running" flag because nothing is persisted
- [x] 8.5 Board→goal sync — moving a mirror card to Done/Review marks its goal done/waiting-for-review; pulling it back out of those columns reactivates it (abandoned goals stay abandoned); "Re-sync from goals" re-fetches goals and enforces the full status→column mapping, parking idle active goals out of the in-flight columns
- [x] 8.6 Mid-run steering — `POST /api/steer {goal, message}` queues a message the agent loop drains between iterations as a user interjection (`Agent.steer_fn`, polled at the one seam where a user message is always legal; a "steering message applied" status event lands on the run's own stream); each running goal's panel carries a send box, including runs streaming in another session

Compare view (blind side-by-side, #9):

- [x] 9.1 Compare tab — `features/compare.js`, wired like every prior module (embed + `out_cap` guard in `webui.zig`, `assetFor` route, `webui_asset_paths` entry, dedicated `render_compare_view`/`gzip_compare_view` whose predicate carries its directory and aliases nothing). Lists past comparisons from `GET /api/compare`, opens one from `GET /api/compare/<id>`, renders its answers side by side in stored blind order under positional `A`/`B`/`C`, deep-links as `#compare/<id>`, and records a pick with `POST /api/compare/<id>` `{"pick":"<letter>"}` — the same tool op the CLI's `--show <id> --pick <letter>` uses
- [x] 9.2 The payload is blind, not just the render — both read paths ask the tool for `"reveal": false`, and an un-revealed reply carries no `provider` and no `model` at all: not for the answers, not for the verdict, and not for the listing's winner column. A recorded pick overrides it and reveals. Pinned by `compare_logic.mayReveal`'s cases, by `compareRouteToToolInput`'s (a `true` there would hand the page the key), and by two `sandbox.runtime` tests that run the real `compare.wasm` against a document a live comparison actually produced and fail on any provider or model name in an un-revealed reply

Infrastructure:

- [x] ES module split (`app.js` 4,998 → 3,545 lines at the `board.js`/
      `goals.js` split, 6,499 today; all `core/*`/`lib/*`/`features/*`
      modules embedded, routed, and individually cached)
- [x] `lib.out_cap` comptime guard passes with headroom
- [x] Strict CSP verified live (`curl -si`): no inline script, and inline style only from the vendored mermaid renderer (`style-src 'self' 'unsafe-inline'`, `script-src 'self'` unchanged)
- [x] Accessibility: Phase 6 + mermaid additions 0 violations across views
      (axe-core 4.13, live sweep 2026-08-12 — see `docs/reviews/webui.md`);
      pre-existing composer/rail/board/goals/runs contrast and structure
      items from the concurrent board/run-compare/workspace work logged there
      as the handoff for that surface

## Open questions / future work

- **Pixel floor** now ships as a minimal decorative canvas (see Design above); richer art (Kenney CC0, `vendor/ART.md` provenance) and live `\x01` glow can be layered later without changing the contract (`aria-hidden` + status text, `prefers-reduced-motion` still frame).
- **Phase 5 progress** now streams over the existing `/api/run` `\x01` channel; history/revert detail can be added per-run without a new transport.
- **Remaining `app.js` decomposition** — `board.js` and `goals.js` split out
  already (see Design), but `app.js` grew back from 3,545 to 6,499 lines as
  later work (Phase 6, Kimi-parity) landed inline; no specific
  next module is scoped, but splitting is cheaper now that the import graph
  is real instead of window-bridge globals.
