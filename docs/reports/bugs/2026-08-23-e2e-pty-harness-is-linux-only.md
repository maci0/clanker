# Bug — zig build e2e does not compile on macOS: the pty harness is Linux-only

## TL;DR

- **What failed:** tests/e2e/pty.zig allocates its pty with /dev/ptmx plus TIOCSPTLCK and TIOCGPTN and sizes it with posix.T.IOCSWINSZ. All three are Linux-only: the darwin branch of std.c.T declares IOCGWINSZ and nothing else, so the file fails to compile and takes the whole 38-test e2e suite down with it on macOS. Behind that sit two darwin runtime traps: a fresh master is not a terminal until something opens the slave, and open-then-close of the slave leaves a transient hangup pump reads as a dead child.
- **Impact:** `zig build e2e` is unavailable on macOS entirely. One file's platform assumptions cost all 38 journeys, including the 36 that have nothing to do with a pty.
- **Resolution:** Resolved on 2026-08-23. Fixed in tests/e2e/pty.zig (PR #354): pty allocation moved to POSIX posix_openpt/grantpt/unlockpt/ptsname, Pty.prime holds a slave fd on non-Linux, the master is NONBLOCK with a bounded POLLOUT wait, and killAndReap drains while reaping instead of blocking. Checked with zig build e2e, not the gate (which compiles no tests/e2e/): the suite went from 1 compilation error and 0 journeys run to 37/38 with both pty journeys passing. aarch64-macos only.

## Status

Resolved on 2026-08-23. Fixed in tests/e2e/pty.zig (PR #354): pty allocation moved to POSIX posix_openpt/grantpt/unlockpt/ptsname, Pty.prime holds a slave fd on non-Linux, the master is NONBLOCK with a bounded POLLOUT wait, and killAndReap drains while reaping instead of blocking. Checked with zig build e2e, not the gate (which compiles no tests/e2e/): the suite went from 1 compilation error and 0 journeys run to 37/38 with both pty journeys passing. aarch64-macos only.

## Symptom and impact

`zig build e2e` on aarch64-macos, at `origin/main` (a6a44dcc), in a worktree
with `zig build` and `zig build tools` already green:

```
tests/e2e/pty.zig:59:51: error: struct 'c.T__struct_28708' has no member named 'IOCSWINSZ'
    if (posix.errno(posix.system.ioctl(fd, posix.T.IOCSWINSZ, @intFromPtr(&ws))) != .SUCCESS)
error: 1 compilation errors
Build Summary: 209/212 steps succeeded (1 failed)
```

It is a compile error in the test module, so it is not one journey failing --
nothing in `tests/e2e/` runs at all. `clanker gate` is unaffected (it does not
include `e2e`), which is why this went unnoticed: the only signal is a hand-run
`zig build e2e`.

## Reproduction

`zig build e2e` from any macOS checkout. Deterministic, not a flake.

## Root cause

Three Linux-only pieces in `tests/e2e/pty.zig`:

- `openPty` opened `/dev/ptmx` and then used `TIOCSPTLCK` (unlock) and
  `TIOCGPTN` (slave number), both Linux ioctls, and built the slave name as
  `/dev/pts/{d}`. Darwin names slaves `/dev/ttysNNN` and has neither ioctl.
- `setWinsize` used `posix.T.IOCSWINSZ`. On Linux `posix.T` resolves to
  `std.os.linux.T`, which carries it. The Darwin/BSD branch of `std.c.T`
  declares `IOCGWINSZ` and nothing else, so the name does not exist and the
  module fails to compile. This is the error above.
- `spawnRepl` used a hardcoded `TIOCSCTTY = 0x540E`, the Linux number. The BSD
  encoding is `_IO('t', 97)` = `0x20007461`.

Two further Darwin behaviours, found by direct probe rather than inference,
sit behind the compile error and would each have failed the two pty journeys
after it was fixed:

- **A freshly opened master is not a terminal.** `posix_openpt` +
  `grantpt` + `unlockpt` succeed, but any tty ioctl on the master returns
  `ENOTTY` (errno 25) until something opens the slave. Probed both as `c_int`
  and as `c_ulong` (the macOS header's parameter type) to rule out an argument
  ABI mismatch: both fail identically, and both succeed once a slave fd
  exists. Since the test's first `setWinsize` runs *before* `spawnRepl`, there
  is no child slave yet and the call fails.
- **Opening and then closing the slave leaves the master hung up.** After
  `open` + `close` of the slave, `poll` on the master reports
  `POLLIN|POLLHUP` (`revents = 0x11`) and `read` returns 0. `pump` treats a
  zero-length read as "the pty closed, the child is gone" and returns false,
  which aborts the handshake before it starts. Reopening the slave restores
  normal reads, which is what makes a *held* fd the fix rather than a
  prime-and-release.

A third defect, found only once the journeys could get far enough to hit it,
and not platform-specific in kind: **the harness can deadlock on a full pty.**
A pty is two bounded kernel buffers, and both sides of `pty_resize_test` write
more than they drain -- the repl paints continuously (that journey runs the
mascot on a loop) while the test drains at most 8 reads per flood iteration,
and the test types 4 bytes per iteration while the repl is busy painting. With
a blocking master that is a mutual write deadlock. Observed on macOS, whose tty
queues are small enough to fill in seconds:

```
$ sample <test-pid>
    801 Thread_114918728   DispatchQueue_1: com.apple.main-thread  (serial)
      801 pty.writeAll  (in test) + 164  [0x1029a9ac0]  pty.zig:142
```

Test at 0.02s CPU, repl child at 1.03s CPU, neither moving, elapsed climbing.
`writeAll` had no timeout at all, so this was unbounded: the journey never
failed, it hung until something killed it. Linux is not immune in principle,
only less likely -- its tty queues are larger and the report that filed the two
investigations describes the journeys as passing there.

And a second, in the *teardown*, which hangs a journey that has already
finished. Both journeys ended with

```zig
defer {
    _ = posix.system.kill(pid, posix.SIG.KILL);
    var st: c_int = 0;
    _ = posix.system.waitpid(pid, &st, 0);
}
```

Nothing drains the master once the test body has returned, so a repl with
output still to flush on the way out blocks in `write` -- and a process blocked
in the kernel does not act on SIGKILL. Observed on macOS as `ps` state `?Es`
(trying to exit) held for minutes, with the test parked in `__wait4` inside its
own `defer`:

```
  PID  PPID STAT   ELAPSED COMMAND
59119 59116 ?Es       3:36 (clanker)
```

```
$ sample 59116
    797 test_runner.mainServer  ... pty_resize_test.zig:65
      797 pty_resize_test.zig:61
        797 __wait4  (in libsystem_kernel.dylib)
```

So the pass/fail verdict was already decided and the suite hung anyway.

## Resolution

`tests/e2e/pty.zig`:

- `openPty` now uses POSIX `posix_openpt` / `grantpt` / `unlockpt` /
  `ptsname`, declared `extern "c"` (the e2e module already links libc).
  That removes the per-platform pty-allocation constants entirely rather than
  adding a second set of them, and the slave name comes from the OS instead of
  being reconstructed.
- `TIOCSWINSZ` and `TIOCSCTTY` are the only remaining per-target values:
  `posix.T` on Linux (per-arch, which the old hardcoded `0x540E` was not),
  the BSD encodings elsewhere.
- The master is opened `NONBLOCK`, `writeAll` waits on `POLLOUT` with a 1s
  budget instead of blocking in the kernel, and `pump` reads `WouldBlock` as
  "nothing right now" rather than "the child is gone". Bytes still unwritten
  when the budget runs out are dropped, which is the same silent give-up
  `writeAll` already did on every other error; the one caller that cannot
  afford a dropped write (`answerQueries`) has an active reader on the far side
  and never reaches the timeout. What this buys is that the drain which frees
  the other side always gets to run.
- New `killAndReap`, which both journeys now `defer` instead of open-coding
  kill + blocking `waitpid`: it drains the master while it waits, so the child
  can finish dying, and gives up after 5s with a diagnostic rather than
  blocking. Draining is the part that matters; the timeout is the backstop.
- `writeAll` returns whether every byte landed, and the resize flood loop fails
  with `error.ReplStoppedReadingTty` after five consecutive give-ups (five
  seconds of the child accepting nothing) rather than grinding through 4000
  iterations at one second each. The diagnostic names the likely cause,
  including the unpatched-dependency one below.
- New `Pty.prime`: a slave fd the parent holds open for the pty's whole life
  on non-Linux, which keeps the master a live terminal and keeps it from
  hanging up. Deliberately **not** taken on Linux, where the master is a tty
  from the start and a parent-held slave fd would suppress the hangup `pump`
  legitimately uses to notice a dead child. `spawnRepl`'s child closes it
  alongside the master, and new `Pty.close` releases both (the two journeys
  now `defer pty.close()` instead of closing `master` directly).

`build.zig`: `-Dtest-filter` now reaches the e2e journeys
(`.filters = test_filters` on the e2e `addTest`). Without it the only way to
re-run one journey is the whole suite, and the resize journey alone floods
4000 resizes -- which is what made investigating a single failing journey
impractical, and is a large part of why the two pty records below sat open.

## Verification

On aarch64-macos, in a worktree:

- Before: `zig build e2e` -> `1 compilation errors`, 0 journeys run.
- After the constants and `posix_openpt`: the suite compiles and runs,
  `35/38 tests passed` -- the two pty journeys now reach `setWinsize` and fail
  there with `error.SetWinsizeFailed`, which is the `ENOTTY` above.
- After `Pty.prime`: both pty journeys get past setup and reach
  `answerQueries`, i.e. exactly the symptom the two investigations below
  describe. That failure is a separate defect with its own fix; see
  References.
- `zig build`, `zig build tools` and `zig build test --summary all` all green
  in the same tree.

This change is test-harness and `build.zig` only: no `src/` behaviour changes,
and the native `zig build test` step does not exercise `tests/e2e/`, so the
gate does not cover it. `zig build e2e` is the check, and it was run.

## Follow-up

Nothing in `tests/e2e/pty.zig` is Linux-specific any more, but nobody runs
`zig build e2e` in CI (billing), so a future platform assumption in it will
again only surface when someone runs it by hand.

## References

- `docs/reports/investigations/2026-08-22-pty-e2e-capability-queries-unanswered.md`
  and `docs/reports/investigations/2026-08-22-pty-e2e-fails-in-a-worktree.md`
  -- the `answerQueries` failure this change exposes on macOS, and the reason
  it looked worktree-specific.
- Investigation: none yet
