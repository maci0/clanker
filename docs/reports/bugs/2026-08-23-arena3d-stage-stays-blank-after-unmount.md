# Bug — The opt-in 3D arena stage is blank for good after one tab switch

## TL;DR

- **What failed:** ensure3d (ui/app/features/arena.js) returns early on `if (arena3d)`, but arena3d is the imported module object and unmountArena3D only nulls its scene state S. After stopArena - which app.js calls on visibilitychange and on leaving the view - re-entering takes the early return, mountArena3D is never called again, and updateArena3D no-ops on !S. The canvas is hidden by syncStageMode and #arena-stage3d is an empty div: no stage and no fallback message.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. ensure3d memoizes only the dynamic import; mountArena3D is called on every entry, which is safe because it opens with its own if (S) return.

## Status

Resolved on 2026-08-23. ensure3d memoizes only the dynamic import; mountArena3D is called on every entry, which is safe because it opens with its own if (S) return.

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

`ensure3d` (`ui/app/features/arena.js`) memoizes the *import* and nothing else:

```js
var loaded = arena3d
  ? Promise.resolve(arena3d)
  : import("/webui/plugins/arena3d/app.js").then(function (mod) { arena3d = mod; return mod; });
return loaded.then(function (mod) {
  var host = byId("arena-stage3d");
  return mod.mountArena3D(host).then(function () { return mod; });
}).catch(...)
```

The module is still fetched once. `mountArena3D` runs on every entry, which is
free when the stage is already up because it opens with `if (S) return
Promise.resolve()`.

One correction to Root cause above, checked rather than assumed: the `.catch`
was already chained on the whole promise, not on the import alone, so a *first*
visit whose mount threw did reach the 2D fallback and its message. What had no
message was every visit after a teardown, because the early return meant
nothing ran at all.

## Verification

`ui/app/features/arena.test.mjs`. `ensure3d` is not exported and importing
arena.js under node would drag in the whole `/webui` module graph, so the
function is lifted out of the shipped source and run in a `vm` over stubs, with
`import(` -- syntax, not a call -- rewritten to a counter the harness owns.

The pin mounts, tears down through `unmountArena3D`, and mounts again:
`imports` stays 1, `mounts` reaches 2, and the stub's scene state is live at
the end. Run against the code as it was, it fails on the second mount, which is
the blank stage. Two more tests cover the fallback (import failure and mount
failure both reach the status line and drop `mode3d`) and the plugin half of
the contract: `mountArena3D` keeps its `if (S) return` and `unmountArena3D`
keeps clearing `S`, since the fix depends on both.

## Follow-up

None.

## References

- Investigation: none yet
