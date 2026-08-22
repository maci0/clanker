# Bug — steerEnqueue delivers to the first matching slot only

## TL;DR

- **What failed:** POST /api/steer walks steer_slots and stops at the first slot whose goal OR session key matches (src/cli.zig steerEnqueue). Two concurrent runs registered for the same goal id mean only the first-found slot ever receives steering; the other run is silently unsteerable. A body naming both goal and session also matches on either key alone (OR, not AND), so a mismatched pair still enqueues. Found while adding webui steering visibility on 2026-08-22.
- **Impact:** A goal worked by two concurrent runs is steerable in only one of them, and the sender gets a 200 either way. A body naming a goal/session pair belonging to no single run still steered whichever run matched one half.
- **Resolution:** Resolved on 2026-08-22. steerEnqueue queues to every slot the named keys address and a named goal/session pair is an AND (steerKeysMatch, src/cli.zig); POST /api/steer answers {"ok":true,"delivered":N}. Registry test in src/cli.zig fails before the fix, clanker gate 10/10.

## Status

Resolved on 2026-08-22. steerEnqueue queues to every slot the named keys address and a named goal/session pair is an AND (steerKeysMatch, src/cli.zig); POST /api/steer answers {"ok":true,"delivered":N}. Registry test in src/cli.zig fails before the fix, clanker gate 10/10.

## Symptom and impact

Two things went wrong in the same loop.

A key can address more than one slot. `runRegister` keys a slot by goal id
and/or session id, and nothing makes a goal id unique across slots: a goal
resumed at serve startup (`resumeGoal` registers by goal alone) while a
browser streams the same goal registers twice. `steerEnqueue` returned on the
first slot it matched, so `POST /api/steer {"goal":g}` reached one of the two
runs and the other kept working uncorrected, with a 200 telling the sender it
had landed.

A pair of keys matched on either half. The match was `goal_hit or
session_hit`, so `{"goal":"g-1","session":"s-2"}` enqueued against a run
holding `g-1` with some other session — the body named a run that does not
exist and steered a different one. No web UI sender passes both keys today
(`ui/app/features/goals.js` sends `goal`, `ui/app/app.js` sends `session`),
so this half was reachable only by an API client.

## Reproduction

Unit-level, against the registry itself (`src/cli.zig`, test "steer registry:
a message reaches every run working the named key"): register two slots under
one goal id and different sessions, enqueue by goal, then poll each slot.
Before the fix the second slot polls empty.

## Root cause

`steerEnqueue` was written as a lookup — find the run, queue, return — when
the slot table it walks is a multimap: the key a caller names is not a
primary key. The `or` in the match compounded it by widening what each key
addresses instead of narrowing it.

## Resolution

Fixed. `steerKeysMatch` (`src/cli.zig`) now requires **every** key the caller
named to match, and a key the slot does not carry matches nothing, so a
half-right pair addresses no run rather than the wrong one; naming neither key
addresses nothing, so an empty body cannot broadcast. `steerEnqueue` walks the
whole table and queues one copy per addressed slot instead of returning at the
first, and reports `full`/`out_of_memory` only when no addressed run took the
message — one run accepting is a success even if a second was at its cap.

`steerEnqueue` returns `SteerOutcome { status, delivered }`, and
`POST /api/steer` answers `{"ok":true,"delivered":N}`. The old body was
`{"ok":true}`, which left the sender to assume exactly one run; both web UI
senders read only `error` on failure, so the extra field is additive.

## Verification

- `zig build test -Dtest-filter="steer"` — the new registry test fails before
  the fix (second slot polls empty) and passes after; `steerKeysMatch` has its
  own table test for the AND rule and for keys a slot does not carry.
- `clanker gate` 10/10 on the branch.
- Not exercised end-to-end: reproducing two concurrent runs on one goal over
  HTTP needs two live streaming connections, so the registry test is the
  assertion, not an e2e journey.

## Follow-up

- Still open and untouched here: non-streaming runs never register a slot at
  all (docs/reports/bugs/2026-08-22-nonstreaming-runs-unsteerable.md). A run
  that never registers is unaddressable no matter how the match is written.

## References

- Investigation: none yet
- docs/reports/bugs/2026-08-22-nonstreaming-runs-unsteerable.md — the other
  half of "steering silently goes nowhere".
