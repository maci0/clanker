//! subagent: delegate a task to a nested sub-agent run (separate context,
//! bounded iterations). Returns the sub-agent's final answer.
//! Input:  {"task": "...", "context": ["..."], "files": ["src/x.zig"], "provider": "kimi-k3"}
//! Output: {"ok": true, "text": "<sub-agent answer>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const task = switch (obj.get("task") orelse return lib.fail(out, "missing task")) {
        .string => |s| s,
        else => return lib.fail(out, "task must be a string"),
    };
    var provider: ?[]const u8 = null;
    if (obj.get("provider")) |p| {
        if (p == .string and p.string.len > 0) provider = p.string;
    }
    // The brief travels as-is: the host reads "context" and "files" out of the
    // same object, so nothing has to be re-encoded here.
    const raw = lib.subagentBriefed(input, task, provider) catch |err| return lib.fail(out, switch (err) {
        // The host only attaches a runner inside an agent run. Over MCP, or
        // from a one-shot tool call, there is nothing to spawn, and
        // "NotFound" reads as if the task or the provider were missing.
        error.NotFound => "sub-agents run only inside an agent run; this call has no parent agent to spawn one",
        error.SandboxDenied => "this tool is not allowed to spawn sub-agents",
        else => @errorName(err),
    });
    return lib.okText(out, raw);
}
