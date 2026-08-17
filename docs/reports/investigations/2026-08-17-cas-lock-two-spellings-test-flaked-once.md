# Investigation — The two-spellings CAS-lock test failed one run in three with lock_count 2

## TL;DR

- **Question:** One zig build test run failed 'two spellings share one lock' at expectEqual(1, lock_count); the same tree passed twice right after, no src/sandbox/ change between runs. tmpDir-scoped test, so the suspect is path resolution against process state, not lock litter. One occurrence; filed for the next gate that hits it.
- **Finding:** Resolved on 2026-08-17. Failing run compiled a peer session's mid-edit host.zig (test present, keying fix incomplete); consistent trees pass. Tree-moving-under-build, not a lock race
- **Resolution:** Resolved on 2026-08-17. Failing run compiled a peer session's mid-edit host.zig (test present, keying fix incomplete); consistent trees pass. Tree-moving-under-build, not a lock race

## Status

Resolved on 2026-08-17. Failing run compiled a peer session's mid-edit host.zig (test present, keying fix incomplete); consistent trees pass. Tree-moving-under-build, not a lock race

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
## Root cause

Not a race in the lock code: the test itself was another session's in-flight work. Session claude-20260817-133119-bf577103de46 was editing src/sandbox/host.zig at the time, adding resolvedLockKey and this very test (fix for docs/reports/bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md); the failing suite run compiled a mid-edit copy where the test existed but the keying fix was incomplete, and the two runs after compiled a consistent tree. This is the documented tree-moving-under-build shape from AGENTS.md, landing as an assertion failure rather than a build error because the mid-edit tree still compiled.