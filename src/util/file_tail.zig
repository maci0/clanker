//! Read the end of a file without loading the rest.
//!
//! JSONL state logs (`autolearn`, `reasoning`, `token_stats`) trim by keeping
//! the newest N lines. A cap-triggered trim used to `readFileAlloc` the whole
//! file, and autolearn did that with `.unlimited`: a log that had grown past
//! the cap (because an earlier trim failed) forced an unbounded allocation,
//! the trim failed again, and the file kept growing. Reading a bounded tail
//! from the end is enough to keep the newest lines and is bounded even when
//! the file is not.

const std = @import("std");
const test_env = @import("test_env.zig");

/// Last `max_bytes` of `path`, owned by `gpa`. A window that starts mid-file
/// is cut forward to the first newline so a JSONL consumer never rewrites a
/// torn first line. An empty file, or a `max_bytes` of 0, returns a freeable
/// empty slice.
pub fn readTail(
    base: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    if (max_bytes == 0) return try gpa.alloc(u8, 0);

    var file = try base.openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    if (st.size == 0) return try gpa.alloc(u8, 0);

    const start: u64 = if (st.size > max_bytes) st.size - max_bytes else 0;
    const to_read: usize = @intCast(st.size - start);
    const buf = try gpa.alloc(u8, to_read);
    errdefer gpa.free(buf);
    const n = try file.readPositionalAll(io, buf, start);
    const filled = buf[0..n];
    const kept = if (start > 0)
        (if (std.mem.findScalar(u8, filled, '\n')) |nl| filled[nl + 1 ..] else filled)
    else
        filled;
    if (kept.ptr == buf.ptr and kept.len == buf.len) return buf;
    const out = try gpa.dupe(u8, kept);
    gpa.free(buf);
    return out;
}

/// Newest `keep_lines` whole lines of `raw`, joined with trailing newlines,
/// owned by `gpa`. Empty input, or `keep_lines` of 0, returns a freeable
/// empty slice.
pub fn joinNewestLines(gpa: std.mem.Allocator, raw: []const u8, keep_lines: usize) ![]u8 {
    if (keep_lines == 0 or raw.len == 0) return try gpa.alloc(u8, 0);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        try lines.append(gpa, ln);
    }
    const keep = if (lines.items.len > keep_lines) lines.items.len - keep_lines else 0;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, raw.len);
    for (lines.items[keep..]) |ln| {
        try out.appendSlice(gpa, ln);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "readTail returns a short file whole" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    try env.tmp.dir.writeFile(io, .{ .sub_path = "log.jsonl", .data = "a\nb\nc\n" });
    const raw = try readTail(env.tmp.dir, io, std.testing.allocator, "log.jsonl", 64);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("a\nb\nc\n", raw);
}

test "readTail of an empty file is a freeable empty slice" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    try env.tmp.dir.writeFile(io, .{ .sub_path = "empty.jsonl", .data = "" });
    const raw = try readTail(env.tmp.dir, io, std.testing.allocator, "empty.jsonl", 64);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 0), raw.len);
}

test "readTail drops a torn first line on a mid-file window" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    // 15 bytes; a 9-byte tail starts inside "bbbb\n", so the kept window is
    // the whole lines after that newline.
    try env.tmp.dir.writeFile(io, .{ .sub_path = "log.jsonl", .data = "aaaa\nbbbb\ncccc\n" });
    const raw = try readTail(env.tmp.dir, io, std.testing.allocator, "log.jsonl", 9);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("cccc\n", raw);
}

test "joinNewestLines keeps only the last N lines" {
    const raw = "a\nb\nc\nd\n";
    const out = try joinNewestLines(std.testing.allocator, raw, 2);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("c\nd\n", out);
}

test "joinNewestLines skips blank lines" {
    const raw = "a\n\nb\n";
    const out = try joinNewestLines(std.testing.allocator, raw, 10);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nb\n", out);
}
