# Bug — A panic raised from a blocked Io.Threaded recurses forever instead of aborting

## TL;DR

- **What failed:** handlePanic routes the message through util/log.zig logPanic -> std.debug.print, whose stderr flush goes back through the same std.Io.Threaded. When the panic came from Threaded.Syscall.start's blocked => unreachable, that flush re-enters the same unreachable and panics again, forever. Captured with sample on a wedged clanker repl: 789 of 789 samples in that cycle, 0 CPU growth, process alive and unreapable until an external SIGKILL. A crash becomes an unkillable hang with no trace.
- **Impact:** Any panic reached while the `Io.Threaded` dispatcher is in that state stops being a crash and becomes a silent hang. Nothing is printed, nothing exits, and `waitpid` never reaps -- so a supervisor that judges liveness by "is it still running" reads a wedged process as healthy. `pty_resize_test`, whose entire assertion is `reapIfDead(pid) == null`, is exactly such a supervisor.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

A `clanker repl` under `pty_resize_test`, on aarch64-macos, mid-SIGWINCH-flood:
alive, 0.09s of CPU over 90 seconds and not climbing, drawing nothing, reading
nothing off its tty, and never exiting. `reapIfDead` reports it healthy. The
test hung rather than failed, which is why this had no diagnosis before -- a
hang looks like a slow test, and the suite has slow tests.

## Reproduction

Observed, not synthesized. Any panic raised from inside
`Io.Threaded.Syscall.start`'s `.blocked => unreachable` will do it; the path
that produced it here was a `clanker repl` on a **pristine** dependency tree
(no `scripts/apply-patches.sh`), where vaxis still runs its winsize callbacks
inside the SIGWINCH handler and a flood of resizes issues `std.Io` work from a
signal that interrupted a pool thread mid-syscall. That is the defect
`patches/vaxis-winch-self-pipe.patch` fixes and
`docs/reports/investigations/2026-08-16-tui-resize-crash.md` describes. This
record is not about that crash. It is about what the process does *after* it.

`sample <pid>` of the wedged repl, two threads:

```
789 Thread_...  main-thread
      ... _sigtramp -> tty.PosixTty.handleWinch -> Loop.winsizeCallback
      -> Loop.postEvent -> queue.push -> Io.Mutex.lock -> futexWait -> __ulock_wait2

789 Thread_...
      Io.Threaded.Syscall.start -> reachedUnreachable -> main.handlePanic
      -> util.log.logPanic -> debug.print -> debug.unlockStderr
      -> Io.unlockStderr -> Io.Threaded.unlockStderr -> Io.Writer.flush
      -> File.Writer.drain -> drainStreaming -> File.writeStreaming
      -> Io.operate -> Io.Threaded.operate -> fileWriteStreaming
      -> Io.Threaded.Syscall.start -> reachedUnreachable -> main.handlePanic
      -> ... (the same eleven frames again, to the depth limit)
```

The main thread's half is the crash. The second thread's half is this bug: the
same frames repeat, so the panic is re-entering itself.

## Root cause

`main.handlePanic` (`src/main.zig`) hands the message to `logPanic`
(`src/util/log.zig`), which formats into a fixed buffer -- fine -- and then
prints it with `std.debug.print`. That flush goes through
`Io.Threaded.unlockStderr` -> `File.writeStreaming` -> `Io.Threaded.operate`
-> `Syscall.start`, i.e. back through the very dispatcher whose state raised
the panic. It hits the same `unreachable`, panics again, and calls
`handlePanic` again. There is no re-entry guard and no `abort()`, so the cycle
is unbounded.

Two independent faults, either of which alone would be enough:

- The panic reporter is not panic-safe: it depends on the subsystem most
  likely to be the thing that failed.
- There is no "already panicking" latch. Zig's default panic handler aborts on
  re-entry; a custom `handlePanic` has to reproduce that itself.

## Resolution

Open. Not fixed here -- this was found while fixing the pty harness and is
outside that change's blast radius. Where a fix belongs, concretely:

- `src/util/log.zig` `logPanic`: write the already-formatted buffer straight to
  fd 2 with a raw `write(2)`, never `std.debug.print` / `std.Io`. The buffer is
  a `Writer.fixed` over a stack array, so nothing else in the function needs
  `Io` either.
- `src/main.zig` `handlePanic`: a thread-safe "already panicking" flag, and
  `abort()` on the second entry, so a panic inside the panic path still
  terminates the process.

## Verification

None yet -- see Resolution. A regression test is available and cheap: assert
that a `clanker repl` which panics under a resize flood *exits* (any status)
within a bounded time, rather than asserting only that it has not exited.

## Follow-up

`pty_resize_test` asserts `reapIfDead(pid) == null`, i.e. "the repl is still
running", which this bug makes satisfiable by a corpse. The journey needs a
liveness check that a wedged process fails -- bytes still arriving, or the tty
still being drained -- not merely a not-exited check.

## References

- `docs/reports/investigations/2026-08-16-tui-resize-crash.md` -- the SIGWINCH
  crash that gets us into the panic path.
- `patches/vaxis-winch-self-pipe.patch` and `patches/README.md` -- why a
  pristine tree still has that crash.
- `docs/reports/bugs/2026-08-23-e2e-pty-harness-is-linux-only.md` -- the change
  this was found under.
- Investigation: none yet
