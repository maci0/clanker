//! Small helpers for pulling typed fields out of a parsed `std.json.Value` object.

const std = @import("std");

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

/// Tolerant string field: missing or non-string reads as "". The wire-format
/// readers (mesh frames, tool answers) all want a value, not an error, when a
/// field is absent; "" and "the field is not there" are the same at those call
/// sites. An empty string is kept as-is.
pub fn strFieldOrEmpty(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// Tolerant string field: missing or non-string reads as null. Unlike
/// `strFieldOrEmpty`, a caller can tell "absent" apart from "empty"; callers
/// that must drop empty strings check `.len` themselves.
pub fn strFieldOrNull(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

test "strField rejects missing and non-string values" {
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

test "strFieldOrEmpty and strFieldOrNull read tolerant string fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"name\":\"x\",\"empty\":\"\",\"n\":3,\"b\":true,\"arr\":[1]}", .{});
    const obj = v.object;

    // Present string: both return it, empty string included.
    try std.testing.expectEqualStrings("x", strFieldOrEmpty(obj, "name"));
    try std.testing.expectEqualStrings("x", strFieldOrNull(obj, "name").?);
    try std.testing.expectEqualStrings("", strFieldOrEmpty(obj, "empty"));
    try std.testing.expectEqualStrings("", strFieldOrNull(obj, "empty").?);

    // Missing, and non-string values: empty vs null by contract.
    try std.testing.expectEqualStrings("", strFieldOrEmpty(obj, "missing"));
    try std.testing.expect(strFieldOrNull(obj, "missing") == null);
    try std.testing.expectEqualStrings("", strFieldOrEmpty(obj, "n"));
    try std.testing.expect(strFieldOrNull(obj, "n") == null);
    try std.testing.expectEqualStrings("", strFieldOrEmpty(obj, "b"));
    try std.testing.expect(strFieldOrNull(obj, "b") == null);
    try std.testing.expectEqualStrings("", strFieldOrEmpty(obj, "arr"));
    try std.testing.expect(strFieldOrNull(obj, "arr") == null);
}
