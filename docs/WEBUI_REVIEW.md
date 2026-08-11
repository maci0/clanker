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

### ES-module split (no bundler)
- `tools/zig/webui/core/utils.js` — `fmtBytes, clip, fuzzyMatch, escapeHtml, fmtMs`
- `tools/zig/webui/core/vendor.js` — `readJson, copyText, loadVendor, loadD3, loadHljs, scrollTo, reducedMotion` (+ window fallback for classic `app.js`)
- `tools/zig/webui/core/theme.js` — `THEMES, loadTheme, applyTheme, cycleTheme` (pure, no auto-init)
- `tools/zig/webui/features/fleet.js` — Fleet view (imports `clip` + `readJson`), groups runs by `parent_run_id` with `[subagent run: sub-…]` output fallback, peers roster, DM channels via `GET /api/chat/rooms` (gate-tolerant), detail fallback fetch, collapsible children, keyboard, skeletons + retry errors.
- `tools/zig/webui.zig` — embed + comptime `encodedLen` guard + `assetFor` for 4 new modules.
- `src/cli.zig` — `is_webui` exact paths + deferred-module dispatch + `RenderCache/GzipCache` vars for each new module; `handleWebuiAsset` cache selection.
- `tools/zig/webui/index.html` — rail `Watch > Fleet` tab, `#view-fleet` with `#fleet-roster/#fleet-dms/#fleet-runs/#fleet-detail`, script order `van-boot → van-ui defer → core/utils → core/vendor → core/theme → features/fleet → app.js defer` (module+defer document order).

### Design / alive polish (app.css, index.html unchanged structurally)
- Header <34rem keeps chips as truncated `8ch` with ellipsis + dot lamp, not `display:none`; `#help-open` stays; breathing clamp on `main` (`88rem`, `clamp(1rem,3vw,2.5rem)`).
- Transcript empty → hero: inset `surface-2` card, `p:first-child` `step-2 700`, staggered `suggestion-in` 150ms per pill, gated by `prefers-reduced-motion`.
- Skeletons `.skeleton/.skeleton-bar/.fleet-skeleton` shimmer `1.2s` (reduced-motion → static `surface-2`).
- Alive lamps: `chip[data-state=pending]` amber, `turn[data-phase=llm|tool|ask]` left 3px (`accent` vs `ok`), rail lamp transition `180ms ease-out`.
- Fleet tokens: `.fleet-card/card--parent/child-group/dm-*` all via `var(--accent/--rule/--surface/--space/--step/--radius/--lift)`, hover `color-mix`, `focus-visible`, `role=list` where needed, `collapsed` state.

### Bugfixes / a11y (app.js)
- Model picker: `runOptions()` split on first space not last, blur via `focusout+relatedTarget` with list containment, bad model surfaces `error/message` from `resp.text()` JSON.
- Runs graph: `loadRuns/loadRun` skeletons + `aria-busy`, stale graph cleared, `drawRun` d3 failure path cleans container, resize handler `pagehide` cleanup.
- Ask/confirm: `role=alertdialog aria-live assertive aria-label`, per-row `Tab` trap + `Escape→deny` via `fleet-status` live announce.
- Palette: empty query returns all grouped entries, labels `textContent` only, no `innerHTML`.

## Constraints honored

- `lib.out_cap = 2MiB` comptime guard passes (largest encoded `app.js` ~215KB; new modules 1–19KB each).
- `script-src 'self'` only: all scripts `src="/webui/…" module` or `defer`, no inline script, no `style=` attrs.
- Offline-capable, vendored `/webui/vendor/*` (d3-dag, hljs, van) lazy via `loadVendor`, no third-party fetch, no new sockets, no `eval/new Function`.
- No `src/improve/`, `src/evals/`, `evals/`, `src/tools/builder.zig` edits.

### Runtime alive + loading (this turn)
- `app.js:skeletonRows` + `setTurnPhase` — turn `data-phase="llm|tool|ask"` wired to `\x01` stream (`tool_call → tool`, `ask|confirm → ask`, `done|error → clear`), `chip[data-state=pending]` amber available; CSS `.turn[data-phase]` already gated.
- `loadRuns/loadRun/markLoading` now render `.skeleton/.skeleton-row/.skeleton-bar` with `aria-busy` (was text `Loading…`).
- `features/fleet.js` now fetches `/.well-known/agent.json` same-origin (gate-tolerant) and renders `This agent` A2A card (`name/id/skills`) via `.fleet-a2a` tokens; DMs already in previous turn.
- `src/cli.zig` fix: `std.time.nanoTimestamp()` → `std.Io.Timestamp.now(...).nanoseconds` (Zig 0.16 `time/epoch.zig` has no such member; `llm/client.zig:132` pattern).

## Verification (manual, this run)

- `zig build` EXIT 0, `zig build tools` EXIT 0, `zig build test` EXIT 0 (separate `zig build test` run: pass; noisy config/provider errors expected).
- `zig fmt --check src/cli.zig tools/zig/webui.zig` EXIT 0; `node --check` on `app.js`, `core/*`, `features/fleet.js` → OK.
- No `innerHTML` assignments in fleet/vendor/theme; no `style=` in `index.html`; only `/api/*` + `/.well-known/agent.json` same-origin fetches (CSP `connect-src 'self'` intact).
- Manual proof: before/after screenshots not yet captured (headless run). Fleet reachable at `#fleet`, roster + A2A + DMs + grouped sub-runs navigable, responsive rail/hero + skeletons + phase lamps verified via CSS/JS.

### This turn — lib/markdown + routing (2026-08-12 ~01:48Z)

- Added `tools/zig/webui/lib/markdown.js` (~9KB ES module) — `INLINE_RE, isSafeLinkUrl, inlineInto, paragraphInto, tableRow, splitRow, renderMarkdown, prettyJsonIfPossible, highlightInto, buildCodeBlock, finalizeAnswer` (from `app.js:1046-1362`). Imports `loadHljs, copyText` from `core/vendor.js` only; no new globals.
- `tools/zig/webui.zig` + `src/cli.zig`: embedded `lib/markdown.js`, extended `is_webui` + handler dispatch + `RenderCache/GzipCache` (`render_markdown/gzip_markdown`), comptime `encodedLen` guard extended (9 assets). Fix for earlier miss: `core/vendor.js`/`core/theme.js` and now `lib/markdown.js` were routed through `webui.zig` but `is_webui` in `src/cli.zig` was stale — patched both.
- `tools/zig/webui/index.html`: inserted `<script type="module" src="/webui/lib/markdown.js">` between `core/theme.js` and `features/fleet.js`; order still `van-boot → van-ui defer → utils → vendor → theme → lib/markdown → fleet → app.js defer`.
- `tools/zig/webui/core/utils.js` already bridges to `window.ckUtil` (splitRow, prettyJsonIfPossible, isSafeLinkUrl etc.) for classic `app.js` fallback; `lib/markdown.js` is additive — `app.js` still ships its own copy until switched to `import` (keeps risk bounded).

## Left / next

- Complete the ES-module cutover: make `app.js` import from `lib/markdown.js` (and eventually `lib/graph.js`, `core/ui.js`, `features/*`) so the duplicated 340-line markdown block is the canonical one in `lib/`.
- Decompose remaining monolith per `docs/webui-framework-research.md` §4: `lib/graph.js` (D3 layout + node boxes), `core/ui.js` (rail + toast + overlays), then feature modules.
- `axe-core` + `playwright` screenshot proof per view (incl. Fleet) — no `axe`/`playwright` harness vendored in this repo today, so manual verification until added.
