# Investigation — TUI crashes irrecoverably on terminal resize with mascot enabled

## TL;DR

- **Question:** Resizing the terminal while clanker repl runs (mascot on) aborts with a 10001-frame recursive std.Io File.Writer trace and leaves the terminal without scroll/copy (mouse tracking still on). Tracing the initial panic via the core dump.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

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