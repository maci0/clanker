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
| 1 | Vendored `patternfly.min.css` + `patternfly-addons.css`, served from `/webui/vendor/*` | done |
| 2 | Page shell: `pf-v6-c-page`, Masthead, sidebar, `main` (`#main` unchanged) | next |
| 3 | Rail navigation → PF Nav (vertical tabs, groups) | |
| 4 | Buttons (`primary`, `secondary`, `danger`, icon buttons) | |
| 5 | Forms (composer, filters, goal form, settings) | |
| 6 | Overlays (palette, help, dialogs, card detail) | |
| 7 | Toasts, chips, status indicators | |
| 8 | Theme bridge (PF dark + clanker palette themes) | |
| 9 | Remove dead CSS from `app.css`; drop cabinet tokens | |

## Step 2 notes (page shell)

Target structure (IDs preserved on inner nodes):

```html
<div class="pf-v6-c-page" id="app-page">
  <header class="pf-v6-c-masthead" id="app-masthead">…existing header children…</header>
  <div class="pf-v6-c-page__sidebar pf-m-expanded" id="rail">…</div>
  <main class="pf-v6-c-page__main" id="main" tabindex="-1">…</main>
</div>
```

Bridge CSS will map `.shell` flex layout to PF page grid until rail collapse logic
is rewritten for `pf-m-collapsed` on the sidebar.

## Updating vendored PatternFly

```sh
cd /tmp && npm pack @patternfly/patternfly@6
tar -xzf patternfly-*.tgz
cp package/patternfly.min.css package/patternfly-addons.css /path/to/clanker/ui/vendor/
```

Update the version in `ui/vendor/README.md`, then `zig build test`.
