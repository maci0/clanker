//! Pure helpers for review_loop: which review ran last, which comes next in
//! rotation, and the state.json shape recording it. Reuses
//! agency_sync_logic.mdFileNames for GitHub directory listings -- same
//! contents-API shape, no reason to parse it twice. No host I/O, so
//! `zig build test` runs it; the `review_loop` guest does the HTTP fetches,
//! reads, and writes around these functions.

const std = @import("std");

pub const State = struct {
    last: []const u8 = "",
};

/// `{"last": "..."}` , or `.{}` (empty last) for missing/malformed input --
/// a first run has no prior state, and a corrupt state.json should not
/// block rotation, only reset it to the start.
pub fn parseState(arena: std.mem.Allocator, raw: []const u8) State {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return .{};
    if (parsed != .object) return .{};
    const last = parsed.object.get("last") orelse return .{};
    if (last != .string) return .{};
    return .{ .last = last.string };
}

pub fn buildState(arena: std.mem.Allocator, last: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"last\":{f}}}", .{std.json.fmt(last, .{})});
}

/// The next name after `last` in `names` (already sorted), wrapping to the
/// first entry past the end and starting from the first entry when `last`
/// is empty or not found (a first run, or a name the rotation no longer
/// carries because its source file was removed upstream).
pub fn nextInRotation(names: []const []const u8, last: []const u8) ?[]const u8 {
    if (names.len == 0) return null;
    if (last.len == 0) return names[0];
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, last)) return names[(i + 1) % names.len];
    }
    return names[0];
}

/// `<name>-review.md` stems from a directory listing (`lib.fsList`'s own
/// shape: a flat JSON array of names, directories suffixed with `/`),
/// sorted so rotation order is stable across runs regardless of listing
/// order.
pub fn reviewStems(arena: std.mem.Allocator, listing_json: []const u8) ![]const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, listing_json, .{}) catch
        return &.{};
    if (parsed != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (parsed.array.items) |item| {
        if (item != .string) continue;
        const name = item.string;
        if (std.mem.endsWith(u8, name, "/")) continue; // a directory, not a file
        if (!std.mem.endsWith(u8, name, "-review.md")) continue;
        try out.append(arena, name[0 .. name.len - "-review.md".len]);
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice(arena);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The union of two already-sorted, deduplicated stem lists, deduplicated
/// against each other (a name present in both keeps one entry) and
/// re-sorted -- a local docs/prompts/ review and a synced one can share a
/// name (e.g. both ship a "sec-review"), and the rotation should visit it
/// once, not twice.
pub fn mergeStems(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, a);
    for (b) |n| {
        var dup = false;
        for (a) |existing| {
            if (std.mem.eql(u8, existing, n)) {
                dup = true;
                break;
            }
        }
        if (!dup) try out.append(arena, n);
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice(arena);
}

test "parseState reads last, empty on missing or malformed input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("sec-review", parseState(arena, "{\"last\":\"sec-review\"}").last);
    try std.testing.expectEqualStrings("", parseState(arena, "not json").last);
    try std.testing.expectEqualStrings("", parseState(arena, "{}").last);
}

test "buildState then parseState round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json = try buildState(arena, "code-review");
    try std.testing.expectEqualStrings("code-review", parseState(arena, json).last);
}

test "nextInRotation starts at the first entry with no prior state" {
    const names = [_][]const u8{ "a-review", "b-review", "c-review" };
    try std.testing.expectEqualStrings("a-review", nextInRotation(&names, "").?);
}

test "nextInRotation advances and wraps" {
    const names = [_][]const u8{ "a-review", "b-review", "c-review" };
    try std.testing.expectEqualStrings("b-review", nextInRotation(&names, "a-review").?);
    try std.testing.expectEqualStrings("c-review", nextInRotation(&names, "b-review").?);
    try std.testing.expectEqualStrings("a-review", nextInRotation(&names, "c-review").?);
}

test "nextInRotation restarts when the last name is no longer in rotation" {
    const names = [_][]const u8{ "a-review", "b-review" };
    try std.testing.expectEqualStrings("a-review", nextInRotation(&names, "removed-review").?);
}

test "nextInRotation returns null for an empty rotation" {
    try std.testing.expectEqual(@as(?[]const u8, null), nextInRotation(&.{}, "a-review"));
}

test "reviewStems keeps only *-review.md files and strips the -review.md suffix" {
    // Bare names, not "code-review": scripts/clanker-review.sh already
    // established "the name alone [without -review] is what users type"
    // for this same file convention, so the stem matches that, not the
    // filename minus its extension.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json =
        \\["sec-review.md", "README.md", "code-review.md", "sub/"]
    ;
    const stems = try reviewStems(arena, json);
    try std.testing.expectEqual(@as(usize, 2), stems.len);
    try std.testing.expectEqualStrings("code", stems[0]);
    try std.testing.expectEqualStrings("sec", stems[1]);
}

test "mergeStems deduplicates a name present in both lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = [_][]const u8{ "code-review", "sec-review" };
    const b = [_][]const u8{ "arch-review", "sec-review" };
    const merged = try mergeStems(arena, &a, &b);
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("arch-review", merged[0]);
    try std.testing.expectEqualStrings("code-review", merged[1]);
    try std.testing.expectEqualStrings("sec-review", merged[2]);
}
