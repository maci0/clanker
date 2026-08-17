# Bug — SIGWINCH runs vaxis winsize callbacks in the signal handler, panicking std.Io and recursing through recover()

## TL;DR

- **What failed:** Resizing the terminal during clanker repl aborts and leaves it in raw mode with the alt-screen up. vaxis runs its winsize callbacks inside the SIGWINCH handler; they use std.Io, and a std.Io call from a signal that interrupted an Io.Threaded pool thread mid-syscall hits .blocked => unreachable in Syscall.start. vaxis.recover() then re-enters std.Io on its first write, re-raising the same panic from inside the panic handler until the stack overflows.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. Fixed by patches/vaxis-winch-self-pipe.patch (SIGWINCH self-pipe dispatch, raw-write recover) plus claimTerminalRecovery in src/main.zig. Verified by tests/e2e/pty_resize_test.zig: ReplCrashedOnResize after 568 resizes on the unfixed build, passes with the fix. Repro harness survives 5000 resizes against a crash at ~1500, and the app still redraws at each new geometry. clanker gate all green.

## Status

Resolved on 2026-08-17. Fixed by patches/vaxis-winch-self-pipe.patch (SIGWINCH self-pipe dispatch, raw-write recover) plus claimTerminalRecovery in src/main.zig. Verified by tests/e2e/pty_resize_test.zig: ReplCrashedOnResize after 568 resizes on the unfixed build, passes with the fix. Repro harness survives 5000 resizes against a crash at ~1500, and the app still redraws at each new geometry. clanker gate all green.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Reproduction

`resize_repro.py` in the session scratchpad: `pty.fork()`, exec
`zig-out/bin/clanker repl --mascot=loop --mascot-size=large --mascot-speed=7`
on the pty, answer the XTSMGRAPHICS geometry report before DA1 (DA1 ends the
query phase, so sixel only engages when the geometry answer precedes it), then
change `TIOCSWINSZ` on the master every 2 ms.

On the unfixed build this aborts with SIGABRT between 246 and 1594 resizes,
depending on how hot the event queue is. The same script and the same numbers
reproduce both from the repo root and from a bare temp directory holding only
a mock `config.toml` and a `zig-out` symlink, so nothing about the operator's
configuration is involved.

## Mechanism

1. `Loop.ttyRun` blocks in `readv` on the tty for the life of the process, so
   its `Io.Threaded` pool thread is permanently marked `.blocked`. It is also
   the thread SIGWINCH usually lands on.
2. `tty.zig handleWinch` runs the registered callbacks inside the signal
   handler. `handler_mutex.lock` and `Loop.winsizeCallback`'s
   `postEvent -> queue.push` are both `std.Io` operations.
3. An uncontended `std.Io.Mutex.lock` is a CAS and returns without a syscall,
   which is why this is intermittent rather than immediate. Under contention
   it goes to `futexWait -> Io.Threaded.Syscall.start`, which reads the
   thread's status, finds the `.blocked` left by the interrupted `readv`, and
   hits `.blocked => unreachable` (Threaded.zig:1358) — panic.
4. `src/main.zig handlePanic` calls `vaxis.recover()`, which writes the reset
   through the same buffered `std.Io` tty writer. That write re-enters
   `Syscall.start` on the same still-blocked thread and raises the identical
   panic from inside the panic handler.
5. The recursion `handlePanic -> recover -> writeAll -> drain -> drainStreaming
   -> writeStreaming -> operate -> fileWriteStreaming -> Syscall.start ->
   reachedUnreachable` repeats until the stack overflows (SIGSEGV), which
   `debug.handleSegfaultPosix` turns into the SIGABRT the operator sees.
   `std.debug.defaultPanic`'s panic-during-panic guard never engages, because
   the recursion happens in `recover()` before `defaultPanic` is reached.
6. The terminal is left unusable because `recover()` panics on its *first*
   write: the kitty keyboard pop, mouse reset, bracketed-paste reset and
   `rmcup` are never delivered.

The mascot is an amplifier, not the cause — its self-driven redraws keep the
event queue busy, which is what makes the mutex contended when a signal lands.

## Evidence that SIGWINCH is the cause

Two controls on the unfixed build, 2 ms per tick, everything else identical:

| run | size changes | keystrokes | outcome |
|---|---|---|---|
| same size set every tick | none, so no SIGWINCH | yes | survived 3000 ticks |
| changing size | yes | none | SIGABRT at 1594 |

## What was left on the terminal

Measured with `panic_cleanliness.py`, which floods until the child dies and
reports what reached the pty afterwards:

| build | outcome | trace bytes | recursion frames | reset sequences |
|---|---|---|---|---|
| unfixed | SIGABRT | 2,012,324 | 3336, unwinder cap hit | 0 of 4 |
| `recover()` + panic guard fixed only | SIGABRT | 8,759 | 3, no cap | 4 of 4 |
| all three fixed | survived 5000 resizes, twice | — | — | n/a |

## Fix

Three changes, each removing one link:

1. `patches/vaxis-winch-self-pipe.patch`, `tty.zig`: `handleWinch` shrinks to
   one raw `write(2)` onto a static self-pipe, skipped when a wakeup is already
   queued. A detached plain `std.Thread` reads that pipe and runs the callbacks
   in normal thread context — `Io.Threaded.Thread.current` is null on a
   non-pool thread, so `Syscall.start` takes its early-return path there.
2. Same patch, `main.zig`: `recover()` writes the reset with raw `write(2)` and
   restores termios with `tcsetattr`, touching no `std.Io`. It also stops
   calling `Tty.deinit`, whose `close` goes through `std.Io`.
3. `src/main.zig`: `claimTerminalRecovery()`, a one-shot atomic, so a panic
   raised inside the recovery write falls through to `std.debug.defaultPanic`
   instead of recursing.

Changes 2 and 3 matter beyond this bug: they apply to *any* panic in the TUI,
and they are what turn an irrecoverable crash into a readable one.

## Verification

- `tests/e2e/pty_resize_test.zig` — allocates a pty, gives the child the slave
  as its controlling terminal, asserts the repl redraws at the new geometry,
  then floods. Fails with `ReplCrashedOnResize` after 598 resizes on the
  unfixed build; passes with the fix.
- Repro harness: 5000 resizes survived twice, against a crash at ~1500.
- Delivery probe: rows 40 -> 45 -> 20 and columns 100 -> 200 -> 60 track the
  requested geometry exactly, so the self-pipe coalesces bursts without losing
  a resize.

## References

- Investigation: [TUI crashes irrecoverably on terminal resize](../investigations/2026-08-16-tui-resize-crash.md)
- Patch: `patches/vaxis-winch-self-pipe.patch`