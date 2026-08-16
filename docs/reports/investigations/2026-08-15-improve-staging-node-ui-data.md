# Investigation — Improve staging omits node UI-test data roots

## TL;DR

- **Question:** Improve-self iterations 1 and 2 exhaust all attempts: every UI proposal fails staging with node --test exit code 1 on ui/app/core/{theme,layout,slash}.test.mjs because the staging tree omits repo-root themes/ and commands/ data those suites read.
- **Finding:** Resolved on 2026-08-16. Added themes/ and commands/ to readable_roots so the staging copy includes the repo-root data the node UI-test suites read; verified by zig build/test/fmt and read-but-not-write tests.
- **Resolution:** Resolved on 2026-08-16. Added themes/ and commands/ to readable_roots so the staging copy includes the repo-root data the node UI-test suites read; verified by zig build/test/fmt and read-but-not-write tests.

## Status

Resolved on 2026-08-16. Added themes/ and commands/ to readable_roots so the staging copy includes the repo-root data the node UI-test suites read; verified by zig build/test/fmt and read-but-not-write tests.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## TL;DR

The `ui/app/core/*.test.mjs` suites run under `node --test` during improve-self's
staging tests and read repo-root data relative to their own directory:
`themes/*.json` and `commands/slash.json`. Those roots were absent from
`readable_roots` in `src/improve/proposal.zig`, so `prepareStaging` copied the
stage without them and *every* UI proposal failed with:

```
test +- run node failure error: process exited with error code 1
failed command: node --test <staging>/ui/app/core/theme.test.mjs
```

iterations 1 and 2 each burned all attempts on this, unrelated to the proposal
being judged.

## Root cause

- `theme.test.mjs` line 12: `themesDir = join(here, "..", "..", "..", "themes")`
- `layout.test.mjs`: same `../../..` up to repo-root data
- `slash.test.mjs` line 8: reads `../../.. /commands/slash.json`

Because `themes/` and `commands/` were not in `readable_roots`, the staging
copy omitted them and every `node --test` suite that walked repo-root data
died with exit code 1.

## Fix

Added `"themes/"` and `"commands/"` to `readable_roots` in
`src/improve/proposal.zig`. They are read + staged automatically (the staging
list derives from `readable_roots`) but are deliberately absent from
`allowed_prefixes`, so the improve loop can judge UI work against the real
data without being able to patch it. Tests assert the read-but-not-write
boundary (`validateReadPath` true, `validatePath` false) for
`themes/dark.json` and `commands/slash.json`.

## Verification

`zig build`, `zig build test`, and fmt all pass. No proposal regression: the
added roots only widen the readable/staged surface.

## Notes

The config errors in the same log (`agent.repeat_tool_thresholds`, `config.toml:10
agent.max_iterations = "many"`, `config.local.toml:3 ttsr pattern = 7`,
`temperature 3`, "no providers defined") are *expected* output from
`src/config.zig`'s own test block, which deliberately loads invalid configs to
assert their error messages. They are not real configuration problems and need
no fix.
