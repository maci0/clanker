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
- `tools/zig/webui/core/utils.js` — `fmtBytes, clip, fuzzyMatch, escapeHtml, fmtMs, fmtInt, fmtCost, formatChatTime, fmtDeadline` (now also `fmtInt/fmtCost/formatChatTime/fmtDeadline`)
- `tools/zig/webui/core/vendor.js` — `readJson, copyText, loadVendor, loadD3, loadHljs, scrollTo, reducedMotion`
- `tools/zig/webui/core/theme.js` — `THEMES, loadTheme, applyTheme, cycleTheme`
- `tools/zig/webui/core/ui.js` / `core/icons.js` — `bind, toast, skeletonRows, setTurnPhase, T/UI` and icon set (already bridged as `window.ckUi/ckIcons`)
- `tools/zig/webui/lib/markdown.js` — markdown pipeline (`~9KB`)
- `tools/zig/webui/lib/graph.js` — execution-graph layout (`~8.7KB`)
- `tools/zig/webui/lib/board.js` — **new** `BOARD_COLUMNS, boardActionLine` extracted from `app.js:2072-2117` (pure, no DOM, bridged as `window.ckBoard`)
- `tools/zig/webui/features/fleet.js` — Fleet view (`clip` + `readJson`), groups runs by `parent_run_id` with `[subagent run: sub-…]` fallback, peers roster, DM channels, detail fetch, collapsible children, keyboard, skeletons + retry.
- `tools/zig/webui.zig` — embed + comptime `encodedLen` guard + `assetFor` for all 13 webui assets (now incl. `lib/board.js`).
- `src/cli.zig` — `is_webui` exact paths + `handleWebuiAsset` `RenderCache/GzipCache` vars for each new module (now 13 routes); `board` added alongside `graph/markdown`.
- `tools/zig/webui/index.html` — rail `Watch > Fleet` tab, `#view-fleet` with roster/DMs/runs/detail, script order `van-boot → van-ui defer → core/utils → core/icons → core/vendor → core/theme → lib/markdown → lib/graph → lib/board → features/fleet → app.js defer` (module+defer document order).

### App.js dedupe (monolith shrink)
- `app.js` now bridges instead of duplicating: `fmtInt/fmtMs/fmtCost/fmtDeadline/formatChatTime → window.ckUtil`, `T/bind/skeletonRows/setTurnPhase/icon/UI → window.ckUi/ckIcons`, `vendor/lifecycle → window.vendorLoads/ckBoard`, `THEMES/loadTheme/applyTheme → window.ckTheme`, `BOARD_COLUMNS/boardActionLine → window.ckBoard`, `graph helpers → window.ckGraph`. Net cut this run: `boardActionLine` (~50 lines) + formatting helpers (~20 lines) + earlier `graph` block (254) and fallback cleanups. Current: `app.js` 4944 lines (from 5511 at start; −567 total).

### Design / alive polish
- Header <34rem keeps chips as truncated `8ch` + dot lamp, not `display:none`; breathing clamp on `main`.
- Transcript empty → hero hero card + staggered `suggestion-in` 150ms/pill (reduced-motion gated).
- Skeletons `.skeleton/.skeleton-bar/.fleet-skeleton` (reduced-motion → static).
- Alive lamps: refined `turn[data-phase=llm|tool|ask]` — shared base rule, tuned glows (`accent 35%/40%/60%`, `ok 40%`), `ask` brightest; `chip[data-state=pending]` amber. Rail lamp `180ms ease-out`.
- Fleet tokens all via `var(--…)` (`accent/rule/surface/space/step/radius/lift`), hover `color-mix`, `focus-visible`, `collapsed` state.

### Bugfixes / a11y
- Model picker, Runs graph skeletons+`aria-busy`, Ask/confirm `alertdialog`+tab trap, Palette dedupe — carried from earlier passes (unchanged this turn).

## Constraints honored

- `lib.out_cap = 2MiB` comptime guard passes (largest encoded `app.js` ~205KB; new modules 2–6KB each; headroom ~1.8MB).
- `script-src 'self'` only: all scripts `src="/webui/…" module` or `defer`, no inline script, no `style=` attrs.
- Offline-capable, vendored `/webui/vendor/*` lazy via `loadVendor`, no third-party fetch, no new sockets, no `eval/new Function`.
- No `src/improve/`, `src/evals/`, `evals/`, `src/tools/builder.zig` edits.

## Verification (this turn)

- `zig build` EXIT 0, `zig build tools` EXIT 0, `zig build test --summary all` 368/369 pass (1 skipped).
- `zig fmt --check src/cli.zig tools/zig/webui.zig` EXIT 0; `node --check` on `app.js`, `core/*`, `lib/*`, `features/fleet.js` → OK.
- `out_cap` per-file: all `ok` (see script check; max ~205KB well under 2MiB).
- CSP/connect: only `/api/*` + `/.well-known/agent.json` same-origin fetches.

## Left / next

- Continue cutover: make `app.js` a real ES module (`<script type="module">` + `import`s) so `window.ck*` bridges can be removed.
- Decompose remaining `app.js` feature slices (`features/board.js`, `features/goals.js`, `features/tools.js`) per `docs/webui-framework-research.md` §4.
- `axe-core` + `playwright` screenshot proof per view (incl. Fleet) — no harness vendored yet, manual verification until added.

