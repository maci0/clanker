//! Small helpers for pulling typed fields out of a parsed `std.json.Value` object.

const std = @import("std");

/// Appends a JSON string literal (quoted, escaped) to `out`.
pub fn appendJsonString(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            0x08 => try out.appendSlice(arena, "\\b"),
            0x0c => try out.appendSlice(arena, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try out.appendSlice(arena, "\\u00");
                const hex = "0123456789abcdef";
                try out.append(arena, hex[c >> 4]);
                try out.append(arena, hex[c & 0x0f]);
            },
            else => try out.append(arena, c),
        }
    }
    try out.append(arena, '"');
}

/// Non-empty string field from a plugin/tool descriptor config object.
pub fn pluginStr(cfg_value: std.json.Value, key: []const u8) ?[]const u8 {
    if (cfg_value != .object) return null;
    const v = cfg_value.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

/// Positive u32 field from a plugin/tool descriptor config object.
pub fn pluginU32(cfg_value: std.json.Value, key: []const u8) ?u32 {
    if (cfg_value != .object) return null;
    const v = cfg_value.object.get(key) orelse return null;
    // Reject out-of-u32-range values instead of panicking in @intCast (a
    // plugin's tool.json is not trusted input).
    if (v == .integer and v.integer > 0 and v.integer <= std.math.maxInt(u32)) return @intCast(v.integer);
    return null;
}

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

test "appendJsonString escapes all JSON control characters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try appendJsonString(arena, &out, "a\x00b\x08c\x0cd\x1fe");
    try std.testing.expectEqualStrings("\"a\\u0000b\\bc\\fd\\u001fe\"", out.items);

    out.clearRetainingCapacity();
    try appendJsonString(arena, &out, "\x01\x0b\x0e\x1f");
    try std.testing.expectEqualStrings("\"\\u0001\\u000b\\u000e\\u001f\"", out.items);

    out.clearRetainingCapacity();
    try appendJsonString(arena, &out, "clean");
    try std.testing.expectEqualStrings("\"clean\"", out.items);
}

test "pluginStr and pluginU32 fall back to null on missing, empty, or wrong-typed fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"provider\":\"kimi\",\"model\":\"m1\",\"max_tokens\":512}", .{});
    try std.testing.expectEqualStrings("kimi", pluginStr(v, "provider").?);
    try std.testing.expectEqualStrings("m1", pluginStr(v, "model").?);
    try std.testing.expect(pluginStr(v, "missing") == null);
    try std.testing.expectEqual(@as(?u32, 512), pluginU32(v, "max_tokens"));

    const arr = try std.json.parseFromSliceLeaky(std.json.Value, arena, "[1,2]", .{});
    try std.testing.expect(pluginStr(arr, "provider") == null);
    try std.testing.expect(pluginU32(arr, "max_tokens") == null);

    const bad = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"provider\":\"\",\"max_tokens\":0}", .{});
    try std.testing.expect(pluginStr(bad, "provider") == null);
    try std.testing.expect(pluginU32(bad, "max_tokens") == null);

    const huge = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"max_tokens\":9000000000}", .{});
    try std.testing.expect(pluginU32(huge, "max_tokens") == null);
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
