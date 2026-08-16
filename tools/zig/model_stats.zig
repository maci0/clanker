//! model_stats: present global token usage per provider/model from the
//! harness's token-usage log (state/token_stats.jsonl). ck_stats only exposes
//! the authorized aggregate from the configured state directory (raw records
//! would overflow the 1 MiB guest arena). This guest owns text rendering
//! (model_stats_logic.zig, host-tested); JSON callers get the host aggregate
//! as-is.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("model_stats_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const raw = lib.stats() catch |err| return lib.failErr(out, err, "reading token stats");
    const request = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    if (request.object.get("args") != null) {
        const result = std.json.parseFromSliceLeaky(logic.Stats, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch |err|
            return lib.failErr(out, err, "parsing token stats");
        const text = logic.renderText(lib.alloc, result.stats, result.totals) catch |err| return lib.failErr(out, err, "rendering token stats");
        return lib.okText(out, text);
    }
    try out.writeAll(raw);
}
