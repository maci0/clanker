# Bug — Runs filter's 'failed' keyword throws a TypeError and could never match

## TL;DR

- **What failed:** ui/app/app.js runFailed reads (r.nodes||[]).some(...), which assumes the node array of a whole graph. GET /api/runs sends 'nodes' as a count, so the expression is (4).some and throws TypeError on the first run with any nodes. Typing 'failed' in the Runs filter therefore kills renderRunOptions. Even guarded it can never match: the listing carries no ok or failed field, so no run in it is ever failed.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-16. One runFailed in ui/app/lib/runs-list.js that accepts a node array or a node count, imported by app.js; and the listing now carries the signal it lacked, as a GraphFile.failed scalar stamped by graph_listing.anyNodeFailed and emitted by listRunsJson. Verified by node --test on runs-list.test.mjs, unit tests on anyNodeFailed, clanker gate, and GET /api/runs now returning failed on every entry.

## Status

Resolved on 2026-08-16. One runFailed in ui/app/lib/runs-list.js that accepts a node array or a node count, imported by app.js; and the listing now carries the signal it lacked, as a GraphFile.failed scalar stamped by graph_listing.anyNodeFailed and emitted by listRunsJson. Verified by node --test on runs-list.test.mjs, unit tests on anyNodeFailed, clanker gate, and GET /api/runs now returning failed on every entry.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence

`ui/app/app.js` defined:

    function runFailed(r){ return r && (r.failed === true || r.ok === false || (r.nodes||[]).some(function(n){ return n.ok===false; })); }

`nodes` is an array on a whole graph (`GET /api/runs/<id>`) but a count on a
listing entry (`GET /api/runs`), and `renderRunOptions` called it with the
listing. Reproduced against a real listing entry:

    node -e 'function runFailed(r){ return r && (r.failed === true || r.ok === false || (r.nodes||[]).some(function(n){ return n.ok===false; })); }
    try { runFailed({ run_id: "run-1786920177", nodes: 4 }); } catch (e) { console.log(e.message); }'

    (r.nodes || []).some is not a function

Only a run with zero nodes escaped it, because `0 || []` is the empty array.
Typing `failed` in the Runs filter therefore threw inside `renderRunOptions`.

Second defect behind the first: the listing carried no failure signal at all —
`listRunsJson` emitted `run_id`, `parent_run_id`, `task`, `provider`,
`duration_ms`, `nodes` and the two token counts. Guarding the type would have
turned a crash into a filter that silently matched nothing.

## Resolution

One predicate, in `ui/app/lib/runs-list.js`, which accepts either shape:
`Array.isArray(run.nodes)` before `.some`. `app.js` imports it and no longer
defines its own.

The missing signal is now recorded. `GraphFile` gains `failed`, stamped at
write time by `graph_listing.anyNodeFailed` and placed with the other listing
scalars in front of `task` so it survives the 4 KiB prefix read, and
`listRunsJson` emits it. Failure means a `check` node with a failing verdict —
the agent loop records one per tool declared `check: true` — so a run with no
check node reads as unjudged, not failed. Graphs written before the field read
`false`.

## Verification

`node --test ui/app/lib/runs-list.test.mjs` covers both node shapes and the
`failed` keyword; a test asserts `app.js` no longer defines a second copy.
Unit tests in `graph_listing.zig` cover `anyNodeFailed`, including a
prefix-truncated graph where only the scalar survives. `clanker gate` passes.

Live, after `zig build tools`:

    curl -s http://127.0.0.1:17921/api/runs | python3 -c "import json,sys; print(all('failed' in r for r in json.load(sys.stdin)))"

    True