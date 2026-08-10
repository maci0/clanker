//! std_api: look up a Zig 0.16 std symbol's signature + doc by grepping the
//! installed std source (host-side ck_std_api). Kills wrong-API proposals.
//! Input:  {"symbol": "readSliceShort"}
//! Output: {"ok": true, "text": "<up to 40 matching lines>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const symbol = switch (obj.get("symbol") orelse return errJson(out, "missing symbol")) {
        .string => |s| s,
        else => return errJson(out, "symbol must be a string"),
    };
    if (symbol.len == 0) return errJson(out, "symbol must not be empty");

    const raw = lib.stdApi(symbol) catch |err| return errJson(out, @errorName(err));
    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(raw);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
