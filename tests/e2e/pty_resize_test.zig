//! Operator journey: `clanker repl` on a real pty must survive a SIGWINCH
//! flood — a drag-resize of the terminal window.
//!
//! This is the regression test for the crash in
//! docs/reports/investigations/2026-08-16-tui-resize-crash.md. vaxis used to
//! run its winsize callbacks inside the SIGWINCH handler; those callbacks take
//! a `std.Io.Mutex` and push onto the event queue, and issuing a `std.Io`
//! operation from a signal that interrupted an `Io.Threaded` pool thread mid
//! syscall hits `.blocked => unreachable` in `Syscall.start`. The read thread
//! sits in `readv` on the tty for the process's whole life, so it is the thread
//! the signal lands on.
//!
//! Nothing short of a pty reproduces it: the defect needs a real controlling
//! terminal (vaxis opens `/dev/tty`), a real `TIOCSWINSZ` so the kernel raises
//! the signal, and enough event-queue traffic for the mutex to be contended
//! when it does. Measured on the unfixed build, the crash arrives at roughly
//! 1500 resizes; the flood below runs well past that. A control that sets the
//! *same* size every tick — no size change, so no SIGWINCH — survived 3000
//! ticks unharmed, which is what pins the cause on the signal rather than on
//! the redraw load.

const std = @import("std");
const harness = @import("harness.zig");
const e2e_options = @import("e2e_options");
const posix = std.posix;

/// Linux pty ioctls. `std.os.linux.T` carries the winsize pair but not these
/// three, and they are fixed ABI.
/// `_IOW`/`_IOR` encodings, so `TIOCGPTN` has its top bit set and does not fit
/// the signed request parameter without a bitcast.
const TIOCSPTLCK: c_int = @bitCast(@as(u32, 0x40045431)); // unlockpt
const TIOCGPTN: c_int = @bitCast(@as(u32, 0x80045430)); // slave number
const TIOCSCTTY: c_int = 0x540E; // make this the controlling terminal

/// Answers to the two capability queries vaxis sends. The geometry report must
/// go back *before* DA1 — DA1 is what ends the query phase — or the sixel
/// renderer never engages. Sixel is not the defect, but it multiplies tty write
/// volume, which is what makes the crash land in seconds instead of minutes.
const geometry_reply = "\x1b[?2;0;10000;10000S";
const da1_reply = "\x1b[?62;4;22c";

const Pty = struct {
    master: posix.fd_t,
    slave_path: [32]u8,
    slave_len: usize,

    fn slave(self: *const Pty) [:0]const u8 {
        return self.slave_path[0..self.slave_len :0];
    }
};

fn openPty() !Pty {
    const master = try posix.openatZ(
        posix.AT.FDCWD,
        "/dev/ptmx",
        .{ .ACCMODE = .RDWR, .NOCTTY = true },
        0,
    );
    errdefer _ = posix.system.close(master);

    var unlock: c_int = 0;
    if (posix.errno(posix.system.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS)
        return error.PtyUnlockFailed;

    var number: c_int = 0;
    if (posix.errno(posix.system.ioctl(master, TIOCGPTN, @intFromPtr(&number))) != .SUCCESS)
        return error.PtyNumberFailed;

    var pty: Pty = .{ .master = master, .slave_path = undefined, .slave_len = 0 };
    const printed = try std.fmt.bufPrintZ(&pty.slave_path, "/dev/pts/{d}", .{number});
    pty.slave_len = printed.len;
    return pty;
}

fn setWinsize(fd: posix.fd_t, rows: u16, cols: u16) !void {
    const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    if (posix.errno(posix.system.ioctl(fd, posix.T.IOCSWINSZ, @intFromPtr(&ws))) != .SUCCESS)
        return error.SetWinsizeFailed;
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + off, bytes.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return;
        off += n;
    }
}

/// Reads whatever is available within `timeout_ms`, appending to `sink`.
/// Returns false once the pty closes, which is how a dead child shows up here.
fn pump(fd: posix.fd_t, sink: *std.ArrayList(u8), gpa: std.mem.Allocator, timeout_ms: i32) !bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&fds, timeout_ms) catch return true;
    if (ready == 0) return true;

    var buf: [8192]u8 = undefined;
    const n = posix.read(fd, &buf) catch return false;
    if (n == 0) return false;
    try sink.appendSlice(gpa, buf[0..n]);
    return true;
}

/// Forks and execs the built binary with `pty`'s slave as its controlling
/// terminal, `cwd` as its working directory. `std.process.Child` cannot do
/// this: the child has to call `setsid` and claim the tty between fork and
/// exec, and vaxis opens `/dev/tty`, which resolves to whatever the process's
/// controlling terminal is.
fn spawnOnPty(pty: *const Pty, cwd: [:0]const u8) !posix.pid_t {
    const bin = e2e_options.clanker_bin ++ "\x00";
    const bin_z: [*:0]const u8 = @ptrCast(bin.ptr);

    const argv = [_:null]?[*:0]const u8{
        bin_z,
        "repl",
        "--mascot=loop",
        "--mascot-size=large",
        "--mascot-speed=7",
    };
    const envp = [_:null]?[*:0]const u8{ "TERM=xterm-256color", "HOME=/tmp" };

    const rc = posix.system.fork();
    if (rc < 0) return error.ForkFailed;
    if (rc != 0) return @intCast(rc);

    // ---- child ----
    // The signal mask survives both fork and exec, and the test runner reaches
    // here with signals blocked (Zig blocks them around thread spawn, and this
    // binary runs an `Io.Threaded` pool). Inheriting that mask leaves the repl
    // with SIGWINCH blocked, so every resize below would be swallowed by the
    // kernel and the flood would prove nothing. Clear it before exec.
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

    _ = posix.system.execve(bin_z, &argv, &envp);
    posix.system._exit(127);
}

/// Non-blocking reap. Returns the raw wait status once the child is gone.
fn reapIfDead(pid: posix.pid_t) ?c_int {
    var status: c_int = 0;
    const rc = posix.system.waitpid(pid, &status, 1); // WNOHANG
    if (rc == pid) return status;
    return null;
}

fn describe(status: c_int) []const u8 {
    // WIFSIGNALED: low 7 bits hold the signal, and are neither 0 nor 0x7f.
    const sig = status & 0x7f;
    return if (sig != 0 and sig != 0x7f) "killed by a signal" else "exited";
}

test "operator journey: repl survives a SIGWINCH flood on a pty" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try harness.writeMockConfig(io, tmp.dir, gpa, 9);
    try harness.linkZigOut(io, tmp.dir);

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try tmp.dir.realPath(io, cwd_buf[0 .. cwd_buf.len - 1]);
    cwd_buf[cwd_len] = 0;
    const cwd_z: [:0]const u8 = cwd_buf[0..cwd_len :0];

    var pty = try openPty();
    defer _ = posix.system.close(pty.master);
    try setWinsize(pty.master, 40, 120);

    const pid = try spawnOnPty(&pty, cwd_z);
    defer {
        _ = posix.system.kill(pid, posix.SIG.KILL);
        var st: c_int = 0;
        _ = posix.system.waitpid(pid, &st, 0);
    }

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(gpa);

    // Query phase: geometry first, then DA1.
    var answered_geometry = false;
    var answered_da1 = false;
    var settle: usize = 0;
    while (settle < 60 and !(answered_geometry and answered_da1)) : (settle += 1) {
        if (!try pump(pty.master, &seen, gpa, 50)) break;
        if (!answered_geometry and std.mem.find(u8, seen.items, "\x1b[?2;1;0S") != null) {
            writeAll(pty.master, geometry_reply);
            answered_geometry = true;
        }
        if (!answered_da1 and answered_geometry and
            std.mem.find(u8, seen.items, "\x1b[c") != null)
        {
            writeAll(pty.master, da1_reply);
            answered_da1 = true;
        }
    }
    try std.testing.expect(answered_geometry);
    try std.testing.expect(answered_da1);

    // Let the repl finish its first paint before touching the size. Answering
    // DA1 ends the *query* phase, not startup; a winsize arriving while the
    // initial layout is still being built gets overwritten by it, and the
    // check below then reads a screen that never grew.
    var warm: usize = 0;
    while (warm < 75) : (warm += 1) {
        if (!try pump(pty.master, &seen, gpa, 20)) break;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }

    // Prove SIGWINCH reaches the app at all before leaning on the flood. The
    // repl started on a 40-row screen; growing to 60 must make it draw down
    // into rows that did not exist before.
    seen.clearRetainingCapacity();
    try setWinsize(pty.master, 60, 200);
    // Sample for up to ~3s of wall clock. `pump` returns the moment bytes are
    // available and the mascot animates continuously, so a bare iteration
    // count burns through in a fraction of a second and reads the screen
    // before the repl has repainted at the new size.
    var settle_tall: usize = 0;
    while (settle_tall < 150) : (settle_tall += 1) {
        if (!try pump(pty.master, &seen, gpa, 20)) break;
        if (maxRowAddressed(seen.items) > 45) break;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    const tall = maxRowAddressed(seen.items);
    if (tall <= 45) std.debug.print(
        "no resize reached the repl: tallest row drawn was {d} after growing to 60 rows\n",
        .{tall},
    );
    try std.testing.expect(tall > 45);

    // Flood. The unfixed build dies around 1500; 4000 leaves clear headroom
    // without making the journey long.
    const sizes = [_][2]u16{
        .{ 40, 120 }, .{ 24, 80 }, .{ 50, 200 }, .{ 30, 100 }, .{ 60, 240 }, .{ 20, 60 },
    };
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const size = sizes[i % sizes.len];
        setWinsize(pty.master, size[0], size[1]) catch break;
        // Keystrokes that never submit a turn: the composer re-lays-out on
        // each one, which is what keeps the event queue contended.
        writeAll(pty.master, "abc\x7f");

        // Pace the flood. SIGWINCH is a standard signal, so a second one
        // raised while the first is still pending is *coalesced*, not queued:
        // resizing as fast as the loop can spin collapses thousands of
        // `TIOCSWINSZ` calls into a handful of deliveries and proves nothing.
        // Leaving ~2ms between changes is what makes each one its own signal.
        var drains: usize = 0;
        while (drains < 8) : (drains += 1) {
            if (!try pump(pty.master, &seen, gpa, 0)) break;
        }
        std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
        if (reapIfDead(pid)) |status| {
            std.debug.print(
                "repl died after {d} resizes ({s}); {d} bytes drawn. " ++
                    "Trace tail:\n{s}\n",
                .{ i, describe(status), seen.items.len, tailOf(seen.items) },
            );
            return error.ReplCrashedOnResize;
        }
        // The transcript is not what this test asserts on; cap it so a long
        // flood cannot grow the buffer without bound.
        if (seen.items.len > 1 << 20) seen.clearRetainingCapacity();
    }

    try std.testing.expect(reapIfDead(pid) == null);
    std.debug.print("pass: operator journey: repl survives a SIGWINCH flood on a pty\n", .{});
}

fn tailOf(bytes: []const u8) []const u8 {
    const want = 2000;
    return if (bytes.len > want) bytes[bytes.len - want ..] else bytes;
}

/// Highest row any `CSI row;col H` cursor move addresses. This is how the test
/// reads back which geometry the app believes it is on: a handler that silently
/// dropped every resize would survive the flood just as happily as a fixed one,
/// so "it did not crash" is only meaningful next to "and it saw the resizes".
///
/// Rows, not columns: the repl anchors its composer to the bottom of the
/// screen, so the tallest row it addresses tracks the height on every frame.
/// Columns do not work — with an empty transcript nothing is drawn out at the
/// right edge, so the widest column stays where the mascot ends no matter how
/// wide the window gets.
fn maxRowAddressed(bytes: []const u8) u32 {
    var best: u32 = 0;
    var i: usize = 0;
    while (i + 2 < bytes.len) : (i += 1) {
        if (bytes[i] != 0x1b or bytes[i + 1] != '[') continue;
        var j = i + 2;
        var row: u32 = 0;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) : (j += 1)
            row = row * 10 + (bytes[j] - '0');
        if (j >= bytes.len or bytes[j] != ';' or j == i + 2) continue;
        j += 1;
        const col_start = j;
        var col: u32 = 0;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) : (j += 1)
            col = col * 10 + (bytes[j] - '0');
        if (j >= bytes.len or bytes[j] != 'H' or j == col_start) continue;
        if (row > best) best = row;
    }
    return best;
}
