//! Leveled logging to stderr: single-write-per-line prefixed output.

const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    error_,

    pub fn fromStr(s: []const u8) ?Level {
        // Closed set; the stored tag is `error_` so stringToEnum cannot
        // accept the operator-facing spelling "error" on its own.
        const names = std.StaticStringMap(Level).initComptime(.{
            .{ "debug", .debug },
            .{ "info", .info },
            .{ "warn", .warn },
            .{ "error", .error_ },
        });
        return names.get(s);
    }
};

test "Level.fromStr accepts operator spellings" {
    try std.testing.expectEqual(Level.debug, Level.fromStr("debug").?);
    try std.testing.expectEqual(Level.info, Level.fromStr("info").?);
    try std.testing.expectEqual(Level.warn, Level.fromStr("warn").?);
    try std.testing.expectEqual(Level.error_, Level.fromStr("error").?);
    try std.testing.expect(Level.fromStr("error_") == null);
    try std.testing.expect(Level.fromStr("nope") == null);
}

var current_level = std.atomic.Value(u8).init(@intFromEnum(Level.info));

/// Correlation context is thread-local so concurrent HTTP connections can
/// attach their request id to logs emitted deep in the agent/sandbox stack.
/// Keep this deliberately small and opaque: callers must not put request
/// bodies, credentials, or other user-controlled data here.
threadlocal var context: []const u8 = "";

pub fn setLevel(l: Level) void {
    current_level.store(@intFromEnum(l), .release);
}

pub fn getLevel() Level {
    return @enumFromInt(current_level.load(.acquire));
}

pub fn setContext(value: []const u8) void {
    context = value;
}

pub fn clearContext() void {
    context = "";
}

pub fn getContext() []const u8 {
    return context;
}

fn unixMilliseconds() i128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i128, ts.nsec), std.time.ns_per_ms);
}

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < current_level.load(.acquire)) return;
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
    w.print("[{s}] ts_ms={d}", .{ prefix, unixMilliseconds() }) catch {};
    if (context.len > 0) w.print(" request_id={s}", .{context}) catch {};
    w.writeByte(' ') catch {};
    w.print(fmt, args) catch {};
    // A tool/provider error may contain newlines. Preserve the information
    // while keeping one physical line per event for log collectors.
    for (buf[0..w.end]) |*byte| {
        if (byte.* == '\n' or byte.* == '\r') byte.* = ' ';
    }
    w.writeByte('\n') catch {
        // Message longer than the buffer: keep the truncated head and still
        // terminate the line.
        buf[buf.len - 1] = '\n';
        w.end = buf.len;
    };
    std.debug.print("{s}", .{buf[0..w.end]});
}
