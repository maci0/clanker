# Bug — clanker janitor never prunes sub-run graphs

## TL;DR

- **What failed:** tools/zig/janitor.zig gates its run-graph sweep on isRunGraph, which requires the name to start with 'run-'. Nested runs are written to the same directory as 'sub-<unix nanoseconds>.json' (src/agent/subagent.zig), so they match neither isRunGraph nor removable: they are invisible to the newest-200 retention and cannot be deleted even when named. state/runs/ held 21 such files out of 208 on 2026-08-17, growing without bound.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-16. isRunGraph now delegates to graph_listing.isRunGraphName, which accepts run- and sub- ids alike by requiring a parsable timestamp; the same predicate gates collectOldest and removable. Verified by unit tests in graph_listing.zig, a full clanker gate, and a dry run that went from reporting nothing to reporting the 8 oldest of 208 graphs while keeping the newest.

## Status

Resolved on 2026-08-16. isRunGraph now delegates to graph_listing.isRunGraphName, which accepts run- and sub- ids alike by requiring a parsable timestamp; the same predicate gates collectOldest and removable. Verified by unit tests in graph_listing.zig, a full clanker gate, and a dry run that went from reporting nothing to reporting the 8 oldest of 208 graphs while keeping the newest.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence

`isRunGraph` in `tools/zig/janitor.zig` read:

    return std.mem.startsWith(u8, name, "run-") and std.mem.endsWith(u8, name, ".json");

It is the predicate for both halves of the sweep — `collectOldest` selects the
retention set with it, and `removable` re-checks each path before deleting — so
a nested run's graph was neither counted nor deletable.

    ls state/runs | grep -c '^sub-'   # 21
    ls state/runs | grep -c '^run-'   # 187

With 187 top-level graphs against `keep_runs = 200`, `collectOldest` returned
early and the sweep reported nothing, while the directory in fact held 208
graphs. The 21 sub-graphs were unreachable by `clanker janitor --yes` at any
size: naming one explicitly still failed `removable`.

## Resolution

The predicate moved to `graph_listing.isRunGraphName`, which accepts both id
shapes by asking `runOrderKey` for a parsable timestamp rather than matching a
prefix. That also tightens it: a hand-made `run-notes.json` is no longer swept,
which is right, because the retention order could not rank it anyway.

## Verification

Unit tests in `tools/zig/graph_listing.zig` cover both shapes and the
rejections. `clanker gate` passes.

Before the fix the dry run reported nothing. After it, on the same directory:

    clanker janitor

    138 KB reclaimable
      8 run graphs beyond the newest 200

208 graphs less the 200 kept is exactly the 8 reported. The 8 selected are the
8 oldest by start time (`run-1786460102` through `run-1786460982`, all
2026-08-11) and the newest three — `run-1786891336`, `run-1786920160`,
`run-1786920177` — are kept, confirming the sweep deletes from the old end of
the chronological order rather than the old end of the alphabet.

Nothing was deleted: `janitor` reports unless given `--yes`, and the sweep was
left for the operator to run.