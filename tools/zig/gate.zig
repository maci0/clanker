//! gate: run the project's deterministic gates and answer pass/fail.
//!
//! The agent can already edit code; this lets it check its own work the same
//! way the improvement engine does, instead of declaring success and hoping.
//!
//! Input:  {} or {"gates": ["build", "test", "tools", "fmt"]}
//! Output: {"ok": true,  "text": "build ok; test ok"}
//!         {"ok": false, "error": "test failed", "text": "<tail of the output>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

/// Ordered by dependency and by cost: a build failure makes the rest moot, and
/// the tools build produces the .wasm artifacts the tests load.
const default_gates = [_][]const u8{ "build", "tools", "test" };

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = std.heap.wasm_allocator;
    var gates: []const []const u8 = &default_gates;

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{}) catch std.json.Value{ .object = .empty };
    if (parsed == .object) {
        if (parsed.object.get("gates")) |g| {
            if (g == .array) {
                var chosen: std.ArrayList([]const u8) = .empty;
                for (g.array.items) |item| {
                    if (item == .string and item.string.len > 0) try chosen.append(alloc, item.string);
                }
                if (chosen.items.len > 0) gates = chosen.items;
            }
        }
    }

    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(alloc);

    for (gates) |gate| {
        // Only the build steps this project actually has: an arbitrary step
        // name would just be a slow way to fail.
        if (!std.mem.eql(u8, gate, "build") and !std.mem.eql(u8, gate, "test") and
            !std.mem.eql(u8, gate, "tools") and !std.mem.eql(u8, gate, "fmt"))
        {
            return errJson(out, "unknown gate; use build, tools, test or fmt");
        }

        const args: []const []const u8 = if (std.mem.eql(u8, gate, "fmt"))
            &[_][]const u8{ "fmt", "--check", "src" }
        else
            &[_][]const u8{ "build", gate };

        const res = lib.exec("zig", args) catch return errJson(out, "could not run zig");
        const failed = std.mem.indexOf(u8, res, "\"code\":0") == null;
        if (failed) {
            var buf: [4096]u8 = undefined;
            const tail = res[res.len -| 1500 ..];
            const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s} failed\",\"text\":{f}}}", .{ gate, std.json.fmt(tail, .{}) });
            return out.writeAll(body);
        }
        try report.appendSlice(alloc, gate);
        try report.appendSlice(alloc, " ok; ");
    }

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(std.mem.trimEnd(u8, report.items, "; "));
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
