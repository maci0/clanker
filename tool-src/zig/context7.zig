//! context7: fetch library documentation (markdown + code examples) from
//! context7.com for the given GitHub org/repo, optionally filtered by topic.
//! Input:  {"org": "ziglang", "repo": "zig", "topic": "std.http", "max_chars": 4000}
//! Output: {"ok": true, "text": "<docs markdown>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const org = switch (obj.get("org") orelse return errJson(out, "missing org")) {
        .string => |s| s,
        else => return errJson(out, "org must be a string"),
    };
    const repo = switch (obj.get("repo") orelse return errJson(out, "missing repo")) {
        .string => |s| s,
        else => return errJson(out, "repo must be a string"),
    };
    var topic: []const u8 = "";
    if (obj.get("topic")) |t| {
        if (t == .string) topic = t.string;
    }
    var max_chars: usize = 4000;
    if (obj.get("max_chars")) |m| {
        if (m == .integer) max_chars = @intCast(m.integer);
    }

    const url = if (topic.len > 0)
        try std.fmt.allocPrint(std.heap.wasm_allocator, "https://context7.com/api/v1/{s}/{s}?topic={s}", .{ org, repo, topic })
    else
        try std.fmt.allocPrint(std.heap.wasm_allocator, "https://context7.com/api/v1/{s}/{s}", .{ org, repo });
    defer std.heap.wasm_allocator.free(url);

    const body = lib.httpGet(url) catch |err| return errJson(out, @errorName(err));
    const text = if (body.len > max_chars) body[0..max_chars] else body;

    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
