# Bug — recent_commits test fails when a commit subject contains the two characters backslash-n

## TL;DR

- **What failed:** The test searches the raw JSON for the two-byte sequence backslash-n, which is meant to catch a trailing newline. A subject that literally mentions \n (improve-self commit 83784944) JSON-encodes as \\n and matches, so zig build test fails on a healthy tool.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-19. fixed in 1751becb: the test parses the tool JSON and asserts the text field holds no raw newline (src/sandbox/runtime.zig), so a subject quoting backslash-n no longer matches; status was left Open when the fix landed

## Status

Resolved on 2026-08-19. fixed in 1751becb: the test parses the tool JSON and asserts the text field holds no raw newline (src/sandbox/runtime.zig), so a subject quoting backslash-n no longer matches; status was left Open when the fix landed

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence

HEAD `83784944` subject contains the two characters backslash-n (`including \r and \n`). `lib.okText` JSON-encodes that as `\\n` in the serialized output. `std.mem.find(u8, out, "\\n")` matches the second backslash plus `n`. The tool itself already `trim`s real newlines from `git log` stdout. The improve-self gate dump blamed `recent_commits wasm tool summarizes git history` for this assertion.
## Root cause

The test searched the raw JSON for the two-byte sequence backslash-n, meant to catch a trailing newline in the serialized `text` field. A subject that literally mentions `\n` JSON-encodes as `\\n` and matches the same two bytes.

## Resolution

Parse the tool JSON and assert the `text` string contains no raw `'\n'`. The tool already trims git-log newlines.

## Verification

Host test `recent_commits wasm tool summarizes git history in one call` in `src/sandbox/runtime.zig`.