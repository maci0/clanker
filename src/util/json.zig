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

/// Returns the float value of `key`, or an error if absent or not a number.
pub fn floatField(obj: std.json.ObjectMap, key: []const u8) !f64 {
    const v = obj.get(key) orelse return error.MissingField;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.FieldNotNumber,
    };
}

/// Returns a slice of string values for `key`, or an error if absent or not an array of strings.
pub fn strListField(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    const arr = switch (v) {
        .array => |a| a,
        else => return error.FieldNotStringArray,
    };
    const strings = try alloc.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        strings[i] = switch (item) {
            .string => |s| s,
            else => return error.FieldNotStringArray,
        };
    }
    return strings;
}

test "json field helpers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "name", .{ .string = "clanker" });
    try obj.put(arena, "count", .{ .integer = 3 });
    try obj.put(arena, "active", .{ .bool = true });
    try obj.put(arena, "ratio", .{ .float = 1.5 });

    try std.testing.expectEqualStrings("clanker", try strField(obj, "name"));
    try std.testing.expectError(error.FieldNotString, strField(obj, "count"));
    try std.testing.expectError(error.MissingField, strField(obj, "missing"));

    try std.testing.expectEqual(@as(i64, 3), try intField(obj, "count"));
    try std.testing.expectError(error.FieldNotInt, intField(obj, "name"));
    try std.testing.expectError(error.MissingField, intField(obj, "missing"));

    try std.testing.expectEqual(true, try boolField(obj, "active"));
    try std.testing.expectError(error.FieldNotBool, boolField(obj, "name"));
    try std.testing.expectError(error.MissingField, boolField(obj, "missing"));

    try std.testing.expectEqual(@as(f64, 1.5), try floatField(obj, "ratio"));
    try std.testing.expectEqual(@as(f64, 3.0), try floatField(obj, "count"));
    try std.testing.expectError(error.FieldNotNumber, floatField(obj, "name"));
    try std.testing.expectError(error.MissingField, floatField(obj, "missing"));
}

test "strListField: string arrays, non-array, missing key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"list\":[\"a\",\"b\"]}", .{});
    const obj = parsed.object;
    const list = try strListField(arena, obj, "list");
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a", list[0]);
    try std.testing.expectEqualStrings("b", list[1]);

    const parsed2 = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"list\":\"nope\"}", .{});
    try std.testing.expectError(error.FieldNotStringArray, strListField(arena, parsed2.object, "list"));

    try std.testing.expectError(error.MissingField, strListField(arena, parsed.object, "nope"));
}
