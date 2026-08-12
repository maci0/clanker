//! rlm: Recursive Language Model — recursively call a sub-LM over a portion of
//! the input, mirroring the RLM paradigm (arXiv:2512.24601): the model treats
//! long inputs as an external environment it can decompose and recursively
//! process. Each call spawns a sub-agent (bounded iterations); the sub-agent
//! may itself call rlm with a higher depth for sub-portions, so arbitrarily
//! long inputs can be processed beyond any single context window.
//! Input:  {"instruction": "summarize", "text": "<chunk>", "depth": 0}
//! Output: {"ok": true, "text": "<sub-LM analysis>"}
//!
//! Settings come from the `config` object in tools/manifests/rlm.tool.json:
//!   max_depth  how many levels of recursion are allowed (default 3)
//! Note that `depth` in the input is the *current* level, counted up by each
//! nested call; `max_depth` is the ceiling it is measured against.

const std = @import("std");
const lib = @import("lib.zig");

const Settings = struct {
    max_depth: u32 = default_max_depth,
};

const default_max_depth: u32 = 3;

/// Every extra level multiplies the number of sub-agent runs, and each of
/// those is a model call with its own iteration budget. A misconfigured value
/// is therefore a bill rather than a slow tool, so the configured setting is
/// clamped instead of trusted.
const depth_ceiling: u32 = 8;

fn maxDepth() u32 {
    const settings = std.json.parseFromSliceLeaky(Settings, lib.alloc, lib.config(), .{ .ignore_unknown_fields = true }) catch Settings{};
    if (settings.max_depth == 0) return default_max_depth;
    return @min(settings.max_depth, depth_ceiling);
}

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;
    const instruction = switch (obj.get("instruction") orelse return lib.fail(out, "missing instruction")) {
        .string => |s| s,
        else => return lib.fail(out, "instruction must be a string"),
    };
    const text = switch (obj.get("text") orelse return lib.fail(out, "missing text")) {
        .string => |s| s,
        else => return lib.fail(out, "text must be a string"),
    };
    var depth: u32 = 0;
    if (obj.get("depth")) |d| {
        if (d == .integer and d.integer > 0) depth = @intCast(d.integer);
    }

    const max_depth = maxDepth();

    var result: []const u8 = undefined;
    if (depth >= max_depth) {
        const cap: usize = 2000;
        const excerpt = if (text.len > cap) text[0..cap] else text;
        result = try std.fmt.allocPrint(lib.alloc, "(rlm depth limit {d} reached) excerpt: {s}", .{ max_depth, excerpt });
    } else {
        const task = try std.fmt.allocPrint(
            lib.alloc,
            "{s}\n\n<rlm chunk at depth {d}>\n{s}\n</rlm chunk>\n\nProcess the chunk per the instruction above. You may call the rlm tool again with depth {d} (and a smaller sub-chunk) for portions needing more analysis. Return your analysis as the final answer.",
            .{ instruction, depth, text, depth + 1 },
        );
        defer lib.alloc.free(task);
        result = lib.subagent(task, null) catch |err| return lib.failErr(out, err, "this tool needs a parent agent to run its sub-steps, and this call has none");
    }

    return lib.okText(out, result);
}
