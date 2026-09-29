//! zig_std: look up a Zig 0.16 std symbol's signature + doc by grepping the
//! installed std source (host-side ck_std_api). Kills wrong-API proposals.
//! Input:  {"symbol": "readSliceShort"}
//! Output: {"ok": true, "text": "<up to 40 matching lines>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;
    const symbol = lib.strFieldRequired(obj, "symbol") orelse return lib.fail(out, "symbol must be a non-empty string");

    const raw = lib.stdApi(symbol) catch |err| return lib.failErr(out, err, "looking up the std symbol");
    return lib.okText(out, raw);
}
