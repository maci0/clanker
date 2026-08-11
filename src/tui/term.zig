//! Raw-mode terminal control and size queries.
//!
//! Split out of the REPL so the raw-mode dance (tcgetattr/tcsetattr) and the
//! terminal-size query (ioctl TIOCGWINSZ) have one home instead of being
//! inlined at each call site. No rendering lives here — just the two ways
//! `src/tui/` needs to talk to the tty device itself.

const std = @import("std");
const linux = std.os.linux;

/// Restores the terminal's original mode. Holds the pre-raw termios so
/// `exit` can undo exactly what `enterRaw` changed, regardless of what else
/// touched the terminal in between.
pub const RawGuard = struct {
    fd: std.posix.fd_t,
    original: std.posix.termios,

    pub fn exit(self: RawGuard) void {
        std.posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
    }
};

/// Puts `fd` into character-at-a-time, no-echo mode: the line editor draws
/// the line itself, so the terminal must not echo input or buffer it into
/// whole lines, and Ctrl-C must arrive as a byte rather than a signal so the
/// REPL can decide what "interrupt" means (clear the line, not exit).
pub fn enterRaw(fd: std.posix.fd_t) !RawGuard {
    const original = std.posix.tcgetattr(fd) catch return error.NotATerminal;
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    std.posix.tcsetattr(fd, .FLUSH, raw) catch return error.NotATerminal;
    return .{ .fd = fd, .original = original };
}

/// Set (atomically, from the signal handler) when a SIGWINCH arrives; the
/// render loop polls and clears it. Async-signal-safe code can do almost
/// nothing — no allocation, no I/O, nothing that could touch a lock the
/// interrupted thread already held — so the handler's entire body is this
/// one store plus a best-effort nudge on `resize_pipe_fds` (see below).
pub var resize_pending: std.atomic.Value(bool) = .init(false);

/// A self-pipe nudged on every SIGWINCH so a blocked `poll()` in the input
/// loop (`input.KeyReader.next`) wakes immediately instead of only noticing
/// a resize on the next real keystroke. `{-1,-1}` (creation never attempted,
/// or failed) is a safe sentinel: `poll()` ignores a negative fd, so a
/// caller degrades to the old "next keystroke" behavior with no branching
/// of its own — see `resizeReadFd`.
var resize_pipe_fds: [2]std.posix.fd_t = .{ -1, -1 };

/// Read end of the resize self-pipe, or `-1` if it doesn't exist.
pub fn resizeReadFd() std.posix.fd_t {
    return resize_pipe_fds[0];
}

fn onSigWinch(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    resize_pending.store(true, .release);
    // Single-byte, best-effort, non-blocking: the atomic flag above (not
    // the byte count) is the real signal, so a full pipe or a dropped byte
    // changes nothing — multiple rapid resizes just coalesce into one wake.
    if (resize_pipe_fds[1] >= 0) _ = std.posix.system.write(resize_pipe_fds[1], &[1]u8{1}, 1);
}

var resize_handler_installed = false;

/// Registers the SIGWINCH handler described by `resize_pending`'s doc
/// comment, and creates the self-pipe `resizeReadFd` reads. Idempotent —
/// safe to call once per REPL start even if that ever happens more than
/// once in a process (e.g. a future session-switch that re-enters the
/// interactive loop).
pub fn installResizeHandler() void {
    if (resize_handler_installed) return;
    resize_handler_installed = true;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSigWinch },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &act, null);

    // Both ends non-blocking: the write end because a signal handler must
    // never block, the read end so the drain loop in KeyReader can empty it
    // without blocking. Failure (fd exhaustion) just leaves both at -1.
    // pipe2 is Linux-flavored, not POSIX: on macOS std.c.pipe2 is a void
    // placeholder ("type 'void' not a function" at compile time), so where
    // it does not exist the flags are set after pipe() with fcntl. The gap
    // between the two calls is harmless here — nothing shares the fds until
    // this function returns.
    var fds: [2]std.posix.fd_t = undefined;
    if (@TypeOf(std.posix.system.pipe2) != void) {
        if (std.posix.errno(std.posix.system.pipe2(&fds, .{ .NONBLOCK = true })) == .SUCCESS) {
            resize_pipe_fds = fds;
        }
    } else {
        if (std.posix.errno(std.c.pipe(&fds)) != .SUCCESS) return;
        const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        for (fds) |fd| {
            const fl = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
            if (fl < 0 or std.c.fcntl(fd, std.c.F.SETFL, fl | nonblock) < 0) {
                for (fds) |f| _ = std.c.close(f);
                return;
            }
        }
        resize_pipe_fds = fds;
    }
}

/// Set (from the signal handler) when a SIGINT arrives while a turn is
/// running. The REPL puts the terminal in raw mode with ISIG off, so at the
/// prompt Ctrl-C is an ordinary keystroke the line editor sees; a turn runs
/// with the terminal restored, and there Ctrl-C is a real signal. Without a
/// handler that signal kills clanker mid-run, which is what made a long turn
/// unstoppable except by losing the session.
///
/// Same async-signal-safety rule as the resize flag: the handler's whole body
/// is one store, and the agent loop polls it between iterations.
pub var interrupt_pending: std.atomic.Value(bool) = .init(false);

fn onSigInt(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    interrupt_pending.store(true, .release);
}

var interrupt_handler_installed = false;

/// Makes Ctrl-C during a turn set `interrupt_pending` instead of killing the
/// process. Idempotent, like the resize handler.
pub fn installInterruptHandler() void {
    if (interrupt_handler_installed) return;
    interrupt_handler_installed = true;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &act, null);
}

pub const Size = struct { rows: u16, cols: u16 };

/// Current terminal size in rows/cols, or null if `fd` isn't a terminal (or
/// the kernel reports a degenerate 0x0, which some pty setups do before the
/// first resize).
pub fn getSize(fd: std.posix.fd_t) ?Size {
    var ws: std.posix.winsize = undefined;
    const rc = linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (std.posix.errno(rc) != .SUCCESS) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ .rows = ws.row, .cols = ws.col };
}
