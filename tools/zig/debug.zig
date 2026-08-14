//! DAP debug tool. Off by default (`debug.enabled = false`): an adapter is
//! an unsandboxed subprocess. The host owns framing and the 0016 registry.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const cfg = lib.parseHarnessConfig();
    if (!cfg.debug.enabled) {
        return lib.fail(out, "debug is disabled (debug.enabled = false); this is an unsandboxed adapter subprocess and stays opt-in");
    }
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;
    const op = switch (obj.get("op") orelse return lib.fail(out, "missing op")) {
        .string => |s| s,
        else => return lib.fail(out, "op must be a string"),
    };
    _ = op;
    const raw = lib.debugEval(input) catch |err| {
        return lib.failErr(out, err, "ck_debug");
    };
    try out.writeAll(raw);
}
