//! jobs: start / list / wait / kill background work.
//! Input: {"op":"list"} | {"op":"start","argv":["zig","build"]} |
//!        {"op":"wait","id":"..."} | {"op":"kill","id":"..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    _ = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const raw = lib.job(input) catch |err| return switch (err) {
        error.SandboxDenied => lib.fail(out, "jobs are not allowed here"),
        error.NotFound => lib.fail(out, "no such job"),
        else => lib.failErr(out, err, "job"),
    };
    try out.writeAll(raw);
}
