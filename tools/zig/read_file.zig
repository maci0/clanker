//! read_file: read a file's text by path, with byte-range pagination so a
//! large file can be walked without blowing the context window.
//!
//! Input:  {"path": "src/agent/loop.zig", "offset": 0, "limit": 65536}
//! Output: {"ok": true, "text": "...", "next_offset": 49152}
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

// A whole file in one call for anything normal-sized; pagination is for the
// genuinely huge, not for ordinary source. Bounded by the host arena a read
// comes through, with room left for the JSON envelope around the text.
const default_limit: usize = 768 * 1024;

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const path = jsonString(input, "path") orelse return lib.fail(out, "missing required field: path");
    if (path.len == 0) return lib.fail(out, "path must not be empty");

    // Read only the requested window. Reading the whole file first capped this
    // tool at the host arena size, which made every large source file in this
    // very repository unreadable.
    const offset = jsonUint(input, "offset", 0);
    const limit = @min(jsonUint(input, "limit", default_limit), default_limit);
    const slice = lib.fsReadRange(path, offset, limit) catch |err| return lib.fail(out, switch (err) {
        error.SandboxDenied => "path is outside the sandbox",
        error.NotFound => "no such file",
        error.TooLarge => "file is too large to read",
        else => "read failed",
    });

    // Straight into the output buffer: a local array of this size would be a
    // megabyte-plus on the wasm stack, which traps.
    var w = out.writer();
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(slice);
    // Only when there is more to come: a caller that sees no next_offset knows
    // it has the whole file, without comparing byte counts itself. A short read
    // means end of file.
    if (slice.len == limit) {
        try s.objectField("next_offset");
        try s.write(offset + slice.len);
    }
    try s.endObject();
    out.len = w.end;
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
