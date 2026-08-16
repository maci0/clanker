//! Pure helpers for the spill id format, shared by the `spill` guest and the
//! harness: the guest reads spilled results back through them, and the agent
//! loop derives the ids and builds the locator lines through the same
//! functions, so the format has one host-tested home. Host-tested.

const std = @import("std");

pub const locator_prefix = "[spill id=";

pub fn parseId(text: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, text, locator_prefix) orelse return null;
    const start = at + locator_prefix.len;
    if (start + 8 > text.len) return null;
    const id = text[start .. start + 8];
    for (id) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex) return null;
    }
    return id;
}

/// One-line locator the model can hand to the `spill` guest.
pub fn locatorLine(id: []const u8) [locator_prefix.len + 8 + 1]u8 {
    var out: [locator_prefix.len + 8 + 1]u8 = undefined;
    @memcpy(out[0..locator_prefix.len], locator_prefix);
    @memcpy(out[locator_prefix.len..][0..8], id[0..8]);
    out[out.len - 1] = ']';
    return out;
}

/// 8 lowercase hex chars from a 32-bit FNV of the bytes plus a salt.
pub fn idFor(content: []const u8, salt: u64) [8]u8 {
    var h: u32 = 2166136261;
    for (content) |c| {
        h ^= c;
        h *%= 16777619;
    }
    // Mix in the low 32 bits of the salt; the high half is dropped on purpose.
    h ^= @truncate(salt);
    h *%= 16777619;
    var out: [8]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 8;
    var n = h;
    while (i > 0) {
        i -= 1;
        out[i] = hex[n & 0xf];
        n >>= 4;
    }
    return out;
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

test "locator is 8 hex and round-trips" {
    const id = idFor("hello tool output", 3);
    try std.testing.expectEqual(@as(usize, 8), id.len);
    const line = locatorLine(&id);
    const parsed = parseId(&line) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(&id, parsed);
    try std.testing.expect(parseId("no locator here") == null);
    try std.testing.expect(parseId("[spill id=nothex!!]") == null);
}
