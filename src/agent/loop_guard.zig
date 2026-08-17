//! Deterministic detection of consecutive, equivalent tool calls.

const std = @import("std");
const utf8 = @import("../util/utf8.zig");

pub const Event = struct {
    tool_name: []const u8,
    canonical_args: []const u8,
    count: u32,
    detailed: bool,
};

pub const LoopGuard = struct {
    last_name: []const u8 = "",
    last_args: []const u8 = "",
    count: u32 = 0,

    pub fn observe(self: *LoopGuard, arena: std.mem.Allocator, name: []const u8, arguments: []const u8, thresholds: []const u32, exclude: []const []const u8) !?Event {
        for (exclude) |pattern| if (matchesPattern(pattern, name)) return null;

        const args = canonicalize(arena, arguments) catch try arena.dupe(u8, std.mem.trim(u8, arguments, " \t\r\n"));
        if (std.mem.eql(u8, self.last_name, name) and std.mem.eql(u8, self.last_args, args)) {
            self.count += 1;
        } else {
            self.last_name = try arena.dupe(u8, name);
            self.last_args = args;
            self.count = 1;
        }
        for (thresholds, 0..) |threshold, i| {
            if (self.count == threshold) return .{
                .tool_name = self.last_name,
                .canonical_args = self.last_args,
                .count = self.count,
                .detailed = i != 0,
            };
        }
        return null;
    }
};

pub fn canonicalize(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try writeValue(arena, &stringify, value);
    return out.written();
}

fn writeValue(arena: std.mem.Allocator, s: *std.json.Stringify, value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            var keys: std.ArrayList([]const u8) = .empty;
            var it = object.iterator();
            while (it.next()) |entry| try keys.append(arena, entry.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
            try s.beginObject();
            for (keys.items) |key| {
                try s.objectField(key);
                try writeValue(arena, s, object.get(key).?);
            }
            try s.endObject();
        },
        .array => |array| {
            try s.beginArray();
            for (array.items) |item| try writeValue(arena, s, item);
            try s.endArray();
        },
        else => try s.write(value),
    }
}

fn matchesPattern(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    const star = std.mem.findScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, name);
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    return name.len >= prefix.len + suffix.len and std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, suffix);
}

pub fn argsPreview(arguments: []const u8) []const u8 {
    return utf8.cap(arguments, 512);
}

test "canonicalization recursively sorts object keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try canonicalize(arena, "{\"z\":[{\"b\":2,\"a\":1}],\"a\":0}");
    const b = try canonicalize(arena, "{\"a\":0,\"z\":[{\"a\":1,\"b\":2}]}");
    try std.testing.expectEqualStrings("{\"a\":0,\"z\":[{\"a\":1,\"b\":2}]}", a);
    try std.testing.expectEqualStrings(a, b);
}

test "excluded calls are transparent and different calls reset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var guard: LoopGuard = .{};
    const thresholds = [_]u32{ 2, 3 };
    try std.testing.expect((try guard.observe(arena, "read", "{\"b\":2,\"a\":1}", &thresholds, &.{"todo_*"})) == null);
    try std.testing.expect((try guard.observe(arena, "todo_list", "{}", &thresholds, &.{"todo_*"})) == null);
    const event = (try guard.observe(arena, "read", "{\"a\":1,\"b\":2}", &thresholds, &.{"todo_*"})).?;
    try std.testing.expectEqual(@as(u32, 2), event.count);
    try std.testing.expect((try guard.observe(arena, "write", "{}", &thresholds, &.{})) == null);
    try std.testing.expect((try guard.observe(arena, "read", "{\"a\":1,\"b\":2}", &thresholds, &.{})) == null);
}

test "the running count is what an abort threshold reads, not the reminder list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var guard: LoopGuard = .{};
    // The reminder thresholds stop at 5; an abort threshold above them still
    // has to be reachable, so the count must keep climbing past the last one.
    const thresholds = [_]u32{ 3, 5 };
    for (0..7) |_| _ = try guard.observe(arena, "jobs", "{\"op\":\"list\"}", &thresholds, &.{});
    try std.testing.expectEqual(@as(u32, 7), guard.count);

    // A different call resets it, so an abort threshold cannot fire on a run
    // that is varying its arguments (the shape the reminders already miss).
    _ = try guard.observe(arena, "jobs", "{\"op\":\"wait\"}", &thresholds, &.{});
    try std.testing.expectEqual(@as(u32, 1), guard.count);

    // An excluded call is transparent: it neither counts nor breaks a chain.
    _ = try guard.observe(arena, "todo_list", "{}", &thresholds, &.{"todo_*"});
    try std.testing.expectEqual(@as(u32, 1), guard.count);
}

test "configured thresholds fire once and stop after the maximum" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var guard: LoopGuard = .{};
    const thresholds = [_]u32{ 3, 5 };
    var fired: std.ArrayList(u32) = .empty;
    for (0..7) |_| {
        if (try guard.observe(arena, "read", "{}", &thresholds, &.{})) |event| try fired.append(arena, event.count);
    }
    try std.testing.expectEqualSlices(u32, &thresholds, fired.items);
}
