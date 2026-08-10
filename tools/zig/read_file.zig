//! read_file: read a file's text by path, with byte-range pagination so a
//! large file can be walked without blowing the context window.
//!
//! Input:  {"path": "src/agent/loop.zig", "offset": 0, "limit": 65536}
//! Output: {"ok": true, "text": "...", "size": 154321, "next_offset": 65536}
//!         next_offset is present only when the read stopped short of the end.

const std = @import("std");
const lib = @import("lib.zig");

/// The harness looks up `run` with this exact signature, and `lib` supplies
/// the rest of the guest ABI (scratch, host_arena, the output buffer). A guest
/// that hand-rolls its own entry point links fine and then fails every call
/// with SignatureMismatch.
export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

const default_limit: usize = 64 * 1024;

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const path = jsonString(input, "path") orelse return errJson(out, "missing required field: path");
    if (path.len == 0) return errJson(out, "path must not be empty");

    const raw = lib.fsRead(path) catch |err| return errJson(out, switch (err) {
        error.SandboxDenied => "path is outside the sandbox",
        error.NotFound => "no such file",
        error.TooLarge => "file is too large to read",
        else => "read failed",
    });

    const offset = @min(jsonUint(input, "offset", 0), raw.len);
    const limit = jsonUint(input, "limit", default_limit);
    const end = @min(raw.len, offset +| limit);
    const slice = raw[offset..end];

    var buf: [lib.out_cap]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(slice);
    try s.objectField("size");
    try s.write(raw.len);
    // Only when there is more to come: a caller that sees no next_offset knows
    // it has the whole file, without comparing byte counts itself.
    if (end < raw.len) {
        try s.objectField("next_offset");
        try s.write(end);
    }
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}

/// Minimal field readers: the guest has no allocator, and the arguments object
/// is small and flat, so a full JSON parse would cost more than it returns.
fn fieldValue(input: []const u8, name: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    if (name.len + 2 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + name.len], name);
    key_buf[1 + name.len] = '"';
    const key = key_buf[0 .. name.len + 2];

    const at = std.mem.indexOf(u8, input, key) orelse return null;
    var i = at + key.len;
    while (i < input.len and (input[i] == ' ' or input[i] == ':')) i += 1;
    if (i >= input.len) return null;
    return input[i..];
}

fn jsonString(input: []const u8, name: []const u8) ?[]const u8 {
    const rest = fieldValue(input, name) orelse return null;
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

fn jsonUint(input: []const u8, name: []const u8, fallback: usize) usize {
    const rest = fieldValue(input, name) orelse return fallback;
    var n: usize = 0;
    var digits: usize = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
        digits += 1;
    }
    return if (digits == 0) fallback else n;
}
