# Web UI Review — 8h Option B (2026-08-12)

## Summary

Goal: transform `tools/zig/webui/*` into an award-winning control surface
(clarity, hierarchy, alive feel) while shipping **Fleet** (Phase 3.2
cross-agent view) and expanding the native ES-module split — no bundler,
strict CSP, offline-capable, no sockets beyond `/api/run`.

Previous state: 5511-line `app.js` monolith + `app.css` 1617 lines + `index.html` 417 lines, one `van-boot.js` bridge, blank transcript empty, header chips hidden on mobile, sub-agent `sub-*` graphs recorded but unfetchable (`handleRuns` rejected `sub-`), no fleet view, no DMs in fleet.

## What changed

### P0 fixes
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
- `tools/zig/webui.zig` — embed + comptime `encodedLen` guard + `assetFor` for all **21** webui assets (now incl. `core/composer.js`).
- `src/cli.zig` — `is_webui` exact paths + `handleWebuiAsset` `RenderCache/GzipCache` vars for each new module (now 21 routes); `composer` alongside `overlay`/`search`/`labels`/`chat`/`ui`/`stream`/`board`; `Accept-Encoding` now parses `q=` quality values per RFC — `gzip;q=0` no longer falsely negotiates gzip.
- `tools/zig/webui/index.html` — rail `Watch > Fleet` tab, `#view-fleet` with roster/DMs/runs/detail, script order `van-boot → van-ui defer → core/utils → core/icons → core/ui → core/vendor → core/chat → core/labels → core/goals → core/stream → core/theme → core/overlay → core/search → core/composer → lib/markdown → lib/graph → lib/board → features/fleet → app.js type=module` (modules defer implicitly; DOMContentLoaded spans them).
- `tools/zig/webui/app.js` — **now a native ES module** (was classic `defer`): top-level `import` from `./core/*` and `./lib/*` replaces all `window.ck*` aliases; no `window.ckUtil/ckUi/ckTheme/ckChat/ckChat/ckLabels/ckGoals/ckGraph/ckMarkdown/ckBoard/ckStream` reads remain (apart from comments). `providerCache` hoisted before `modelLabel` curry so import order is explicit. **4682** lines (from 5511 at start; −829 total).
- Fleet `app.js`/`features/fleet.js` a11y: fleet cards/rows lose duplicate `tabIndex`/`aria-label`/`keydown` handlers — the inner `Open` button is the single tab stop. Toasts gain `aria-label` + keyboard dismiss (`Enter`/`Space`/`Escape`).

### Design / alive polish
- Header <34rem keeps chips as truncated `8ch` + dot lamp, not `display:none`; breathing clamp on `main`.
- Transcript empty → hero card + staggered `suggestion-in` 150ms/pill (reduced-motion gated).
- Skeletons `.skeleton/.skeleton-bar/.fleet-skeleton` (reduced-motion → static).
- Alive lamps: refined `turn[data-phase=llm|tool|ask]` — shared base rule, tuned glows (`accent 35%/40%/60%`, `ok 40%`), `ask` brightest; `ask` now **breathes** (`lamp-breathe 2.2s` opacity pulse, reduced-motion gated); `chip[data-state=pending]` amber. Rail lamp `180ms ease-out`.
- Board narrow: `<900px` tightens gaps + min-width so Done stays reachable without sideways overflow.
- Fleet tokens all via `var(--…)` (`accent/rule/surface/space/step/radius/lift`), hover `color-mix`, `focus-visible`, `collapsed` state.
- Goal actions empty state suppressed (`:empty` → `display:none`) so stale margin doesn't linger.

### Bugfixes / a11y
- Model picker, Runs graph skeletons+`aria-busy`, Ask/confirm `alertdialog`+tab trap, Palette dedupe — carried from earlier passes (unchanged this turn).
- Shared formatters now via `Intl.NumberFormat` + i18n-aware `searchFold`/`Array.from` clip in `core/utils.js`; pure helper, module-tested via `node --check`.

## Constraints honored

- `lib.out_cap = 2MiB` comptime guard passes (largest encoded `app.js` ~180KB; new modules 1–9KB each; headroom ~1.8MB; 21 assets).
- `script-src 'self'` only: all scripts `src="/webui/…" module` or `defer`, no inline script, no `style=` attrs.
- Offline-capable, vendored `/webui/vendor/*` lazy via `loadVendor`, no third-party fetch, no new sockets, no `eval/new Function`.
- No `src/improve/`, `src/evals/`, `evals/`, `src/tools/builder.zig` edits (non-webui stashes kept aside).
- ES-module split: native `<script type="module">`, no bundler/npm build step, per-module embedding like `app.css/app.js` (zig fmt clean).
- A11y sweep: skip-links, 8 view live regions, roving tabindex on rail, canvas/graph tabindex, toast keyboard dismiss, fleet cards single tab-stop (inner Open button), reduced-motion gated skeletons/animations.

## Verification (this turn)

- `zig build` EXIT 0, `zig build tools` EXIT 0, `zig build test --summary all` 375/376 pass (1 skipped).
- `zig fmt --check src/cli.zig tools/zig/webui.zig` EXIT 0; `node --check` on `app.js`, `core/*`, `lib/*`, `features/fleet.js` → OK (all 17 js files).
- `out_cap` per-file: all `ok` (max ~180KB well under 2MiB; 21 assets via assetFor).
- CSP/connect: only `/api/*` + `/.well-known/agent.json` same-origin fetches; `/webui/vendor` immutable-cache + gzip; no inline script, no third-party origin.

### Shipped this turn
- `core/composer.js` — `loadPrompts/savePrompts/promptQuery/autoGrow/contextLabel` extracted as a real module (pure, tested via `node --check`); `app.js` 4682 lines.
- Show-taught `showToast` now delegates to `core/ui.js:toast`; `llm`-phase lamp breathes alongside `ask`.

## Left / next

- Decompose remaining `app.js` feature slices (`features/board.js`, `features/goals.js`, `features/tools.js`, palette/model-picker) per `docs/webui-framework-research.md` §4 — now cheaper because imports are real.
- `axe-core` + `playwright` screenshot proof per view (incl. Fleet) — no harness vendored yet, manual verification until added.
