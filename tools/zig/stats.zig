//! model_stats: aggregate global token usage per provider/model from the
//! harness's token-usage log (state/token_stats.jsonl). All aggregation is
//! host-side in ck_stats; this module just forwards the result so the agent
//! can review its own spending (cost, cache hit rate, tok/s) and decide which
//! backend to use or whether to compact.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    _ = input;
    const result = lib.stats() catch |err| return errJson(out, @errorName(err));
    try out.writeAll(result);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
