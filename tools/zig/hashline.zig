//! Shared 4-hex xxHash32 used by `read_file` (`hashes: true`) and
//! `edit_file` (`op: "hashline"`). The digest covers the line's bytes
//! without the trailing `\n` / `\r\n`.

const std = @import("std");

pub fn lineHash(line: []const u8) u16 {
    const body = trimEnding(line);
    return @truncate(std.hash.XxHash32.hash(0, body));
}

pub fn formatHash(hash: u16) [4]u8 {
    var buf: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>4}", .{hash}) catch unreachable;
    return buf;
}

pub fn hashHex(line: []const u8) [4]u8 {
    return formatHash(lineHash(line));
}

pub fn parseHash(s: []const u8) ?u16 {
    if (s.len != 4) return null;
    return std.fmt.parseInt(u16, s, 16) catch null;
}

pub fn trimEnding(line: []const u8) []const u8 {
    var body = line;
    if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
    if (body.len > 0 and body[body.len - 1] == '\r') body = body[0 .. body.len - 1];
    return body;
}

/// Annotate `text` as `{line:04} {hash:4}  {content}` lines. `start_line`
/// is the 1-based number of the first line in `text`.
pub fn annotate(alloc: std.mem.Allocator, text: []const u8, start_line: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var line_no: usize = if (start_line == 0) 1 else start_line;
    var i: usize = 0;
    while (i < text.len) {
        const rest = text[i..];
        const nl = std.mem.findScalar(u8, rest, '\n');
        const raw = if (nl) |n| rest[0 .. n + 1] else rest;
        const hex = hashHex(raw);
        var buf: [32]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buf, "{d:0>4} {s}  ", .{ line_no, hex }) catch unreachable;
        try out.appendSlice(alloc, prefix);
        try out.appendSlice(alloc, raw);
        i += raw.len;
        line_no += 1;
        if (nl == null) break;
    }
    return out.toOwnedSlice(alloc);
}

test "lineHash is xxHash32 truncated to 16 bits" {
    const full = std.hash.XxHash32.hash(0, "fn main() void {");
    try std.testing.expectEqual(@as(u16, @truncate(full)), lineHash("fn main() void {\n"));
    try std.testing.expectEqual(lineHash("fn main() void {"), lineHash("fn main() void {\r\n"));
}

test "formatHash is exactly 4 lowercase hex digits" {
    try std.testing.expectEqualStrings("0000", &formatHash(0));
    try std.testing.expectEqualStrings("00ab", &formatHash(0x00ab));
    try std.testing.expectEqualStrings("ffff", &formatHash(0xffff));
}

test "annotate prefixes every line with number and hash" {
    const text = "alpha\nbeta\n";
    const out = try annotate(std.testing.allocator, text, 1);
    defer std.testing.allocator.free(out);
    const a = hashHex("alpha");
    const b = hashHex("beta");
    var expect_buf: [64]u8 = undefined;
    const expect = std.fmt.bufPrint(&expect_buf, "0001 {s}  alpha\n0002 {s}  beta\n", .{ a, b }) catch unreachable;
    try std.testing.expectEqualStrings(expect, out);
}

pub const Hunk = struct {
    anchor_hash: u16,
    anchor_line: usize,
    old_count: usize,
    new_text: []const u8,
};

pub const Applied = struct {
    start_line: usize,
    hashes: []const [4]u8,
};

pub const ApplyError = error{
    AnchorNotFound,
    HashMismatch,
    PastEnd,
    OutOfMemory,
};

const Resolved = struct { start: usize, hunk: Hunk };

fn resolvedLess(_: void, a: Resolved, b: Resolved) bool {
    return a.start > b.start;
}

fn appliedLess(_: void, a: Applied, b: Applied) bool {
    return a.start_line < b.start_line;
}

/// Validate every hunk, then apply them last-to-first so earlier edits do
/// not shift later anchors. `tolerance` is the ± window around `anchor_line`.
pub fn apply(
    alloc: std.mem.Allocator,
    src: []const u8,
    hunks: []const Hunk,
    tolerance: usize,
) ApplyError!struct { text: []u8, applied: []Applied } {
    const lines = try splitLines(alloc, src);
    var resolved: std.ArrayList(Resolved) = .empty;
    for (hunks) |h| {
        const start = findAnchor(lines, h, tolerance) orelse return error.AnchorNotFound;
        if (start + h.old_count > lines.len) return error.PastEnd;
        try resolved.append(alloc, .{ .start = start, .hunk = h });
    }
    std.mem.sort(Resolved, resolved.items, {}, resolvedLess);

    var text = try alloc.dupe(u8, src);
    var applied: std.ArrayList(Applied) = .empty;
    for (resolved.items) |r| {
        const start_off = lineOffset(lines, r.start);
        const end_off = if (r.start + r.hunk.old_count < lines.len)
            lineOffset(lines, r.start + r.hunk.old_count)
        else
            src.len;
        var next: std.ArrayList(u8) = .empty;
        try next.appendSlice(alloc, text[0..start_off]);
        try next.appendSlice(alloc, r.hunk.new_text);
        if (r.hunk.new_text.len > 0 and r.hunk.new_text[r.hunk.new_text.len - 1] != '\n' and end_off < text.len) {
            try next.append(alloc, '\n');
        }
        try next.appendSlice(alloc, text[end_off..]);
        text = try next.toOwnedSlice(alloc);
        const new_lines = try splitLines(alloc, r.hunk.new_text);
        var hashes = try alloc.alloc([4]u8, new_lines.len);
        for (new_lines, 0..) |ln, i| hashes[i] = hashHex(ln);
        try applied.append(alloc, .{ .start_line = r.start + 1, .hashes = hashes });
    }
    std.mem.sort(Applied, applied.items, {}, appliedLess);
    return .{ .text = text, .applied = try applied.toOwnedSlice(alloc) };
}

fn splitLines(alloc: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        const rest = src[i..];
        const nl = std.mem.findScalar(u8, rest, '\n');
        const raw = if (nl) |n| rest[0 .. n + 1] else rest;
        try out.append(alloc, raw);
        i += raw.len;
        if (nl == null) break;
    }
    if (src.len > 0 and src[src.len - 1] == '\n') {
        // trailing newline does not add an extra empty line
    }
    return out.toOwnedSlice(alloc);
}

fn lineOffset(lines: []const []const u8, idx: usize) usize {
    var n: usize = 0;
    for (lines[0..idx]) |ln| n += ln.len;
    return n;
}

fn findAnchor(lines: []const []const u8, hunk: Hunk, tolerance: usize) ?usize {
    if (lines.len == 0) return null;
    const hint = if (hunk.anchor_line == 0) 1 else hunk.anchor_line;
    const center = @min(hint -| 1, lines.len - 1);
    const lo = center -| tolerance;
    const hi = @min(lines.len - 1, center + tolerance);
    var best: ?usize = null;
    var best_dist: usize = std.math.maxInt(usize);
    var i = lo;
    while (i <= hi) : (i += 1) {
        if (lineHash(lines[i]) != hunk.anchor_hash) continue;
        const dist = if (i >= center) i - center else center - i;
        if (dist < best_dist) {
            best = i;
            best_dist = dist;
        }
    }
    return best;
}

test "parseHash accepts 4 hex digits only" {
    try std.testing.expectEqual(@as(?u16, 0x00ab), parseHash("00ab"));
    try std.testing.expectEqual(@as(?u16, null), parseHash("ab"));
    try std.testing.expectEqual(@as(?u16, null), parseHash("gggg"));
}

test "apply replaces a single hunk and returns new hashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src = "alpha\nbeta\ngamma\n";
    const hunks = [_]Hunk{.{
        .anchor_hash = lineHash("beta"),
        .anchor_line = 2,
        .old_count = 1,
        .new_text = "BETA\n",
    }};
    const result = try apply(arena_state.allocator(), src, &hunks, 10);
    try std.testing.expectEqualStrings("alpha\nBETA\ngamma\n", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.applied.len);
    try std.testing.expectEqual(@as(usize, 2), result.applied[0].start_line);
    try std.testing.expectEqualStrings(&hashHex("BETA"), &result.applied[0].hashes[0]);
}

test "apply finds an anchor that shifted within the tolerance window" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src = "keep\nkeep\nkeep\nkeep\nkeep\ntarget\n";
    const hunks = [_]Hunk{.{
        .anchor_hash = lineHash("target"),
        .anchor_line = 2,
        .old_count = 1,
        .new_text = "changed\n",
    }};
    const result = try apply(arena_state.allocator(), src, &hunks, 10);
    try std.testing.expectEqualStrings("keep\nkeep\nkeep\nkeep\nkeep\nchanged\n", result.text);
}

test "apply rejects a missing anchor without changing the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src = "alpha\nbeta\n";
    const hunks = [_]Hunk{.{
        .anchor_hash = 0xdead,
        .anchor_line = 1,
        .old_count = 1,
        .new_text = "nope\n",
    }};
    try std.testing.expectError(error.AnchorNotFound, apply(arena_state.allocator(), src, &hunks, 10));
}

test "apply rejects when old_count walks past the end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src = "only\n";
    const hunks = [_]Hunk{.{
        .anchor_hash = lineHash("only"),
        .anchor_line = 1,
        .old_count = 4,
        .new_text = "x\n",
    }};
    try std.testing.expectError(error.PastEnd, apply(arena_state.allocator(), src, &hunks, 10));
}

test "apply applies later hunks first so earlier offsets stay valid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src = "one\ntwo\nthree\n";
    const hunks = [_]Hunk{
        .{ .anchor_hash = lineHash("one"), .anchor_line = 1, .old_count = 1, .new_text = "ONE\nONE2\n" },
        .{ .anchor_hash = lineHash("three"), .anchor_line = 3, .old_count = 1, .new_text = "THREE\n" },
    };
    const result = try apply(arena_state.allocator(), src, &hunks, 10);
    try std.testing.expectEqualStrings("ONE\nONE2\ntwo\nTHREE\n", result.text);
}
