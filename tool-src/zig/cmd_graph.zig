//! cmd_graph: show the most recent execution graph (state/runs/*.json).
//! Input:  {"args": "..."}
//! Output: {"ok": true, "text": "<summary + node lines>"}

const std = @import("std");
const lib = @import("lib.zig");

const GraphNode = struct {
    kind: []const u8 = "",
    iteration: u32 = 0,
    label: []const u8 = "",
    detail: []const u8 = "",
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    result_bytes: usize = 0,
    duration_ms: u64 = 0,
};

const GraphFile = struct {
    run_id: []const u8 = "",
    task: []const u8 = "",
    provider: []const u8 = "",
    duration_ms: u64 = 0,
    total_prompt_tokens: u64 = 0,
    total_completion_tokens: u64 = 0,
    nodes: []const GraphNode = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    _ = parsed;

    const raw = lib.fsList("state/runs") catch |err| return errJson(out, @errorName(err));
    const names = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, raw, .{});

    // Pick the lexically-last run file (run-<ts> sorts chronologically).
    var best: ?[]const u8 = null;
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            if (!std.mem.endsWith(u8, item.string, ".json")) continue;
            if (best == null or std.mem.lessThan(u8, best.?, item.string)) best = item.string;
        }
    }
    const fname = best orelse {
        try out.writeAll("{\"ok\":true,\"text\":\"(no runs yet — clanker run creates one)\"}");
        return;
    };
    const path = try std.fmt.allocPrint(std.heap.wasm_allocator, "state/runs/{s}", .{fname});
    defer std.heap.wasm_allocator.free(path);
    const content = lib.fsRead(path) catch |err| return errJson(out, @errorName(err));
    const g = std.json.parseFromSliceLeaky(GraphFile, std.heap.wasm_allocator, content, .{ .ignore_unknown_fields = true }) catch |err| return errJson(out, @errorName(err));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.wasm_allocator);
    try buf.appendSlice(std.heap.wasm_allocator, g.run_id);
    try buf.appendSlice(std.heap.wasm_allocator, " — ");
    try buf.appendSlice(std.heap.wasm_allocator, g.task);
    const hdr = try std.fmt.allocPrint(std.heap.wasm_allocator, "  ({s}, {d}ms, prompt={d} completion={d})\n", .{ g.provider, g.duration_ms, g.total_prompt_tokens, g.total_completion_tokens });
    defer std.heap.wasm_allocator.free(hdr);
    try buf.appendSlice(std.heap.wasm_allocator, hdr);

    var iter_note: u32 = 0;
    for (g.nodes) |n| {
        if (n.iteration != iter_note) {
            iter_note = n.iteration;
            if (iter_note > 1) try buf.append(std.heap.wasm_allocator, '\n');
            const ih = try std.fmt.allocPrint(std.heap.wasm_allocator, "iter {d}\n", .{n.iteration});
            defer std.heap.wasm_allocator.free(ih);
            try buf.appendSlice(std.heap.wasm_allocator, ih);
        }
        if (std.mem.eql(u8, n.kind, "tool")) {
            const line = try std.fmt.allocPrint(std.heap.wasm_allocator, "  tool {s}  {d} B\n", .{ n.label, n.result_bytes });
            defer std.heap.wasm_allocator.free(line);
            try buf.appendSlice(std.heap.wasm_allocator, line);
        } else if (std.mem.eql(u8, n.kind, "final")) {
            const line = try std.fmt.allocPrint(std.heap.wasm_allocator, "  done {d} B, {s}\n", .{ n.result_bytes, n.detail });
            defer std.heap.wasm_allocator.free(line);
            try buf.appendSlice(std.heap.wasm_allocator, line);
        } else {
            const line = try std.fmt.allocPrint(std.heap.wasm_allocator, "  llm  {s}  {d}/{d} tok, {d}ms\n", .{ n.label, n.prompt_tokens, n.completion_tokens, n.duration_ms });
            defer std.heap.wasm_allocator.free(line);
            try buf.appendSlice(std.heap.wasm_allocator, line);
        }
    }

    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(buf.items);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
