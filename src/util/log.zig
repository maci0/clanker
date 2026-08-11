//! Leveled logging to stderr: single-write-per-line prefixed output.

const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    error_,

    pub fn fromStr(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .error_;
        return null;
    }
};

var current_level: Level = .info;

pub fn setLevel(l: Level) void {
    current_level = l;
}

pub fn getLevel() Level {
    return current_level;
}

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(current_level)) return;
    const prefix = switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .error_ => "ERROR",
    };
    // One write per line: tools run on worker threads and the model's tokens
    // stream to stdout at the same time, so a line split across several prints
    // interleaves with them mid-word.
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("[{s}] ", .{prefix}) catch {};
    w.print(fmt, args) catch {};
    w.writeByte('\n') catch {
        // Message longer than the buffer: keep the truncated head and still
        // terminate the line.
        buf[buf.len - 1] = '\n';
        w.end = buf.len;
    };
    std.debug.print("{s}", .{buf[0..w.end]});
}
