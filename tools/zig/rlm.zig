//! rlm: Recursive Language Model — recursively call a sub-LM over a portion of
//! the input, mirroring the RLM paradigm (arXiv:2512.24601): the model treats
//! long inputs as an external environment it can decompose and recursively
//! process. Each call spawns a sub-agent (bounded iterations); the sub-agent
//! may itself call rlm with a higher depth for sub-portions, so arbitrarily
//! long inputs can be processed beyond any single context window.
//! Input:  {"instruction": "summarize", "text": "<chunk>", "depth": 0}
//! Output: {"ok": true, "text": "<sub-LM analysis>"}

const std = @import("std");
const lib = @import("lib.zig");

const max_depth: u32 = 3;

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const instruction = switch (obj.get("instruction") orelse return errJson(out, "missing instruction")) {
        .string => |s| s,
        else => return errJson(out, "instruction must be a string"),
    };
    const text = switch (obj.get("text") orelse return errJson(out, "missing text")) {
        .string => |s| s,
        else => return errJson(out, "text must be a string"),
    };
    var depth: u32 = 0;
    if (obj.get("depth")) |d| {
        if (d == .integer and d.integer > 0) depth = @intCast(d.integer);
    }

    var result: []const u8 = undefined;
    if (depth >= max_depth) {
        const cap: usize = 2000;
        const excerpt = if (text.len > cap) text[0..cap] else text;
        result = try std.fmt.allocPrint(std.heap.wasm_allocator, "(rlm depth limit {d} reached) excerpt: {s}", .{ depth, excerpt });
    } else {
        const task = try std.fmt.allocPrint(
            std.heap.wasm_allocator,
            "{s}\n\n<rlm chunk at depth {d}>\n{s}\n</rlm chunk>\n\nProcess the chunk per the instruction above. You may call the rlm tool again with depth {d} (and a smaller sub-chunk) for portions needing more analysis. Return your analysis as the final answer.",
            .{ instruction, depth, text, depth + 1 },
        );
        defer std.heap.wasm_allocator.free(task);
        result = lib.subagent(task, null) catch |err| return errJson(out, @errorName(err));
    }

    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(result);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
