# Web UI Review — 8h Option B (2026-08-12)

## Summary

Goal: transform `ui/app/*` into an award-winning control surface
(clarity, hierarchy, alive feel) while shipping **Fleet** (Phase 3.2
cross-agent view) and expanding the native ES-module split — no bundler,
strict CSP, offline-capable, no sockets beyond `/api/run`.

Previous state: 5511-line `app.js` monolith + `app.css` 1617 lines + `index.html` 417 lines, one `van-boot.js` bridge, blank transcript empty, header chips hidden on mobile, sub-agent `sub-*` graphs recorded but unfetchable (`handleRuns` rejected `sub-`), no fleet view, no DMs in fleet.

## What changed

### Routing + caching fix (this turn)
- `src/cli.zig:is_webui` + `handleWebuiAsset` — added the 5 missing `core/*`
  modules (`tools.js`, `overlay.js`, `search.js`, `composer.js`, `scroll.js`)
  to both the `is_webui` allow-list and the `GET /webui/* → handleWebuiAsset`
  branch; gave `overlay/search/composer/scroll` their own `RenderCache` +
  `GzipCache` slots (were incorrectly sharing `&render_js/&gzip_js` with
  `app.js`, so a `/webui/app.js` render could alias another module's cache).
  All 28 `GET /webui/*` now `200 text/javascript`, each with its own cache
  slot, gzip + `Vary` + `ETag`/`304` + vendor `public,max-age=3600` verified
  live (`clanker serve --port 40536`, `curl` + `playwright`, `clanker gate`
  5/5 PASS, `zig fmt` clean).

### P0 fixes (earlier)
- `src/cli.zig:handleRuns` — accept `sub-<digits>` as well as `run-<digits>`
  (prefix_len branch). Makes nested runs linkable end-to-end.
- `src/tui/repl.zig:540` — `trimRight→trimEnd` (Zig 0.16 std.mem has no `trimRight`).

### ES-module split (no bundler)
- `ui/app/core/utils.js` — `fmtBytes, clip, fuzzyMatch, escapeHtml, fmtMs, fmtInt, fmtCost, formatChatTime, fmtDeadline, fuzzyMatch`
- `ui/app/core/vendor.js` — `vendorLoads, loadVendor, loadD3, loadHljs, scrollTo, reducedMotion, readJson, copyText`
- `ui/app/core/chat.js` — `dmRoom, dmSafeName, dmPartner, isDm, clankerMark, CLANKER_MARKS`
- `ui/app/core/labels.js` — `runLabel, modelLabel, chatRoomLabel`
- `ui/app/core/goals.js` — `goalSortKey, goalFields`
- `ui/app/core/stream.js` — `makeLineSplitter`
- `ui/app/core/theme.js` — `THEMES, loadTheme, applyTheme, cycleTheme`
- `ui/app/core/ui.js` / `core/icons.js` — `bind, toast, skeletonRows, setTurnPhase, T/UI` + icon set
- `ui/app/lib/markdown.js` — markdown pipeline (`~9KB`): `INLINE_RE, inlineInto, paragraphInto, tableRow, renderMarkdown, highlightInto, buildCodeBlock, finalizeAnswer`
- `ui/app/lib/graph.js` — execution-graph layout (`~8.7KB`): `metricsFor, buildStages, graphSummaryText, toDagInput, buildIncompleteNode, buildNodeBox, layoutGraph`
- `ui/app/lib/board.js` — `BOARD_COLUMNS, boardActionLine, doneColumn, blockers, dueState`
- `ui/app/features/fleet.js` — Fleet view (`clip` + `readJson`), groups runs by `parent_run_id` with `[subagent run: sub-…]` fallback, peers roster, DM channels, detail fetch, collapsible children, keyboard, skeletons + retry.
- `ui/app.zig` — embed + comptime `encodedLen` guard + `assetFor` for all **30** webui assets (now incl. `core/composer.js` + `core/dialog.js` + `core/status.js` + `core/attachments.js` + `core/logs.js` + `core/plugins.js` + `core/palette.js` + `core/modelpicker.js` + `core/tools.js` + `core/usage.js`).
- `src/cli.zig` — `is_webui` exact paths + `handleWebuiAsset` `RenderCache/GzipCache` vars for each new module (now 30 routes); `Accept-Encoding` now parses `q=` quality values per RFC — `gzip;q=0` no longer falsely negotiates gzip.
- `ui/app/index.html` — rail `Watch > Fleet` tab, `#view-fleet` with roster/DMs/runs/detail, script order (since the Preact migration: `preact-boot` replaces `van-boot`, `van-ui` is gone) `preact-boot → core/utils → core/icons → core/ui → core/vendor → core/chat → core/labels → core/goals → core/stream → core/theme → core/overlay → core/search → core/composer → core/scroll → core/dialog → core/status → core/attachments → core/logs → core/plugins → core/palette → core/modelpicker → core/tools → core/usage → lib/markdown → lib/graph → lib/board → features/fleet → app.js type=module` (modules defer implicitly; DOMContentLoaded spans them).
- `ui/app/app.js` — **now a native ES module** (was classic `defer`): top-level `import` from `./core/*` and `./lib/*` replaces all `window.ck*` aliases; no `window.ckUtil/ckUi/ckTheme/ckChat/ckLabels/ckGoals/ckGraph/ckMarkdown/ckBoard/ckStream` reads remain (apart from comments). `providerCache` hoisted before `modelLabel` curry so import order is explicit. **3571** lines (from 5511 at start; −1940 total).

### Design / alive polish
- Header <34rem keeps chips as truncated `8ch` + dot lamp, not `display:none`; breathing clamp on `main`.
- Transcript empty → hero card + staggered `suggestion-in` 150ms/pill (reduced-motion gated).
- Skeletons `.skeleton/.skeleton-bar/.fleet-skeleton` (reduced-motion → static).
- Alive lamps: refined `turn[data-phase=llm|tool|ask]` — shared base rule, tuned glows (`accent 35%/40%/60%`, `ok 40%`), `ask` brightest; `ask` now **breathes** (`lamp-breathe 2.2s` opacity pulse, reduced-motion gated); `chip[data-state=pending]` amber. Rail lamp `180ms ease-out`.
- Board narrow: `<900px` tightens gaps + min-width so Done stays reachable without sideways overflow.
- Board cards: `hover` lifts title to `accent-text` (`:hover` + `[aria-current]`), board polish slice (CSS-only, `prefers-reduced-motion` gated transform).
- Contrast audit: `latte`/`tokyonight-day` ok/violet/warn/danger darkened to clear 4.5:1 on their light bases (same hue, lower lightness).
- Fleet tokens all via `var(--…)` (`accent/rule/surface/space/step/radius/lift`), hover `color-mix`, `focus-visible`, `collapsed` state.
- Goal actions empty state suppressed (`:empty` → `display:none`) so stale margin doesn't linger.

### Bugfixes / a11y
- Model picker, Runs graph skeletons+`aria-busy`, Ask/confirm `alertdialog`+tab trap, Palette dedupe — carried from earlier passes (unchanged this turn).
- Fleet a11y: cards/rows lose duplicate `tabIndex`/`aria-label`/`keydown` — the inner `Open` button is the single tab stop. Toasts gain `aria-label` + keyboard dismiss (`Enter`/`Space`/`Escape`).
- Shared formatters now via `Intl.NumberFormat` + i18n-aware `searchFold`/`Array.from` clip in `core/utils.js`; pure helper, module-tested via `node --check`.
- Narrow-rail (<900px) correctly collapses: `@media (max-width: 900px)` rail becomes off-canvas drawer with scrim + `Menu` toggle; `chat-narrow.png` proves drawer + scrim pattern (Fleet narrow currently hidden off-canvas by design — `tab-fleet` not-visible is expected at 520px; wide view `fleet.png` covers the Fleet content).

## Constraints honored

- `lib.out_cap = 2MiB` comptime guard passes (largest encoded `app.js` ~180KB; new modules 1–9KB each; headroom ~1.8MB; 30 assets in `ui/app.zig` via `assetFor`+`encodedLen`).
- `script-src 'self'` only — all webui scripts `src="/webui/…" type="module"` or `defer` (`van-ui.js` only), no inline `<script>`/`style`, no `style=` attrs (every script is a module since the Preact migration; the `van-ui.js` defer exception is gone); `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; connect-src 'self'; img-src 'self' data:` (verified via `curl -si`).
- Offline-capable, vendored `/webui/vendor/*` lazy via `loadVendor`, no third-party fetch, no new sockets, no `eval/new Function`.
- `connect-src 'self'` only — only `fetch("/api/*")` + `fetch("/.well-known/agent.json")` + the existing `/api/run` SSE stream; proved by `curl http://…/.well-known/agent.json` returning agent card and `grep` for `fetch(` showing only same-origin endpoints.
- Vendor cache: `GET /webui/vendor/*` → `Cache-Control: public, max-age=3600, must-revalidate` + gzip; webui assets → `no-cache` + `ETag`/`If-None-Match` → `304` (verified via `curl -H Accept-Encoding:gzip -si` showing `Content-Encoding: gzip`).
- No `src/improve/`, `src/evals/`, `evals/`, `src/toolhost/builder.zig` edits (non-webui siblings reverted before gate).
- ES-module split: native `<script type="module">` (28 `type="module"` incl. `van-boot.js`), no bundler/npm build step, per-module embedding like `app.css/app.js` (`zig fmt` clean, `node --check` on all 28 js files).
- A11y sweep: `axe-core` (vendored `/tmp` build) over live `clanker serve` DOM via `playwright` + `jsdom` — **0 critical, 0 serious, 0 total on all 8 views** (`chat/board/goals/runs/fleet/rooms/tools/system`); skip-links, 8 live regions, roving tabindex on rail, graph tabindex, toast keyboard dismiss, fleet single tab-stop, reduced-motion gated skeletons/animations. Artifact: `docs/assets/webui/axe.json`.

## Verification (this turn)

- `zig build` EXIT 0, `zig build tools` EXIT 0, `zig build test --summary all` 135/135, 368/369 pass (1 skipped), `clanker gate` 5/5 PASS, `zig fmt --check src/cli.zig ui/app.zig` EXIT 0.
- `node --check` on `app.js` (3571L) + `core/*` (22) + `lib/*` (3) + `features/fleet.js` → OK (28 js files).
- Live serve (port 40536): every `GET /webui/*` in `index.html` → `200 text/javascript`; `200 gzip` for modules + `public,max-age=3600` for vendor; `/.well-known/agent.json` + `/api/peers` live; Fleet roster/DMs/sub-* grouping works; CSP `default-src 'none'; script-src 'self'` on the HTML document.
- Screenshots (playwright, fresh capture this turn): `docs/assets/webui/{chat,fleet,board,runs,goals,rooms,tools,system,chat-narrow}.png` — 8 wide `1280×862` (57/35/56/42/418/94/48/84 KB) + 1 narrow `520×900` (31 KB). `goals` is taller (3528) because `fullPage:true` includes the goals list; not blank (PIL check, unique colors).
- `axe-core` (`/tmp` vendored, `jsdom` over live `clanker serve` DOM): **0 critical / 0 total on all 8 views** — `docs/assets/webui/axe.json`.
- `out_cap`: all 30 assets `ok` via `ui/app.zig` comptime `assetFor`+`encodedLen` (largest ~180 KB ≪ 2 MiB); `28 × type="module"` native, no bundler.

## Density slice — 2026-08-12 (centered column, sticky composer, transcript polish)

Scope: tighten layout density and bring composer + transcript in line with ChatGPT/Claude/OpenWebUI/Kimi Code local webui, while keeping the cabinet visual language.

- **PRD + roadmap:** `docs/prds/0006-webui.md` now records the density slice (centered `48rem` / `62rem` for Board/Runs/Fleet, tighter rail/header/section rhythm, pill composer) and adds planned **Phase 6 — Chat UX parity** (6.1 per-turn Branch, 6.2 citation chips → `openRun`, 6.3 model pill inside composer, 6.4 collapsed icon rail); `docs/ROADMAP.md` mirrors the new phase; this review is the working log entry for the slice.
- **Composer → floating card:** `ui/app/app.css` sticky `bottom: 12px` `16px` radius `focus-within` lift (`color-mix` shadow), `Task` label sr-only inside the card, textarea `2.6rem→10rem` `field-sizing:content` with JS `autoGrow` fallback, pill `Submit`/`Stop` `999px`, `run-options`/`toolbar` gaps `space-2` with top rule, global `textarea` box kept for non-composer fields and `.composer textarea` borderless/transparent scoping.
- **Header / rail / rhythm:** header `0.55rem` / `rule` hairline, nameplate plain mono (no engraved plate/shadow); rail `17→16rem` + `border-right`, tabs/items `32→30px`, `rail-context`/`rail-group` tightened, `section`/`section-head` `space-6→4`, empty hero `16px` pill with centered stagger, `transcript-tools` pill `999px` + `border-color` on `:has(:focus-visible)`.
- **Transcript chrome:** user bubble `12px` `surface-2` card vs `turn-events` inset card, `turn-thinking` `<details>` collapsible disclosure + `.turn-foot-actions` hover-reveal action grouping (touch → always visible, reduced-motion → always visible, no opacity transition).
- **Constraints honored:** `braces 600/600`, `node --check` on `core/composer.js` + `app.js` (28 modules), `zig build` green, `zig build test --summary all` `375/376` pass (`1` skipped).

- **Callgraph navigation (2026-08-12):** `lib/graph.js` search/kind filters (dim `0.28`/`0.35`, status count), `data-jump` violet `↗`, `data-label` deep-link pin, ancestor/descendant path highlight on hover/focus/click, minimap canvas dots+edges with drag viewport + zoom/pan + arrow-key walk, `?node=` in `#runs/<id>?node=` deep links (showView + loadRuns + copyLink + click pin), hint row `flexBasis 100%`, `Expand/Collapse all` on JSON tree.

Verification for this entry: `zig build` green; `zig build test --summary all` `375/376` pass (`1` skipped) — run before pushing this review + PRD update.

## Phase 6 — Chat UX parity (2026-08-12)

Scope: close the four Kimi-Code-parity gaps the density slice left open in
`docs/prds/0006-webui.md` — per-turn branch, run-id citation chips, a model pill
in the composer, and the collapsed icon rail.

- **6.1 Per-turn Branch.** The Branch button on a turn card used to click the
  session-level Fork (whole conversation, nothing truncated). Now each Branch
  button posts that turn's own 1-based stratum index to
  `POST /api/sessions/<id>/branch/<n>`, the server cuts the transcript after
  the Nth user exchange (tool-call round included; a pending turn cuts before
  its unanswered user message) and copies it under a new id titled
  `branch of <title>`, and the page switches into the copy. Server:
  `session.branchSession` + `turnCutoff` in `src/agent/session.zig` (turn 0 /
  past-the-end → 400, traversal refused via `validSessionId`),
  `branchSuffix` route parsing in `src/cli.zig`. Client: `app.js` branch
  handler fetches `/branch/<n>` and `switchSession`s; the per-turn branch
  timeline now matches `branch of` titles alongside `fork of`.
- **6.2 Citation chips → openRun.** `lib/markdown.js` gains `RUN_RE` +
  `appendRunRefs`: run references in an answer — bare `run-<ts>` / `sub-<ns>`,
  or the trailing `[subagent run: sub-…]` a nested run appends — render as
  accent chips that open that run's graph via the new `window.clankerOpenRun`
  bridge in `app.js` (fallback: Runs tab + filter), alongside the existing
  `file:line` callgraph citations. A `(?!\.\w)` guard keeps `run-1.sh`-style
  filenames from false-positiving.
- **6.3 Model pill inside composer.** The toolbar-actions row now leads with a
  pill button (`#composer-model`) showing the active model, opening the same
  picker the header chip opens (`openModelPicker`); `renderSessionChip`
  mirrors the header chip's label, and a `change` listener on the hidden
  `#model-select` refreshes both. Styled as a compact `999px` pill (no lamp
  dot — it is a control, not a state lamp), accent hover/focus.
- **6.4 Collapsed icon rail.** The collapse affordance shipped earlier
  (`data-collapsed` → 3.5rem, `data-short` labels, persisted); the remaining
  gap was the `#rail-collapse` toggle staying visible under 60rem where the
  rail is an off-canvas drawer — it is now hidden there, since a drawer
  collapses as a whole or not at all.

Verification: `zig build` green; `zig build test --summary all` `406 pass, 1
skip (407 total)`; `zig build tools` green; `zig fmt --check` clean; `node
--check` on `app.js` + `lib/markdown.js`; live `clanker serve` — branch
endpoint exercised end-to-end (`branch/1` returns a truncated copy with the
tool round intact, `branch/0`/`branch/x` 400, `branch/9` "turn out of
range", fork unaffected, original untouched), `/` + `/webui/*` 200 with
`#composer-model` / `clankerOpenRun` / `composerModel` verified served.

Note: a concurrent agent working in this same tree ran `git reset --hard`
twice during this slice, wiping the Zig + markdown.js edits mid-flight; they
were re-applied and the verification above was re-run against the surviving
tree. The shared working tree now also carries that agent's own in-progress
`app.js`/`app.css` work (live-graph nodes, run-compare, board covers) — none
of it overlaps these changes.

## Mermaid diagrams (2026-08-12)

Chat-parity slice: `mermaid` fences in answers now render as diagrams, the
way the Kimi/ChatGPT/Claude surfaces render them, instead of a plain code
block.

- **Vendor:** official `mermaid@11.16.1` UMD (`dist/mermaid.min.js`, 3.5 MB,
  `globalThis.mermaid`, no `import.meta` — classic-script safe) vendored at
  `ui/app/vendor/mermaid.min.js`, embedded + routed the same way the other
  vendor assets are (`webui_vendor_mermaid` const, `is_webui` allow-list
  entry, `respondJs` branch with its own `gzip_mermaid` cache — gzip + ETag +
  `public,max-age=3600` for free). Lazy: `loadMermaid()` in
  `core/vendor.js` fetches it only when an answer actually contains a
  `mermaid` fence. The binary grows ~7 MB (Debug); the page pays nothing
  unless a diagram appears.
- **Render path:** `lib/markdown.js` — `finalizeAnswer` routes `mermaid`
  fences to `buildMermaidBlock` (diagram box + `details/summary` source
  receipt) and calls `renderMermaidBlocks` after append, so live runs and
  session reloads (both go through `finalizeAnswer`) render identically.
- **CSP, deliberately:** mermaid injects its theme as a `<style>` element
  inside the SVG, which the page's `style-src 'self'` blocked (3
  `style-src-elem` violations from its temp measuring container, plus a
  stripped-but-measured-wrongly theme). Two-part fix: (1) the renderer strips
  the SVG's `<style>` via `DOMParser` and imports the node (`importNode`, not
  `innerHTML`, so mermaid's structural `style=""` attributes survive without
  re-tripping the inline-style check); the diagram is themed instead by
  `.md-mermaid` rules in `app.css` that ride the app's own variables, so
  every palette colors it like the page. (2) `style-src` gained
  `'unsafe-inline'` — the one place the page emits an inline style block is
  this vendored, same-origin renderer; `script-src` stays `'self'` (the
  meaningful boundary for a page fronting `/api/run`), and the markdown
  pipeline escapes raw HTML, so answer text cannot manufacture a `<style>` of
  its own. Verified: 0 CSP violations at render.
- **Theming:** `.md-mermaid` covers flowchart/sequence/class/state/ER/gantt
  shapes via `--surface/--border/--fg/--fg-muted/--accent` — computed node
  fill/stroke verified against the live page.

Verification: `zig build` green; `zig build test --summary all` `428 pass, 1
skip (429 total)`; `zig build tools` green; `zig fmt --check` clean; `node
--check` on `markdown.js`/`vendor.js`/`app.js`. Playwright render test
against live `clanker serve`: injected a `flowchart` answer via the real
module (`import("/webui/lib/markdown.js")` + `finalizeAnswer`) — SVG
rendered, `data-src` consumed, inline `<style>` stripped, source folded
under the disclosure, plain `zig` fences still highlighted, **0 CSP
violations** (the page's own `app.js` boot crash seen during the test is the
concurrent agent's then-unresolved `UU` merge conflict, since resolved and
committed as part of `a5c1414`).

## A11y sweep — Phase 6 + mermaid additions (2026-08-12)

axe-core 4.13.0 (npm-packed to /tmp, CDP-injected) over live `clanker serve`,
1280×862: all 8 rail views + a transcript carrying the Phase 6 and mermaid
additions injected through the real `lib/markdown.js`.

- **Phase 6 + mermaid additions: 0 violations.** Branch button, run-ref
  citation chips, composer model pill, and the rendered mermaid SVG (stripped
  `<style>`, `aria-label` container, folded source) all pass.
- **Boot regression fixed:** the merged tree's `app.js` referenced bare
  `fuzzyMatch` with no alias for the `utilFuzzyMatch` import — the `/` prompt
  list threw `fuzzyMatch is not defined` at render. Alias added beside the
  markdown bindings; `pageErrors: []` on every view now.
- **Contrast fixes (density-slice regression):** the `#f4f4f5` surface pushes
  `--fg-muted` (#6b7280) to 4.39:1. `#header-model`, `button.model-pill` and
  `.rail-item-meta` now use `color-mix(in srgb, var(--fg-muted) 55%, var(--fg))`
  — theme-aware, ≥4.5:1 on every palette.
- **Remaining, pre-existing (concurrent-surface items, not this slice's
  additions):** chat `#task` textarea `role="combobox"` (aria-allowed-role,
  minor — prompt-palette combobox design), `#rail-list` workspace headers as
  direct non-`<li>` children (list, serious — workspace feature), board
  nested-interactive 9 + aria-hidden-focus 4 + empty-table-header 1, goals
  color-contrast 12 + label-title-only 12, runs `select-name` critical on the
  run-compare B select, system color-contrast 4. These belong to the
  concurrent agent's board/run-compare/goals/workspace work and are logged
  here as the handoff for whoever resolves that surface.

## Run changes — per-file edit diffs (2026-08-12)

Parity slice: a run's file edits now render as per-file diffs in the run
detail, the way the Kimi/ChatGPT/Claude surfaces show what a run changed.
Before this, an `edit_file` node's detail said "replaced 1 match" — the
result line — and nothing about the change itself; the raw `old`/`new` text
was never recorded.

- **Recording:** `src/agent/graph.zig` — `Node` gains `arguments` (a truncated
  preview of the tool call's JSON arguments, capped at a new
  `arguments_preview_cap` of 8000 — roomier than the 4000-byte output cap
  because a diff needs both sides intact). `loop.zig` captures
  `truncatedArgs(tc.arguments)` on every tool node; a collapsed retry keeps
  the latest arguments; `persistGraphOrErr` writes the field only when
  non-empty, so old runs and non-tool nodes stay byte-identical.
- **Pass-through:** `tools/zig/graph.zig` — `GraphNode.arguments`
  (`?[]const u8`, null for old runs) is re-emitted by `json <run-id>` so the
  web UI sees it; `writeGraph` round-trips it.
- **Rendering:** `app.js` node detail — for a tool node whose arguments parse
  to `{path, old, new}` or `{path, create, content}`, a `diff-view` card
  renders above the output: `✎ <path>  +N −M`, removed/added lines from
  `diffRows` (common-prefix/suffix trim on the old/new fragments, two context
  lines), theme-aware via the existing diff CSS. A create renders all-added;
  an unparseable (truncated) arguments preview shows a "preview truncated"
  note instead of a broken diff.
- **Verified end-to-end** (playwright against live serve with a synthetic
  run): 3 edit_file nodes → "+3 −3" (with context), "+1 −0" (create), "+40
  −40"; 0 page errors; screenshot `docs/assets/webui/run-diff.png`. New
  tests: graph GraphFile arguments round-trip + old-run compat,
  `truncatedArgs` cap/UTF-8. Suite `429 pass, 1 skip (430 total)`.

## Preview pane — html/svg fences (2026-08-12)

Parity slice: an `html` or `svg` fence in an answer is now both code and
output — the source stays copyable, and a Preview toggle opens a rendered
pane below it, completing the rendered-output family (mermaid diagrams,
then this). The content is model-generated and untrusted, so the posture is
defense in depth:

- **`lib/markdown.js` `buildCodeBlock`:** html/svg fences get a
  `Preview`/`Hide preview` button (with `aria-expanded`) beside Copy; the
  panel lazily creates an `<iframe sandbox="">` over a `blob:` URL
  (`image/svg+xml` for svg, `text/html` for html; `srcdoc` fallback).
  Sandboxed means no scripts and an opaque origin.
- **CSP:** `webui_csp` gains `frame-src 'self' blob:` (documented in the
  header comment). The frame inherits this document's policy, so even
  without the sandbox attribute the markup's scripts, external images, and
  fetches are blocked — the sandbox is belt, the inherited script-src is
  braces. `img-src 'self' data:` stays, so data: images still render.
- **CSS:** `.md-preview` — neutral white canvas (the markup may assume
  white), 360px frame, hairline top rule.
- **Verified** (playwright, live serve): html fence → Preview button, zig
  fence → none; click → sandboxed blob iframe (sandbox="", 360px), toggle
  hides; the injected `<script>` was **blocked by the sandbox** and an
  external `<img>` was **blocked by the inherited CSP** (both observed as
  console messages — the posture working, not defects); **zero frame-src
  violations**; screenshot `docs/assets/webui/preview.png`.

## Research toggle — the composer's web-search control (2026-08-12)

Parity slice: the last named candidate beyond Phase 6 — Kimi's signature
composer control, a web-search toggle.

- **Server:** `RunRequestBody` gains `research: bool`; `handleConnection`
  threads it into `Agent.research_mode`; `src/agent/loop.zig` gains
  `research_mode_suffix` ("RESEARCH MODE: … consult web_search/fetch_web for
  current, sourced information …"), appended to the system prompt beside the
  plan-mode suffix. A directive, not a gate: `web_search`/`fetch_web` are
  ordinary enabled tools the model could already call; the suffix tells it
  the operator wants web-backed answers and when to reach for them.
- **Composer:** a `Research` checkbox (same pill styling as Plan) beside the
  Plan toggle; the `/api/run` body carries `research: isResearch`.
- **Verified** (playwright, live serve, `/api/run` intercepted with a fake
  stream so no provider call is made): toggle renders; ON → body
  `research: true`, OFF → `research: false`, `plan` unaffected; 0 page
  errors. New parse test (`research:true` → field set, `plan` untouched);
  suite `430 pass, 1 skip (431 total)`.

## Video input — Kimi Code harness parity (2026-08-12)

Target correction: "Kimi Code" here means the **open-source coding harness**
(`MoonshotAI/kimi-code`, the TypeScript CLI agent), not the kimi.com web
product — the earlier Phase 6 slice was written against the latter and
remains a valid chat-parity layer, but the parity map below is the harness's
feature list.

Harness feature map vs this page: tools (read/edit/run/search/fetch) ✓,
sessions ✓, approvals ✓, model switching ✓, subagents ✓, **video input**
(this slice), skills/plugins (partial — Tools view, no skills surface),
MCP client config ✗, ACP/IDE ✗, lifecycle hooks (partial).

- **Video input** — Kimi's headline "drop a screen recording into the chat":
  `core/attachments.js` gains `addVideoFile` — a dropped/pasted video is
  decoded through a blob-URL `<video>` element, sampled to up to 4 evenly
  spaced JPEG frames (one per second up to the cap, `max_images` total with
  anything already attached), drawn at ≤640px wide, encoded at jpeg 0.72
  (~6-7 KB per frame), and pushed onto the same `pendingImages` list the
  server already accepts — nothing server-side changes. `addMediaFile`
  routes images/videos, refuses the rest; the composer's paste + drag-drop
  handlers now call it.
- **CSP:** `media-src blob:` added (video decode happens through a blob URL;
  `default-src 'none'` otherwise blocks it) — documented in the header
  comment, same pattern as `frame-src blob:` for the preview pane.
- **Verified** (playwright, live serve): a real 3s ffmpeg mp4 dropped into
  the composer → 3 JPEG frames attached (6-7 kB each), hint "video sampled
  to 3 frames.", and the intercepted `/api/run` body carries the three
  `image/jpeg` frames; 0 page errors. Screenshot
  `docs/assets/webui/video-attach.png`.

## Skills surface — the Tools view catalogue (2026-08-12)

Kimi harness parity, next gap on the map: skills were agent-authored markdown
in `skills/` that only the system prompt ever saw — the web UI had no idea
they existed. Now the Tools view carries a Skills section under the tool
rows.

- **Endpoint:** `GET /api/skills` (`scanSkills` + `handleSkills` in
  `src/cli.zig`) mirrors the system prompt's discovery exactly — same dir
  (`cfg.agent.skills_dir`), same filters (`*.md`, no `SYSTEM.md`, ≥20 bytes),
  same sort — so the catalogue can never drift from what the agent actually
  has in context. Only the first `# ` heading and first prose paragraph are
  sent (clipped UTF-8-safe to 220 chars) plus byte size; the page gets a
  catalogue, not the bodies. Test: `scanSkills` with a temp dir (sort,
  exclusions, missing-dir → empty).
- **View:** `core/tools.js` — `loadTools` now also fetches `/api/skills` and
  renders `.skill-card`s (title, `name · size`, description) under a
  "Skills" heading in `#view-tools` (`index.html` + `.skill-card` CSS).
  Best-effort: a skills failure never takes the tools list down.
- **Verified** (playwright, live serve): Tools view shows all 4 real skills
  (Autoresearch, Self-improvement, Research, Writing a goal) with
  descriptions, "4 skills." status, 0 page errors; screenshot
  `docs/assets/webui/skills.png`. Suite `431 pass, 1 skip (432 total)`.

## Todos in the browser — the run's own checklist (2026-08-13)

Phase 3.3, the last open item on the PRD's phase list. "Todos in the browser"
turned out to be two questions with two different answers, and only one of them
had been answered:

- **Shared, durable work** is the Kanban board, and always was — room-scoped
  todo lists were removed once the board covered that need
  (`docs/prds/0001-chatrooms.md` § Known issues, ADR 0002). The board's
  filtered view already shipped and is what the earlier `[x]` on 3.3 meant.
- **A run's own working plan** is the private per-run list
  (`src/agent/private_todos.zig`): `todo_add`/`todo_claim`/`todo_close`/
  `todo_list` with no `room`, in memory, capped at 100, discarded when the run
  returns. Nothing in the browser could see it. That is this slice.

Design constraint that shaped everything: ephemerality is the feature
(`docs/prds/0003-run-todos.md` § Non-goals), so the browser had to get a
*window* onto the list, not a store of its own. No endpoint, no polling, no
persistence — it rides the one long-lived channel that already exists.

- **Server:** `List.rev` counts real changes. A `todo_list` read does not bump
  it, and neither does re-claiming an item this run already holds or closing
  an already-closed one — a run that polls its own list would otherwise push an
  event per poll. `Agent.on_todos` (beside `on_tool_call`/`on_tool_result`)
  fires once per tool batch whose `rev` moved, at the seam right after
  `executeCalls` has joined its workers, so the deliberately unsynchronized
  list has exactly one reader. `private_todos.listJson` is the same
  `writeTodoArray` `todo_list` uses, so the model and the browser can never be
  shown different ids, titles or status spellings.
- **Transport:** `runStreamTodos` writes
  `\x01{"type":"todos","todos":[…]}` on the run's own `/api/run` stream. The
  array is spliced rather than re-encoded — `writeStreamEvent` would escape it
  into a string, and its 4 KiB stack buffer cannot hold 100 items of 512-char
  titles, so the line is built with `serve_gpa` instead. The whole list travels
  every time, not a delta: a client that missed an event is never out of step.
- **View:** `features/todos.js`, wired like every prior module (embed +
  `out_cap` guard in `webui.zig`, `assetFor` route, `index.html` module tag,
  `webui_asset_paths` entry, dedicated `render_todos_view`/`gzip_todos_view`
  whose predicate aliases nothing). A per-turn `state()`/`bind()` signal, not a
  module-level one — a finished turn must keep the checklist its run ended
  with, not the next run's. Rendered above the answer through `T`, so every
  title is a text node. Item state is a CSS box off `data-status` (`--ok-fill`
  filled + a drawn tick when closed, `--accent` tinted when claimed) plus the
  state in words beside it; no glyph stands in for an icon, and the panel is
  `aria-live="polite"`. Palette variables only, so all ten `data-theme` blocks
  get it for free.

### Two bugs found on the way, both fixed here

- **`features/arena.js` 404'd.** It was `@embedFile`'d and routed in
  `ui/app.zig`, but named in neither the `is_webui` module gate nor
  the `handleWebuiAsset` dispatch condition in `src/cli.zig` — two
  hand-maintained copies of one set, and the Arena view's dynamic `import()`
  fell through both. Found independently and fixed upstream in the same window
  (`644dc37`, "webui: serve features/arena.js from the native server"), which
  is itself the argument: two people hit the same trap in one day. This slice
  keeps the fix and removes the trap — both lists now read a single
  `webui_asset_paths`, and a test walks `ui/app/{core,lib,features}`
  and fails on any `.js` the list has never heard of, so the next module cannot
  repeat it.
- **Unescaped interpolation in the run `Export .html` path.** `drawRun`'s
  export builds a self-contained page by string concatenation and wrote
  `g.run_id` and `g.task` raw into `<title>`, `<h1>` and `<p>`. The task is
  operator- or agent-written text, and the file is then opened from a blob
  URL, so markup in a task became markup in the export. The `JSON.stringify`
  dump further down was already `<`-escaped, which is how the gap in the header
  stayed invisible. Every interpolated field now goes through
  `core/utils.js`'s `escapeHtml`.

### Verified

Live, with the configured DeepSeek provider (`providers check deepseek` ok,
610ms), a real top-level `clanker run` driving `todo_add` x3, `todo_claim`,
`todo_close`, `todo_list` through the real WASM tools. With `on_todos`
temporarily probed to stderr, the run emitted exactly three events — the
`todo_add` batch, the claim, the close — and **none** for the `todo_list` read,
with the untrusted title `<b>report</b> the count` arriving JSON-encoded and
intact. The probe was removed before commit.

Not verified live: the browser rendering itself. `clanker serve` dies at
`accept` (SIGSYS) in this environment, so nothing was clicked through and no
screenshot was taken. Covered by test instead — `runStreamTodos`' framing
(one line, `\x01`-prefixed, parses, markup survives as data), the asset route
(`isWebuiAssetPath` plus the source-tree walk), and the `webui` wasm tool
actually serving `features/todos.js` and `features/arena.js` with a JS content
type rather than falling through to the page. Suite `583 pass, 2 skip (585
total)`; 163/163 build steps.

## Export escaping, finished — the run `Export .html` path (2026-08-13)

Follow-up to "Two bugs found on the way, both fixed here" above. That entry
fixed the header fields (`<title>`, `<h1>`, `<p>`) and said every interpolated
field now goes through `core/utils.js`'s `escapeHtml`. One did not: the JSON
dump at the end of the document still carried its own
one-character escaper, a bare regex replace of `<` alone, written inline in
`drawRun`.

- **Why it survived a fix that was looking straight at it.** `<` is the only
  character that can open a tag, so escaping just `<` really does keep markup
  out of the `<pre>` — the dump was not an injection hole, and reading the line
  for injection finds nothing. It is a *fidelity* hole. With `&` left alone, a
  run whose text contained the literal characters `&lt;script&gt;` renders in
  the export as `<script>`, and `&amp;` renders as `&`: the file disagrees with
  the run it claims to be a copy of, in the direction of showing markup that
  was never there. Order matters too — `&` has to be replaced first, which a
  chain of replaces gets wrong and a single-pass escaper cannot.
- **The fix is deletion, not addition.** The dump goes through the same `esc`
  the header fields already use. There is now exactly one escaper on this path
  (`escapeHtml`, `[&<>"']` in one pass), which was the intent of the earlier
  entry; what was left was a second, partial one sitting beside it.
- **Guarded, because a comment is not a gate.** A source-tree test in
  `src/cli.zig` ("no webui source hand-rolls a partial HTML escape") walks
  `ui/app/{.,core,lib,features}` and fails on a `.replace(/</g`,
  `.replace(/&/g` or `.replace(/>/g` shaped call in code (comment lines are
  skipped, so the pattern can still be named where it is explained). It skips
  outside the repo root, like its `webui_asset_paths` neighbour. Two people
  have now written a partial escaper into this one function; the third attempt
  turns the suite red instead.

### Verified

Not in the browser: `clanker serve` still dies at `accept` (SIGSYS) here, so
nothing was clicked through. Covered by the source-tree gate above, and the
same escaping question was verified end to end on the native side, where it
*is* runnable: `clanker session export` (docs/ROADMAP.md, Done) renders a
transcript through a single-pass Zig escaper of the same five characters, and
a real export of a live DeepSeek session whose answer was
`<script>alert("x & y")</script>` was fed to a strict HTML parser — no
`script` element in the tree, the sequence present only as a text node.
Suite `608/610 tests passed (2 skipped)`; 169/169 build steps.

## Compare view — the blind side-by-side in the browser (2026-08-13)

The web UI half of `clanker compare`, listed as still open on the roadmap since
the feature shipped. The REPL `/compare` slash command is the other half and was
deliberately not in this slice: it is a `src/tui/*` change, and that surface was
being worked concurrently. (It has since landed in maci0/clanker#149, so the
comparison surface is complete: CLI, browser and REPL.)

The rendering was the easy part. What this slice is actually about is that the
`compare` tool's read paths were written for exactly one caller — a person who
had already watched the blind view that minted the id, which is what
`clanker compare --show <id>` is — and a browser is not that caller.

- **The payload has to be blind, not the render.** A page that receives a
  provider name and chooses not to paint it is one devtools panel away from
  being un-blinded, so "the view is careful" is not a mechanism. `"reveal":
  false` on a read or a listing now withholds the key from the tool's *reply*:
  no `provider`, no `model`, not for the answers, not for the verdict.
  `compare_logic.mayReveal` is the rule, on the host-tested side of the split
  with the rest of them, and a recorded pick overrides it — being told who you
  picked is the point of having picked blind.
- **The listing leaked worse than the read did.** `state/compare/log.jsonl`'s
  row carries the winning *provider*, and the blind view shows the verdict's
  *letter*; for a two-way comparison those two facts together are the whole key,
  and the listing is read before anything is even opened. An un-revealed listing
  now reports `"judged": true|false` and nothing else about the outcome.
- **A leak the tests caught, not the review.** The blind render printed
  `verdict: A (judged by deepseek)` and, on the next line, `caveat: the judge is
  also an entrant`. Between them that names an entrant. Unreachable from the CLI
  (a verdict makes `reveal` default to true, so the CLI never renders that line
  blind) and reachable from exactly the new path. The judge's name is now gated
  on `reveal`; the caveat, which carries no name, stays either way.
- **Two gaps in the structured output, filled:** `emit` returned neither the
  `prompt` nor the recorded `pick`, so a renderer had to scrape both back out of
  the rendered text block. A renderer that scrapes one field out of prose will
  eventually scrape another.

- **Server:** `GET /api/compare` (blind listing), `GET /api/compare/<id>` (blind
  read), `POST /api/compare/<id>` `{"pick":"<letter>"}` (record and reveal), all
  through `compareRouteToToolInput` — split out of the handler for the reason
  `arenaRouteToToolInput` was, since `clanker serve` cannot accept a connection
  here and a route decision reachable only through the listener is a route
  decision with no test. The pick reaches the same tool op the CLI's
  `--show <id> --pick <letter>` reaches; nothing about what a pick means is
  decided client-side. Read-only otherwise: starting a comparison is 2-8
  concurrent model calls against a server that answers one request per
  connection, the same reason the Arena view links to `clanker arena`.
- **View:** `features/compare.js`, wired like every prior module (embed +
  `out_cap` guard in `webui.zig`, `assetFor` route, `webui_asset_paths` entry,
  dedicated `render_compare_view`/`gzip_compare_view` whose predicate carries
  its directory and aliases nothing). Answers render as equal-width columns
  under nothing but their letter, deliberately identical to each other — any
  per-column decoration is a place to learn something before choosing. Model
  text reaches the DOM as text nodes, so there is no interpolation step to
  escape. Deep-links as `#compare/<id>`, adds a `/compare` composer command
  beside `/knowledge` and `/prompts`, and holds no timer, so the view has
  nothing to stop when it is navigated away from. Palette variables only.

### Verified

Live, with the configured DeepSeek provider (`providers check deepseek` ok,
1140ms): a real `clanker compare "In one sentence, why is the sky blue?" --with
deepseek@deepseek-v4-flash --with deepseek@deepseek-v4-pro`, two answers and a
judged verdict, then `--show <id>` and `--show <id> --pick B` against the same
document. The document that run produced is the fixture the two new
`sandbox.runtime` tests drive the real `compare.wasm` with, byte for byte —
a hand-written fixture would only prove the tool agrees with itself. Those
tests fail on any occurrence of `deepseek`, `deepseek-v4-flash` or
`deepseek-v4-pro` in an un-revealed reply, which is how the judge-line leak
above was found.

Not verified live: the browser rendering itself. `clanker serve` dies at
`accept` (SIGSYS) in this environment, so nothing was clicked through and no
screenshot was taken. Covered by test instead — the route mapping
(`compareRouteToToolInput`, including that both read paths ask for
`"reveal": false`), the asset route (`isWebuiAssetPath` plus the source-tree
walk), and the `webui` wasm tool actually serving `features/compare.js` with a
JS content type rather than falling through to the page. Suite
`613/615 tests passed (2 skipped)`; `169/169` build steps. (Two skips rather
than one: this ran in a worktree, where `.git` is a file.)

## Schedule view — the last subsystem with no browser surface (2026-08-13)

`clanker schedule` has had a store, a cron parser, a runner, a ledger and eight
subcommands since it landed, and nothing in the browser: the roadmap carried
"Not built: a WASM tool or web UI view over the schedule" as its only open item.
This is the view half.

**Routes.** `GET /api/schedule` returns every entry with a computed `next_run`,
plus the last 20 ledger records. `POST /api/schedule/<id>` with
`{"enabled":bool}` pauses or resumes one, through the same `schedule_store`
session `clanker schedule enable|disable` writes, so the two paths cannot drift.
Resuming re-dates `last_run` to now, matching `setEnabled` in
`src/schedule/command.zig`: an entry parked for a month must not come back owing
a run.

**Scope.** Read-and-toggle, which is the whole surface deliberately. Firing an
entry is an agent run and this server answers one request per connection, the
same reason the Arena and Compare views link out rather than starting a match.
Adding is not here either: `add` has to reject a spec that never fires and say
which of the spec and the task was wrong, and a form that quietly accepted a
spec matching nothing would be worse than no form.

**Two things the view had to get right rather than inherit:**

- **Times render at each entry's own fixed UTC offset**, not the browser's
  locale. The offsets are fixed and never DST-aware (ADR 0009), so a row that
  says 09:00 has to mean the 09:00 the cron field names; localising it would
  quietly move it twice a year.
- **`next_run` is absent, not zero, when an entry can never fire.** Disabled and
  "the spec parses to nothing" are both "never", and only one of them is
  something the user chose, so the page separates them: `paused` against
  `never: check the cron spec`. Folding them together would hide a typo behind
  a state that looks intentional.

The empty ledger says what an empty ledger nearly always means: nothing is
calling `run-due`.

### Verified

`clanker serve` still cannot run in this environment (it logs `serve listening`
and the process dies at `accept`), so there is no browser or curl check here and
none is claimed. What was run:

- **Zig unit test** over `scheduleNextRun` + `writeScheduleEntry`: the next fire
  of an every-minute entry, `null` for both disabled and an unparseable spec,
  and the serialized entry carrying `next_run` in the first case and omitting
  the field in the second.
- **The real view module under node**, against canned `/api/schedule` payloads
  and a minimal DOM: 19 checks covering the ids `index.html` actually defines,
  an active entry's next fire at a non-UTC offset, `paused` vs the bad-spec
  wording, Pause/Resume per state, the entry count, a rendered ledger row, both
  empty states, and a 500 surfacing the server's reason instead of drawing
  "nothing scheduled".
- **The CLI end of the same store**: `schedule add` x2, `schedule disable`,
  `schedule list`, confirming the on-disk shape the route reads.

## Search view — finding a conversation by what was said in it (2026-08-13)

The sidebar's filter box matches conversation *titles*, and a title is mostly
the first line of the first task, so until now a conversation was findable by
how it started and by nothing else. `core/search.js` only ever highlighted
matches inside the transcript already on screen. Nothing read the archive.

**Route.** `GET /api/sessions/search?q=` walks `state/sessions` exactly the way
`listSessions` does — same directory, same open, so a `state/` that is a
symlink into the checkout (which it now can be, after #165) resolves
identically for both — and returns one row per conversation: id, title,
updated, archived, the index and role of the first matching message, a snippet
around the match, and `more`, the number of further matches in that same
conversation.

**Decisions worth keeping:**

- **Substring, not fuzzy.** The rail filter is fuzzy over titles and that is
  right for a short string. Fuzzy over whole transcripts matches nearly every
  conversation, and a search that always answers "all of them" answers
  nothing.
- **One row per conversation, with a count.** Ten hits in one conversation is
  one result that says ten, not ten results that bury every other
  conversation.
- **A 3-character floor, answered as `ok` with an empty list.** One or two
  characters match everything and cost a full read of every session to prove
  it. An empty search box is the normal state of a search view, so that is a
  prompt in the page, not an error.
- **Snippets are built server-side and stripped there.** Newlines and tabs
  collapse to spaces and control bytes are dropped, so a hit is one line of
  safe text however the message was written — the same treatment
  `transcript.zig` gives untrusted model output.
- **Opening a hit goes through `switchSession`.** It refuses mid-run and puts
  the rail back; the search view has no business reimplementing that.
- **The turn number is shown but not jumped to.** The transcript renders from
  the top and there is no per-turn anchor to scroll to, so saying where the
  match is beats pretending to navigate there. That anchor is the obvious next
  slice. *(Built — see "Search hits land on the turn that matched" below.)*

### Verified

`clanker serve` still cannot run here (it logs `serve listening` and the
process is gone by the first connection), so there is no browser check and
none is claimed.

- **Zig unit tests**, three of them: `findFold` (case folding, an empty needle
  and an over-long needle finding nothing rather than everything),
  `snippetAround` (no ellipsis when nothing was cut, one at each end when it
  was, radius-bounded, newlines flattened and control bytes dropped), and
  `searchSessions` against a real `tmpDir` store — two saved conversations,
  one row for the one holding the word twice with `more: 1`, both rows newest
  first for a word in each, an empty list for no match and for an empty store,
  and the cap applied after the sort so it keeps the newest.
- **The real store format**, from a live DeepSeek run: a conversation written
  by `clanker run` was found by a phrase from the model's own answer, at the
  right turn and role, with the snippet cut at a word boundary. That is the
  check the tmpDir test cannot make, since it writes the file itself.
- **The view module under node**, 21 checks: the ids `index.html` defines,
  titles/snippets/turn/role/`more`/archived rendering, the `<mark>` landing on
  the query inside the snippet, a click reaching `openSession`, the short-query
  prompt not touching the server, the no-match and truncated wordings, and a
  500 surfacing the server's reason.

One bug the harness caught before it shipped: the failure path set `hits = []`
and re-rendered, which drew "No conversation says …" over a server error — the
same misleading empty state PR #153 had just removed from four other views.
The view now carries an explicit error state.

## Create forms answer Enter — Knowledge and Prompts (2026-08-13)

Two of the page's eight `<form>`s had no submit handler and no
`type="submit"` button: `#knowledge-create-form` and `#prompts-create-form`
both hung their Create on the button's `click`. What Enter did in each was
decided by an HTML rule neither form was written against — implicit submission
is suppressed when a form holds more than one field that blocks it — so the
two behaved differently, and both wrongly:

- **Prompts** has one blocking field (`#prompts-title`; a `<textarea>` does not
  block). Enter in the title submitted a handler-less, action-less form, so the
  browser navigated to the page's own URL: the whole app reloaded and the
  half-typed prompt went with it.
- **Knowledge** has two (`#knowledge-title`, `#knowledge-desc`), which
  suppressed submission entirely. Enter did nothing at all — a dead key in the
  one place on the page where every other form sends.

Both now bind `submit` and `preventDefault()`, and both Create buttons are
`type="submit"`, so the click path and the Enter path are one path. The
button-disabled guards moved inside the handler (`if (createBtn)`), since the
handler no longer proves the button exists.

### Verified

`node` + a DOM stub driving the real ES modules (no browser, no server):
`bindPrompts()` / `bindKnowledge()` bind exactly one `submit` listener each,
the listener calls `preventDefault`, one `POST` reaches `/api/prompts` and
`/api/knowledge` respectively, and neither Create button carries a second
`click` listener that would double-send. The same harness run against `main`
fails 10 of its 12 assertions, so it is testing the fix and not the harness.
Gate: `zig build`, `zig build tools`, `zig build test --summary all` —
163/163 steps, 763/765 tests (2 skipped, the expected worktree pair).

## The digit shortcut says what it does (2026-08-13)

Three places describe "a digit jumps to a view" and all three knew a different
number:

- `core/dialog.js`'s shortcut table — the `?` overlay, the page's own answer to
  "what are the keys?" — still said **1 – 8**, from when there were eight views.
- `core/palette.js` numbered **every** view, so Ctrl/⌘+K listed
  `Schedule (10)` … `System (14)`. There is no "10" keystroke; those five were
  advertising a key that does nothing, on the surface whose job is to teach
  the keys.
- Only `app.js`'s handler was right, and only by accident: `n <= VIEWS.length`
  reads as "all fourteen", and it stops at nine because `parseInt(e.key)` on a
  single keypress cannot be more.

There are fourteen views and nine usable digits, so a fifth of the tablist was
never going to have one; the tenth view onward is reached by the palette or by
the tablist arrows, both of which already work. The fix is to stop claiming
otherwise: `view_digit_max` in `core/utils.js` is the one number, the help
table builds its row from it, the palette prints the `(n)` only below it, and
the handler bounds on `Math.min(view_digit_max, VIEWS.length)` so the intent is
in the code rather than in an arithmetic coincidence.

### Verified

`node` reads all three surfaces and checks they agree: it evaluates the
handler's guard expression over 1–20, keeping only lone digits, and asserts the
help table's printed range and `view_digit_max` both equal the resulting count
(9 of 14), and that the palette's label is gated rather than unconditional.
Against `main` five of the nine assertions fail. Gate: `zig build`,
`zig build tools`, `zig build test --summary all` — 163/163 steps,
763/765 tests (2 skipped, the expected worktree pair).

## A failed schedule toggle no longer disables its own switch (2026-08-13)

`setEnabled` disables the row's Pause/Resume for the duration of the POST
(`toggle.disabled = state.busy === e.id`), then cleared `state.busy` and
redrew **only on success** — `if (out) render()`. On the failure path the flag
was cleared but nothing redrew, so the button kept the `disabled` it was given
before the request. A server that refused once left a switch that could not be
tried again for the rest of the visit: the only way back was to leave the view
and return, and nothing on screen said so.

The redraw is now unconditional. The reason it was not is that `render()` ends
by writing the entry count to `#schedule-status`, which would have overwritten
the message the `catch` had just put there — so the failure moved into
`state.error`, and `render()` reports that instead of the count while it is
set. `loadScheduleView` clears it, which makes Refresh the way to dismiss a
stale failure. Same shape the Search view already uses for the same reason.

### Verified

`node` + a DOM stub driving the real `features/schedule.js`, with `fetch`
stubbed to fail the POST and succeed the reload. After a failed toggle the row
redraws, its button is enabled again, the failure is still on the status line
(not replaced by the count), and a second click reaches the server. The stub
refuses to fire `click` on a disabled element, as a browser does, so the retry
assertion is real. Against `main` the same harness fails both: the button
stays disabled and the retry never leaves the page. Gate: `zig build`,
`zig build tools`, `zig build test --summary all` — 163/163 steps,
763/765 tests (2 skipped, the expected worktree pair).

## Search hits land on the turn that matched (2026-08-13)

The Search view shipped with the jump deliberately unwired, and said so: the
transcript renders from the top and there was no per-turn anchor to scroll to,
so a hit showed the turn number without following it. That is the right call
for a view that would otherwise pretend to navigate — but it left the feature
half-done. Finding the conversation is the easy half; on a forty-turn
transcript, opening at the top is close to not going there at all.

The anchor exists now. `/api/sessions/search` already returns `turn` as an
index into the same `messages` array `/api/sessions/<id>` returns, so the two
were always talking about the same array — nothing on the server changes.

- **`core/search.js: turnForMessage(spans, index)`** — pure, the whole mapping.
  A turn is a question plus everything answered before the next question, so it
  covers a *run* of message indices, not one. Total by construction: an index
  past the end (a conversation that grew since the search) resolves to the last
  turn rather than to nothing, because roughly the right place beats not
  moving; `-1` only when there are no turns.
- **`app.js: renderSessionHistory`** — records `{ from, to }` per rendered turn
  into `replayedSpans` as it replays, including the orphan-answer branch. The
  one place that knows how messages map onto turn cards.
- **`app.js: jumpToMessage(index, query)`** — resolves the span, scrolls the
  card to centre, marks the query inside it with the transcript's own
  find-in-page highlighter (so a hit found from Search looks exactly like one
  found with `/`, and the next `/` clears it), and flags the card
  `data-found` for two seconds.
- **`switchSession(id, jump)`** — the target is passed in rather than read back
  later, because the scroll can only happen once the fetch resolves and the
  caller is gone by then. It also fires when the hit is in the conversation
  already open: that is the case where scrolling helps most, and the early
  `id === sessionId` return used to make it a dead link.
- **`app.css`** — `.turn[data-found="true"]` gets the accent strip the live
  turn uses, held rather than pulsing, over a wash that fades out. The wash is
  decoration and is off under `prefers-reduced-motion`; the mark inside the
  turn is what actually says where the match is, and that is never animated.

The row's `aria-label` now names the turn it will open at, so the destination
is announced before the click rather than discovered after it.

### Verified

`node` + a DOM stub driving the real modules. `turnForMessage` over a
two-turn transcript where the second turn spans three messages: question,
answer, a later message in the same turn, past-the-end, negative, empty, and
null all resolve as documented. Driving the real `features/search.js`: a
rendered hit's click reaches `openSession` carrying `{ index: 7, query:
"needle" }` — the server's index, and the query that matched rather than
whatever is in the box by the time the transcript loads. The `app.js` and
`app.css` halves are checked as source shape, since importing `app.js` boots
the page. Against `main` the same harness fails 14 of its 23 assertions.
Gate: `zig build`, `zig build tools`, `zig build test --summary all` —
163/163 steps, 763/765 tests (2 skipped, the expected worktree pair).

## The run graph knew which iteration only half of it belonged to (2026-08-13)

Two defects in `lib/graph.js`, both of them the graph disagreeing with itself
about what it had drawn.

**A tool call had no iteration.** `toDagInput` stamped `iteration` on the llm
entry that opened a stage and on nothing else, so the tool calls made inside
that iteration, and the final answer that closed the last one, went into the
layout without it. `layoutGraph` then wrote `String(dn.data.iteration)` onto
every node as `data-iter` — which for those is the five characters
`undefined`. The iteration scrubber reads it back with `parseInt`, bails on
`NaN`, and so dimmed only the model calls: dragging it to iteration 1 of a
four-iteration run left every tool call and the answer at full opacity, which
is the opposite of what the control is for. The same attribute is what a click
uses to mark the matching breadcrumb chip `aria-current`, so clicking a tool
node cleared the crumb instead of moving it. Fixed where it originates: the
stage's iteration goes onto its tools, and the last stage's onto the answer.

**The arrowhead was counted as an edge.** The `<marker>` that draws the arrow
head is a `<path>`, and it lives inside the `<defs>` of the same
`svg.run-edges`. `highlightPath` walked `dag.ilinks()` against
`canvas.querySelectorAll(".run-edges path")` by index, and that answer begins
with the marker — so edge *n* was painted onto edge *n-1*, and the last edge in
the graph could never highlight at all. On a fan-out/fan-in graph the effect is
that hovering a node lights up a neighbouring branch. The drawn edges are now
kept in a list in creation order and highlighted through it, and each carries
`data-edge` so anything else that wants the real edges can ask for them by
name. `app.js`'s minimap was the other victim of the same query: it parsed the
marker's `M0,0 L8,4` as an edge and drew a stray hairline in the corner of
every map. It now asks for `path[data-edge]`.

### Verified

`node` + the DOM stub driving the real `lib/graph.js`, with `core/vendor.js`
swapped for a stub whose `loadD3` installs a fake `dagStratify`/`sugiyama` —
so `layoutGraph` really runs, really builds the svg, and the hover listener is
really dispatched. 19 assertions: the iteration each of the five nodes ends up
with, `data-iter` never being the string `undefined`, the five edges of a
two-stage run with two parallel tools, all five of them marked on hover, the
marker path never marked, the highlight clearing on `mouseleave`, and a second
`layoutGraph` replacing the first render rather than stacking on it. Against
unmodified `main` the same harness fails 6 of the 19. The `app.js` minimap line
is one selector and is checked as source shape, since importing `app.js` boots
the page. Gate: `zig build`, `zig build tools`, `zig build test --summary all`
— 163/163 steps, 765/767 tests (2 skipped, the expected worktree pair).

## A table under a sentence is a table (2026-08-13)

`renderMarkdown` had two ideas about what opens a block. The dispatcher at the
top of the loop knew about headings, thematic breaks, blockquotes, lists and
tables. The paragraph accumulator underneath it knew about headings,
blockquotes and lists — and nothing about breaks or tables. Whichever ran
first won, and for a table written directly under the line that introduces it
the accumulator ran first:

```
Here are the results:
| name | count |
| --- | --- |
| a | 1 |
```

That whole block rendered as one paragraph of literal `|` characters — exactly
the "wall of monospace" the markdown renderer exists to prevent — because the
paragraph swallowed the header row before the dispatcher could look at it. A
`---` rule under a line of prose went the same way, appearing as three hyphens
mid-sentence. Both shapes are what a model writes: prose introducing a table,
no blank line between.

- **`lib/markdown.js: ruleAt(line)`, `tableAt(lines, i)`, `blockAt(lines, i)`**
  — the question is asked once now, and both the dispatcher and the paragraph
  accumulator ask it, so they cannot drift apart again. `tableAt` needs the
  header *and* the `|---|---|` under it, because a line with pipes in it is
  otherwise just prose: `a | b is not a table` still renders as the sentence it
  is.
- The dispatcher's own inline copies of the rule and table tests are replaced by
  calls to the same predicates, so there is one definition of each.

`blockAt` is exactly the disjunction of the dispatcher's own tests, which is
what keeps the paragraph loop from stalling: a line the accumulator refuses is
by construction a line the dispatcher consumes.

### Verified

`node` + a DOM stub driving the real `lib/markdown.js` and asserting on the
rendered node tree. A table under a sentence renders `p` + `.md-table-wrap`
with two `th` and two `tbody tr`, and the paragraph above it holds no `|` at
all; `before\n---\nafter` renders `p`,`hr`,`p`. Alongside them, the shapes
that already worked are pinned so this cannot be a trade: a standalone table, a
table after a blank line, heading/list/quote breaks, a nested list, a plain
three-line paragraph with its two `<br>`, `- - -` as a rule, and inline
`*emphasis*` not opening a block. 30 assertions green; the same harness
against unmodified `main` fails 12 of its 24.
Gate: `zig build`, `zig build tools`, `zig build test --summary all`.

## The Models view stops forgetting which provider you picked (2026-08-13)

`#models-live-provider` is the provider the "List models" button asks. It is
filled by `loadConfigured()`, which starts by emptying it — and
`loadModelsView()` runs on **every** entry to the Models view as well as behind
Refresh. Emptying a `<select>` throws its selection away, and refilling it
leaves whichever option lands first selected (the HTML "ask for a reset"
algorithm), so the choice was silently replaced by the alphabetically-first
provider every single time. Nothing on screen said so, the table from the
provider you *had* chosen was still sitting under the control, and the next
click asked a different backend and drew its models in the same place.

`restoreProvider(sel, wanted)` reads the value before the refill and puts it
back after. The case that needs care is a provider removed from `config.toml`
since: assigning a value no option carries leaves `selectedIndex` at `-1` and
the control **blank**, not fallen back — so that is detected and stepped to the
first option deliberately, and the live listing still on screen is dropped,
because it belongs to a provider the select no longer names and leaving it
there reads as the new selection's models.

### Verified

`node` + a DOM stub driving the real `features/models.js` — bind, load, choose
`openai`, list its models, then reload the view twice. The stub models the two
`<select>` behaviours the bug rides on: refilling an emptied select selects the
first option, and assigning an unknown value gives `selectedIndex -1` with an
empty `value` rather than a silent fallback. Faking either would have made the
test test itself. 12 assertions: the chosen provider survives Refresh, a second
"List models" still reaches `name=openai`, and a provider dropped from config
falls back to the first while its stale table is cleared. Against `main` the
same harness fails 3 of the 12 — the selection resets, the follow-up request
goes to `deepseek`, and the dead listing stays. Gate: `zig build`,
`zig build tools`, `zig build test --summary all` — 163/163 steps, 765/767
tests (2 skipped, the expected worktree pair).

## The Knowledge "Linked folder" row no longer outlives its collection (2026-08-13)

`#knowledge-sync-row` is the folder a collection mirrors, and in `index.html` it
is a **sibling** of `#knowledge-detail`, not a child of it — it sits above
`#knowledge-list` while the detail sits below. `openCollection` revealed both;
everything that put the detail away only ever set `detail.hidden = true`. So:

- **Close** left "Linked folder" on screen, filled with the path of a
  collection that was no longer open, with nothing naming which collection it
  now belonged to. `syncOpenId` still pointed at it, so "Sync changes" mirrored
  a folder into a collection the reader had closed and moved on from.
- **Delete the open collection** was worse. The detail was hidden, the row was
  not, and `syncOpenId` still held the id the server had just deleted. Clicking
  "Sync changes" POSTed to `/api/knowledge/<deleted-id>/sync` and reported the
  404 on the status line as `Sync failed: …`, which reads as a bad path.

`closeCollection()` is now the one way the detail is put away: it hides the
detail, hides the row, and clears `syncOpenId` — the id is what the request
sends, so it must not outlive the collection either. `showSyncRow` sets
`syncOpenId` *before* its DOM guard rather than after, because it is "which
collection is open" and making it conditional on the row's markup would let a
delete miss the close.

Deleting a **different** collection now leaves the open one alone. The old code
hid the detail on any successful delete, so tidying up an unrelated collection
shut the panel you were reading; the close is conditional on the deleted id
being the open one.

### Verified

`node` + a DOM stub driving the real `features/knowledge.js`, with a fetch
router for the collection list, the detail, DELETE and the sync POST. 16
assertions over the real controls: Open reveals both, Close hides both, delete
of the open collection closes both, and — the decisive one — "Sync changes"
after that delete issues no request at all, where before it reached the dead
id. The stub queues `dialog.close()` as a task rather than firing it inline,
which is what a browser does and what `core/ui.js`'s `uiConfirm` depends on;
firing it synchronously turns every confirmed dialog into a dismissed one and
would have made the delete path untestable. Against unmodified `main` the same
harness fails 4 of the 16. Gate: `zig build`, `zig build tools`,
`zig build test --summary all` — 163/163 steps, 765/767 tests (2 skipped, the
expected worktree pair).

## The board's lane menu did nothing, loudly and quietly (2026-08-13)

Four defects behind the column head's `⋯` menu and the card it sorts.

**All three sorts were no-ops.** Each one sorted a copy of the lane's cards and
then re-appended them by asking the list for `[data-id='<id>']`. A card carries
`data-card`; nothing in this codebase has ever set `data-id`. Every lookup
returned `null`, every sort returned to a lane in exactly the order it started
in. The three near-identical handlers are now one `reorderLane(cmp)` and three
comparators, and the node it moves is the card's `<li>` rather than the card
itself: the card is a button *inside* a list item, so appending the button
would have pulled it out of its item and left an empty one behind even once the
attribute was right.

**Sort by priority put high cards with the normal ones.** `{high:0, normal:1,
low:2}[p] || 1` — `high` is rank 0, which is falsy, so it read as 1. The list
view has its own copy of the same expression and the same bug, which is why the
lookup now lives in `lib/board.js` as `priorityRank(card)` with both callers
importing it: one place to be right, and a pure function to test.

**Move all cards threw.** The handler posts one move per card and then called
`toast(...)`. `features/board.js` has its own `boardToast` and never imported
the app-level `toast`, so the last line of the handler raised
`ReferenceError: toast is not defined` on every use. The moves had already been
sent, so the visible symptom was a lane that emptied with no confirmation and
an error in the console.

**No card ever showed its notes.** The mini-card's description preview was
guarded on `c.notes`. The field is `body` — what the detail panel edits, what
the filter searches, what the create payload sends, what the board tool
serialises. The preview now reads `body`, through `clip()` so a cut line ends
in an ellipsis instead of mid-word.

### Verified

`node` + the DOM stub driving the real `features/board.js`: `bindBoard` against
a stub `el`, a three-card board rendered through the module's own reactive
render, then the `⋯` menu opened and its items clicked the way a pointer would.
23 assertions covering the rendered preview text, each of the three sorts
landing in its own distinct order, the lane still holding only `<li>` children
afterwards, `Move all cards → Doing` posting one `move` per card *without*
throwing, and the list view's Sort by priority putting the high card first.
Against unmodified `main` the same harness fails 6 of them — including
`ReferenceError: toast is not defined`, caught out of the click. Gate:
`zig build`, `zig build tools`, `zig build test --summary all` — 163/163 steps,
765/767 tests (2 skipped, the expected worktree pair).

## A message without an id took the room down with it (2026-08-13)

`chatrooms.zig` does not promise an id. `Message.id` defaults to `""`, the
field's absence is documented ("a peer too old to send one"), and `receive`
deliberately accepts such a message rather than dropping it — there is even a
test for it. The rooms view took the id on faith anyway, in three places, and
each one failed differently.

- **`var threadKey = m.id || msgKey;`** — `msgKey` is not declared anywhere in
  `app.js`, or anywhere else in the tree. Reading it under the module's
  `"use strict"` throws `ReferenceError`, so the first id-less message aborted
  `buildChatMessage` mid-render. The throw unwound through `pollChat`'s
  `forEach` into its `.catch`, which reported it as a failed fetch —
  "Could not load messages: msgKey is not defined" — and widened the poll
  backoff. Worse, `chatLastTs` and the seen-set are advanced *before* the
  message is built, so every message after it in that batch was neither drawn
  nor ever asked for again.
- **The seen-set keyed on `m.id`.** `chatSeen[""]` is set by the first id-less
  message, so from then on every id-less message was filtered out as a
  redelivery of it. Within a single batch this happens to work (the `filter`
  runs before the `forEach` that records ids), which is why it survived: the
  loss only shows up across polls.
- **The room actions sent `msg_id: ""`.** Pin, edit, delete and react all
  match on the id server-side, and `""` matches whichever id-less message the
  log holds first — so acting on one message could act on a different one.

- **`core/chat.js: messageKey(m)`** — pure, and one definition of a message's
  identity for the page's own bookkeeping. A real id is used as-is; an id-less
  message falls back to `local:<sender>:<ts>:<djb2 of the text>`, which
  distinguishes the messages that need distinguishing and collides only where
  sender, second and text are all the same — a message there is no way to tell
  apart anyway. The `local:` prefix means a fallback key can never be mistaken
  for a server id.
- **`core/chat.js: hasServerId(m)`** — asked by `buildChatMessage` before it
  builds anything that names the message to the server. React, pin, edit and
  delete are left out for an id-less message rather than pointed at the wrong
  one. Copy is client-side and stays.
- **`app.js`** — the seen-set, `rememberChatId` and the thread key all go
  through `messageKey`. `msgKey` no longer appears in the tree.

### Verified

`node` driving the real `core/chat.js`: a real id passes through untouched; an
id-less message gets a stable non-empty key that changes with the text, the
sender and the timestamp; `null`, `undefined` and `{}` are total. The seen-set
is then driven the way `pollChat` drives it — three distinct id-less messages
in one batch all survive, a redelivered one is still deduped, and an id-less
message arriving in a *second* batch survives, which is the case `m.id` lost.
The `app.js` half is checked as source shape (the wiring, and that `msgKey` is
gone from the file), since importing `app.js` boots the page. 31 assertions
green; against unmodified `main` the same harness fails 20 of its 31.
Gate: `zig build`, `zig build tools`, `zig build test --summary all`.

## One dropped poll no longer ends the arena watch (2026-08-13)

The Arena view follows a running match by polling `/api/arena/<id>` every
1.1 s, and `fetchMatch`'s `catch` called `stopPolling()`. Every failure was
therefore terminal: one reset connection, one moment where the server was busy
answering something else, and the timer was gone for good. What is left on
screen is the worst version of that. The stage keeps its last frame, the HP
chips keep their last numbers, the transcript keeps the round it had, and the
one thing that would have told you it is no longer live, the status line, has
been overwritten with `Could not load match: …`. Nothing is asking any more,
and nothing says so. This server answers one request per connection, so a poll
colliding with another client is ordinary rather than exceptional.

Consecutive failures are now counted, five in a row give up, and any answer
resets the count. Below the threshold the last known state stays on screen and
the status line is left alone, so a hiccup is invisible, which is what it
should be. At the threshold it stops and says `Lost track of match <id> after 5
failed updates (…). Refresh to pick it up again.` — the state a frozen view was
already in, said out loud. Opening a match by hand still fails loudly on the
first try, because that failure is the answer to something you just asked for.

The picker had a smaller version of the same disagreement: the lamp decided
"running" from `!winner && !headline`, while the words beside it decided from
`winner` alone. A match that ended with nobody named, a mutual concession, was
drawn with a "done" lamp and labelled `running`. Both now read the same test,
and that case reads `no verdict` — the vocabulary the Compare list already uses
for it.

### Verified

`node` + the DOM stub driving the real `features/arena.js`, with
`window.setInterval` handing back a token the test ticks by hand, so a poll is a
poll and the test can then ask whether the timer is still there. 14 assertions:
opening a running match starts exactly one timer, the status line describes the
last move, a single failed poll leaves the timer alive and does *not* replace
the live status with an error, the next poll recovers, a match that reaches a
verdict still stops the timer and reaches both the status line and the
transcript, twelve failures in a row stop it once and say so, and the picker row
for a headline-without-winner match is neither lit nor labelled as running.
Against unmodified `main` the same harness fails 6 of the 14: the timer is gone
after the first failure, and everything downstream of still-watching goes with
it. Gate: `zig build`, `zig build tools`, `zig build test --summary all` —
163/163 steps, 765/767 tests (2 skipped, the expected worktree pair).


## The Prompts filter survives a re-render (2026-08-13)

`#prompts-filter` hid non-matching cards from its own `input` handler, walking
the cards that happened to exist at that moment. Nothing else knew the filter
was there — so every re-render silently dropped it. `renderPrompts` starts with
`listEl.textContent = ""` and rebuilds, and Refresh, Create and Delete all
reload the list, which means:

- typing a filter and pressing Refresh brought every prompt back while the
  filter box still read `review`;
- saving a new prompt did the same, so the one moment you most want the list
  narrowed is the moment it widened;
- `#prompts-status` reported the full count either way, contradicting a list
  that was showing one card.

The filter is now part of what "render" means. `applyPromptFilter()` decides
which cards are on screen, owns the status line, and runs at the end of every
render as well as on input — so the box and the list cannot disagree, and
`loadPromptsView` no longer writes its own count over the top of it.

A filter matching nothing used to leave a blank panel with no explanation:
`#prompts-status` is `.sr-only`, so "0 of 4" was announced to a screen reader
and to nobody else. There is now a visible note where the cards were, naming
the query. It lives inside `#prompts-list` and is therefore thrown away by the
next render's `textContent = ""`, which is why it is looked up by id rather
than held in a variable.

### Verified

`node` + a DOM stub driving the real `features/prompts.js`: bind, load three
prompts, filter to one, then Refresh, then create a fourth through the form's
own `submit` — 17 assertions on card visibility, the status text and the
no-match note. Against unmodified `main` the same harness fails 6 of the 17:
the list unfilters on Refresh and again on create, the count ignores the filter,
and the no-match case draws nothing at all. Gate: `zig build`,
`zig build tools`, `zig build test --summary all` — 163/163 steps, 765/767
tests (2 skipped, the expected worktree pair).

## One popup, three lists, one index (2026-08-13)

The composer's suggestion popup (`#prompt-list`) is shared by three different
lists: saved prompts, `/` commands, and the `#` knowledge-collection mentions.
Each keeps its own highlight — `promptIndex` for the first two, `kbMentionIndex`
for mentions — but the keydown handler only ever knew about `promptIndex` and
the prompt list. Every key pressed while the mention list was open was
dispatched against the wrong one.

- **An arrow key dismissed the mentions.** ↓ nudged `promptIndex` and called
  `renderPromptList()`, and `renderPromptList` hides the popup outright when the
  composer's value does not start with `/`. So the first arrow press closed the
  list it was meant to walk; the mentions could only be picked with the mouse,
  or with Enter, which —
- **— always took the first row.** The Enter branch reached for
  `el.promptList.querySelector(".palette-item")`, the first item in the DOM,
  ignoring `kbMentionIndex` entirely. `kbMentionIndex` was written by the
  renderer and read by nobody.
- **Delete forgot a prompt you had not asked it to.** The Delete branch was
  guarded on `!isSlash` only, so it fired for mentions too. It read the row's
  label — `"3 docs"` — as the text of a saved prompt and ran
  `prompts.splice(prompts.indexOf(doomed), 1)`. `indexOf` is `-1`, and
  `splice(-1, 1)` removes the **last** element: pressing Delete over a knowledge
  collection silently deleted your most recently saved prompt and wrote that to
  `localStorage`, under the status line "Forgot that prompt."
- **A stale index could be past the end.** With six saved prompts and a mention
  list of two, `promptIndex` was still 5 and `items[5]` is `undefined` — Enter or
  Delete then threw on `.querySelector` of undefined.

- **`core/composer.js: forgetPrompt(prompts, text)`** — removes by exact text
  and says whether it removed anything. The `-1` case is the whole point.
- **`core/composer.js: setActiveItem(listEl, index, taskEl)`** — moves the
  highlight and `aria-activedescendant` inside a list that is already on screen,
  and clamps an out-of-range index to the first row. The mention list is built
  from a `/api/knowledge` fetch, so re-rendering it to move a highlight would be
  one request per arrow key.
- **`app.js`** — the handler now names which list is on screen (`kb`, `slash` or
  `prompt`), reads that list's own index, clamps it against what is actually
  rendered, and routes every key accordingly. Delete is offered for saved
  prompts only. `hidePromptList` clears the mention flag, since it is the one
  place that means "no suggestion list is open".

### Verified

`node` driving the real `core/composer.js`. `forgetPrompt` over a three-prompt
list: the named prompt goes, a text that was never saved removes nothing and in
particular leaves the *last* prompt alone, and an empty list is total.
`setActiveItem` over a rendered list of `.palette-item` rows: exactly one row
carries `aria-selected="true"`, `aria-activedescendant` names it, the rows are
not rebuilt, an index of 5 against two rows falls back to the first, and an
empty list reports `-1` rather than throwing. The keydown handler is checked as
source shape — including that no bare `prompts.splice(prompts.indexOf(...))` is
left in the file — since importing `app.js` boots the page. 32 assertions
green; against unmodified `main` the same harness fails 25 of its 32.

## The composer keeps what you were writing (2026-08-13)

A half-written task had no owner. Reloading the page threw it away, and so did
opening another conversation — which is precisely what you do when the question
needs something you have to go and look up first. The composer text was the one
thing on the page with nowhere to live: the transcript is on the server, and the
model, theme, view, rail state and selected knowledge collections are all in
`localStorage`. The sentence you were in the middle of was not.

A draft now belongs to the conversation it was written for.

- **`core/composer.js: loadDrafts()`, `saveDrafts(drafts)`,
  `draftFor(drafts, sessionId)`, `setDraft(drafts, sessionId, text, now)`** —
  pure but for the one `localStorage` read and write, and the whole shape of the
  store. One key (`clanker.drafts`), not one per conversation: a profile that
  has seen a thousand conversations should not carry a thousand entries, so
  `setDraft` bounds the store to the `max_drafts` (20) most recently touched and
  drops the rest by age. Whitespace is not a draft — an empty or blank composer
  deletes the entry rather than storing it, so restoring can never replace a
  cleared box with blanks. Storage that is unparseable, an array, `null`, or an
  entry of the wrong shape all read as "no draft" rather than throwing.
- **`app.js`** — `rememberDraft` on `input`, debounced 400 ms because
  `localStorage` is synchronous and this is every keystroke; `flushDraft` on
  `beforeunload` so a closed tab is not a special case. `switchSession` flushes
  *before* the id moves — otherwise the text would be filed against the
  conversation being opened — and restores after the transcript lands, or after
  a failed load, where an empty composer would otherwise read as the draft
  having been lost. New chat banks the draft against the conversation it leaves
  and opens with an empty box. Boot restores.
- **When a draft stops existing** — a run that finishes drops it: it was asked
  and answered. A run that *doesn't* finish deliberately does not; the existing
  "the run ended before it finished; your task is still in the composer" branch
  leaves the task in the box, and that is exactly a draft worth keeping.
  Deleting a conversation drops its draft, since there is nothing left for it to
  belong to.
- **Restore never overwrites.** It fills an empty composer only. Dropping a
  saved draft on top of a sentence someone is writing is the same loss in the
  other direction.

### Verified

`node` driving the real `core/composer.js` against the DOM stub's
`localStorage`. A draft written for one conversation comes back from a fresh
read of storage (a reload); two conversations keep their own and a third gets
nothing; an empty text and a whitespace-only text both clear the entry rather
than storing it. The bound: `max_drafts + 5` conversations leave exactly
`max_drafts` entries, the oldest is the one dropped, the newest is kept, and
touching an old draft stops it being evicted for its age. Storage that is
unparseable, an array, `null`, an entry with no `text` and an entry that is a
bare string all read as no draft. The `app.js` wiring is checked as source shape
— the debounce, the `beforeunload` flush, flush-before-id-moves, restore after
load and after a failed load, the New chat and delete paths, and that restore
returns early when the box is not empty — since importing `app.js` boots the
page. 37 assertions green; against unmodified `main` the same harness fails 20
of its 33.
Gate: `zig build`, `zig build tools`, `zig build test --summary all`.

## The run graph points at the bottleneck (2026-08-13)

A run graph already showed every step's duration, twice: a badge on the card and
a bar scaled against the slowest node. Neither says which step *was* the slowest
one, so finding it meant reading fifteen badges and comparing them by eye, and
the bar is no help at all for that — the slowest node's bar is full, and so is
that of anything within a few percent of it. The sr-only summary, which is both
what a screen reader hears and what `Copy summary` puts on the clipboard,
described the shape of the run and said nothing about its cost.

`lib/graph.js` now works out where the time went, and both surfaces say so:

- **`graphTotals(built)`** — the sum of every timed step, how many there were,
  the longest one and what kind of step it was. A sum of steps, not a wall
  clock: tools in one iteration run in parallel, so the total can exceed the
  elapsed time, and a step's share of the *work* is the number worth acting on.
- **`slowestWorthNaming(totals)`** — the editorial half, kept separate because it
  is a judgement rather than arithmetic. A step is only called out when there is
  another timed step to compare it against and it took at least 40% of the
  total. On a run of evenly matched calls "slowest" is noise, and a run with one
  timed step is not its own bottleneck.
- **The node** gets `data-slowest`, the words `· slowest step` on its metrics
  line, and `, the slowest step of this run` in its accessible name. The colour
  on the border and the duration badge is emphasis on top of a label, not the
  thing carrying it.
- **The summary** gains a closing sentence: `The slowest step was the tool grep
  at 900ms, 67% of the 1,350ms the steps took together.` When nothing dominates
  it says so instead, rather than promoting whichever step happened to come
  first.

`buildNodeBox` takes the pick through a new optional `opts` argument, so its
existing signature and every other caller are unchanged.

### Verified

`node` + the DOM stub driving the real `lib/graph.js`, with `core/vendor.js`
swapped for a stub whose `loadD3` installs a fake `dagStratify`/`sugiyama`, so
`layoutGraph` really runs and really builds the nodes. 37 assertions, 17 of them
this slice: exactly one node marked across a five-node graph, that it is the
900ms `grep` and not the 300ms model call, the mark present in the metrics text
and the accessible name as well as the attribute, the totals (1,350ms over four
timed steps, longest `grep`, kind `tool`), the summary naming the step, its
share and the total, and both refusals — three steps within 10ms of each other
name nobody, and neither does a run with a single timed step. Against unmodified
`main` the same harness fails 6 of them, including the two new exports not
existing. The `app.css` rules are two lines and are checked as source shape.
Gate: `zig build`, `zig build tools`, `zig build test --summary all` — 163/163
steps, 766/768 tests (2 skipped, the expected worktree pair).

## The Models view hands you the config.toml entry (2026-08-13)

The Models view exists so that finding a model to add to `config.toml` does not
need a terminal, and it stopped one step short of that: it showed the context
window, the prices and the capabilities, then left you to hand-type the TOML
from them in another window. That is where a context window loses a digit and
where `max_tokens` gets forgotten — and forgetting it is not cosmetic, because
the entry then takes `config.Model`'s 1024-token default and truncates every
answer the model gives.

`clanker providers fill` already prints exactly the right block. Each row of the
models.dev results now has a **config.toml** button that shows that same block,
built from the same catalog fields and the same capability vocabulary. Still
read-only: it hands over text to paste and never writes `config.toml`, matching
`providers fill`'s own stance.

- **`features/models.js: configSnippet(m, configured, known)`** — pure and
  exported, so the text a test asserts is the text the button shows. Provider
  and model ids arrive from a third-party fetch and land inside double-quoted
  TOML strings, so quotes and backslashes are escaped; a provider name that is
  not a bare TOML key (`[providers."muse-spark-1.1"]`, which this repo's own
  `config.toml` already needs) is quoted in the hint. When the catalog's
  provider has no `[providers.*]` table the block alone would be rejected at
  startup, so the snippet says what else is needed instead of looking complete;
  `known` keeps "we have not loaded the provider list" distinct from "the list
  is empty", so nothing is claimed about a provider we cannot see.
- **`src/cli.zig: catalogCapabilities`** — models.dev's
  `reasoning`/`tool_call`/`modalities.input` translated to the tags
  `config.Model.capabilities` accepts, extracted from `renderModelSnippet` so
  the CLI's snippet and the page's read one definition. `/api/catalog` now also
  returns `display` and `output` (the fields the snippet needs for `display` and
  `max_tokens`) alongside the columns the table already showed.
- **`index.html` / `app.css`** — the snippet is a selectable `<pre>`, not just a
  clipboard write. `navigator.clipboard` exists only in a secure context and
  `clanker serve` speaks plain http, so on `http://192.168.0.5:8080` a
  copy-only affordance would be dead on exactly the setup this server is built
  for. Copy is the shortcut; when the API is missing or refuses, the button
  reads `Select it` and the status line says why, rather than doing nothing.

### Verified

`node` + a DOM stub driving the real `features/models.js` — 32 assertions.
`configSnippet` over a full catalog entry (every field, in order, ending in a
newline), a bare one, an undeclared provider, an unknown provider list, a dotted
provider name and an id carrying a quote and a backslash. Then the real table:
both rows get a button, the panel opens titled with its model and holding the
real snippet, Copy reaches the clipboard and says `Copied`, the same click with
`navigator.clipboard` removed falls back to `Select it` with the text still on
screen, and Close and a fresh search both put the stale panel away. The earlier
provider-selection regression test still passes 12/12 on this branch.

The Zig half: a new test pins `catalogCapabilities` across every branch of the
vocabulary, including `false` and a non-object entry. That the extraction is
behaviour-preserving was checked live rather than argued —
`clanker providers fill deepseek` against the real models.dev catalog produces
**byte-identical** output on this branch and on unmodified `main`
(`clanker providers check deepseek: ok, 786ms`).

Then end to end, over real HTTP — `clanker serve` runs again since #188, so this
no longer has to stop at the module boundary. `serve --port 41998`, then:

- `/webui`, `/webui/features/models.js`, `/webui/app.css` all `200`, and each
  really carries this change: `export function configSnippet` in the served
  module, all five `id="models-snippet*"` in the served page, the
  `.models-snippet` rules in the served stylesheet.
- `GET /api/catalog?q=kimi-k3` → `200`, 63 entries from the real models.dev,
  and **63 of 63** carry all three new fields. The sample carries
  `capabilities: ["thinking","tool_use","image_in","video_in"]`, so the shared
  helper's `modalities.input` branch is exercised by real data and not only by
  the fixture.
- The full loop: that live JSON fed through the real `configSnippet`, the result
  pasted into a `config.toml` next to a `[providers.moonshotai]` table, and
  `clanker providers check` run against it. clanker parses the generated block
  with **no warnings** and resolves the model (`moonshotai  not configured
  kimi-k3  *` — the only complaint is the missing API key, which is credentials,
  not syntax). Appending one bogus key to the same block immediately produces
  `config: unknown key 'bogus_key' in kimi-k3`, so the clean run is a real
  result and not a check that never fires.

Gate: `zig build`, `zig build tools`, `zig build test --summary all` — 163/163
steps, 773/775 tests (2 skipped, the expected worktree pair).

## Left / next

- The config.toml snippet is on the models.dev rows only. The "Live from
  provider" listing is the case a local Ollama/vLLM user wants it for most, but
  `GET /models` returns an id and sometimes a context window and never an output
  limit — so a snippet from there would ship exactly the missing-`max_tokens`
  footgun the catalog snippet was built to close. It needs a way to ask for, or
  default, an output cap before it is worth offering.
- `#models-status` is one `aria-live` line shared by three independent panels
  (Configured, Live, Discover) and is only ever written on success, so a stale
  "12 catalog matches." survives a failed live listing. Each panel wants its own
  line, or the writes want a panel tag.
- `core/tools.js: buildToolConfig` types its inputs off `typeof current`, so a
  key in `config_editable` that is absent from `config` is typed `"undefined"`
  and saved back as a string — a numeric setting silently becomes `""` the first
  time it is set from the page. The fix wants the manifest to say the type
  rather than the current value implying it.
- Decompose remaining `app.js` feature slices (`features/board.js`, `features/goals.js`, remaining view logic) per `docs/prds/0006-webui.md`'s Design → Framework choice — now cheaper because imports are real and the serve path is complete.
- Promote `axe-core` into the repo + `clanker gate` so the a11y proof is not `/tmp`-vendored; add narrow-viewport Fleet interaction (hamburger → Fleet) to the screenshot harness so the drawer path is also photographed.
- Resolve the pre-existing axe items logged in the sweep entry (composer `#task` combobox role, `#rail-list` workspace header structure, board/goals/runs contrast + labels, run-compare B select name) — they sit in the concurrent agent's board/run-compare/workspace surface.
- If Kimi parity is to extend beyond the documented Phase 6: decompose remaining `app.js` view logic (`features/board.js`, `features/goals.js`), promote `axe-core` into `clanker gate`, and resolve the pre-existing axe handoff items (composer `#task` combobox role, `#rail-list` workspace header structure, board/goals/runs contrast + labels, run-compare B select name) — all already logged in the sweep entry. The composer Research toggle from this slice closes the last named parity candidate.
- Kimi Code **harness** parity (open-source CLI, the corrected target): remaining gaps are MCP **client** configuration (clanker already serves MCP; `/mcp-config`-style client management is new), ACP/IDE integration (`kimi acp` equivalent), and lifecycle hooks surfaced from the page. Video input and the skills catalogue just landed; each remaining item is a bounded slice on its own.
