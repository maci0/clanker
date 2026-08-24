# Bug — a mis-escaped trim set lets a whitespace-only hook command through, and the warn log then indexes an empty argv

## TL;DR

- **What failed:** src/hooks/config.zig trims with the plain literal " \\t\\r\\n", whose set is the five bytes space backslash t r n, not the four whitespace bytes. A command of a bare tab passes validation, splitCommand returns a zero-length argv, host refuses it as not_allowed, and src/hooks/runner.zig logs argv[0] on that empty slice. Contradicts PRD 0028's rule that a typo'd hook must not take the agent down. Same function rejects the whole hooks file for a command spelled nrt.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-24. Fixed in 1e8f01b8: the trim set is std.ascii.whitespace, so a bare-tab command is refused and a command spelled 'nrt' no longer fails the whole file; the runner's three warn lines name an argv0 local that is empty rather than indexing argv[0]; and a non-positive hook timeout is refused so timeout_ms can never reach the host's no-deadline reading. Verified by clanker gate (11/11 PASS) with three new unit tests.

## Status

Resolved on 2026-08-24. Fixed in 1e8f01b8: the trim set is std.ascii.whitespace, so a bare-tab command is refused and a command spelled 'nrt' no longer fails the whole file; the runner's three warn lines name an argv0 local that is empty rather than indexing argv[0]; and a non-positive hook timeout is refused so timeout_ms can never reach the host's no-deadline reading. Verified by clanker gate (11/11 PASS) with three new unit tests.

## Symptom and impact

`src/hooks/config.zig` validates a hook command with a trim set written as a
plain Zig string literal containing backslash-t and friends, so the set is the
five bytes `{space, backslash, t, r, n}` rather than the four whitespace bytes
it reads as. Two consequences, opposite directions:

- A command that is a real tab or newline is **not** rejected.
  `runner.splitCommand` skips spaces and tabs, so it returns a zero-length
  argv. `host.execUnderPolicyInput` correctly guards that and answers
  `.not_allowed` — and the caller's warn log then formats `argv[0]` on the
  empty slice. Index-out-of-bounds panic in Debug, a garbage pointer in
  ReleaseFast. Three lines in `runner.zig` read `argv[0]` this way.
- A command spelled out of those five bytes — `nrt`, `rn`, `tt` — trims to
  empty and is rejected, and the rejection fails the whole `hooks.json`, so one
  such entry disables every hook for the run.

PRD 0028's failure table says a typo'd hooks path must not take the agent down.

## Reproduction

```json
{"hooks": [{"event": "PreToolUse", "command": "\t"}]}
```

with `[hooks] enabled = true`. The first `PreToolUse` panics.

## Root cause

A missing `\\` in a Zig string literal, in a validation function whose whole job
is to keep an empty argv out of the runner.

## Resolution

Open. Two independent fixes, both wanted: escape the trim set correctly (or use
`std.ascii.whitespace`), and make `runner.zig`'s three log lines tolerate an
empty argv rather than trusting the validator upstream. A guard that a panic
depends on should not be a string literal a typo can silently widen.

While there: `"timeout": 0` in `hooks.json` passes validation and `host` reads
`timeout_ms == 0` as *no* deadline, so such a hook blocks the turn forever —
against the same PRD's "hook exceeds its timeout → killed". Either reject 0 or
fall back to `default_timeout_ms`.

## Verification

Needs a test with a whitespace-only command that asserts a warn rather than a
panic, and one with `"timeout": 0` that asserts a bounded wait.

## Follow-up

The five lifecycle wiring points themselves were audited and are correct: all
reachable, at the documented sites, in the documented order (plan mode, then
hooks, then `confirm_fn`), with exit-2-denies and the most-restrictive fold over
nested results.

## References

- PRD: [0028-hooks-bridge.md](../../prds/0028-hooks-bridge.md)
- Code: `src/hooks/config.zig` (command validation, timeout validation),
  `src/hooks/runner.zig` (`splitCommand`, the `argv[0]` log lines),
  `src/sandbox/host.zig` (`execUnderPolicyInput`, the `timeout_ms == 0` read)
