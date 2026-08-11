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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const task = switch (obj.get("task") orelse return errJson(out, "missing task")) {
        .string => |s| s,
        else => return errJson(out, "task must be a string"),
    };
    var provider: ?[]const u8 = null;
    if (obj.get("provider")) |p| {
        if (p == .string and p.string.len > 0) provider = p.string;
    }
    // The brief travels as-is: the host reads "context" and "files" out of the
    // same object, so nothing has to be re-encoded here.
    const raw = lib.subagentBriefed(input, task, provider) catch |err| return errJson(out, @errorName(err));
    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(raw);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
