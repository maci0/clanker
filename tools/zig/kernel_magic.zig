//! Magic-prefix parse for the `kernel` guest. Host-tested so the dialect
//! cannot drift from the PRD table.

const std = @import("std");

pub const Kind = enum { pip, time, bash, bang, cell };

pub const Parsed = struct {
    kind: Kind,
    rest: []const u8,
};

pub fn parse(cell: []const u8) Parsed {
    const trimmed = std.mem.trimStart(u8, cell, " \t");
    if (std.mem.startsWith(u8, trimmed, "%pip ")) {
        return .{ .kind = .pip, .rest = std.mem.trim(u8, trimmed["%pip ".len..], " \t\r\n") };
    }
    if (std.mem.startsWith(u8, trimmed, "%time")) {
        const after = trimmed["%time".len..];
        const rest = if (after.len > 0 and (after[0] == ' ' or after[0] == '\n')) after[1..] else after;
        return .{ .kind = .time, .rest = rest };
    }
    if (std.mem.startsWith(u8, trimmed, "%%bash")) {
        const after = trimmed["%%bash".len..];
        const rest = if (after.len > 0 and after[0] == '\n') after[1..] else std.mem.trimStart(u8, after, " \t");
        return .{ .kind = .bash, .rest = rest };
    }
    if (std.mem.startsWith(u8, trimmed, "!")) {
        return .{ .kind = .bang, .rest = std.mem.trim(u8, trimmed[1..], " \t\r\n") };
    }
    return .{ .kind = .cell, .rest = cell };
}

test "magic prefixes match the PRD table" {
    try std.testing.expectEqual(Kind.pip, parse("%pip install requests").kind);
    try std.testing.expectEqualStrings("install requests", parse("%pip install requests").rest);
    try std.testing.expectEqual(Kind.time, parse("%time print(1)").kind);
    try std.testing.expectEqualStrings("print(1)", parse("%time print(1)").rest);
    try std.testing.expectEqual(Kind.bash, parse("%%bash\nls").kind);
    try std.testing.expectEqualStrings("ls", parse("%%bash\nls").rest);
    try std.testing.expectEqual(Kind.bang, parse("!echo hi").kind);
    try std.testing.expectEqualStrings("echo hi", parse("!echo hi").rest);
    try std.testing.expectEqual(Kind.cell, parse("1 + 1").kind);
}

test "leading whitespace is ignored" {
    try std.testing.expectEqual(Kind.pip, parse("  %pip install x").kind);
}
