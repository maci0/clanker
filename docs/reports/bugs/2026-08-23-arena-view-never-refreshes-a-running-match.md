# Bug — The Arena view freezes on a running match: its poll skips every tick while the live stream is up

## TL;DR

- **What failed:** startPolling's interval opened with 'if (liveOk()) return;', copied from the Fleet floor where t:mesh really is published. Nothing publishes t:arena: Topic.arena exists in src/serve/live.zig and is in the default mask, but no publish(.arena, ...) call site does, and ck_publish stamps every guest event t:plugin. Importing arena.js opens the EventSource, so liveOk() was true from load and every tick returned early.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. The liveOk() early return is gone from startPolling's tick in ui/app/features/arena.js; the onLive hook stays as a documented no-op. Pinned by a cross-file test in arena.test.mjs that fails while arena.js gates on liveOk() and src/serve/live.zig has no publish(.arena) call. clanker gate green on eleven checks. Live: a real 3-round deepseek match went running rounds 1 -> 2 -> finished rounds 3 on GET /api/arena/<id> while GET /api/events carried nine t:metrics events and zero t:arena.

## Status

Resolved on 2026-08-23. The liveOk() early return is gone from startPolling's tick in ui/app/features/arena.js; the onLive hook stays as a documented no-op. Pinned by a cross-file test in arena.test.mjs that fails while arena.js gates on liveOk() and src/serve/live.zig has no publish(.arena) call. clanker gate green on eleven checks. Live: a real 3-round deepseek match went running rounds 1 -> 2 -> finished rounds 3 on GET /api/arena/<id> while GET /api/events carried nine t:metrics events and zero t:arena.

## Symptom and impact

Open the Arena view on a match that is still running in any browser with a
working `/api/events` stream, and the stage, the combatant chips, the HP
graph and the transcript stay on whatever the first fetch returned until the
operator refreshes the page by hand. `wasRunning` never flips either, so the
trash-compactor elimination sequence (PRD 0008 Phase 5) never plays.

PRD 0008 Phase 5 asks for "`GET /api/arena/<id>` polling only while the match
is running, stopped on verdict". The polling was started and stopped
correctly; the tick just never fetched.

## Reproduction

Start `clanker serve`, start a match, open `#arena/<id>`. The status line
and transcript stop moving. Equivalently, from a shell: watch
`GET /api/arena/<id>` change from `running` to `finished` while
`GET /api/events` carries nothing about the arena at all.

## Root cause

`startPolling` (`ui/app/features/arena.js`) opened its interval callback
with `if (liveOk()) return;` — the stream is up, so let the event carry it.
That is copied from the Fleet floor (`ui/app/features/fleet.js`), where it is
correct because `t:"mesh"` really is published.

Nothing publishes `t:"arena"`. `Topic.arena` exists in
`src/serve/live.zig` and is in the default subscriber mask, and
`?topics=arena` parses, but there is no `publish(.arena, ...)` call site
anywhere in `src/`; the only publishers are `.chat`, `.mesh`, `.run`,
`.metrics` and `.plugin`. A guest cannot produce one either: `ck_publish`
stamps every guest event `t:"plugin"` on purpose. So the companion
`onLive` handler's `ev.t !== "arena"` branch is unreachable.

And `onLive` itself calls `ensureLive`, which opens the `EventSource`. So
merely importing the module made `liveOk()` true, and the guard then held for
the life of the view.

## Resolution

The `liveOk()` early return is gone from the tick: the 1100 ms interval is
the only thing that can follow a running match, so it always fetches. The
`onLive` hook stays, with a comment naming why it is a standing no-op, so a
real publisher lands as a speed-up rather than a rewrite. Publishing the
topic properly is native work in `src/serve/` plus a way for the arena tool
to reach it, which is a bigger change than the frozen view needs.

## Verification

## Follow-up

## References

- Investigation: none yet
