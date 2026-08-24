# Bug — Every plugin's api.status writes the same sr-only live region, and Health rewrites it about once a second

## TL;DR

- **What failed:** pluginApi's status (ui/app/core/plugins.js) writes #webui-plugins-status, a role=status aria-live=polite node. Health calls it from applySample, which runs on every 1 Hz metrics event, so a screen reader gets a fresh polite announcement every second while that tab is open. The same node also carries the loader's own enable/disable/failure lines, so a confirmation is overwritten within the second. This is the defect already fixed for #models-status, with N producers instead of three.
- **Impact:** Confirmed, and worse than a screen-reader-only cost: `#webui-plugins-status` is one of the ids the page's status-to-toast mirror watches, so Health's 1 Hz line also put a fresh toast on screen every second for as long as the tab was open.
- **Resolution:** Resolved on 2026-08-24. api.status writes a per-view sr-only region (#plugin-status-<id>) built with the view's chrome and joined to the page's status-to-toast mirror; the shared #webui-plugins-status is the loader's alone. Health only announces a read somebody asked for, not the 1 Hz metrics sample. ui/app/core/plugins.js, ui/app/app.js, ui/plugins/health/app.js.

## Status

Resolved on 2026-08-24. api.status writes a per-view sr-only region (#plugin-status-<id>) built with the view's chrome and joined to the page's status-to-toast mirror; the shared #webui-plugins-status is the loader's alone. Health only announces a read somebody asked for, not the 1 Hz metrics sample. ui/app/core/plugins.js, ui/app/app.js, ui/plugins/health/app.js.

## Symptom and impact

While the Health tab is open a screen reader gets a fresh polite announcement
roughly once a second, indefinitely. Enabling or disabling a plugin at the same
time produces a confirmation that is overwritten inside a second, so the one
message the operator asked for is the one they do not hear.

## Reproduction

Read from the source. Open Health, then enable any plugin from System.

## Root cause

`pluginApi().status` writes `#webui-plugins-status`, a single
`role="status" aria-live="polite"` node, and so do the loaders own five
messages. Health calls `api.status` from `applySample`, which runs on every live
`metrics` event, throttled server-side to 1 Hz. `docs/reviews/webui.md` records
the same defect being fixed for `#models-status`, where three panels shared one
line; here the producer set is every plugin plus the loader. `api.status` also
has no `if (_el.webuiPluginsStatus)` guard, unlike the loaders own writes.

## Resolution

`api.status` writes a per-view `sr-only` `role="status" aria-live="polite"`
node, `#plugin-status-<id>`, created with the view's chrome in `makeViewShell`
and kept in `pluginStatusNodes`. Each is handed to the page's status-to-toast
mirror through a new `observeStatus` entry in the plugin context, so a plugin's
message is still seen and not only announced; the mirror is now joinable rather
than a fixed list of ids, since a plugin's region does not exist when it runs.
Writing the same line twice running is one announcement.

`#webui-plugins-status` is the loader's alone now, so an enable or disable
confirmation cannot be overwritten by a plugin on a timer. The loader's five
writes to it go through one guarded `hostStatus` helper, which is also the
fallback for a spec with no view chrome behind it.

Health was the producer that made this visible, and the frequency was its own
defect: `applySample` takes an `announce` flag, false for a sample that arrived
on the live bus and true for a read somebody asked for (mount, Refresh, coming
back to the view). The tiles are the live surface; the status line is not.

## Verification

`ui/app/core/plugins.test.mjs`. Two plugins announce and land in two
different nodes with the shared line left empty; the region is checked for
`role`, `aria-live`, `sr-only`, containment in its own panel, and membership of
the toast mirror; a repeated line writes once; a spec with no chrome (and a null
spec) still lands on the shared line rather than throwing. Health's gating is
pinned in source, including that `.then(applySample)` is gone, since passing it
straight to `then` would hand the promise index in as `announce`.

Control run against untouched `origin/main`: the per-region tests fail there
(the node does not exist), while the no-chrome fallback test passes on both
sides. Full `clanker gate` green, twelve of twelve.

## Follow-up

## References

- Investigation: none yet
