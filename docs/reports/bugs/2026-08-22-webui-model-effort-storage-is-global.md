# Bug — webui model and effort choices are stored browser-global, not per chat

## TL;DR

- **What failed:** The composer's provider/model choice (`localStorage["clanker.model"]`) and reasoning effort (`localStorage["clanker.effort"]`) are single browser-global keys, shared by every conversation and every open tab.
- **Impact:** Switching the model or effort in one chat silently changes what every other chat and tab sends on its next message; nothing announces it.
- **Resolution:** Open (the misleading copy is fixed; the scope itself is unchanged).

## Status

Open.

## Symptom and impact

`ui/app/core/modelpicker.js` mirrors the hidden `#model-select` into `clanker.model` on every change and restores it at boot; `#param-effort` does the same with `clanker.effort`. Both keys are unscoped. Open two tabs on two conversations, change the model in one, send in the other after a reload: the second conversation now runs on the first tab's choice.

Until PR #315 the Advanced fold's tooltip claimed the effort was "pinned for this chat", which it never was; the copy now says the value is sent with each new message.

## Reproduction

1. Open the chat, pick model A, send a message.
2. In a second tab, open a different conversation and reload; the picker shows model A.
3. Change to model B in tab two; reload tab one — it now shows and sends model B.

## Root cause

The selects were designed as browser preferences, and per-chat wording was added later without per-chat storage. Nothing in the session store persists a conversation's model/effort (deliberate for the wire, which is per-request).

## Resolution

Open. If per-chat pinning is wanted, key the stored value off the session id, or persist it in the session record server-side; if browser-global is the intended scope, the UI should say so where the value is set.

## Verification

Pending the chosen design.

## Follow-up

- Decide the intended scope before touching storage; the wire protocol (per-request override on `POST /api/run`) is correct either way and verified end to end on 2026-08-22.

## References

- PR #315 — copy fix and per-turn model/effort visibility in the turn footer.
