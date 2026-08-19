//! Host-clipboard fallback for `clanker repl`.
//!
//! Copying normally goes through OSC 52, which only works when the hosting
//! terminal implements (and enables) it. This module offers a best-effort
//! fallback that pipes the text into a platform clipboard tool instead. It is
//! deliberately silent: every error is swallowed, so a missing `wl-copy` or a
//! headless DISPLAY never breaks a copy that OSC 52 already handled.

const std = @import("std");
const builtin = @import("builtin");

const macos_candidates = [_][]const []const u8{
    &.{"pbcopy"},
};

const wayland_candidates = [_][]const []const u8{
    &.{"wl-copy"},
    &.{ "xclip", "-selection", "clipboard" },
    &.{ "xsel", "--clipboard", "--input" },
};

const x11_candidates = [_][]const []const u8{
    &.{ "xclip", "-selection", "clipboard" },
    &.{ "xsel", "--clipboard", "--input" },
};

/// Clipboard commands to try, in order. Each element is a full argv. The
/// caller picks the platform by passing its own booleans; this stays pure so
/// it can be tested without a display.
pub fn candidates(is_macos: bool, wayland: bool, x11: bool) []const []const []const u8 {
    if (is_macos) return &macos_candidates;
    if (wayland) return &wayland_candidates;
    if (x11) return &x11_candidates;
    return &.{};
}

test "candidates" {
    const wayland = candidates(false, true, false);
    try std.testing.expectEqualStrings("wl-copy", wayland[0][0]);
    const macos = candidates(true, false, false);
    try std.testing.expectEqualStrings("pbcopy", macos[0][0]);
}

/// Pipe `text` into the first available clipboard command. wayland/x11 are
/// detected from WAYLAND_DISPLAY / DISPLAY in `environ_map`; macOS is detected
/// from the build target. Returns on the first command that exits 0; any
/// spawn/write/wait failure just moves on to the next candidate.
pub fn copyBestEffort(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: anytype,
    text: []const u8,
) void {
    _ = gpa;
    const is_macos = builtin.os.tag == .macos;
    const wayland = environ_map.get("WAYLAND_DISPLAY") != null;
    const x11 = environ_map.get("DISPLAY") != null;
    for (candidates(is_macos, wayland, x11)) |argv| {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        var waited = false;
        defer {
            // Every failure path above `continue`s past `child.wait`, leaving
            // the tool signaled-but-unreaped (a zombie per failed candidate)
            // with the stdin pipe still open in the parent. Kill blocks until
            // the process is gone and cleans its resources, so this reaps the
            // stragglers the same way a `wait` would.
            if (!waited) child.kill(io);
        }
        if (child.stdin) |stdin_file| {
            var wbuf: [4096]u8 = undefined;
            var writer = stdin_file.writer(io, &wbuf);
            const wrote = blk: {
                writer.interface.writeAll(text) catch break :blk false;
                writer.interface.flush() catch break :blk false;
                break :blk true;
            };
            // Close the write end on every path, not just the happy one:
            // skipping it on failure leaked a pipe handle per candidate, and
            // EOF is also what tells the tool its input is complete.
            stdin_file.close(io);
            child.stdin = null;
            if (!wrote) continue;
        }
        const term = child.wait(io) catch continue;
        waited = true;
        if (term == .exited and term.exited == 0) return;
    }
}
