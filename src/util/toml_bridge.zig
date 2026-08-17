//! Converts parsed TOML values into the JSON value tree used by configuration.

const std = @import("std");
const json = std.json;
const toml = @import("toml");

/// Parses TOML source into a std.json.Value tree so callers can reuse
/// existing json.Value-based config parsing unchanged. Allocates from
/// `arena` only (leaky, matching parseFromSliceLeaky elsewhere in config.zig).
pub fn parseToJsonValue(arena: std.mem.Allocator, raw: []const u8) !json.Value {
    var line: ?usize = null;
    return parseToJsonValueAtLine(arena, raw, &line);
}

/// Like `parseToJsonValue`, but returns the TOML parser's one-based source
/// line when syntax parsing fails.  The JSON tree deliberately has no source
/// spans, so callers that turn it into a schema need this boundary to retain
/// useful syntax diagnostics.
pub fn parseToJsonValueAtLine(arena: std.mem.Allocator, raw: []const u8, error_line: *?usize) !json.Value {
    var parser = toml.Parser(toml.Table).init(arena);
    defer parser.deinit();
    const result = parser.parseString(raw) catch |err| {
        if (parser.error_info) |info| switch (info) {
            .parse => |position| error_line.* = position.line,
            else => {},
        };
        return err;
    };
    return tableToJson(arena, result.value);
}

fn tableToJson(arena: std.mem.Allocator, table: toml.Table) !json.Value {
    var obj: json.ObjectMap = .empty;
    var it = table.iterator();
    while (it.next()) |entry| {
        try obj.put(arena, entry.key_ptr.*, try valueToJson(arena, entry.value_ptr.*));
    }
    return json.Value{ .object = obj };
}

fn valueToJson(arena: std.mem.Allocator, value: toml.Value) (std.mem.Allocator.Error || error{ UnsupportedTomlType, NonFiniteFloat })!json.Value {
    return switch (value) {
        .string => |s| json.Value{ .string = s },
        .integer => |i| json.Value{ .integer = i },
        .float => |f| blk: {
            // TOML allows inf and nan; JSON does not. Rejecting at the
            // boundary keeps a non-finite value from drifting into
            // downstream JSON serialization and turns it into a precise
            // config-load failure naming the value's nature.
            if (!std.math.isFinite(f)) return error.NonFiniteFloat;
            break :blk json.Value{ .float = f };
        },
        .boolean => |b| json.Value{ .bool = b },
        .date, .time, .datetime => error.UnsupportedTomlType,
        .array => |arr| blk: {
            var list = json.Array.init(arena);
            for (arr.items) |item| try list.append(try valueToJson(arena, item));
            break :blk json.Value{ .array = list };
        },
        .table => |t| try tableToJson(arena, t.*),
    };
}

test "parseToJsonValue converts nested tables, arrays and scalars" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const val = try parseToJsonValue(arena,
        \\default_provider = "kimi-k3"
        \\
        \\[providers.kimi-k3]
        \\kind = "openai_compat"
        \\tags = ["fast", "cheap"]
        \\
        \\[providers.kimi-k3.models.kimi-k3]
        \\context_window = 1048576
        \\temperature = 0.7
    );

    try std.testing.expectEqualStrings("kimi-k3", val.object.get("default_provider").?.string);
    const kimi = val.object.get("providers").?.object.get("kimi-k3").?.object;
    try std.testing.expectEqualStrings("openai_compat", kimi.get("kind").?.string);
    try std.testing.expectEqualStrings("fast", kimi.get("tags").?.array.items[0].string);
    const model = kimi.get("models").?.object.get("kimi-k3").?.object;
    try std.testing.expectEqual(@as(i64, 1048576), model.get("context_window").?.integer);
    try std.testing.expectEqual(@as(f64, 0.7), model.get("temperature").?.float);
}

test "parseToJsonValue rejects date/time values, unused by clanker's config schema" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.UnsupportedTomlType, parseToJsonValue(arena, "d = 2022-07-03"));
    try std.testing.expectError(error.UnsupportedTomlType, parseToJsonValue(arena, "t = 14:30:00"));
    try std.testing.expectError(error.UnsupportedTomlType, parseToJsonValue(arena, "dt = 2022-07-03T14:30:00"));
}

test "valueToJson rejects non-finite floats at the boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.NonFiniteFloat, valueToJson(arena, .{ .float = std.math.inf(f64) }));
    try std.testing.expectError(error.NonFiniteFloat, valueToJson(arena, .{ .float = std.math.nan(f64) }));
    // A finite float still crosses untouched.
    const ok = try valueToJson(arena, .{ .float = 2.5 });
    try std.testing.expectEqual(@as(f64, 2.5), ok.float);
}
