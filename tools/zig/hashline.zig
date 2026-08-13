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
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const raw = if (nl) |n| rest[0 .. n + 1] else rest;
        const hex = hashHex(raw);
        try out.writer(alloc).print("{d:0>4} {s}  {s}", .{ line_no, hex, raw });
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

test "parseHash accepts 4 hex digits only" {
    try std.testing.expectEqual(@as(?u16, 0x00ab), parseHash("00ab"));
    try std.testing.expectEqual(@as(?u16, null), parseHash("ab"));
    try std.testing.expectEqual(@as(?u16, null), parseHash("gggg"));
}
