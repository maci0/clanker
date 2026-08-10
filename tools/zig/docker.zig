//! docker: query the local Docker daemon via its Unix socket.
//! Input:  {"path": "/v1.41/containers/json", "method": "GET"}
//! Output: {"ok": true, "body": "<raw response>"} or {"ok": false, "error": ...}
//! Only GET/POST to /v1.* paths are allowed by the sandbox.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const path = switch (obj.get("path") orelse return errJson(out, "missing path")) {
        .string => |s| s,
        else => return errJson(out, "path must be a string"),
    };
    var method: []const u8 = "GET";
    if (obj.get("method")) |m| {
        switch (m) {
            .string => |s| method = s,
            else => {},
        }
    }

    const body = lib.dockerRequest(method, path) catch |err| {
        return errJson(out, @errorName(err));
    };

    var buf: [256 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("bytes");
    try s.print("{d}", .{body.len});
    try s.objectField("body");
    try s.write(body);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
