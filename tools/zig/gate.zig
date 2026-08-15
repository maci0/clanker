//! gate: run the project's deterministic gates and answer pass/fail.
//!
//! The agent can already edit code; this lets it check its own work the same
//! way the improvement engine does, instead of declaring success and hoping.
//!
//! Input:  {} or {"gates": ["build", "test", "tools", "fmt"]}
//!         {"dir": "..."} runs every step with that directory as cwd, for
//!         checking a subdirectory such as a git worktree. The host resolves
//!         `dir` against the sandbox root and refuses anything outside the
//!         roots the descriptor grants.
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

/// Choose the slice of a failed gate's output that actually diagnoses it.
///
/// zig prints the real compile errors (`file.zig:line:col: error: ...` and bare
/// `error: ...` message lines) *before* the closing summary and the trailing
/// `error: the following build command failed with exit code N:` plus its
/// command dump. A fixed last-N-chars tail can therefore land entirely on that
/// trailing command line and hide the very errors it is meant to show — which
/// is how the improvement engine once burned two full iterations failing blind.
///
/// Anchor the window on the last diagnostic error line instead, and drop any
/// trailing build-command dump that slips into the window.
fn failureWindow(res: []const u8) []const u8 {
    const max_window: usize = 20000;
    const fallback_tail: usize = 1500;

    // Walk backwards over lines looking for the last real diagnostic: a line
    // mentioning "error:" that is not the closing build-command banner.
    var start: ?usize = null;
    var i: usize = res.len;
    while (i > 0) {
        var line_start = i;
        while (line_start > 0 and res[line_start - 1] != '\n') line_start -= 1;
        const line = res[line_start..i];
        i = line_start;
        if (line_start > 0) i -= 1;
        if (std.mem.indexOf(u8, line, "error:") != null and
            !std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "error: the following build command"))
        {
            start = line_start;
            break;
        }
    }

    const from = start orelse @max(0, res.len - fallback_tail);
    const to = @min(res.len, from + max_window);
    // Trim a trailing build-command dump that landed inside the window.
    var end = to;
    if (std.mem.indexOf(u8, res[from..to], "error: the following build command")) |p| end = from + p;
    return res[from..end];
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    var gates: []const []const u8 = &default_gates;
    var dir: ?[]const u8 = null;

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
        if (parsed.object.get("dir")) |d| {
            if (d == .string and d.string.len > 0) dir = d.string;
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

        const res = if (dir) |d|
            lib.execCwd("zig", args, d) catch |err| return lib.failErr(out, err, "running zig")
        else
            lib.exec("zig", args) catch |err| return lib.failErr(out, err, "running zig");
        const failed = std.mem.find(u8, res, "\"code\":0") == null;
        if (failed) {
            // Emit a compact JSON object. A growable buffer, not a fixed one:
            // the diagnostic window is unbounded and JSON escaping can roughly
            // double it, and truncating here would recreate the very blindness
            // failureWindow exists to fix.
            report.clearRetainingCapacity();
            var w: std.Io.Writer.Allocating = .init(alloc);
            defer w.deinit();
            var s = std.json.Stringify{ .writer = &w.writer, .options = .{} };
            try s.beginObject();
            try s.objectField("ok");
            try s.write(false);
            try s.objectField("error");
            try s.write(std.fmt.allocPrint(alloc, "{s} failed", .{gate}) catch gate);
            try s.objectField("text");
            try s.write(failureWindow(res));
            try s.endObject();
            return out.writeAll(w.written());
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
