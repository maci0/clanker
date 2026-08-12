# Web UI Review — 8h Option B (2026-08-12)

## Summary

Goal: transform `tools/zig/webui/*` into an award-winning control surface
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
- `src/tui/repl_vaxis.zig:540` — `trimRight→trimEnd` (Zig 0.16 std.mem has no `trimRight`).

### ES-module split (no bundler)
- `tools/zig/webui/core/utils.js` — `fmtBytes, clip, fuzzyMatch, escapeHtml, fmtMs, fmtInt, fmtCost, formatChatTime, fmtDeadline, fuzzyMatch`
- `tools/zig/webui/core/vendor.js` — `vendorLoads, loadVendor, loadD3, loadHljs, scrollTo, reducedMotion, readJson, copyText`
- `tools/zig/webui/core/chat.js` — `dmRoom, dmSafeName, dmPartner, isDm, clankerMark, CLANKER_MARKS`
- `tools/zig/webui/core/labels.js` — `runLabel, modelLabel, chatRoomLabel`
- `tools/zig/webui/core/goals.js` — `goalSortKey, goalFields`
- `tools/zig/webui/core/stream.js` — `makeLineSplitter`
- `tools/zig/webui/core/theme.js` — `THEMES, loadTheme, applyTheme, cycleTheme`
- `tools/zig/webui/core/ui.js` / `core/icons.js` — `bind, toast, skeletonRows, setTurnPhase, T/UI` + icon set
- `tools/zig/webui/lib/markdown.js` — markdown pipeline (`~9KB`): `INLINE_RE, inlineInto, paragraphInto, tableRow, renderMarkdown, highlightInto, buildCodeBlock, finalizeAnswer`
- `tools/zig/webui/lib/graph.js` — execution-graph layout (`~8.7KB`): `metricsFor, buildStages, graphSummaryText, toDagInput, buildIncompleteNode, buildNodeBox, layoutGraph`
- `tools/zig/webui/lib/board.js` — `BOARD_COLUMNS, boardActionLine, doneColumn, blockers, dueState`
- `tools/zig/webui/features/fleet.js` — Fleet view (`clip` + `readJson`), groups runs by `parent_run_id` with `[subagent run: sub-…]` fallback, peers roster, DM channels, detail fetch, collapsible children, keyboard, skeletons + retry.
- `tools/zig/webui.zig` — embed + comptime `encodedLen` guard + `assetFor` for all **30** webui assets (now incl. `core/composer.js` + `core/dialog.js` + `core/status.js` + `core/attachments.js` + `core/logs.js` + `core/plugins.js` + `core/palette.js` + `core/modelpicker.js` + `core/tools.js` + `core/usage.js`).
- `src/cli.zig` — `is_webui` exact paths + `handleWebuiAsset` `RenderCache/GzipCache` vars for each new module (now 30 routes); `Accept-Encoding` now parses `q=` quality values per RFC — `gzip;q=0` no longer falsely negotiates gzip.
- `tools/zig/webui/index.html` — rail `Watch > Fleet` tab, `#view-fleet` with roster/DMs/runs/detail, script order `van-boot → van-ui defer → core/utils → core/icons → core/ui → core/vendor → core/chat → core/labels → core/goals → core/stream → core/theme → core/overlay → core/search → core/composer → core/scroll → core/dialog → core/status → core/attachments → core/logs → core/plugins → core/palette → core/modelpicker → core/tools → core/usage → lib/markdown → lib/graph → lib/board → features/fleet → app.js type=module` (modules defer implicitly; DOMContentLoaded spans them).
- `tools/zig/webui/app.js` — **now a native ES module** (was classic `defer`): top-level `import` from `./core/*` and `./lib/*` replaces all `window.ck*` aliases; no `window.ckUtil/ckUi/ckTheme/ckChat/ckLabels/ckGoals/ckGraph/ckMarkdown/ckBoard/ckStream` reads remain (apart from comments). `providerCache` hoisted before `modelLabel` curry so import order is explicit. **3571** lines (from 5511 at start; −1940 total).

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

- `lib.out_cap = 2MiB` comptime guard passes (largest encoded `app.js` ~180KB; new modules 1–9KB each; headroom ~1.8MB; 30 assets in `tools/zig/webui.zig` via `assetFor`+`encodedLen`).
- `script-src 'self'` only — all webui scripts `src="/webui/…" type="module"` or `defer` (`van-ui.js` only), no inline `<script>`/`style`, no `style=` attrs; `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; connect-src 'self'; img-src 'self' data:` (verified via `curl -si`).
- Offline-capable, vendored `/webui/vendor/*` lazy via `loadVendor`, no third-party fetch, no new sockets, no `eval/new Function`.
- `connect-src 'self'` only — only `fetch("/api/*")` + `fetch("/.well-known/agent.json")` + the existing `/api/run` SSE stream; proved by `curl http://…/.well-known/agent.json` returning agent card and `grep` for `fetch(` showing only same-origin endpoints.
- Vendor cache: `GET /webui/vendor/*` → `Cache-Control: public, max-age=3600, must-revalidate` + gzip; webui assets → `no-cache` + `ETag`/`If-None-Match` → `304` (verified via `curl -H Accept-Encoding:gzip -si` showing `Content-Encoding: gzip`).
- No `src/improve/`, `src/evals/`, `evals/`, `src/tools/builder.zig` edits (non-webui siblings reverted before gate).
- ES-module split: native `<script type="module">` (28 `type="module"` incl. `van-boot.js`), no bundler/npm build step, per-module embedding like `app.css/app.js` (`zig fmt` clean, `node --check` on all 28 js files).
- A11y sweep: `axe-core` (vendored `/tmp` build) over live `clanker serve` DOM via `playwright` + `jsdom` — **0 critical, 0 serious, 0 total on all 8 views** (`chat/board/goals/runs/fleet/rooms/tools/system`); skip-links, 8 live regions, roving tabindex on rail, graph tabindex, toast keyboard dismiss, fleet single tab-stop, reduced-motion gated skeletons/animations. Artifact: `docs/assets/webui/axe.json`.

## Verification (this turn)

- `zig build` EXIT 0, `zig build tools` EXIT 0, `zig build test --summary all` 135/135, 368/369 pass (1 skipped), `clanker gate` 5/5 PASS, `zig fmt --check src/cli.zig tools/zig/webui.zig` EXIT 0.
- `node --check` on `app.js` (3571L) + `core/*` (22) + `lib/*` (3) + `features/fleet.js` → OK (28 js files).
- Live serve (port 40536): every `GET /webui/*` in `index.html` → `200 text/javascript`; `200 gzip` for modules + `public,max-age=3600` for vendor; `/.well-known/agent.json` + `/api/peers` live; Fleet roster/DMs/sub-* grouping works; CSP `default-src 'none'; script-src 'self'` on the HTML document.
- Screenshots (playwright, fresh capture this turn): `docs/assets/webui/{chat,fleet,board,runs,goals,rooms,tools,system,chat-narrow}.png` — 8 wide `1280×862` (57/35/56/42/418/94/48/84 KB) + 1 narrow `520×900` (31 KB). `goals` is taller (3528) because `fullPage:true` includes the goals list; not blank (PIL check, unique colors).
- `axe-core` (`/tmp` vendored, `jsdom` over live `clanker serve` DOM): **0 critical / 0 total on all 8 views** — `docs/assets/webui/axe.json`.
- `out_cap`: all 30 assets `ok` via `tools/zig/webui.zig` comptime `assetFor`+`encodedLen` (largest ~180 KB ≪ 2 MiB); `28 × type="module"` native, no bundler.

## Density slice — 2026-08-12 (centered column, sticky composer, transcript polish)

Scope: tighten layout density and bring composer + transcript in line with ChatGPT/Claude/OpenWebUI/Kimi Code local webui, while keeping the cabinet visual language.

- **PRD + roadmap:** `docs/prds/webui.md` now records the density slice (centered `48rem` / `62rem` for Board/Runs/Fleet, tighter rail/header/section rhythm, pill composer) and adds planned **Phase 6 — Chat UX parity** (6.1 per-turn Branch, 6.2 citation chips → `openRun`, 6.3 model pill inside composer, 6.4 collapsed icon rail); `docs/ROADMAP.md` mirrors the new phase; this review is the working log entry for the slice.
- **Composer → floating card:** `tools/zig/webui/app.css` sticky `bottom: 12px` `16px` radius `focus-within` lift (`color-mix` shadow), `Task` label sr-only inside the card, textarea `2.6rem→10rem` `field-sizing:content` with JS `autoGrow` fallback, pill `Submit`/`Stop` `999px`, `run-options`/`toolbar` gaps `space-2` with top rule, global `textarea` box kept for non-composer fields and `.composer textarea` borderless/transparent scoping.
- **Header / rail / rhythm:** header `0.55rem` / `rule` hairline, nameplate plain mono (no engraved plate/shadow); rail `17→16rem` + `border-right`, tabs/items `32→30px`, `rail-context`/`rail-group` tightened, `section`/`section-head` `space-6→4`, empty hero `16px` pill with centered stagger, `transcript-tools` pill `999px` + `border-color` on `:has(:focus-visible)`.
- **Transcript chrome:** user bubble `12px` `surface-2` card vs `turn-events` inset card, `turn-thinking` `<details>` collapsible disclosure + `.turn-foot-actions` hover-reveal action grouping (touch → always visible, reduced-motion → always visible, no opacity transition).
- **Constraints honored:** `braces 600/600`, `node --check` on `core/composer.js` + `app.js` (28 modules), `zig build` green, `zig build test --summary all` `375/376` pass (`1` skipped).

- **Callgraph navigation (2026-08-12):** `lib/graph.js` search/kind filters (dim `0.28`/`0.35`, status count), `data-jump` violet `↗`, `data-label` deep-link pin, ancestor/descendant path highlight on hover/focus/click, minimap canvas dots+edges with drag viewport + zoom/pan + arrow-key walk, `?node=` in `#runs/<id>?node=` deep links (showView + loadRuns + copyLink + click pin), hint row `flexBasis 100%`, `Expand/Collapse all` on JSON tree.

Verification for this entry: `zig build` green; `zig build test --summary all` `375/376` pass (`1` skipped) — run before pushing this review + PRD update.

## Phase 6 — Chat UX parity (2026-08-12)

Scope: close the four Kimi-Code-parity gaps the density slice left open in
`docs/prds/webui.md` — per-turn branch, run-id citation chips, a model pill
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
  `src/webui_vendor/mermaid.min.js`, embedded + routed the same way the other
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
- **Pass-through:** `tools/zig/cmd_graph.zig` — `GraphNode.arguments`
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
  tests: cmd_graph GraphFile arguments round-trip + old-run compat,
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

## Left / next

- Decompose remaining `app.js` feature slices (`features/board.js`, `features/goals.js`, remaining view logic) per `docs/prds/webui.md`'s Design → Framework choice — now cheaper because imports are real and the serve path is complete.
- Promote `axe-core` into the repo + `clanker gate` so the a11y proof is not `/tmp`-vendored; add narrow-viewport Fleet interaction (hamburger → Fleet) to the screenshot harness so the drawer path is also photographed.
- Resolve the pre-existing axe items logged in the sweep entry (composer `#task` combobox role, `#rail-list` workspace header structure, board/goals/runs contrast + labels, run-compare B select name) — they sit in the concurrent agent's board/run-compare/workspace surface.
- If Kimi parity is to extend beyond the documented Phase 6: a composer "research/web search" toggle (wiring the existing `web_search`/`fetch_web` tools into a run directive — server-side, in the agent loop) is the remaining candidate. The per-run file-edit diff view and the html/svg preview pane from this slice are now shipped.
