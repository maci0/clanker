# Bug — A hung-up /api/events subscriber does not release its in-flight slot on macOS

## TL;DR

- **What failed:** tests/e2e/live_sse_test.zig:145 fails: after a subscriber connects to /api/events and hangs up without the server ever writing to it, the in-flight count reads 2 where the test expects the pre-connect 1. The slot is held by a socket nobody is on, and enough of them would exhaust the subscriber cap. 1 of 38 e2e journeys on aarch64-macos. Not caused by the pty-harness work it was found under: it failed identically when the only diff from origin/main was pty allocation constants.
- **Impact:** Unquantified. A leaked slot per abandoned subscriber would eventually exhaust the cap and refuse new `/api/events` connections, but nothing here measures whether that is reachable in practice or how many slots exist. Reported at the strength it was observed: one assertion, off by one.
- **Resolution:** Resolved on 2026-08-23. idleTickSawHangup polled for POLLRDHUP alone, which is 0 on macOS, so the pollfd requested no event and the tick was a sleep that never saw the hangup. Now polls POLLRDHUP|POLLIN and tells EOF from inbound bytes with a zero-length MSG_PEEK. Three unit tests (two fail pre-fix), the e2e hung-up journey goes 1/1 (expected-1-found-2 with the change reverted), and five live subscribers against a real serve released all five slots in 600ms with errors_total 0. Gate: all eleven PASS.

## Status

Resolved on 2026-08-23. idleTickSawHangup polled for POLLRDHUP alone, which is 0 on macOS, so the pollfd requested no event and the tick was a sleep that never saw the hangup. Now polls POLLRDHUP|POLLIN and tells EOF from inbound bytes with a zero-length MSG_PEEK. Three unit tests (two fail pre-fix), the e2e hung-up journey goes 1/1 (expected-1-found-2 with the change reverted), and five live subscribers against a real serve released all five slots in 600ms with errors_total 0. Gate: all eleven PASS.

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

Real leak, not a race with the server's own cleanup.

`idleTickSawHangup` in `src/serve/live.zig` polled for `poll_hangup` and
nothing else. `poll_hangup` resolves to `std.posix.POLL.RDHUP` where libc
carries it, 0x2000 on Linux, and **0 everywhere else** -- so on macOS the
pollfd requested no event at all. `poll` then behaved as a 50ms sleep that
always returned 0, the tick answered "still there" for a socket nobody was on,
and `serveSse` kept looping until the 15s keepalive ping's write failed. That
is what held the slot and the connection thread, and it is why the count read
one high 600ms after the hangup.

Measured directly on aarch64-macos, a stream socket whose peer has fully
closed:

```
events=0      -> ready=0 revents=0x0
events=POLLIN -> ready=1 revents=0x11   (POLLIN|POLLHUP)
MSG_PEEK      -> n=0
```

So macOS does report `POLLHUP` on this socket -- but only to a caller that
asked for some event. `POLLHUP` on its own is still not enough in general: it
wants both halves shut and the server's half stays open, which is exactly the
half-close case, and there the zero-length peek is the only signal.

What *is* established is that it is not caused by the change it was found
under. It failed identically in a tree whose only difference from
`origin/main` was the pty allocation constants in `tests/e2e/pty.zig` -- a file
this test does not import. The caveat worth stating: `origin/main` itself could
not compile `zig build e2e` on macOS at all before that change, so there is no
true untouched-base measurement of this test on this platform, and "pre-existing"
here means "independent of the diff", not "verified against a green base".

Whether it also fails on Linux is unknown and unchecked.

## Resolution

Fixed. `idleTickSawHangup` now requests `poll_hangup | POLL.IN`, treats any
of `poll_dead` as gone, and for a readable socket with no hangup flag tells
EOF from inbound bytes with a zero-length `MSG_PEEK`. Bytes that are not EOF
are paced on the clock, because a readable edge makes `poll` return at once
and the tick would otherwise spin.

## Verification

Three levels, all on aarch64-macos.

- Unit, in `src/serve/live.zig`: `the idle tick sees a subscriber that hung
  up, and leaves a live one alone`, `the idle tick sees a subscriber that shut
  only its write half`, and `a subscriber that sends bytes is not mistaken for
  one that left`. The first two fail against the pre-fix `events = poll_hangup`
  and pass after; the third passes both ways and is a guard against the fix
  over-reporting.
- The e2e journey this record was filed from: `zig build e2e
  -Dtest-filter="hung-up"` fails `expected 1, found 2` with the one-line
  `events` change reverted and passes 1/1 with it, in the same tree.
- Live, against a real `clanker serve --webui-port 17931`: five `/api/events`
  subscribers opened, read their 200, and hung up with the server never having
  written to them. `/api/metrics` went `in_flight 1 / subs 0` -> `6 / 5` ->
  `1 / 0` within 600ms, with `errors_total` staying 0 throughout (so no
  phantom error of the kind reported in #199).

`clanker gate`: all eleven checks PASS.

Not verified: whether Linux was ever affected. It has `POLLRDHUP` and so was
polling for a real event all along; nothing here was run on Linux.

## Follow-up

Answered: real leak, see Root cause. The assertion was not racing cleanup --
there was no cleanup to race until the 15s ping.

## References

- `docs/reports/bugs/2026-08-23-e2e-pty-harness-is-linux-only.md` -- the change
  that made this test runnable here at all.
- Investigation: none yet
