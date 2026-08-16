# Investigation — Web UI run history is stale because graph listings sort filenames lexically

## TL;DR

- **Question:** state/runs holds run-<unix seconds> and sub-<unix nanoseconds> graphs. tools/zig/graph.zig sorts raw filenames with std.mem.lessThan and takes the tail as the newest page, but 's' > 'r', so every sub-* sorts after every run-*. GET /api/runs returns 21 Aug-12 sub-runs first, so the System history panel (runs.slice(0,8)) and the Runs picker default both show Aug-12 sub-runs. janitor.zig sorts the same way.
- **Finding:** Resolved on 2026-08-16. graph_listing.lessThanChronological orders run-<s> and sub-<ns> ids on the timestamp instead of the filename; wired into both listings and the most-recent pick in tools/zig/graph.zig and into tools/zig/janitor.zig's retention sort. Verified by unit tests in graph_listing.zig, a full clanker gate in a worktree at HEAD, and GET /api/runs now returning today's runs first.
- **Resolution:** Resolved on 2026-08-16. graph_listing.lessThanChronological orders run-<s> and sub-<ns> ids on the timestamp instead of the filename; wired into both listings and the most-recent pick in tools/zig/graph.zig and into tools/zig/janitor.zig's retention sort. Verified by unit tests in graph_listing.zig, a full clanker gate in a worktree at HEAD, and GET /api/runs now returning today's runs first.

## Status

Resolved on 2026-08-16. graph_listing.lessThanChronological orders run-<s> and sub-<ns> ids on the timestamp instead of the filename; wired into both listings and the most-recent pick in tools/zig/graph.zig and into tools/zig/janitor.zig's retention sort. Verified by unit tests in graph_listing.zig, a full clanker gate in a worktree at HEAD, and GET /api/runs now returning today's runs first.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Evidence

The store itself is current. `state/runs/` had 208 graphs, the newest written
eight minutes before the investigation started, and `/api/sessions` and
`/api/stats` both returned today's data — only the run listings looked frozen.

    ls -lt --time-style=full-iso state/runs | head -3
    curl -s http://127.0.0.1:17921/api/runs | python3 -c "import json,sys; d=json.load(sys.stdin); print([r['run_id'] for r in d[:8]])"

The listing returned 21 `sub-*` ids before the first `run-*` id. Two ids, two
clocks: `src/agent/subagent.zig:98` names a nested run `sub-<unix nanoseconds>`
(several sub-agents can start inside one second), while a top-level run is
`run-<unix seconds>`. `tools/zig/graph.zig` ordered the raw filenames with
`std.mem.lessThan` and took the tail as the newest page, and `'s' > 'r'`, so
every sub-run outranked every top-level run regardless of when it ran.

Two surfaces read that order directly, which is why it looked like staleness
rather than a sorting glitch: `ui/app/app.js:5858` renders `runs.slice(0, 8)`
as the System view's history panel, and `renderRunOptions` makes entry 0 the
Runs picker's default selection. Both landed on 2026-08-12 sub-runs, whose
`task` is empty, so nothing on screen dated itself.

## Resolution

`graph_listing.runOrderKey` reads the digits after `run-`/`sub-` and pads them
to nanosecond width, and `lessThanChronological` orders on that, falling back
to name order for a name of neither shape. Both listings in `graph.zig`
(`list` and `json`) and the no-argument "most recent run" pick now use it.
`tools/zig/janitor.zig` sorts with it too: its `collectOldest` deletes the
front of that order, and while its `isRunGraph` predicate matches only
`run-*.json` today, a name sort also mis-ranks `run-` ids of differing digit
width against each other.

## Verification

`clanker gate` passes (build, test, tools, fmt, lint, provider-kind,
tools-ts-toolchain, release-contract), run in a worktree detached at HEAD with
only the three tool files applied, because an unrelated concurrent edit to
`src/main.zig` in the shared checkout did not compile at the time.

Unit tests in `tools/zig/graph_listing.zig` pin both directions: a name sort
collects the `sub-` ids at the tail, and the chronological sort interleaves
them (the sub-run at 1786471458 does start before the run at 1786561572).

End to end, against the running `clanker serve` with no restart — the guest is
loaded from disk per call, so `zig build tools` was enough:

    curl -s http://127.0.0.1:17921/api/runs | python3 -c "import json,sys; d=json.load(sys.stdin); print([r['run_id'] for r in d[:3]])"

The first three entries are now the runs recorded today, and the 10 `sub-*`
entries on the page sit at indices 25 and beyond, interleaved by start time.