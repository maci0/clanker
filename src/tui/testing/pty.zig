//! A hand-rolled pseudo-terminal for pty-driven integration tests.
//!
//! Zig's std ships no `forkpty()` wrapper, and this build doesn't link libc
//! (see build.zig's musl-without-libc note), so `grantpt`/`unlockpt` aren't
//! available either. This does what they do internally, in raw syscalls:
//! open `/dev/ptmx`, unlock the slave via the `TIOCSPTLCK` ioctl (skipping
//! `grantpt`'s chown — a same-uid devpts mount already permits opening the
//! slave), read the slave number via `TIOCGPTN`, then `fork` + `setsid` +
//! `TIOCSCTTY` + `execve` in the child.
//!
//! Only for tests: `zig build tui-test`, never `zig build test` (see
//! build.zig's step comment for why they're separate).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

fn check(rc: usize) !void {
    if (posix.errno(rc) != .SUCCESS) return error.SyscallFailed;
}

fn ioctlChecked(fd: posix.fd_t, request: u32, arg: usize) !void {
    try check(linux.ioctl(fd, request, arg));
}

pub const Pty = struct {
    master: posix.fd_t,
    child: posix.pid_t,

    /// Opens a pty pair, forks, and `execve()`s `path` in the child with the
    /// slave as its controlling terminal (stdin/stdout/stderr all dup'd
    /// from it) at `cols`x`rows`. The parent gets `master` back to read and
    /// write the child's terminal I/O.
    pub fn spawn(
        path: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
        cols: u16,
        rows: u16,
    ) !Pty {
        const master_rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        try check(master_rc);
        const master: posix.fd_t = @intCast(master_rc);
        errdefer _ = linux.close(master);

        // unlockpt(): without this the slave can be opened but every I/O
        // call on it fails with EIO.
        var unlock: c_int = 0;
        try ioctlChecked(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock));

        var slave_num: c_uint = 0;
        try ioctlChecked(master, linux.T.IOCGPTN, @intFromPtr(&slave_num));

        var ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        try ioctlChecked(master, linux.T.IOCSWINSZ, @intFromPtr(&ws));

        var slave_path_buf: [32]u8 = undefined;
        const slave_path = try std.fmt.bufPrintZ(&slave_path_buf, "/dev/pts/{d}", .{slave_num});

        const pid_rc = linux.fork();
        try check(pid_rc);
        const pid: isize = @bitCast(pid_rc);
        if (pid == 0) {
            // Child: raw syscalls only from here to execve — no allocation,
            // no stdlib call that might be holding a lock the parent had.
            _ = linux.close(master);
            _ = linux.setsid();
            const slave_rc = linux.open(slave_path.ptr, .{ .ACCMODE = .RDWR }, 0);
            if (posix.errno(slave_rc) != .SUCCESS) linux.exit(126);
            const slave: posix.fd_t = @intCast(slave_rc);
            _ = linux.ioctl(slave, linux.T.IOCSCTTY, 0);
            _ = linux.dup2(slave, 0);
            _ = linux.dup2(slave, 1);
            _ = linux.dup2(slave, 2);
            if (slave > 2) _ = linux.close(slave);
            _ = linux.execve(path, argv, envp);
            linux.exit(127); // execve only returns on failure
        }

        return .{ .master = master, .child = @intCast(pid) };
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        return posix.read(self.master, buf);
    }

    pub fn write(self: *Pty, bytes: []const u8) !usize {
        const rc = linux.write(self.master, bytes.ptr, bytes.len);
        try check(rc);
        return rc;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        var ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        try ioctlChecked(self.master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
        // The kernel only sends SIGWINCH to the pty's foreground process
        // group on an actual change; setting winsize via ioctl on the
        // master does exactly that (this is the same mechanism a real
        // terminal emulator uses when its window is resized).
    }

    /// Blocks until the child exits; returns its raw wait status
    /// (`std.posix.W.EXITSTATUS`/`W.IFSIGNALED` etc. decode it).
    pub fn wait(self: *Pty) !u32 {
        var status: u32 = undefined;
        while (true) {
            const rc = linux.waitpid(self.child, &status, 0);
            const e = posix.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return error.WaitFailed;
            return status;
        }
    }

    /// Sends the child a signal directly — used by tests that want to
    /// verify SIGWINCH handling without waiting on the kernel's own
    /// resize-triggers-WINCH plumbing (`resize` above already exercises
    /// that path; this is for isolating "does our handler behave" from
    /// "does the kernel deliver the signal").
    pub fn signal(self: *Pty, sig: posix.SIG) !void {
        try posix.kill(self.child, sig);
    }

    pub fn close(self: *Pty) void {
        _ = linux.close(self.master);
    }
};

/// Builds a null-terminated C-style argv array (`execve`'s expected shape)
/// from plain Zig strings, arena-owned.
pub fn buildArgv(arena: std.mem.Allocator, parts: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const out = try arena.allocSentinel(?[*:0]const u8, parts.len, null);
    for (parts, 0..) |p, i| out[i] = try arena.dupeZ(u8, p);
    return out.ptr;
}

test "buildArgv null-terminates and preserves order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const argv = try buildArgv(arena_state.allocator(), &.{ "clanker", "repl" });
    try std.testing.expectEqualStrings("clanker", std.mem.span(argv[0].?));
    try std.testing.expectEqualStrings("repl", std.mem.span(argv[1].?));
    try std.testing.expect(argv[2] == null);
}
