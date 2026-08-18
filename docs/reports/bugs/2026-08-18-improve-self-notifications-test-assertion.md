# Bug — improve-self staging tests fail on peers.notifications unreadable-log test

## TL;DR

- **What failed:** Commit 3b2f6c42 added the test `an unreadable log is an error, not an empty one` asserting `expectError(error.FileNotFound, ...)` against a directory standing in for an unreadable log. Reading a directory is not FileNotFound, so every improve-self staged tree failed the test and iterations 2 and 3 exhausted all attempts. Fixed by asserting store() returns a non-FileNotFound error; build, tools, test, fmt all pass.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-18. Fixed the test's wrong error expectation in src/peers/notifications.zig; verified with zig build, zig build tools, zig build test, and zig fmt --check all passing.

## Status

Resolved on 2026-08-18. Fixed the test's wrong error expectation in src/peers/notifications.zig; verified with zig build, zig build tools, zig build test, and zig fmt --check all passing.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Diagnose

`zig build test` fails with `error: 'peers.notifications.test.an unreadable log is an error, not an empty one' failed`. The test (added in 3b2f6c42 alongside the `store()` change that propagates non-`FileNotFound` read errors) creates a directory at `state/notifications.jsonl` to stand in for an unreadable log, then asserts `expectError(error.FileNotFound, store(...))`. Reading a directory is not `FileNotFound`, so `store()` correctly returns the directory-read error and the assertion fails.

Improve-self iterations 2 and 3 each exhausted all attempts because every staged tree failed this test. The repair attempts compounded it by introducing compile errors in their own staged patches (`error set is discarded` from `_ = err;`, and `unused local constant` from an unused `const result = store(...)`), which never landed.

## Fix

`src/peers/notifications.zig`: the test now asserts `store()` returns an error that is not `FileNotFound` (the store refuses rather than treating the unreadable log as empty), instead of pinning a specific wrong error code.

## Verify

- `zig build` ok
- `zig build tools` ok
- `zig build test` ok
- `zig fmt --check` ok