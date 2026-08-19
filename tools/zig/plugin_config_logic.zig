//! The read-modify-write of `state/plugin_config.json`, the machine-local
//! overlay the registry layers over each descriptor's `config`.
//!
//! Pure on purpose: the guest reads the file and the descriptors, this decides
//! what the new document is, and `zig build test` runs it as a host module.
//! The whole document is rewritten on every save, so every other plugin's
//! overrides have to survive an edit to one of them.

const std = @import("std");

pub const Outcome = union(enum) {
    /// The whole new document, ready to serialize.
    store: std.json.Value,
    /// The descriptor did not list this key in `config_editable`.
    not_editable: []const u8,
};

/// True when `key` is one of the descriptor's opted-in settings. A key the
/// descriptor did not list is a structural setting, and the registry drops it
/// at load, so accepting the write here would report a success that changes
/// nothing.
pub fn isEditable(editable: []const []const u8, key: []const u8) bool {
    for (editable) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// `store` is the parsed file (`.null` for one that does not exist yet),
/// `wanted` the keys this request changes.
///
/// Every key is checked before anything is written, so a request naming one
/// editable and one structural setting saves neither half of itself.
pub fn apply(
    alloc: std.mem.Allocator,
    store: std.json.Value,
    name: []const u8,
    wanted: std.json.ObjectMap,
    editable: []const []const u8,
) !Outcome {
    var check = wanted.iterator();
    while (check.next()) |entry| {
        if (!isEditable(editable, entry.key_ptr.*)) return .{ .not_editable = entry.key_ptr.* };
    }

    var out: std.json.ObjectMap = if (store == .object) try store.object.clone(alloc) else .empty;
    // This tool's previous overrides are merged into, not replaced: a form that
    // submits one field must not clear the others.
    var merged: std.json.ObjectMap = .empty;
    if (out.get(name)) |prev| {
        if (prev == .object) merged = try prev.object.clone(alloc);
    }
    var set = wanted.iterator();
    while (set.next()) |entry| try merged.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    try out.put(alloc, name, .{ .object = merged });
    return .{ .store = .{ .object = out } };
}

fn parse(alloc: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
}

test "apply refuses a key the descriptor did not open" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const wanted = (try parse(alloc, "{\"max_bytes\":10,\"wasm\":\"evil.wasm\"}")).object;
    const outcome = try apply(alloc, .{ .null = {} }, "read_file", wanted, &.{"max_bytes"});
    try std.testing.expectEqualStrings("wasm", outcome.not_editable);
}

test "apply starts from an absent file and keeps other plugins' overrides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const first = try apply(
        alloc,
        .{ .null = {} },
        "read_file",
        (try parse(alloc, "{\"max_bytes\":10}")).object,
        &.{"max_bytes"},
    );
    const second = try apply(
        alloc,
        first.store,
        "web_search",
        (try parse(alloc, "{\"results\":5}")).object,
        &.{"results"},
    );

    const doc = second.store.object;
    try std.testing.expectEqual(@as(i64, 10), doc.get("read_file").?.object.get("max_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 5), doc.get("web_search").?.object.get("results").?.integer);
}

test "apply merges into a tool's existing overrides rather than replacing them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const store = try parse(alloc, "{\"read_file\":{\"max_bytes\":10,\"tail\":true}}");
    const outcome = try apply(
        alloc,
        store,
        "read_file",
        (try parse(alloc, "{\"max_bytes\":20}")).object,
        &.{ "max_bytes", "tail" },
    );
    const mine = outcome.store.object.get("read_file").?.object;
    try std.testing.expectEqual(@as(i64, 20), mine.get("max_bytes").?.integer);
    try std.testing.expectEqual(true, mine.get("tail").?.bool);
}
