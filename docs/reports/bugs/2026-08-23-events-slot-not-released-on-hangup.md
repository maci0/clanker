# Bug — A hung-up /api/events subscriber does not release its in-flight slot on macOS

## TL;DR

- **What failed:** tests/e2e/live_sse_test.zig:145 fails: after a subscriber connects to /api/events and hangs up without the server ever writing to it, the in-flight count reads 2 where the test expects the pre-connect 1. The slot is held by a socket nobody is on, and enough of them would exhaust the subscriber cap. 1 of 38 e2e journeys on aarch64-macos. Not caused by the pty-harness work it was found under: it failed identically when the only diff from origin/main was pty allocation constants.
- **Impact:** Unquantified. A leaked slot per abandoned subscriber would eventually exhaust the cap and refuse new `/api/events` connections, but nothing here measures whether that is reachable in practice or how many slots exist. Reported at the strength it was observed: one assertion, off by one.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

```
error: 'live_sse_test.test.a hung-up /api/events subscriber releases its slot
        without waiting for a write' failed:
       expected 1, found 2
       tests/e2e/live_sse_test.zig:145
           try std.testing.expectEqual(before, try inFlight(after_body));
```

`before` is the in-flight subscriber count taken before the test connects.
After connecting and hanging up without the server having written anything, the
count is one higher than it started, so the slot was never released.

## Reproduction

`zig build e2e -Dtest-filter="hung-up"` on aarch64-macos. 1 of 38 journeys;
the other 37 pass.

## Root cause

Not investigated. Filed on the assertion alone.

What *is* established is that it is not caused by the change it was found
under. It failed identically in a tree whose only difference from
`origin/main` was the pty allocation constants in `tests/e2e/pty.zig` -- a file
this test does not import. The caveat worth stating: `origin/main` itself could
not compile `zig build e2e` on macOS at all before that change, so there is no
true untouched-base measurement of this test on this platform, and "pre-existing"
here means "independent of the diff", not "verified against a green base".

Whether it also fails on Linux is unknown and unchecked.

## Resolution

Open. Not mine to fix -- found while making the e2e suite compile on macOS,
and it is in the serve/SSE surface, not the pty harness.

## Verification

None.

## Follow-up

Someone with the serve surface should check whether the leak is real or the
assertion is racing the server's own cleanup: the test reads the count
immediately after the hang-up, and "released eventually" would look identical
to "never released" at that instant.

## References

- `docs/reports/bugs/2026-08-23-e2e-pty-harness-is-linux-only.md` -- the change
  that made this test runnable here at all.
- Investigation: none yet
