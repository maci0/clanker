# Bug — A plugin's refresh hook is documented as the re-entry point but the host never calls a view loader twice

## TL;DR

- **What failed:** ui/app/core/plugins.js builds a loader that calls spec.mount once and spec.refresh on every later call. But showView (ui/app/app.js) only invokes viewLoaders[name] under if (!viewLoaded[name]), and viewLoaded[name] is never reset once set. So refresh is reachable only from runPluginHook's Retry path. PRD 0012 documents refresh? as part of the registration API without saying so, and mesh's own comment claims refresh covers re-entry. health and office each bolt on a MutationObserver instead.
- **Impact:** Confirmed. Every plugin that stops work while hidden stayed stopped on return, and two of the shipped nine had already grown a private workaround for it.
- **Resolution:** Resolved on 2026-08-24. showView now calls the host's pluginViewShown() on every switch to an already-loaded view, so spec.refresh is reached; the hook is read at call time so a mount that reassigns this.refresh wins. health and office dropped their MutationObserver workarounds. ui/app/core/plugins.js, ui/app/app.js, ui/app/core/plugins.test.mjs.

## Status

Resolved on 2026-08-24. showView now calls the host's pluginViewShown() on every switch to an already-loaded view, so spec.refresh is reached; the hook is read at call time so a mount that reassigns this.refresh wins. health and office dropped their MutationObserver workarounds. ui/app/core/plugins.js, ui/app/app.js, ui/app/core/plugins.test.mjs.

## Symptom and impact

A plugin that registers a `refresh` hook never has it called. Nothing is
visibly broken on first open; the cost is that a plugin has no way to notice it
became visible again, so a view that stopped its own polling while hidden can
never restart it. `mesh` and `schedule` both rely on `refresh` for exactly that.

## Reproduction

Read-only, from the source. Open a plugin view, switch away, switch back:
`showView` finds `viewLoaded[name]` already true and does not call the loader,
so neither `mount` nor `refresh` runs on the second visit.

## Root cause

`viewLoaded[name] = true` in `ui/app/app.js` is set on a successful load and
never cleared; the only other references are the initial `{}` and read-only
checks. The loader in `ui/app/core/plugins.js` is therefore called at most once
per view outside its own Retry path, and its `mounted` flag guarantees the
`refresh` branch is the second-and-later call.

## Resolution

`showView` reads `viewLoaded[name]` into `wasLoaded` before the load branch
can set it, and calls the host's new `pluginViewShown(name)` after it. The host
keeps per-view mount state in `pluginMounts` (`trackMount`), shared by both the
eager and the deferred loader, so `pluginViewShown` can reach `spec.refresh`
without a path back to `mount`. It is a no-op until `mount` has run, which is
what keeps `refresh` out of the switch that mounted the view.

The hook is read through `getSpec()` at call time rather than captured, because
`health` and `office` both assign `this.refresh` from inside `mount`. Both of
those then dropped the `MutationObserver` on their panel's `hidden` attribute
they had bolted on to work around this: with a working hook, the observer only
bought a second `/api/metrics` read (health) and a second poll (office) per
re-entry.

Consolidating the two loaders onto one guarded mount/refresh pair also took the
count of `runPluginHook(section,` call sites from four to two, which an existing
assertion in `ui/app/webui-load.test.mjs` pinned by number. That assertion now
names the two hooks behind the shared guard instead of counting call sites.

## Verification

`ui/app/core/plugins.test.mjs`, registered in `build.zig`. The host is run in
a `vm` with its six sibling imports stripped and stubbed, over a DOM stub built
to the shape of the shipped rail. Four behavioural tests: `refresh` before
`mount` is a no-op, the first open mounts and does not refresh, later switches
refresh and do not re-mount, and a `refresh` reassigned inside `mount` is the
one called. A throwing `refresh` is still contained to the plugin's own panel.
The page end is pinned by source: the one call site and the ordering of
`wasLoaded` against the load branch.

The suite was run against an untouched `origin/main` worktree as a control: it
fails there, naming the missing export. Full `clanker gate` green, twelve of
twelve. Live: `clanker serve` returns the new host and app bytes, and the served
`health/app.js` no longer contains a `MutationObserver`.

## Follow-up

## References

- Investigation: none yet
