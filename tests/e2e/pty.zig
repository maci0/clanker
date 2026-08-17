//! Shared pty plumbing for operator journeys that must run the repl on a real
//! controlling terminal (vaxis opens `/dev/tty`, so nothing short of a pty
//! exercises the real TUI). Extracted from pty_resize_test.zig so a second
//! pty journey does not re-derive the fork/setsid/TIOCSCTTY dance.

const std = @import("std");
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
/// renderer never engages.
pub const geometry_reply = "\x1b[?2;0;10000;10000S";
pub const da1_reply = "\x1b[?62;4;22c";

pub const Pty = struct {
    master: posix.fd_t,
    slave_path: [32]u8,
    slave_len: usize,

    pub fn slave(self: *const Pty) [:0]const u8 {
        return self.slave_path[0..self.slave_len :0];
    }
};

pub fn openPty() !Pty {
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

pub fn setWinsize(fd: posix.fd_t, rows: u16, cols: u16) !void {
    const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    if (posix.errno(posix.system.ioctl(fd, posix.T.IOCSWINSZ, @intFromPtr(&ws))) != .SUCCESS)
        return error.SetWinsizeFailed;
}

pub fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
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
pub fn pump(fd: posix.fd_t, sink: *std.ArrayList(u8), gpa: std.mem.Allocator, timeout_ms: i32) !bool {
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

/// Answers vaxis's startup capability queries as they arrive in `seen`.
/// Returns true once both the geometry query and DA1 have been answered,
/// which is what ends the repl's query phase.
pub fn answerQueries(master: posix.fd_t, seen: *std.ArrayList(u8), gpa: std.mem.Allocator) !bool {
    var answered_geometry = false;
    var answered_da1 = false;
    var settle: usize = 0;
    while (settle < 60 and !(answered_geometry and answered_da1)) : (settle += 1) {
        if (!try pump(master, seen, gpa, 50)) break;
        if (!answered_geometry and std.mem.find(u8, seen.items, "\x1b[?2;1;0S") != null) {
            writeAll(master, geometry_reply);
            answered_geometry = true;
        }
        if (!answered_da1 and answered_geometry and
            std.mem.find(u8, seen.items, "\x1b[c") != null)
        {
            writeAll(master, da1_reply);
            answered_da1 = true;
        }
    }
    return answered_geometry and answered_da1;
}
