# Bug — A panic raised from a blocked Io.Threaded recurses forever instead of aborting

## TL;DR

- **What failed:** handlePanic routes the message through util/log.zig logPanic -> std.debug.print, whose stderr flush goes back through the same std.Io.Threaded. When the panic came from Threaded.Syscall.start's blocked => unreachable, that flush re-enters the same unreachable and panics again, forever. Captured with sample on a wedged clanker repl: 789 of 789 samples in that cycle, 0 CPU growth, process alive and unreapable until an external SIGKILL. A crash becomes an unkillable hang with no trace.
- **Impact:** Any panic reached while the `Io.Threaded` dispatcher is in that state stops being a crash and becomes a silent hang. Nothing is printed, nothing exits, and `waitpid` never reaps -- so a supervisor that judges liveness by "is it still running" reads a wedged process as healthy. `pty_resize_test`, whose entire assertion is `reapIfDead(pid) == null`, is exactly such a supervisor.
- **Resolution:** Resolved on 2026-08-23. Both halves shipped: logPanic writes fd 2 with a raw write(2) (writePanicLine), no std.Io; handlePanic latches per thread and abort()s on re-entry. Three unit tests, two of which fail against the old std.debug.print body. A standalone repro of the shape re-entered past 100000 times without the latch and aborts (exit 134) with it. clanker gate: all eleven PASS.

## Status

Resolved on 2026-08-23. Both halves shipped: logPanic writes fd 2 with a raw write(2) (writePanicLine), no std.Io; handlePanic latches per thread and abort()s on re-entry. Three unit tests, two of which fail against the old std.debug.print body. A standalone repro of the shape re-entered past 100000 times without the latch and aborts (exit 134) with it. clanker gate: all eleven PASS.

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

Spelled out, because this is the part that makes it urgent rather than merely
ugly: **any panic reached while `Io.Threaded` is blocked stops being a crash and
becomes a silent, traceless hang.** Nothing is printed, no exit status is
produced, and nothing reaps. That is *why* a crashed repl wedges instead of
dying: the crash itself is ordinary and diagnosable, and this defect is what
converts it into an invisible one. It applies to every panic reached in that
state, not only the SIGWINCH one that exposed it.

Two independent faults, either of which alone would be enough:

- The panic reporter is not panic-safe: it depends on the subsystem most
  likely to be the thing that failed.
- There is no "already panicking" latch. Zig's default panic handler aborts on
  re-entry; a custom `handlePanic` has to reproduce that itself.

## Resolution

Fixed. Both halves of the proposal below shipped in
`src/util/log.zig` and `handlePanic` in `src/main.zig`; what follows now
describes the code rather than proposing it:

- `src/util/log.zig` `logPanic`: write the already-formatted buffer straight to
  fd 2 with a raw `write(2)`, never `std.debug.print` / `std.Io`. The buffer is
  a `Writer.fixed` over a stack array, so nothing else in the function needs
  `Io` either.
- `src/main.zig` `handlePanic`: a thread-safe "already panicking" flag, and
  `abort()` on the second entry, so a panic inside the panic path still
  terminates the process.

## Verification

Three unit tests, all in the root test suite:

- `writePanicLine reaches the fd without going through std.Io` and
  `writePanicLine keeps a panic message on one physical line` capture the line
  off a pipe. Both were run against the old `std.debug.print` body first and
  both fail there, so they discriminate the fix rather than merely passing
  beside it.
- `the panic report is claimed once per thread, so a nested panic aborts` pins
  the latch. It tests `claimPanicReport`, not `handlePanic`, because
  `handlePanic` is `noreturn` and cannot be called from a test -- the same
  shape as the existing `claimTerminalRecovery` test beside it.

The recursion-to-abort behaviour itself is not synthesizable in-tree, so it was
verified with a standalone reproduction of the shape: a custom
`std.debug.FullPanic` handler whose reporting path raises the same panic.
Without the latch it re-entered past 100000 times (a counter in the repro, not
a natural bound); with the latch the second entry fires and `abort()` ends the
process, exit 134 / SIGABRT. `clanker gate` all eleven checks PASS, and a live
`clanker run` against deepseek still answers, so the handler install is intact.

Not verified: the original `clanker repl` SIGWINCH reproduction on a pristine
dependency tree. It needs the patches removed and was not re-run.

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
