# Investigation — The two-spellings CAS-lock test failed one run in three with lock_count 2

## TL;DR

- **Question:** One zig build test run failed 'two spellings share one lock' at expectEqual(1, lock_count); the same tree passed twice right after, no src/sandbox/ change between runs. tmpDir-scoped test, so the suspect is path resolution against process state, not lock litter. One occurrence; filed for the next gate that hits it.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Evidence

- Failing run: zig build test at ts_ms 1786972893479, error: 'sandbox.host.test.a CAS lock is keyed by the resolved target, so two spellings share one lock' failed at src/sandbox/host.zig's expectEqual(@as(usize, 1), lock_count) — two lock files where one was expected.
- Passing runs: the next two zig build test invocations on the identical tree (no edits under src/sandbox/ between any of the three; the only edits were src/tui/repl.zig help text).
- The test builds both sandboxes over one std.testing.tmpDir and counts <tmp>/state/locks entries, so operator lock litter cannot reach it. The relative sandbox is rooted at "." though — if lock keying ever resolves that root against the process CWD rather than the passed tmp dir handle, two spellings resolve to two targets and the count is 2. Concurrent test binaries share one CWD.

## Next step when it recurs

Capture the two lock file names (each embeds target=) from the failing run before cleanup; they name the two resolutions directly.