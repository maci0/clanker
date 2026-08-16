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

pub const marker = tool_out.prune_marker;
pub const locator_prefix = "[spill id=";

/// One-line locator the model can hand to the `spill` guest.
pub fn locatorLine(id: []const u8) [locator_prefix.len + 8 + 1]u8 {
    var out: [locator_prefix.len + 8 + 1]u8 = undefined;
    @memcpy(out[0..locator_prefix.len], locator_prefix);
    @memcpy(out[locator_prefix.len..][0..8], id[0..8]);
    out[out.len - 1] = ']';
    return out;
}

pub fn parseId(text: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, text, locator_prefix) orelse return null;
    const start = at + locator_prefix.len;
    if (start + 8 > text.len) return null;
    const id = text[start .. start + 8];
    for (id) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex) return null;
    }
    return id;
}

/// 8 lowercase hex chars from a 32-bit FNV of the bytes plus a salt.
pub fn idFor(content: []const u8, salt: u64) [8]u8 {
    var h: u32 = 2166136261;
    for (content) |c| {
        h ^= c;
        h *%= 16777619;
    }
    // Mix in the low 32 bits of the salt; the high half is dropped on purpose.
    h ^= @truncate(salt);
    h *%= 16777619;
    var out: [8]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 8;
    var n = h;
    while (i > 0) {
        i -= 1;
        out[i] = hex[n & 0xf];
        n >>= 4;
    }
    return out;
}

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

test "locator is 8 hex and round-trips" {
    const id = idFor("hello tool output", 3);
    try std.testing.expectEqual(@as(usize, 8), id.len);
    const line = locatorLine(&id);
    const parsed = parseId(&line) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(&id, parsed);
    try std.testing.expect(parseId("no locator here") == null);
    try std.testing.expect(parseId("[spill id=nothex!!]") == null);
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
