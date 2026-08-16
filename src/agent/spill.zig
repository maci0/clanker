//! Persist an oversized tool result so the request-only pruner can drop the
//! middle without losing the bytes. The saved transcript stays exact; only
//! the next model request carries a locator.
//!
//! The write itself lives in the `spill` WASM tool ({"write": ...}), which
//! owns state/spills/ on disk and reads it back on demand. The agent loop
//! keeps the decision half native because it sits inside the per-turn request
//! build: pick which pruned messages need spilling, derive the id, and append
//! the locator only after the guest confirmed the write.

const std = @import("std");
const types = @import("../llm/types.zig");
const tool_out = @import("../util/tool_out.zig");
const spill_logic = @import("spill_logic");

pub const marker = tool_out.prune_marker;

/// The spill id format (locator line, id derivation, id parsing) lives in
/// `spill_logic`, the same host-tested module the `spill` guest reads results
/// back through; the harness imports it rather than carrying a second copy.
pub const locator_prefix = spill_logic.locator_prefix;
pub const locatorLine = spill_logic.locatorLine;
pub const parseId = spill_logic.parseId;
pub const idFor = spill_logic.idFor;

/// One spill: what to preserve, where, and which pruned message it belongs to.
pub const Spill = struct {
    session: []const u8,
    id: [8]u8,
    /// Full pre-prune tool result, kept exact.
    content: []const u8,
    /// Index into the pruned message list the locator must be appended to.
    index: usize,
};

/// The decision half of a spill pass: for every pruned tool message that
/// carries a prune marker and no locator yet, pick the id and the content to
/// preserve. Pure; the caller writes each spill through the `spill` guest and
/// appends the locator only on success.
pub fn collectSpills(
    arena: std.mem.Allocator,
    session_id: []const u8,
    pruned: []const types.Message,
    originals: []const types.Message,
) ![]Spill {
    if (pruned.len != originals.len) return &.{};
    var out_list: std.ArrayList(Spill) = .empty;
    errdefer out_list.deinit(arena);
    for (pruned, originals, 0..) |dst, src, i| {
        if (dst.role != .tool) continue;
        const pc = dst.content orelse continue;
        const oc = src.content orelse continue;
        if (std.mem.find(u8, pc, marker) == null) continue;
        if (parseId(pc) != null) continue;
        try out_list.append(arena, .{ .session = session_id, .id = idFor(oc, i), .content = oc, .index = i });
    }
    return out_list.toOwnedSlice(arena);
}

/// Appends the locator line to a pruned message's content. Call only after
/// the write succeeded, so a dangling locator is never left behind.
pub fn applyLocator(arena: std.mem.Allocator, dst: *types.Message, id: []const u8) !void {
    const pc = dst.content orelse return;
    dst.content = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ pc, locatorLine(id) });
}

test "collectSpills picks pruned tool results and applyLocator appends the locator" {
    const original = "HEAD" ++ ("x" ** 80) ++ "TAIL";
    const pruned_body = "HEAD" ++ marker ++ "TAIL";
    var originals = [_]types.Message{.{ .role = .tool, .content = original, .tool_call_id = "1" }};
    var pruned = [_]types.Message{.{ .role = .tool, .content = pruned_body, .tool_call_id = "1" }};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spills = try collectSpills(arena, "sess01ab", &pruned, &originals);
    try std.testing.expectEqual(@as(usize, 1), spills.len);
    try std.testing.expectEqual(@as(usize, 0), spills[0].index);
    try std.testing.expectEqualStrings("sess01ab", spills[0].session);
    try std.testing.expectEqualStrings(original, spills[0].content);

    // The message content is untouched until the locator is applied.
    try std.testing.expectEqualStrings(pruned_body, pruned[0].content.?);
    try applyLocator(arena, &pruned[0], &spills[0].id);
    const id = parseId(pruned[0].content.?) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(&spills[0].id, id);

    // An already-located message and a message without the marker spill nothing.
    var pruned2 = [_]types.Message{
        .{ .role = .tool, .content = pruned[0].content.?, .tool_call_id = "1" },
        .{ .role = .tool, .content = "no marker here", .tool_call_id = "2" },
    };
    try std.testing.expectEqual(@as(usize, 0), (try collectSpills(arena, "sess01ab", &pruned2, &originals)).len);
}

test "collectSpills is a no-op when the lists do not line up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const pruned = [_]types.Message{.{ .role = .tool, .content = "x", .tool_call_id = "1" }};
    const spills = try collectSpills(arena_state.allocator(), "sess01ab", &pruned, &[_]types.Message{});
    try std.testing.expectEqual(@as(usize, 0), spills.len);
}
