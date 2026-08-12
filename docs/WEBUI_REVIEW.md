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

## Left / next

- Phase 6 items 6.1–6.4 per `docs/prds/webui.md` (Branch per turn, citation chips, model pill inside composer, collapsed rail) — none land in this slice beyond the CSS+grouping scaffolding already shipped.
- Decompose remaining `app.js` feature slices (`features/board.js`, `features/goals.js`, remaining view logic) per `docs/prds/webui.md`'s Design → Framework choice — now cheaper because imports are real and the serve path is complete.
- Promote `axe-core` into the repo + `clanker gate` so the a11y proof is not `/tmp`-vendored; add narrow-viewport Fleet interaction (hamburger → Fleet) to the screenshot harness so the drawer path is also photographed.
