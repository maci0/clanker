//! Pure helpers for the spill guest. Host-tested.

const std = @import("std");

pub const locator_prefix = "[spill id=";

pub fn parseId(text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, locator_prefix) orelse return null;
    const start = at + locator_prefix.len;
    if (start + 8 > text.len) return null;
    const id = text[start .. start + 8];
    for (id) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex) return null;
    }
    return id;
}

pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

pub fn validId(id: []const u8) bool {
    if (id.len != 8) return false;
    for (id) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex) return false;
    }
    return true;
}

pub fn pathFor(session_id: []const u8, id: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "state/spills/{s}/{s}.txt", .{ session_id, id });
}

test "parseId accepts only 8 lowercase hex" {
    try std.testing.expectEqualStrings("deadbeef", parseId("head\n[spill id=deadbeef]\n") orelse "");
    try std.testing.expect(parseId("[spill id=DEADBEEF]") == null);
    try std.testing.expect(parseId("[spill id=short]") == null);
    try std.testing.expect(validId("cafebabe"));
    try std.testing.expect(!validId("cafe"));
    try std.testing.expect(validSessionId("default"));
    try std.testing.expect(!validSessionId("../x"));
}
