//! Minimal flat-JSON field readers for tools/zig/read_file.zig. The guest is a
//! sandboxed wasm module, where a `test` block can never run, so these pure
//! readers live here and `zig build test` runs their tests on the host.

const std = @import("std");

/// Minimal field readers: the guest has no allocator, and the arguments object
/// is small and flat, so a full JSON parse would cost more than it returns.
pub fn fieldValue(input: []const u8, name: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    if (name.len + 2 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + name.len], name);
    key_buf[1 + name.len] = '"';
    const key = key_buf[0 .. name.len + 2];

    const at = std.mem.find(u8, input, key) orelse return null;
    var i = at + key.len;
    while (i < input.len and (input[i] == ' ' or input[i] == ':')) i += 1;
    if (i >= input.len) return null;
    return input[i..];
}

pub fn jsonString(input: []const u8, name: []const u8) ?[]const u8 {
    const rest = fieldValue(input, name) orelse return null;
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.findScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

// A schema-typed "integer" field is not proof the caller sent a bare number:
// nothing between the model and this guest validates that, and a quoted
// "603" is a real shape models produce. Skipping a leading quote here is the
// difference between silently reading from byte 0 (wrong file location, no
// error) and honoring what was plainly meant.
pub fn jsonUintOpt(input: []const u8, name: []const u8) ?usize {
    var rest = fieldValue(input, name) orelse return null;
    if (rest.len > 0 and rest[0] == '"') rest = rest[1..];
    var n: usize = 0;
    var digits: usize = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
        digits += 1;
    }
    return if (digits == 0) null else n;
}

pub fn jsonBool(input: []const u8, name: []const u8) bool {
    const rest = fieldValue(input, name) orelse return false;
    return std.mem.startsWith(u8, rest, "true");
}

pub fn jsonUint(input: []const u8, name: []const u8, fallback: usize) usize {
    var rest = fieldValue(input, name) orelse return fallback;
    if (rest.len > 0 and rest[0] == '"') rest = rest[1..];
    var n: usize = 0;
    var digits: usize = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
        digits += 1;
    }
    return if (digits == 0) fallback else n;
}

test "jsonUintOpt reads a bare number and a quoted one alike" {
    try std.testing.expectEqual(@as(?usize, 603), jsonUintOpt("{\"start_line\":603}", "start_line"));
    try std.testing.expectEqual(@as(?usize, 603), jsonUintOpt("{\"start_line\":\"603\"}", "start_line"));
    try std.testing.expectEqual(@as(?usize, null), jsonUintOpt("{\"path\":\"x\"}", "start_line"));
}

test "jsonUint falls back only when no digits are present at all" {
    try std.testing.expectEqual(@as(usize, 40), jsonUint("{\"line_count\":40}", "line_count", 200));
    try std.testing.expectEqual(@as(usize, 40), jsonUint("{\"line_count\":\"40\"}", "line_count", 200));
    try std.testing.expectEqual(@as(usize, 200), jsonUint("{}", "line_count", 200));
}
