# Investigation — TUI crashes irrecoverably on terminal resize with mascot enabled

## TL;DR

- **Question:** Resizing the terminal while clanker repl runs (mascot on) aborts with a 10001-frame recursive std.Io File.Writer trace and leaves the terminal without scroll/copy (mouse tracking still on). Tracing the initial panic via the core dump.
- **Finding:** Resolved on 2026-08-17. Root-caused to vaxis running winsize callbacks inside the SIGWINCH handler (std.Io is unsafe there on a pool thread already blocked in readv) and to recover() re-entering std.Io and re-raising the same panic. Fixed by patches/vaxis-winch-self-pipe.patch and claimTerminalRecovery in src/main.zig. Verified by tests/e2e/pty_resize_test.zig, which fails with ReplCrashedOnResize at 568 resizes unfixed and passes fixed; clanker gate all green.
- **Resolution:** Resolved on 2026-08-17. Root-caused to vaxis running winsize callbacks inside the SIGWINCH handler (std.Io is unsafe there on a pool thread already blocked in readv) and to recover() re-entering std.Io and re-raising the same panic. Fixed by patches/vaxis-winch-self-pipe.patch and claimTerminalRecovery in src/main.zig. Verified by tests/e2e/pty_resize_test.zig, which fails with ReplCrashedOnResize at 568 resizes unfixed and passes fixed; clanker gate all green.

## Status

Resolved on 2026-08-17. Root-caused to vaxis running winsize callbacks inside the SIGWINCH handler (std.Io is unsafe there on a pool thread already blocked in readv) and to recover() re-entering std.Io and re-raising the same panic. Fixed by patches/vaxis-winch-self-pipe.patch and claimTerminalRecovery in src/main.zig. Verified by tests/e2e/pty_resize_test.zig, which fails with ReplCrashedOnResize at 568 resizes unfixed and passes fixed; clanker gate all green.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Evidence

- Crash artifact: systemd core dump PID 2753705, SIGABRT at 2026-08-16 21:50:29 +08, from `coredumpctl list`. Command line: `clanker --mascot=input --mascot-size=large --mascot-speed=7 --mascot-facing=inverted` inside Konsole (control group `app-org.kde.konsole-*`), so the mascot's sixel renderer path is in play.
- The crashing thread is TID 2753707 (not the main thread 2753705). systemd's crash-time symbolication shows `debug.handleSegfaultPosix -> debug.handleSegfault -> debug.defaultHandleSegfault -> abort`: the original fault was a SIGSEGV that Zig's segfault handler caught and turned into the abort. The SIGABRT is secondary.
- The on-screen trace repeats the cycle `Io/Threaded.zig operate -> File.zig writeStreaming -> File/Writer.zig drainStreaming` until "Stopping trace after 10001 frames". Checked against /usr/lib/zig/std (zig 0.16.0): `Threaded.fileWriteStreaming` is a leaf writev loop and cannot call back into `drainStreaming`, so that cycle is impossible as a real call stack. The printed recursion is the stack unwinder looping while dumping, not the defect; the true faulting frame is not visible on screen. systemd's unwinder also stopped at the signal trampoline (frame 7, no caller), consistent with an unwalkable interrupted stack.
- The core cannot be symbolized after the fact: `coredumpctl gdb` against the current `zig-out/bin/clanker` resolves the same addresses to different symbols than systemd recorded at crash time (binary has no build-id and was rebuilt since), so gdb backtraces from this core are garbage.
- Terminal left unusable (no scroll/copy) even though src/main.zig installs `vaxis.recover()` via `std.debug.FullPanic`: a SIGSEGV takes the segfault-handler path, not the panic path, so recover() never ran. Unverified: whether wiring recover into the segfault path is safe.
- Suspect under investigation (unverified): vaxis 0.6.0 `tty.zig handleWinch` runs registered callbacks inside the SIGWINCH signal handler; `Loop.winsizeCallback` calls `getWinsize` (ioctl, safe) and `postEvent` -> `queue.push` through std.Io (mutex/futex, not async-signal-safe). A Konsole drag-resize delivers a SIGWINCH flood while the render thread is streaming sixel payloads to the tty every frame.
## Reproduced and root-caused

Reproduced outside Konsole with a pty harness (scratchpad resize_repro.py): spawn `zig-out/bin/clanker --mascot=input --mascot-size=large --mascot-speed=7 --mascot-facing=inverted` on a pty, answer the XTSMGRAPHICS geometry query (`ESC[?2;0;10000;10000S`) before DA1 (`ESC[?62;4;22c`) so the sixel renderer engages, then change TIOCSWINSZ every 20ms. Crashed with the identical SIGABRT signature after 198 resizes (core PID 3211390, 2026-08-16 22:25). The first run that answered DA1 before the geometry report never engaged sixel and survived 1674 resizes; sixel raises tty write volume and contention, it is not the defect.

Full backtrace from the matching binary (55679 frames), thread LWP 3211392 = the vaxis Loop.ttyRun read thread running as an Io.concurrent pool worker:

1. Trigger: the read thread is blocked in readv on the tty (Threaded fileReadStreaming). SIGWINCH is delivered to it. vaxis tty.zig handleWinch (line 164) runs inside the signal handler and calls Io.Mutex.lock(handler_mutex) -> futexWait -> Io.Threaded.Syscall.start (Threaded.zig:1358), which reads the thread status, finds it already blocked-in-syscall from the interrupted readv, and hits unreachable -> panic. Any std.Io operation from a signal handler on a busy pool thread does this; Loop.winsizeCallback's postEvent -> queue.push is the same class.
2. Amplifier: src/main.zig handlePanic calls vaxis.recover(), which writes the terminal reset through the same std.Io tty writer -> Syscall.start -> the same unreachable -> handlePanic again. The frames repeat handlePanic -> recover -> writeAll/flush -> drain -> drainStreaming -> writeStreaming -> operate -> fileWriteStreaming -> Syscall.start -> reachedUnreachable, ~6900 cycles, until stack overflow (SIGSEGV) -> debug.handleSegfaultPosix -> abort. std.debug.defaultPanic's panic-during-panic protection never engages because the recursion happens in recover() before defaultPanic is reached.
3. Terminal left unusable because recover() panics on its first write: kitty keyboard pop, mouse reset, bracketed paste reset and rmcup are never delivered on this path.

The mascot is an amplifier (self-driven 20fps redraws keep the event queue and tty busy, making handler_mutex/futex contention near-certain during a drag-resize), not the cause.
## Fix plan (not yet implemented)

Three changes, smallest that removes both the trigger and the amplifier:

1. vaxis (vendored zig-pkg tree + new patch file in patches/, since zig-pkg is gitignored): make SIGWINCH delivery async-signal-safe via the self-pipe pattern. `tty.zig handleWinch` shrinks to one raw `write(2)` onto a static nonblocking pipe created in `PosixTty.init`; a detached plain `std.Thread` (`Thread.current == null`, so its std.Io mutex/queue use never trips `Syscall.start`) blocks reading that pipe and runs the registered handler callbacks (getWinsize + postEvent) in normal thread context.
2. vaxis `main.zig recover()`: replace the buffered std.Io tty writer with raw `write(2)` of `csi_u_pop ++ mouse_reset ++ bp_reset ++ rmcup` plus `posix.tcsetattr(fd, .FLUSH, gty.termios)` — recover is documented as panic-context-only and must not re-enter std.Io.
3. clanker `src/main.zig handlePanic`: one-shot atomic guard so a panic raised inside the recovery write falls through to `std.debug.defaultPanic` (which has its own panicked-during-panic handling) instead of recursing.

Verification: the pty repro harness (scratchpad resize_repro.py, copy in this record's Evidence section) crashes the current build in under ~200 resizes with sixel engaged; after the fix it must survive the full window, and a deliberate panic in the TUI must leave the terminal scrollable/copyable. Failing e2e first per AGENTS.md: tests/e2e/ has no pty helper yet; a pty resize-flood journey (fork + /dev/ptmx + TIOCSWINSZ flood, answer geometry-then-DA1) belongs in tests/e2e/ alongside journeys_test.zig. Then `clanker gate`, CHANGELOG under [Unreleased], patches/README.md entry for the new vaxis patch.
## Fix implemented and measured (2026-08-17)

All three changes from the fix plan are implemented. Each was measured
separately on the pty repro harness, so the effect of each is attributable
rather than inferred.

### The harness

`resize_repro.py` (scratchpad, reconstructed 2026-08-17 — the original
session's copy was gone): `pty.fork()`, exec
`zig-out/bin/clanker repl --mascot=loop --mascot-size=large --mascot-speed=7`,
answer the XTSMGRAPHICS geometry report before DA1 so sixel engages, then
change `TIOCSWINSZ` on the master on a fixed interval, optionally writing
`abc\x7f` each tick to keep the event queue hot.

### What the numbers say the cause is

Two controls, both on the unfixed build, both 2 ms per tick:

| run | SIGWINCH raised | keystrokes | outcome |
|---|---|---|---|
| same size every tick | no | yes | survived 3000 ticks |
| changing size, no keystrokes | yes | no | SIGABRT at 1594 |

So SIGWINCH is necessary and sufficient; the keystrokes and the mascot only
raise the odds by making the mutex contended more often. This corrects a
guess in the earlier evidence: the first run of the reconstructed harness
used `--mascot=input` with no keystrokes and survived 600 resizes, which
would have read as "not reproducible" without the controls.

The crash is contention-gated, not signal-count-gated: `std.Io.Mutex.lock`
only enters a syscall when the lock is already held, so an uncontended
SIGWINCH handler returns without ever reaching `Syscall.start`.

### What each change is worth

Measured with `panic_cleanliness.py`, which floods until the child dies and
then reports the trace size and whether the terminal reset ever reached the
pty:

| build | outcome | trace bytes | recursion frames | reset sequences delivered |
|---|---|---|---|---|
| none of the three | SIGABRT | 2,012,324 | 3336, unwinder cap hit | 0 of 4 |
| `recover()` + panic guard only | SIGABRT | 8,759 | 3, no cap | 4 of 4 |
| all three | survived 5000 resizes, twice | — | — | n/a |

The middle row is the point of changes 2 and 3 on their own: the process
still dies, but it dies in three frames and hands the terminal back, so the
operator gets a readable panic in a usable terminal instead of a megabyte of
repeated frames and a shell with no scroll, no copy and mouse tracking still
on. That is the difference between a crash and an irrecoverable one, and it
holds for **any** panic in the TUI, not only this one.

### Delivery, not just survival

Surviving a flood proves nothing on its own — a handler that dropped every
resize would survive it too. `resize_delivers.py` settles the repl, changes
the size once, and reads back which geometry the app redraws at. On the
fixed build: 40 rows -> 45 -> 20, and columns 100 -> 200 -> 60, tracking
exactly. The self-pipe coalesces bursts (one pending wakeup at a time) but
loses no resize, because each callback re-reads the current size with
`TIOCGWINSZ` rather than carrying a size through the pipe.

## Regression test

`tests/e2e/pty_resize_test.zig`, wired into `tests/e2e/main.zig`. It
allocates a pty by hand (`/dev/ptmx`, `TIOCSPTLCK`, `TIOCGPTN`), forks, and
gives the child the slave as its controlling terminal —
`std.process.Child` cannot express this, because the child has to `setsid`
and claim the tty between fork and exec and vaxis opens `/dev/tty`.

Three things had to be right before it reproduced anything, each of which
was a false green until measured:

1. **The signal mask survives fork *and* exec.** The child must
   `sigprocmask(SIG_SETMASK, empty)` before exec, or it inherits the test
   runner's blocked mask and never receives SIGWINCH at all.
2. **The flood has to be paced.** SIGWINCH is a standard signal, so a second
   one raised while the first is still pending is coalesced, not queued.
   Resizing as fast as the loop could spin collapsed ~4000 `TIOCSWINSZ`
   calls into a handful of deliveries and the unfixed build passed. At 2 ms
   per change the unfixed build dies at 598.
3. **The delivery assertion has to read rows, not columns.** With an empty
   transcript the repl draws nothing at the right edge, so the widest column
   addressed stays at the mascot regardless of window width; the composer is
   bottom-anchored, so the tallest row tracks the height on every frame.
   Verified against the same measurement taken with the python probe in the
   same environment: rows 40 -> 45 -> 20.

Confirmed failing for the intended reason on the unfixed build
(`ReplCrashedOnResize` after 598 resizes) and passing with the fix.