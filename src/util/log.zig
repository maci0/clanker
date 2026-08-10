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

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(current_level)) return;
    const prefix = switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .error_ => "ERROR",
    };
    std.debug.print("[{s}] ", .{prefix});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}
