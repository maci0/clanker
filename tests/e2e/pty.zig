//! Shared pty plumbing for operator journeys that must run the repl on a real
//! controlling terminal (vaxis opens `/dev/tty`, so nothing short of a pty
//! exercises the real TUI). Extracted from pty_resize_test.zig so a second
//! pty journey does not re-derive the fork/setsid/TIOCSCTTY dance.

const std = @import("std");
const e2e_options = @import("e2e_options");
const posix = std.posix;
const native_os = @import("builtin").os.tag;

/// The two pty ioctls `std.c.T` does not carry on every target. Linux keeps
/// them per-arch in `std.os.linux.T`, which `posix.T` re-exports; the
/// Darwin/BSD branch of `std.c.T` declares only `IOCGWINSZ`, so the BSD
/// encodings are spelled out. Both are fixed ABI.
///
/// Only the request numbers are platform-specific. Allocating the pty itself
/// goes through `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` below, which is
/// POSIX and needs no per-target constants at all -- the previous
/// `/dev/ptmx` + `TIOCSPTLCK` + `TIOCGPTN` sequence was Linux-only and made
/// this file, and with it the whole `zig build e2e` suite, fail to compile on
/// macOS.
const TIOCSWINSZ: c_int = switch (native_os) {
    .linux => @bitCast(@as(u32, @intCast(posix.T.IOCSWINSZ))),
    // _IOW('t', 103, struct winsize)
    else => @bitCast(@as(u32, 0x80087467)),
};
const TIOCSCTTY: c_int = switch (native_os) {
    .linux => @bitCast(@as(u32, @intCast(posix.T.IOCSCTTY))),
    // _IO('t', 97)
    else => @bitCast(@as(u32, 0x20007461)),
};

/// `std.c` does not declare the POSIX pty helpers, and `std.posix` has no
/// wrapper for them. They live in libc on every target this suite runs on
/// (the e2e module links libc), so declare them directly rather than
/// re-deriving each platform's ioctl encoding.
extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;

/// The capability queries this harness recognizes, and what it answers.
///
/// DA1 is what ends vaxis's query phase, so it is the one that must be
/// answered for the repl to start drawing. The XTSMGRAPHICS geometry query is
/// optional: only the sixel half of `patches/vaxis-sixel-graphics.patch` sends
/// it, and its report must go back *before* DA1 or the sixel renderer never
/// engages. `patches/` is applied into gitignored `zig-pkg/`, so whether it
/// arrives is a property of the checkout, not of the code under test.
pub const geometry_query = "\x1b[?2;1;0S";
pub const geometry_reply = "\x1b[?2;0;10000;10000S";
pub const da1_query = "\x1b[c";
pub const da1_reply = "\x1b[?62;4;22c";

/// Wall-clock budget for the handshake. A bare iteration count is not a
/// timeout: `pump` returns the moment bytes are available, so a repl that
/// writes a burst before its queries can burn any fixed number of iterations
/// in milliseconds (`pty_resize_test` learned the same lesson for its own
/// settle loops).
const answer_timeout_ms: i64 = 5000;

fn nowMs() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

pub const Pty = struct {
    master: posix.fd_t,
    /// Darwin names slaves `/dev/ttysNNN` and Linux `/dev/pts/N`; both fit
    /// well inside this, and `openPty` refuses anything that does not.
    slave_path: [64]u8,
    slave_len: usize,
    /// A slave fd the *parent* holds open for the pty's whole life, or -1.
    ///
    /// Darwin needs it. A freshly opened master there is not a terminal until
    /// something opens the slave: every tty ioctl on it fails `ENOTTY`, which
    /// is what `setWinsize` was hitting before the first `spawnRepl`. Opening
    /// the slave once fixes that permanently -- but opening and *closing* it
    /// leaves the master in a transient hangup (`poll` reports
    /// `POLLIN|POLLHUP`, `read` returns 0), and `pump` reads a zero-length
    /// read as "the child is gone" and gives up. So the fd is opened once and
    /// held, never closed, which keeps the master continuously non-hung.
    ///
    /// Linux does not need it and must not have it: there the master is a tty
    /// from `posix_openpt`, and a parent-held slave fd would suppress the
    /// hangup `pump` uses to notice a dead child.
    prime: posix.fd_t = -1,

    pub fn slave(self: *const Pty) [:0]const u8 {
        return self.slave_path[0..self.slave_len :0];
    }

    /// Releases both fds. Tests `defer` this rather than closing `master`
    /// directly, so the primed slave does not outlive the test.
    pub fn close(self: *Pty) void {
        if (self.prime >= 0) {
            _ = posix.system.close(self.prime);
            self.prime = -1;
        }
        _ = posix.system.close(self.master);
    }
};

/// Whether the master needs a live slave fd to behave as a terminal. See
/// `Pty.prime`.
const needs_prime = native_os != .linux;

pub fn openPty() !Pty {
    // NONBLOCK, so neither direction of this pty can wedge the test. A pty is
    // two bounded kernel buffers and both sides here write more than they
    // drain: the repl paints continuously (the resize journey runs the mascot
    // on a loop) while the test drains at most 8 reads per flood iteration,
    // and the test types 4 bytes per iteration while the repl is busy
    // painting. With a blocking master that is a mutual write deadlock --
    // observed on macOS, whose tty queues are small enough to fill in
    // seconds, with the test parked in `writeAll` and the repl parked in its
    // own `write`, both at 0% CPU, forever. `writeAll` bounds its wait and
    // `pump` treats `WouldBlock` as "nothing right now", so the drain that
    // frees the other side always gets to run.
    const flags: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true })));
    const master = posix_openpt(flags);
    if (master < 0) return error.PtyOpenFailed;
    errdefer _ = posix.system.close(master);

    if (grantpt(master) != 0) return error.PtyGrantFailed;
    if (unlockpt(master) != 0) return error.PtyUnlockFailed;
    const name = ptsname(master) orelse return error.PtyNumberFailed;

    var pty: Pty = .{ .master = master, .slave_path = undefined, .slave_len = 0 };
    const name_len = std.mem.len(name);
    // Leave room for the sentinel `slave()` hands to `openatZ`.
    if (name_len >= pty.slave_path.len) return error.PtyNameTooLong;
    @memcpy(pty.slave_path[0..name_len], name[0..name_len]);
    pty.slave_path[name_len] = 0;
    pty.slave_len = name_len;
    if (needs_prime) {
        pty.prime = posix.openatZ(posix.AT.FDCWD, pty.slave(), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch
            return error.PtySlaveOpenFailed;
    }
    return pty;
}

pub fn setWinsize(fd: posix.fd_t, rows: u16, cols: u16) !void {
    const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    if (posix.errno(posix.system.ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws))) != .SUCCESS)
        return error.SetWinsizeFailed;
}

/// How long `writeAll` will wait for a full master before giving up on the
/// rest of its bytes. Generous next to the handshake (which must not lose the
/// DA1 reply) and short next to a wedge (which used to be unbounded).
const write_timeout_ms: i32 = 1000;

/// Best-effort write to the master. Bounded: the master is non-blocking, so a
/// full buffer surfaces as `AGAIN` and is waited on with `POLLOUT` rather than
/// blocking in the kernel. Bytes still unwritten when the budget runs out are
/// dropped, which is the same silent give-up this already did on any other
/// error -- and the caller that cannot afford that (`answerQueries`) has a
/// reader on the far side, so it never reaches the timeout.
/// Returns false if any byte was dropped, which for a caller in a loop is the
/// signal that the child has stopped reading its tty -- see `pty_resize_test`,
/// where a wedged repl used to make the journey hang instead of fail.
pub fn writeAll(fd: posix.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + off, bytes.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            .AGAIN => {
                var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                const ready = posix.poll(&fds, write_timeout_ms) catch return false;
                if (ready == 0) return false;
                continue;
            },
            else => return false,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return false;
        off += n;
    }
    return true;
}

/// Reads whatever is available within `timeout_ms`, appending to `sink`.
/// Returns false once the pty closes, which is how a dead child shows up here.
pub fn pump(fd: posix.fd_t, sink: *std.ArrayList(u8), gpa: std.mem.Allocator, timeout_ms: i32) !bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&fds, timeout_ms) catch return true;
    if (ready == 0) return true;

    var buf: [8192]u8 = undefined;
    const n = posix.read(fd, &buf) catch |err| switch (err) {
        // The master is non-blocking, so a spurious wakeup with nothing
        // buffered is "no data", not "the child is gone".
        error.WouldBlock => return true,
        else => return false,
    };
    if (n == 0) return false;
    try sink.appendSlice(gpa, buf[0..n]);
    return true;
}

/// Forks and execs the built binary with `pty`'s slave as its controlling
/// terminal, `cwd` as its working directory, and `repl <extra_args...>` as its
/// command line. `std.process.Child` cannot do this: the child has to call
/// `setsid` and claim the tty between fork and exec, and vaxis opens
/// `/dev/tty`, which resolves to whatever the process's controlling terminal
/// is.
pub fn spawnRepl(pty: *const Pty, cwd: [:0]const u8, extra_args: []const [*:0]const u8) !posix.pid_t {
    const bin = e2e_options.clanker_bin ++ "\x00";
    const bin_z: [*:0]const u8 = @ptrCast(bin.ptr);

    var argv: [8:null]?[*:0]const u8 = @splat(null);
    argv[0] = bin_z;
    argv[1] = "repl";
    if (extra_args.len > argv.len - 3) return error.TooManyArgs;
    for (extra_args, 0..) |arg, i| argv[2 + i] = arg;
    const envp = [_:null]?[*:0]const u8{ "TERM=xterm-256color", "HOME=/tmp" };

    const rc = posix.system.fork();
    if (rc < 0) return error.ForkFailed;
    if (rc != 0) return @intCast(rc);

    // ---- child ----
    // The signal mask survives both fork and exec, and the test runner reaches
    // here with signals blocked (Zig blocks them around thread spawn, and this
    // binary runs an `Io.Threaded` pool). Inheriting that mask leaves the repl
    // with SIGWINCH blocked, so a resize journey's floods would be swallowed
    // by the kernel. Clear it before exec.
    const empty = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty, null);

    _ = posix.system.setsid();
    _ = posix.system.chdir(cwd.ptr);

    const slave = posix.openatZ(posix.AT.FDCWD, pty.slave(), .{ .ACCMODE = .RDWR }, 0) catch
        posix.system._exit(127);
    _ = posix.system.ioctl(slave, TIOCSCTTY, @as(usize, 0));
    _ = posix.system.dup2(slave, 0);
    _ = posix.system.dup2(slave, 1);
    _ = posix.system.dup2(slave, 2);
    if (slave > 2) _ = posix.system.close(slave);
    _ = posix.system.close(pty.master);
    if (pty.prime >= 0) _ = posix.system.close(pty.prime);

    _ = posix.system.execve(bin_z, &argv, &envp);
    posix.system._exit(127);
}

/// Non-blocking reap. Returns the raw wait status once the child is gone.
pub fn reapIfDead(pid: posix.pid_t) ?c_int {
    var status: c_int = 0;
    const rc = posix.system.waitpid(pid, &status, 1); // WNOHANG
    if (rc == pid) return status;
    return null;
}

/// Teardown: SIGKILL the repl and reap it, draining the master throughout and
/// giving up rather than waiting forever.
///
/// A plain `kill` + blocking `waitpid` is not safe here, and this is what a
/// journey's `defer` must use instead. Nothing drains the master once the test
/// body has returned, so a repl that still has output to flush on the way out
/// blocks in `write` -- and a process blocked in the kernel does not act on
/// SIGKILL. Observed on macOS as `ps` state `?Es` (trying to exit) for as long
/// as anyone was willing to watch, with the test parked in `__wait4` in its own
/// `defer`: the journey did not fail, it hung after having already finished.
/// Draining while waiting is what lets the child finish dying.
pub fn killAndReap(pty: *const Pty, pid: posix.pid_t) void {
    _ = posix.system.kill(pid, posix.SIG.KILL);
    const deadline = nowMs() + reap_timeout_ms;
    var sink: [8192]u8 = undefined;
    while (nowMs() < deadline) {
        if (reapIfDead(pid) != null) return;
        var fds = [_]posix.pollfd{.{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, 20) catch 0;
        if (ready > 0) _ = posix.read(pty.master, &sink) catch {};
    }
    // Out of budget. Leaving the child unreaped is a leak the test runner
    // survives; blocking here is not, so say so and move on.
    std.debug.print(
        "pty: repl {d} did not die within {d}ms of SIGKILL; leaving it unreaped\n",
        .{ pid, reap_timeout_ms },
    );
}

/// How long `killAndReap` drains before giving up on a child that will not die.
const reap_timeout_ms: i64 = 5000;

/// Answers vaxis's startup capability queries as they arrive in `seen`.
/// Returns true once DA1 has been answered, which is what ends the repl's
/// query phase and lets it draw its first frame.
///
/// The geometry query is answered when it arrives and skipped when it does
/// not. It used to be *required*, and waiting for it deadlocked the whole
/// handshake on an unpatched dependency: upstream vaxis 0.6.0 declares
/// `sixel_geometry_query` but never sends it (only
/// `patches/vaxis-sixel-graphics.patch` does), and because the DA1 arm was
/// gated behind `answered_geometry`, DA1 went unanswered too even though it
/// was sitting in `seen`. That made `pty_resize_test` and `pty_preview_test`
/// fail in any tree where `scripts/apply-patches.sh` had not run -- every
/// fresh worktree, since `zig-pkg/` is gitignored -- for reasons neither
/// journey is about (a SIGWINCH flood and the `/` command preview).
///
/// Ordering still holds where it matters: the patched query phase sends the
/// geometry query *before* DA1, so a stream that carries both is seen in that
/// order and answered in that order.
pub fn answerQueries(master: posix.fd_t, seen: *std.ArrayList(u8), gpa: std.mem.Allocator) !bool {
    var answered_geometry = false;
    var answered_da1 = false;
    const deadline = nowMs() + answer_timeout_ms;
    while (!answered_da1 and nowMs() < deadline) {
        if (!try pump(master, seen, gpa, 50)) break;
        if (!answered_geometry and std.mem.find(u8, seen.items, geometry_query) != null) {
            _ = writeAll(master, geometry_reply);
            answered_geometry = true;
        }
        if (std.mem.find(u8, seen.items, da1_query) != null) {
            _ = writeAll(master, da1_reply);
            answered_da1 = true;
        }
    }
    return answered_da1;
}
