# Bug — Every kernel cell was held for the full timeout_ms before its reply was returned

## TL;DR

- **What failed:** The timeout watchdog in roundTrip (src/sandbox/kernel.zig) slept the whole budget and only read the cancel flag after waking, and roundTrip joins that thread before returning, so a 5 ms cell cost the full 10 s default. Observed live as `tool 'kernel' -> 357 bytes in 10051ms` beside the supervisor's own `"duration_ms": 5`. timeout_ms was a schedule, not a ceiling.
- **Impact:** Every `kernel` tool call took at least `timeout_ms` (default 10 s, and 15 s in this file own tests), no matter how fast the cell was. A model doing arithmetic in a cell waited the same ten seconds as one running a real computation, and the kernel unit tests each paid 15 s per `eval`.
- **Resolution:** Resolved on 2026-08-23. The watchdog now waits on a std.Io.Event the reader sets when the round trip ends, under a deadline from timeout_ms, so it wakes on whichever comes first; the SIGTERM path is unchanged. Pinned by 'a finished cell returns at once instead of waiting out timeout_ms' in src/sandbox/kernel.zig, which fails when the io.sleep body is restored. Live with deepseek-v4-flash: the same run went from 'tool kernel -> 357 bytes in 10051ms' to '334 bytes in 92ms', same answer.

## Status

Resolved on 2026-08-23. The watchdog now waits on a std.Io.Event the reader sets when the round trip ends, under a deadline from timeout_ms, so it wakes on whichever comes first; the SIGTERM path is unchanged. Pinned by 'a finished cell returns at once instead of waiting out timeout_ms' in src/sandbox/kernel.zig, which fails when the io.sleep body is restored. Live with deepseek-v4-flash: the same run went from 'tool kernel -> 357 bytes in 10051ms' to '334 bytes in 92ms', same answer.

## Symptom and impact

A `kernel` call returned the right answer and took `timeout_ms` to do it. The
two numbers in one log line are the whole symptom -- the host reports how long
the tool took, and the supervisor reports how long the cell took:

```
[INFO] tool 'kernel' -> 357 bytes in 10051ms
```

with `"duration_ms": 5` inside that reply. Nothing failed, nothing was logged
as slow, and the excess is exactly the configured ceiling, which is why it
reads as a hanging tool rather than as a bug in the clock.

## Reproduction

Found live, not by reading. With `kernel.enabled = true`:

```
clanker run --model deepseek-v4-flash "Use the kernel tool once with the cell 6*7"
```

The reply is correct and the tool line reports ~10 s against a `duration_ms`
in single digits. Lowering `timeout_ms` in the tool input lowers the wall time
to match it, which is the tell: the budget is what is being waited on.

Deterministically, `test "a finished cell returns at once instead of waiting
out timeout_ms"` in `src/sandbox/kernel.zig` times one round trip against its
own budget.

## Root cause

`roundTrip` (`src/sandbox/kernel.zig`) spawned a watchdog thread whose body was

```zig
self.io.sleep(.{ .nanoseconds = @as(i96, self.ms) * std.time.ns_per_ms }, .awake) catch return;
self.timed_out.store(true, .monotonic);
if (!self.cancel.load(.monotonic)) {
    std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
}
```

The `cancel` flag was read only *after* the sleep returned, so setting it
could stop the SIGTERM but never shorten the sleep. `roundTrip` ends with

```zig
defer {
    cancel.store(true, .monotonic);
    if (thread) |t| t.join();
}
```

and that `join` is what the caller waits on. So the flag worked -- the healthy
supervisor was never signalled -- while the thread it was meant to release
still ran for the whole budget, and `eval` could not return until it did.

Both halves have to be true for the symptom, which is why neither reads as
wrong on its own: a fire-and-forget watchdog with this body would have been
harmless, and a joined watchdog that woke on the flag would have been correct.

## Resolution

Fixed. The watchdog waits on a `std.Io.Event` the reader sets the moment the
round trip is over, under a deadline built from `timeout_ms`, so it wakes on
whichever comes first:

- reply read (or read failed) -> the event is set, the thread returns at once
  and the `join` is free;
- deadline reached -> `timed_out` is set and the supervisor is SIGTERMed,
  exactly as before.

`waitTimeout` reports `error.Timeout` on a spurious wakeup as well as a real
one, so the loop re-checks the clock before acting -- the subtlety
`src/util/deadline.zig` already documents for the same pattern.

It stays a thread rather than becoming a `deadline.runBounded` window around
the read, because what unblocks the read is the SIGTERM: cancelling a task
already blocked in `read(2)` on the supervisor pipe does not reach it. The
timeout path is unchanged; only the wait is now interruptible.

## Verification

`test "a finished cell returns at once instead of waiting out timeout_ms"`
(`src/sandbox/kernel.zig`) runs a warm-up cell so interpreter startup is not
being timed, then times a second `eval` with an 8 s budget and requires it
under a quarter of that. Restoring the `io.sleep` body fails that test, so it
fails for the reported reason and not merely passes now.

Live, same command, DeepSeek `deepseek-v4-flash`, `kernel.enabled = true`:

| | tool line |
|---|---|
| before | `tool 'kernel' -> 357 bytes in 10051ms` |
| after | `tool 'kernel' -> 334 bytes in 92ms` |

Same answer both times (`42`), and the default `timeout_ms` was 10000 in both,
so the ceiling did not move -- only the wait.

Side effect, measured: the kernel `test` blocks do several round trips each at
a 15 s budget. The `tests` step of `clanker gate` on this tree went from 292 s
to 65 s across this one commit, which also *added* a test, so the drop is the
watchdog and not a smaller suite.

## Follow-up

- `src/debug/dap.zig` shares the subprocess registry and already had the
  correct shape: `waitTimeout` under a deadline, then SIGTERM, then a 2 s grace
  window before SIGKILL. Read, not assumed -- `grep -n "io.sleep"
  src/debug/dap.zig src/agent/subprocess.zig` returns nothing. The kernel was
  the outlier, and DAP is worth reading as the reference for this pattern.
- The kernel has no SIGKILL escalation after its SIGTERM, where DAP does. A
  supervisor that ignored SIGTERM would still hold the pipe and the reader
  would stay blocked. Not observed, and out of scope here; noted because the
  comparison above is what surfaced it.

## References

- Investigation: none. The two numbers in the one log line named the cause,
  and the watchdog body confirmed it.
- `src/sandbox/kernel.zig` -- `roundTrip` and its `Killer`.
- `src/util/deadline.zig` -- the same wait-under-a-deadline pattern, with the
  spurious-wakeup rule written down.
- [PRD 0016](../../prds/0016-eval-kernel.md) -- the kernel spec; `timeout_ms`
  is specified as a cap.

- Investigation: none yet
