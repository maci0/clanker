//! swarm: fan a batch of self-contained tasks out to nested agents running
//! concurrently, each with its own context and a short iteration budget.
//! Input:  {"tasks": ["...", "..."], "provider": "kimi-k3"}
//! Output: {"ok": true, "text": "<JSON array of {task, ok, text|error}>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const tasks = obj.get("tasks") orelse return lib.fail(out, "missing tasks");
    if (tasks != .array or tasks.array.items.len == 0) return lib.fail(out, "tasks must be a non-empty array of strings");
    // The host reads "tasks"/"provider" straight out of this object; nothing
    // here needs to be re-parsed to forward it.
    const raw = lib.swarm(input) catch |err| return lib.fail(out, switch (err) {
        // The host only attaches a subagent runner inside an agent run. Over
        // MCP, or from a one-shot tool call, there is nothing to spawn from.
        error.NotFound => "swarm runs only inside an agent run; this call has no parent agent to spawn from",
        error.SandboxDenied => "this tool is not allowed to spawn a swarm",
        error.TooLarge => "too many tasks for one swarm call, or the combined results were too large",
        else => @errorName(err),
    });
    return lib.okText(out, raw);
}
