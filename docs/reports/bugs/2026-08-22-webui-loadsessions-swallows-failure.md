# Bug — loadSessions folds every failure into an empty conversation list

## TL;DR

- **What failed:** `loadSessions()` in `ui/app/app.js` catches every fetch/JSON failure and renders an empty list.
- **Impact:** Sessions-module-off, an auth failure, or a dead server all present as "no conversations yet"; features gated on the list degrade with no signal that anything failed.
- **Resolution:** Open (mitigated for the session action buttons by PR #317).

## Status

Open.

## Symptom and impact

```js
function loadSessions() {
  return fetch("/api/sessions")
    .then(readJson)
    .then(function (data) { renderSessionOptions(data.sessions || []); })
    .catch(function () { renderSessionOptions([]); });
}
```

A failed `GET /api/sessions` and a genuinely empty history are indistinguishable in the rail. Before 2026-08-22 the session action buttons (Archive, Delete, Rename) gated on this list and early-returned into a visually hidden status node, so one swallowed failure made all of them look dead — the shape of the "archive and delete buttons don't work" report.

## Reproduction

Stop the server (or set `modules.sessions = false`) and load the page: the rail shows the empty state, not an error.

## Root cause

The catch exists because sessions may legitimately be disabled, but it treats every other failure the same way.

## Resolution

Open. Distinguish "module disabled" (the route answers with a clear error) from transport failure, and give the rail a visible failed state with a retry, the way other views use `showLoadError`.

## Verification

Pending: with the server stopped, the rail should show a retry affordance rather than the empty state.

## Follow-up

- PR #317 made the action buttons refresh-and-retry once and toast their outcomes, so a stale or empty list no longer silently dead-ends them; the rail's own state remains undifferentiated.

## References

- PR #317 — session actions: visible feedback and refresh-and-retry.
