//! Small helpers for pulling typed fields out of a parsed `std.json.Value` object.

const std = @import("std");

/// Returns the string value of `key`, or an error if absent or not a string.
pub fn strField(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    return switch (v) {
        .string => |s| s,
        else => error.FieldNotString,
    };
}

test strField {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "name", .{ .string = "clanker" });
    try obj.put(arena, "count", .{ .integer = 3 });

    try std.testing.expectEqualStrings("clanker", try strField(obj, "name"));
    try std.testing.expectError(error.FieldNotString, strField(obj, "count"));
    try std.testing.expectError(error.MissingField, strField(obj, "missing"));
}
