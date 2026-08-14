//! Deterministic, request-only tool-result pruning.

const std = @import("std");
const types = @import("../llm/types.zig");
const utf8 = @import("../util/utf8.zig");

pub const marker = "\n\n[... tool result middle pruned ...]\n\n";

fn tailStart(content: []const u8, want: usize) usize {
    var start = content.len -| want;
    while (start < content.len and content[start] & 0xc0 == 0x80) start += 1;
    return start;
}

pub fn replacementLen(content: []const u8, threshold: usize, head_bytes: usize, tail_bytes: usize) ?usize {
    if (threshold == 0 or content.len <= threshold) return null;
    const head = utf8.cap(content, @min(head_bytes, content.len));
    const tail_start = tailStart(content, @min(tail_bytes, content.len - head.len));
    if (tail_start < head.len) return null;
    const new_len = head.len + marker.len + content.len - tail_start;
    if (new_len >= threshold or new_len >= content.len) return null;
    return new_len;
}

/// Rewrites only tool-message content in the caller-provided message copy.
/// The original content is never duplicated: only retained head/marker/tail
/// bytes are allocated.
pub fn pruneToolResults(messages: []types.Message, arena: std.mem.Allocator, threshold: usize, head_bytes: usize, tail_bytes: usize) !usize {
    if (threshold == 0) return 0;
    var reclaimed: usize = 0;
    for (messages) |*message| {
        if (message.role != .tool) continue;
        const content = message.content orelse continue;
        const new_len = replacementLen(content, threshold, head_bytes, tail_bytes) orelse continue;
        const head = utf8.cap(content, @min(head_bytes, content.len));
        const tail_start = tailStart(content, @min(tail_bytes, content.len - head.len));
        const out = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ head, marker, content[tail_start..] });
        message.content = out;
        reclaimed += content.len - new_len;
    }
    return reclaimed;
}

pub fn reclaimableBytes(messages: []const types.Message, threshold: usize, head_bytes: usize, tail_bytes: usize) usize {
    var reclaimed: usize = 0;
    for (messages) |message| {
        if (message.role != .tool) continue;
        const content = message.content orelse continue;
        if (replacementLen(content, threshold, head_bytes, tail_bytes)) |new_len| reclaimed += content.len - new_len;
    }
    return reclaimed;
}

test "pruning is UTF-8 safe, role-scoped, and idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original = "head🙂" ++ ("x" ** 100) ++ "🙂tail";
    const canonical = [_]types.Message{
        .{ .role = .user, .content = original },
        .{ .role = .tool, .content = original, .tool_call_id = "1" },
    };
    var messages = canonical;
    const reclaimed = try pruneToolResults(&messages, arena, 64, 7, 8);
    try std.testing.expect(reclaimed > 0);
    try std.testing.expectEqualStrings(original, messages[0].content.?);
    try std.testing.expectEqualStrings(original, canonical[1].content.?);
    try std.testing.expect(std.unicode.utf8ValidateSlice(messages[1].content.?));
    try std.testing.expect(std.mem.find(u8, messages[1].content.?, marker) != null);
    try std.testing.expectEqual(@as(usize, 0), try pruneToolResults(&messages, arena, 64, 7, 8));
}

test "threshold zero and exact threshold are no-ops" {
    var message = [_]types.Message{.{ .role = .tool, .content = "12345678", .tool_call_id = "1" }};
    try std.testing.expectEqual(@as(usize, 0), try pruneToolResults(&message, std.testing.allocator, 0, 1, 1));
    try std.testing.expectEqual(@as(usize, 0), try pruneToolResults(&message, std.testing.allocator, 8, 1, 1));
}
