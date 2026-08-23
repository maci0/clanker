# Bug — The opt-in 3D arena stage is blank for good after one tab switch

## TL;DR

- **What failed:** ensure3d (ui/app/features/arena.js) returns early on `if (arena3d)`, but arena3d is the imported module object and unmountArena3D only nulls its scene state S. After stopArena - which app.js calls on visibilitychange and on leaving the view - re-entering takes the early return, mountArena3D is never called again, and updateArena3D no-ops on !S. The canvas is hidden by syncStageMode and #arena-stage3d is an empty div: no stage and no fallback message.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

`ui/app/features/arena.js`:

```js
function ensure3d() {
  if (arena3d) return Promise.resolve(arena3d);
  return import("/webui/plugins/arena3d/app.js").then(function (mod) {
    arena3d = mod;
    var host = byId("arena-stage3d");
    return mod.mountArena3D(host).then(function () { return mod; });
  })
```

`unmountArena3D` (`ui/plugins/arena3d/app.js`) sets `S = null` and removes the
renderer's DOM node, but leaves the module object truthy. So the memo short
circuits and `mountArena3D` is never called a second time; `updateArena3D`
then returns on `if (!S || !m)`.

Triggers, none exotic: `stopArena()` runs on `visibilitychange` when the tab
hides and on navigating out of the view, and `toggle3d()` off then on is the
same path. The `.catch` that falls back to the 2D stage is on the *import*,
not the mount, so there is no message either - `#arena-canvas` is `hidden` by
`syncStageMode` and `#arena-stage3d` is empty.

`mountArena3D` already opens with `if (S) return Promise.resolve()`, so it is
idempotent: the fix is to call it outside the import's `.then` every time.

Suggested pin: a stub module recording `mountArena3D`/`unmountArena3D` calls;
toggle on, `stopArena()`, toggle on again, assert `mountArena3D` was called
twice. Decorative only - the transcript, chips and status line are
unaffected.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
