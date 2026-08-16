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
/// A failing `zig build test` is different: the only `error:` lines it prints
/// are expected log noise from passing tests (a config test deliberately loads
/// a bad file and logs it), while the actual failure is a `✘`-prefixed test
/// line sitting in the middle of a long transcript. A window anchored only on
/// `error:` would miss it entirely.
///
/// Prefer the last `✘` test-failure marker when one exists (test transcripts
/// interleave, so the last failed test is the one that actually aborted);
/// otherwise anchor on the last diagnostic error line. In both cases drop any
/// trailing build-command dump that slips into the window.
fn failureWindow(res: []const u8) []const u8 {
    // Keep the returned slice small: the host truncates tool output in the
    // middle when it is large, which is exactly what hides the one diagnostic
    // line we want. So anchor on the diagnostic and cap the window tightly.
    const max_window: usize = 3000;
    const fallback_tail: usize = 1500;

    // A failing `zig build test` aborts at the first failed test and prints a
    // `✘`-prefixed line naming it. Prefer the first such marker so the reader
    // sees the failed test's name and its assertion output. (There can be
    // several in one run because suites interleave; the first is the one the
    // build actually stopped on.)
    if (std.mem.indexOf(u8, res, "\u{2718}")) |m| {
        var line_start = m;
        while (line_start > 0 and res[line_start - 1] != '\n') line_start -= 1;
        const from = line_start;
        const to = @min(res.len, from + max_window);
        return res[from..to];
    }

    // Otherwise this is a compile error (or an unexpected build failure): zig
    // prints the real diagnostic lines (`file.zig:line:col: error: ...` and
    // bare `error: ...` messages) *before* the closing "Build Summary" and the
    // trailing `error: the following build command failed ...` plus its command
    // dump. A fixed last-N-chars tail can land entirely on that command line
    // and hide the very error it should show. Find the first real diagnostic
    // and return from its line up to the summary banner.
    var first: ?usize = null;
    var i: usize = 0;
    while (i < res.len) {
        var line_end = i;
        while (line_end < res.len and res[line_end] != '\n') line_end += 1;
        const line = res[i..line_end];
        if (std.mem.find(u8, line, "error:") != null and
            !std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "error: the following build command"))
        {
            first = i;
            break;
        }
        i = line_end + 1;
    }

    var from = first orelse @max(0, res.len - fallback_tail);
    // Trim a leading run of unrelated log lines so the slice opens on the error.
    if (first != null) {
        var line_start = from;
        while (line_start > 0 and res[line_start - 1] != '\n') line_start -= 1;
        from = line_start;
    }
    const to = @min(res.len, from + max_window);
    // Drop the closing build-command banner so the slice ends on the diagnostics.
    var end = to;
    if (std.mem.find(u8, res[from..to], "error: the following build command")) |p| end = from + p;
    if (std.mem.find(u8, res[from..end], "Build Summary:")) |p| end = from + p;
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
            //
            // `res` is the host's exec wrapper (`{"ok":false,"code":1,"stdout":
            // "...\n..."}`), so the transcript is JSON-escaped — window the
            // decoded stdout, not the wrapper.
            const stdout = blk: {
                var saw_stdout: ?[]const u8 = null;
                if (std.json.parseFromSliceLeaky(std.json.Value, alloc, res, .{})) |exec_parsed| {
                    if (exec_parsed == .object) {
                        if (exec_parsed.object.get("stdout")) |v| {
                            if (v == .string) saw_stdout = v.string;
                        }
                    }
                } else |_| {}
                break :blk saw_stdout orelse res;
            };
            // Debug helper: also spill the full decoded transcript so the raw
            // compile error survives display truncation. Spill for a compile
            // error (`error:`) and a failed test (`✘`) alike; the file lands in
            // the (gitignored) build output dir so a debugger can read the whole
            // transcript even when the windowed slice is truncated in display.
            if (std.mem.find(u8, stdout, "error:") != null or
                std.mem.find(u8, stdout, "\u{2718}") != null)
            {
                _ = lib.fsWrite("zig-out/gate-failure.txt", stdout) catch {};
            }
            const text = failureWindow(stdout);
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
            try s.write(text);
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
