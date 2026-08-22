# Bug — loadSessions folds every failure into an empty conversation list

## TL;DR

- **What failed:** `loadSessions()` in `ui/app/app.js` catches every fetch/JSON failure and renders an empty list.
- **Impact:** Sessions-module-off, an auth failure, or a dead server all present as "no conversations yet"; features gated on the list degrade with no signal that anything failed.
- **Resolution:** Resolved on 2026-08-22. The rail states a failed load with a retry, and a switched-off sessions module separately; readJson stamps the HTTP status so the two can be told apart. Verified by node --test ui/app/core/utils.test.mjs, a live serve with modules.sessions=false answering 404 "sessions module disabled", and a green clanker gate.

## Status

Resolved on 2026-08-22. The rail states a failed load with a retry, and a switched-off sessions module separately; readJson stamps the HTTP status so the two can be told apart. Verified by node --test ui/app/core/utils.test.mjs, a live serve with modules.sessions=false answering 404 "sessions module disabled", and a green clanker gate.

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

Fixed. `readJson` (`ui/app/core/utils.js`) now stamps the HTTP status onto the
error it throws, which is what separates the two shapes: the route answers a
switched-off module with `404 {"ok":false,"error":"sessions module disabled"}`
(`src/cli.zig`), and a fetch that never reached the server rejects with no
status at all. `classifyLoadFailure` in the same file turns an error into
`{kind, retry, message}` — `disabled` (settled, no retry) or `failed`
(retryable, carrying the server's own words, or "Could not reach the server."
when there were none).

`loadSessions()` stores that classification in `railFailure` and the rail's
`bind` renders it where the rows would have been: "Could not load
conversations: <reason>" with a Try again button that calls `loadSessions()`
again, or a plain "Conversation history is off (…)" for the disabled case. It
answers before the filter's own "No title matches" row, because that sentence
describes a list that loaded. The retryable kind is also written to
`el.sessionStatus` for a screen reader; the disabled kind is not, since it
would announce itself on every load.

Only `loadSessions` writes `railFailure`, so a re-render for a filter keystroke
or a pin toggle cannot clear a failure the page has not retried.

## Verification

- `node --test ui/app/core/utils.test.mjs` — seven new cases pin the status
  stamp (both the JSON and non-JSON body paths) and each classifier branch:
  disabled, a 404 that is not a disabled module, a 500, a `TypeError` from a
  fetch that never connected, and a null error.
- Live: `clanker serve --webui-port 18744` with `modules.sessions = false`
  answers `GET /api/sessions` with `404` and
  `{"ok":false,"error":"sessions module disabled"}` — the exact pair the
  `disabled` branch keys on (checked 2026-08-22).
- `clanker gate` — all gates pass.

## Follow-up

- PR #317 made the action buttons refresh-and-retry once and toast their outcomes, so a stale or empty list no longer silently dead-ends them; the rail's own state remains undifferentiated.

## References

- PR #317 — session actions: visible feedback and refresh-and-retry.
