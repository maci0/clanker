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

/// Returns the integer value of `key`, or an error if absent or not an integer.
pub fn intField(obj: std.json.ObjectMap, key: []const u8) !i64 {
    const v = obj.get(key) orelse return error.MissingField;
    return switch (v) {
        .integer => |i| i,
        else => error.FieldNotInt,
    };
}

/// Returns the boolean value of `key`, or an error if absent or not a boolean.
pub fn boolField(obj: std.json.ObjectMap, key: []const u8) !bool {
    const v = obj.get(key) orelse return error.MissingField;
    return switch (v) {
        .bool => |b| b,
        else => error.FieldNotBool,
    };
}

test "json field helpers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "name", .{ .string = "clanker" });
    try obj.put(arena, "count", .{ .integer = 3 });
    try obj.put(arena, "active", .{ .bool = true });

    try std.testing.expectEqualStrings("clanker", try strField(obj, "name"));
    try std.testing.expectError(error.FieldNotString, strField(obj, "count"));
    try std.testing.expectError(error.MissingField, strField(obj, "missing"));

    try std.testing.expectEqual(@as(i64, 3), try intField(obj, "count"));
    try std.testing.expectError(error.FieldNotInt, intField(obj, "name"));
    try std.testing.expectError(error.MissingField, intField(obj, "missing"));

    try std.testing.expectEqual(true, try boolField(obj, "active"));
    try std.testing.expectError(error.FieldNotBool, boolField(obj, "name"));
    try std.testing.expectError(error.MissingField, boolField(obj, "missing"));
}
