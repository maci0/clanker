//! Persist an oversized tool result so the request-only pruner can drop the
//! middle without losing the bytes. The saved transcript stays exact; only
//! the next model request carries a locator.

const std = @import("std");
const types = @import("../llm/types.zig");
const tool_out = @import("../util/tool_out.zig");
const ensure_dir = @import("../util/ensure_dir.zig");
const session = @import("session.zig");

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
    const at = std.mem.indexOf(u8, text, locator_prefix) orelse return null;
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

pub fn pathFor(session_id: []const u8, id: []const u8) ![32 + 8 + 8]u8 {
    var buf: [32 + 8 + 8]u8 = undefined;
    const sid = if (session.validSessionId(session_id)) session_id else "default";
    const written = try std.fmt.bufPrint(&buf, "state/spills/{s}/{s}.txt", .{ sid, id });
    var out: [32 + 8 + 8]u8 = undefined;
    @memcpy(out[0..written.len], written);
    return out;
}

/// Writes the original tool content and appends a locator to the pruned
/// request copy. The original slice in `originals` is not mutated.
pub fn annotate(
    io: std.Io,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    session_id: []const u8,
    pruned: []types.Message,
    originals: []const types.Message,
) !usize {
    if (pruned.len != originals.len) return 0;
    var wrote: usize = 0;
    for (pruned, originals, 0..) |*dst, src, i| {
        if (dst.role != .tool) continue;
        const pc = dst.content orelse continue;
        const oc = src.content orelse continue;
        if (std.mem.indexOf(u8, pc, marker) == null) continue;
        if (parseId(pc) != null) continue;
        const id = idFor(oc, i);
        try persist(io, base, session_id, &id, oc);
        const loc = locatorLine(&id);
        dst.content = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ pc, loc });
        wrote += 1;
    }
    return wrote;
}

pub fn persist(
    io: std.Io,
    base: std.Io.Dir,
    session_id: []const u8,
    id: []const u8,
    content: []const u8,
) !void {
    const sid = if (session.validSessionId(session_id)) session_id else "default";
    var dir_buf: [64]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "state/spills/{s}", .{sid});
    try ensure_dir.ensureDir(base, io, dir_path);
    var name_buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}.txt", .{id});
    var dir = try base.openDir(io, dir_path, .{});
    defer dir.close(io);
    var file = try dir.createFile(io, name, .{ .exclusive = false });
    defer file.close(io);
    var wbuf: [512]u8 = undefined;
    var w = file.writer(io, &wbuf);
    try w.interface.writeAll(content);
    try w.interface.flush();
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

test "annotate writes the original and appends a locator" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "HEAD" ++ ("x" ** 80) ++ "TAIL";
    const pruned_body = "HEAD" ++ marker ++ "TAIL";
    var originals = [_]types.Message{.{ .role = .tool, .content = original, .tool_call_id = "1" }};
    var pruned = [_]types.Message{.{ .role = .tool, .content = pruned_body, .tool_call_id = "1" }};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const n = try annotate(io, arena_state.allocator(), tmp.dir, "sess01ab", &pruned, &originals);
    try std.testing.expectEqual(@as(usize, 1), n);
    const id = parseId(pruned[0].content.?) orelse return error.TestExpectedEqual;
    var path_buf: [80]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "state/spills/sess01ab/{s}.txt", .{id});
    const got = try tmp.dir.readFileAlloc(io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(original, got);
    try std.testing.expectEqual(@as(usize, 0), try annotate(io, arena_state.allocator(), tmp.dir, "sess01ab", &pruned, &originals));
}
