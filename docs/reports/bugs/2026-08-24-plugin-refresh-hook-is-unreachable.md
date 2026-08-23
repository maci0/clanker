# Bug — A plugin's refresh hook is documented as the re-entry point but the host never calls a view loader twice

## TL;DR

- **What failed:** ui/app/core/plugins.js builds a loader that calls spec.mount once and spec.refresh on every later call. But showView (ui/app/app.js) only invokes viewLoaders[name] under if (!viewLoaded[name]), and viewLoaded[name] is never reset once set. So refresh is reachable only from runPluginHook's Retry path. PRD 0012 documents refresh? as part of the registration API without saying so, and mesh's own comment claims refresh covers re-entry. health and office each bolt on a MutationObserver instead.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

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

## Verification

## Follow-up

## References

- Investigation: none yet
