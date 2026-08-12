//! Chunker for the memory layer. Fixed and markdown-aware.

const std = @import("std");

pub const Strategy = enum { fixed, markdown };

pub const Chunk = struct {
    doc_id: []const u8,
    idx: usize,
    text: []const u8,
    hash: []const u8, // hex sha256 of text
};

fn hashHex(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(text);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.allocPrint(arena, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

pub fn chunkText(arena: std.mem.Allocator, doc_id: []const u8, content: []const u8, size: usize, overlap: usize, strategy: Strategy) ![]Chunk {
    if (size == 0) return try arena.alloc(Chunk, 0);
    const eff_overlap = @min(overlap, size - 1);
    var out: std.ArrayList(Chunk) = .empty;
    if (strategy == .markdown) {
        // Split on markdown boundaries: headings/separators then fall back to fixed windowing
        var sections: std.ArrayList([]const u8) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i < content.len) {
            const is_heading = content[i] == '#' and (i == 0 or content[i - 1] == '\n');
            const is_sep = i + 2 < content.len and content[i] == '\n' and content[i + 1] == '\n' and content[i + 2] == '\n';
            if (is_heading and i != start) {
                try sections.append(arena, content[start..i]);
                start = i;
            } else if (is_sep and i != start) {
                try sections.append(arena, content[start..i]);
                start = i + 1;
            }
            i += 1;
        }
        if (start < content.len) try sections.append(arena, content[start..]);
        if (sections.items.len == 0) try sections.append(arena, content);
        var idx: usize = 0;
        for (sections.items) |sec| {
            var off: usize = 0;
            const s = std.mem.trim(u8, sec, " \t\r\n");
            if (s.len == 0) continue;
            while (off < s.len) {
                const end = @min(s.len, off + size);
                var slice = s[off..end];
                slice = std.mem.trim(u8, slice, " \t\r\n");
                if (slice.len > 0) {
                    const h = try hashHex(arena, slice);
                    const owned = try arena.dupe(u8, slice);
                    try out.append(arena, .{ .doc_id = doc_id, .idx = idx, .text = owned, .hash = h });
                    idx += 1;
                }
                if (end >= s.len) break;
                off = end - eff_overlap;
            }
        }
        return out.toOwnedSlice(arena);
    }
    // fixed
    var off: usize = 0;
    var idx: usize = 0;
    while (off < content.len) {
        const end = @min(content.len, off + size);
        var slice = content[off..end];
        slice = std.mem.trim(u8, slice, " \t\r\n");
        if (slice.len > 0) {
            const h = try hashHex(arena, slice);
            const owned = try arena.dupe(u8, slice);
            try out.append(arena, .{ .doc_id = doc_id, .idx = idx, .text = owned, .hash = h });
            idx += 1;
        }
        if (end >= content.len) break;
        off = end - eff_overlap;
    }
    return out.toOwnedSlice(arena);
}

test "chunk fixed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const chunks = try chunkText(arena, "d1", "abcdefghij", 4, 1, .fixed);
    try std.testing.expect(chunks.len >= 3);
    try std.testing.expectEqualStrings("abcd", chunks[0].text);
}

test "chunk markdown heading split" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const md = "# A\nhello world\n## B\nmore text here and there";
    const chunks = try chunkText(arena, "d1", md, 12, 2, .markdown);
    try std.testing.expect(chunks.len >= 2);
}
