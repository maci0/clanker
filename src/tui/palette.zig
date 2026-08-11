//! Slash-command completion. Does not replace the WASM `cmd_*` dispatch
//! (`replSlashTool` in cli.zig still executes them) — this is a thin
//! Zig-side `{name, description}` index over the same registry, built once
//! at REPL startup, that powers Tab-completion and a live `:help` listing
//! that can't go stale the way a hand-maintained string can.

const std = @import("std");
const registry = @import("../tools/registry.zig");

pub const Entry = struct { name: []const u8, description: []const u8 };

/// Every `cmd_*` tool in `reg`, with the `cmd_` prefix stripped (so `/help`
/// indexes as `"help"`) and sorted by name.
pub fn index(arena: std.mem.Allocator, reg: *const registry.Registry) ![]const Entry {
    const names = try reg.names(arena);
    var out: std.ArrayList(Entry) = .empty;
    for (names) |full| {
        if (!std.mem.startsWith(u8, full, "cmd_")) continue;
        const tool = reg.get(full) orelse continue;
        try out.append(arena, .{ .name = full["cmd_".len..], .description = tool.description });
    }
    std.mem.sort(Entry, out.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

/// What Tab should turn `typed` (the text after `/`, before any space) into:
/// the full name plus a trailing space when it uniquely identifies one
/// command, or the longest prefix shared by every match otherwise. Null
/// means nothing useful to add (no matches, or `typed` already is the
/// longest common prefix).
pub fn complete(arena: std.mem.Allocator, entries: []const Entry, typed: []const u8) !?[]const u8 {
    var matches: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        if (std.mem.startsWith(u8, e.name, typed)) try matches.append(arena, e.name);
    }
    if (matches.items.len == 0) return null;
    if (matches.items.len == 1) return try std.fmt.allocPrint(arena, "{s} ", .{matches.items[0]});

    var lcp = matches.items[0];
    for (matches.items[1..]) |m| {
        var n: usize = 0;
        while (n < lcp.len and n < m.len and lcp[n] == m[n]) n += 1;
        lcp = lcp[0..n];
    }
    if (lcp.len <= typed.len) return null;
    return try arena.dupe(u8, lcp);
}

/// A `:help`-style listing generated from the index instead of hand-typed,
/// so a command the registry knows about can't silently go missing from it.
pub fn helpText(arena: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "slash commands:\n");
    for (entries) |e| {
        try out.appendSlice(arena, "  /");
        try out.appendSlice(arena, e.name);
        var pad = if (e.name.len < 14) 14 - e.name.len else 1;
        while (pad > 0) : (pad -= 1) try out.append(arena, ' ');
        try out.appendSlice(arena, e.description);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

// ------------------------------------------------------------------- tests --

const test_entries = [_]Entry{
    .{ .name = "goal", .description = "set a goal" },
    .{ .name = "goals", .description = "list goals" },
    .{ .name = "graph", .description = "show the run graph" },
    .{ .name = "help", .description = "show help" },
};

test "index strips the cmd_ prefix and sorts by name" {
    var reg = registry.Registry{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try reg.tools.put(arena, "cmd_help", .{ .name = "cmd_help", .description = "show help", .wasm = "x", .input_schema = .{ .object = .{} } });
    try reg.tools.put(arena, "cmd_goal", .{ .name = "cmd_goal", .description = "set a goal", .wasm = "x", .input_schema = .{ .object = .{} } });
    try reg.tools.put(arena, "calculator", .{ .name = "calculator", .description = "math", .wasm = "x", .input_schema = .{ .object = .{} } });

    const entries = try index(arena, &reg);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("goal", entries[0].name);
    try std.testing.expectEqualStrings("help", entries[1].name);
}

test "complete returns the unique match plus a trailing space" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try complete(arena_state.allocator(), &test_entries, "hel");
    try std.testing.expectEqualStrings("help ", got.?);
}

test "complete returns the longest common prefix for multiple matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // "goal" and "goals" share a longer common prefix than what's typed.
    const goal_entries = [_]Entry{
        .{ .name = "goal", .description = "" },
        .{ .name = "goals", .description = "" },
    };
    const got = try complete(arena_state.allocator(), &goal_entries, "g");
    try std.testing.expectEqualStrings("goal", got.?);
}

test "complete returns null when the matches diverge right after what's typed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // "goal" and "graph" only share "g" — already exactly what's typed.
    const got = try complete(arena_state.allocator(), &test_entries, "g");
    try std.testing.expect(got == null);
}

test "complete narrows to a unique match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try complete(arena_state.allocator(), &test_entries, "gr");
    try std.testing.expectEqualStrings("graph ", got.?);
}

test "complete returns null for no matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try complete(arena_state.allocator(), &test_entries, "zzz");
    try std.testing.expect(got == null);
}

test "helpText lists every entry with its description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try helpText(arena_state.allocator(), &test_entries);
    try std.testing.expect(std.mem.indexOf(u8, text, "/goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "set a goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/help") != null);
}
