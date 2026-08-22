# Bug — webui model and effort choices are stored browser-global, not per chat

## TL;DR

- **What failed:** The composer's provider/model choice (`localStorage["clanker.model"]`) and reasoning effort (`localStorage["clanker.effort"]`) are single browser-global keys, shared by every conversation and every open tab.
- **Impact:** Switching the model or effort in one chat silently changes what every other chat and tab sends on its next message; nothing announces it.
- **Resolution:** Resolved on 2026-08-22. Per-chat pinning: new ui/app/core/chatprefs.js stores one model/effort pin per session id (bounded like the drafts store), clanker.model/clanker.effort demoted to the default a new chat starts from; picker and app.js wired, first turn pins what it ran on, fork carries and delete drops. 14 node tests, gate 10/10, asset served live.

## Status

Resolved on 2026-08-22. Per-chat pinning: new ui/app/core/chatprefs.js stores one model/effort pin per session id (bounded like the drafts store), clanker.model/clanker.effort demoted to the default a new chat starts from; picker and app.js wired, first turn pins what it ran on, fork carries and delete drops. 14 node tests, gate 10/10, asset served live.

## Symptom and impact

`ui/app/core/modelpicker.js` mirrors the hidden `#model-select` into `clanker.model` on every change and restores it at boot; `#param-effort` does the same with `clanker.effort`. Both keys are unscoped. Open two tabs on two conversations, change the model in one, send in the other after a reload: the second conversation now runs on the first tab's choice.

Until PR #315 the Advanced fold's tooltip claimed the effort was "pinned for this chat", which it never was; the copy was changed to say only that the value is sent with each new message. With the store below it is true again, and the fold summary and idle hint say "pinned for this conversation" once more.

## Reproduction

1. Open the chat, pick model A, send a message.
2. In a second tab, open a different conversation and reload; the picker shows model A.
3. Change to model B in tab two; reload tab one — it now shows and sends model B.

## Root cause

The selects were designed as browser preferences, and per-chat wording was added later without per-chat storage. Nothing in the session store persists a conversation's model/effort (deliberate for the wire, which is per-request).

## Resolution

Per-chat pinning, keyed off the session id in a second localStorage store, with
the two global keys demoted to the default a *new* chat starts from. The scope
question the follow-up parked is answered that way because the surface already
said so: the effort select's own title reads "Pin this chat's reasoning
effort", and per-chat is the reading a conversation's history supports (what it
ran on is part of what it is), while a browser preference is the right shape
only for a chat that has no history yet.

- `ui/app/core/chatprefs.js` (new) owns the store: one entry per session id
  under `clanker.chatprefs`, `at` stamped on every touch and the
  `max_prefs` (50) most recently touched kept, the same shape and bound as
  `drafts` in `core/composer.js`. `effectiveModel`/`effectiveEffort`
  are the precedence rule itself: the pin when there is one, the browser
  default otherwise.
- `ui/app/core/modelpicker.js` writes both on every change — the pin so this
  conversation keeps the value, `clanker.model`/`clanker.effort` so the next
  new chat opens on what you last chose — and restores through
  `effectiveModel`/`effectiveEffort` instead of reading the global key
  directly. New export `applyChatPrefs()` puts a conversation's values back on
  the shared selects.
- `ui/app/app.js` owns the session id, so it supplies the picker's
  `chatPrefs: { get, set }` hooks and calls `applyChatPrefs()` on every
  switch, new chat and delete. A fork, branch or import carries the pin onto
  the new id (`chatPrefsCarry`); a delete drops it (`chatPrefsDrop`); and a
  conversation with no pin is pinned by its first turn
  (`chatPrefsPinFirstTurn`), so history keeps what it ran on rather than
  following a model chosen later in another tab. `applyChatPrefs()`
  deliberately does not dispatch a `change` event: that would re-write the
  browser default and re-open the leak.
- A new `ui/app/**` module is two lockstep registrations, both done:
  `@embedFile` + comptime size entry + `assetFor` route in `ui/webui.zig`,
  and `Kind` tag + `kindFor` suffix + `asset_paths` entry in
  `src/serve/webui_assets.zig`.

An empty chat that was never touched still follows the browser default, which
is what a new conversation is for.

## Verification

`ui/app/core/chatprefs.test.mjs` (14 tests, node --test) drives the store and
the precedence rule: two conversations keep separate pins, an untouched one has
none and falls back, a field cleared unpins only that field, the store evicts
oldest-touched past `max_prefs`, a delete drops the pin and a fork copies it
without linking the two. Three of the tests read the shipped
`modelpicker.js`/`app.js` sources, because a store nothing calls would pass
every behavioral test above and change nothing: they pin that both model-change
paths and the effort path record the pin, that no bare
`setItem("clanker.model"/"clanker.effort")` write is left, that restore
goes through `effectiveModel`/`effectiveEffort`, and that app.js binds the
hooks and carries/drops/re-applies the pin across the session lifecycle.

Written failing first: with only the test file present the run failed on the
missing module, and each wiring assertion was checked against the pre-change
sources.

`clanker gate` 10/10 PASS in the worktree, and the per-file
`node --test` sweep over `ui/app` passes (the directory invocation is a
separate known failure, docs/reports/bugs/2026-08-22-node-test-dir-mode-fails-on-ui-app.md).
Served live from a worktree `clanker serve`: `GET /webui/core/chatprefs.js`
answers 200 with the module, and the served `core/modelpicker.js` imports it —
the two asset registrations are what that checks.

## Follow-up

- The pin is browser-local, not server-side: the same conversation opened in a
  different browser follows that browser's default until it is touched there.
  Persisting it in the session record is the next step if that matters; the
  wire protocol (per-request override on `POST /api/run`) is correct either
  way and was verified end to end on 2026-08-22.

## References

- PR #315 — copy fix and per-turn model/effort visibility in the turn footer.
