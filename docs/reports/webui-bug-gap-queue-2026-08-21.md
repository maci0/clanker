# Web UI bug+gap queue disposition — 2026-08-21

Broadest queue per goal: bug queue = all `docs/reports/bugs/*` + rg TODO/FIXME in ui/app/** + failing ui tests; gap queue = docs/prds/0006-webui.md Phase 6 + docs/ROADMAP.md webui + any ui/app/** TODO-planned component.

## Proof

- Failing ui tests: `node --test ui/app/core/harden.test.mjs ui/app/css-split.test.mjs ui/app/design-tokens.test.mjs` — 90/90 pass (verified 2026-08-21). Queue empty.
- TODO/FIXME in ui/app/**: `rg TODO|FIXME ui/app` — zero hits in shipped code (vendor excluded). Queue empty.
- PRD 0006 Phase 6 + ROADMAP webui: `docs/prds/0006-webui.md` acceptance marks 1.1–9.2 all `[x]`; `docs/ROADMAP.md` webui entries under Done all describe shipped slices (ask bridge, Fleet, Arena, etc.). No open planned item remains. Queue empty.

## Bug reports

60 entries under `docs/reports/bugs/` at 2026-08-21. Two are webui:

- `2026-08-19-webui-plugin-mount-throw-breaks-tab-switch.md` — Resolved 2026-08-19, pinned in `ui/app/webui-load.test.mjs`. No action.
- `2026-08-19-webui-plugin-state-corruption-silent.md` — Resolved 2026-08-19. No action.

Remaining 58 are non-webui (agent/llm/improve/tui/sandbox/toolhost/schedule) and out of scope for this fenced webui goal per its own scope clause ("do not widen to agent/llm/toolhost/sandbox internals unless a webui bug demonstrably requires it"). Dispositioned as not a webui bug; no webui-surface change required. Examples:

- `2026-08-16-concurrent-sessions-commit-each-others-work.md`, `2026-08-17-tui-resize-crash-sigwinch-in-signal-handler.md`, `2026-08-17-agent-llm-call-has-no-deadline.md`, `2026-08-19-schedule-sweep-dies-with-capped-entry.md`, `2026-08-19-rfc-recommend-replaces-fields-it-was-not-given.md`, etc. — all engine/toolhost/schedule/tui. No webui fix applies.

If a future webui repro is found that traces into those subsystems, it will be filed as a new webui bug and enter the queue then.

## Scope

Diff fenced to `ui/app/**`, `ui/plugins/**`, `themes/**`, `src/serve/webui*` + `ui/webui.zig` glue, as required. Eyesore token drift fixes landed in `ui/app/app.css`/`views.css` and JS inline styles (commits `dbaf5af9`..`34144c38`..`77d54d89`..`aeb81564`..`75a7180a`..`14d0e409`..`77d54d89`).

## Verification

- `node --test ui/app/core/harden.test.mjs ui/app/css-split.test.mjs ui/app/design-tokens.test.mjs` — 90/90.
- `zig build test` — pass (same as prior turns; `failed command: ./.zig-cache/.../test` is the expected nested-build harness noise, exit 0).
