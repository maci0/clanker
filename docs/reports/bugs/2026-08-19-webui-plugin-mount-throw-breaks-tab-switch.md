# Bug — A throwing plugin mount broke the tab switch instead of showing a tab error

## TL;DR

- **What failed:** Both view loaders in ui/app/core/plugins.js called spec.mount (and spec.refresh) bare, so a plugin that throws while mounting rode its exception up through the tab switch and the page looked dead. PRD 0012's failure modes promise the tab stays and the panel names the plugin and the exception. runPluginHook now contains the throw to the plugin's own panel with a Retry that re-runs the loader.
- **Impact:** One broken third-party plugin made the whole page's tab switch throw; the panel stayed blank or half-rendered and the rest of the page looked dead.
- **Resolution:** Resolved on 2026-08-19. runPluginHook contains mount/refresh throws to the plugin's panel with Retry; verified behaviorally against both trees and pinned in webui-load.test.mjs

## Status

Resolved on 2026-08-19. runPluginHook contains mount/refresh throws to the plugin's panel with Retry; verified behaviorally against both trees and pinned in webui-load.test.mjs

## Symptom and impact

Opening the tab of a web UI plugin whose `mount` throws let the exception ride
up through `_viewLoaders[...]()` into the page's `showView`, breaking the tab
switch itself. PRD 0012's failure-mode table promises the opposite: "Tab still
appears; the view panel shows a tab error naming the plugin and the exception
message, instead of a blank panel or a broken page."

## Reproduction

Node harness (loader hook + DOM stub, ad hoc — see Verification): register a
spec whose `mount` throws, invoke its view loader the way `showView` does.
Unfixed (f9b80752's parent tree): the loader call itself throws
(`RESULT: THREW mount exploded`).

## Root cause

Both view-loader closures in `ui/app/core/plugins.js` — the deferred-shell
loader in `registerDeferredView` and the immediate one in
`clanker.registerView` — called `spec.mount.call(...)` and
`spec.refresh.call(...)` bare. `spec.boot` was already guarded with a
try/catch; the two hooks that run inside the tab switch were not.

## Resolution

`runPluginHook(section, label, retryFn, fn)`: try/catch around every mount and
refresh invocation in both loaders. On a throw it clears the panel and renders
`showLoadError` — "The <plugin> plugin failed: <message>" with a Retry that
resets the mounted flag and re-runs the loader — and returns null, so the tab
switch completes and the rest of the page stays alive.

## Verification

- Behavioral, via a node loader-hook + DOM-stub harness driving the real
  `plugins.js`: unfixed tree throws out of the loader; fixed tree returns
  null and records exactly one `showLoadError` call with
  "The Boom plugin failed: mount exploded". Control both ways.
- Pinned in-tree: `ui/app/webui-load.test.mjs` gained "a plugin's mount or
  refresh throw is contained to its own panel", asserting `runPluginHook`
  catches into `showLoadError` and that no bare `spec.mount.call` /
  `spec.refresh.call` survives outside the guard. Runs under `zig build test`
  with the other node UI tests.

## Follow-up

None.

## References

- PRD: docs/prds/0012-surface-plugins.md (Known issues, failure modes)
- Investigation: none — straight from the PRD's Known issues entry
