# PatternFly migration

Incremental port of the clanker web UI from the custom "control cabinet" stylesheet
to [PatternFly 6](https://www.patternfly.org/) HTML/CSS. The app stays vanilla JS
(no bundler, no React); we adopt PF markup and classes directly.

## Approach

1. Load PatternFly base CSS first, then `app.css` (legacy overrides during migration).
2. Keep every existing element `id` until the JS that references it is updated.
3. One surface per step; each step should leave the UI usable and gate-clean.
4. Delete migrated rules from `app.css` only after the PF replacement ships.

## Steps

| Step | Scope | Status |
|------|-------|--------|
| 1 | Vendored `patternfly.min.css` (+ optional `patternfly-addons.css` kept on disk), served from `/webui/vendor/*` | done |
| 2 | Page shell: `pf-v6-c-page`, Masthead, sidebar, `main` (`#main` unchanged) | done |
| 3 | Rail navigation → PF Nav (vertical tabs, groups) | done |
| 4 | Buttons (`primary`, `secondary`, `danger`; skip chip-btn + composer submit/cancel) | done |
| 5 | Forms (composer, filters, goal form, settings) | done |
| 6 | Overlays (palette, help, dialogs, card detail) | done |
| 7 | Toasts, chips, status indicators | done |
| 8 | Theme bridge (PF dark + clanker palette themes) | done |
| 9 | Remove dead CSS from `app.css`; drop cabinet tokens | done |

## Runtime upgrades

`upgradePfUi(document)` in `app.js` runs at init. It calls, in order:

- `upgradePfButtons` — `pf-v6-c-button` + variant modifiers
- `upgradePfForms` — `pf-v6-c-form`, `pf-v6-c-form-control`, `pf-v6-c-check`
- `upgradePfOverlays` — `pf-v6-c-backdrop` / `pf-v6-c-modal` / `pf-v6-c-modal-box`
- `upgradePfChips` — `pf-v6-c-label` on masthead status chips

Dynamic UI (`toast`, `uiConfirm`, `uiPrompt`, `UI.field`, `renderStatusInto`) applies
the same helpers when creating nodes.

## CSS layering (step 9)

Generic controls use PF classes via `upgradePfUi`. Legacy cabinet rules are scoped to
elements that skip the upgrade (`button:not(.pf-v6-c-button)`,
`input:not(.pf-v6-c-form-control)`, etc.). Bridge blocks own the upgraded look.

Domain-specific surfaces keep cabinet CSS only (no PF wrapper):

- Transcript turns, run graph nodes, code blocks, board cards, arena lamps
- Chat bubbles, markdown prose, syntax-highlighted output

## Step 9 notes

Legacy `button` rules use `:where(:not(.pf-v6-c-button))` so component classes
(`.suggestion`, `.rail-pin`, `.rail-group`, nav tabs) keep their own look.
Plain `:not(.pf-v6-c-button)` raised specificity above those classes and painted
the sidebar / suggestion chips as blue actuators.

PF's page shell paints a glass frame on `.pf-v6-c-page__main-container` (4px
accent border). Zero those tokens on `#app-page` and `.shell` so the cabinet
surface shows through instead of a blue chrome box.

`index.html` loads `patternfly.min.css` with `media="print"` first, then
`app.js` flips it to `all` (CSP blocks inline `onload`). Cabinet `app.css`
stays after PF in document order so token remaps win.

Masthead `chip-btn` controls and `#submit`/`#cancel` stay off `pf-v6-c-button`:
PF brand/plain colours were beating `--accent` / `--fg-muted` across themes.

## Updating vendored PatternFly

```sh
cd /tmp && npm pack @patternfly/patternfly@6
tar -xzf patternfly-*.tgz
cp package/patternfly.min.css package/patternfly-addons.css /path/to/clanker/ui/vendor/
```

Update the version in `ui/vendor/README.md`, then `zig build test`.
