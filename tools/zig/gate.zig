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
    const alloc = lib.alloc;
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

    // astcheck needs a file to parse; default to the agent loop only because
    // something must be named, and the caller almost always names its own.
    var target_file: []const u8 = "src/main.zig";
    if (parsed == .object) {
        if (parsed.object.get("file")) |f| {
            if (f == .string and f.string.len > 0) target_file = f.string;
        }
    }

    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(alloc);

    for (gates) |gate| {
        // Only the build steps this project actually has: an arbitrary step
        // name would just be a slow way to fail.
        if (!std.mem.eql(u8, gate, "build") and !std.mem.eql(u8, gate, "test") and
            !std.mem.eql(u8, gate, "tools") and !std.mem.eql(u8, gate, "fmt") and
            !std.mem.eql(u8, gate, "astcheck"))
        {
            return lib.fail(out, "unknown gate; use build, tools, test, fmt or astcheck");
        }

        // astcheck parses a single file against the real Zig grammar in
        // milliseconds: after editing one file, that answers "is this still
        // valid Zig" deterministically without waiting for a whole build.
        const args: []const []const u8 = if (std.mem.eql(u8, gate, "fmt"))
            &[_][]const u8{ "fmt", "--check", "src" }
        else if (std.mem.eql(u8, gate, "astcheck"))
            &[_][]const u8{ "ast-check", target_file }
        else if (std.mem.eql(u8, gate, "build"))
            // The default step, not a step named "build": build.zig declares
            // run, test and tools, so `zig build build` fails with "no step
            // named 'build'". That is the first gate in the default list, so
            // every gate call with no arguments failed before running anything.
            &[_][]const u8{"build"}
        else
            &[_][]const u8{ "build", gate };

        const res = lib.exec("zig", args) catch return lib.fail(out, "could not run zig");
        const failed = std.mem.indexOf(u8, res, "\"code\":0") == null;
        if (failed) {
            var buf: [4096]u8 = undefined;
            const tail = res[res.len -| 1500..];
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
