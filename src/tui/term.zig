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
/// one store, nothing more.
///
/// This means a resize is only picked up the next time something already
/// reads from stdin (the next keystroke) or explicitly polls this flag —
/// there's no `EINTR`-driven redraw of a truly idle prompt. Interrupting the
/// blocking `read()` in `input.readKey` would need disabling `SA_RESTART`
/// (a portability landmine) or a self-pipe (extra fd plumbing) for a
/// cosmetic win: a resize during a genuinely idle prompt looks stale until
/// the user's next keystroke. Accepted, not chased.
pub var resize_pending: std.atomic.Value(bool) = .init(false);

fn onSigWinch(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    resize_pending.store(true, .release);
}

var resize_handler_installed = false;

/// Registers the SIGWINCH handler described by `resize_pending`'s doc
/// comment. Idempotent — safe to call once per REPL start even if that ever
/// happens more than once in a process (e.g. a future session-switch that
/// re-enters the interactive loop).
pub fn installResizeHandler() void {
    if (resize_handler_installed) return;
    resize_handler_installed = true;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSigWinch },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &act, null);
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
