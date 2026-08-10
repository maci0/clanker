//! reasoning: read recent reasoning traces (state/reasoning.jsonl) recorded
//! from reasoning models, so the agent can review its own chain-of-thought
//! and learn from it (RLM).
//! Input:  {"last": 5}
//! Output: {"ok": true, "text": "<recent reasoning traces>"}

const std = @import("std");
const lib = @import("lib.zig");

const Trace = struct {
    ts: i64 = 0,
    provider: []const u8 = "",
    model: []const u8 = "",
    task: []const u8 = "",
    reasoning: []const u8 = "",
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    var last: usize = 5;
    if (parsed == .object) {
        if (parsed.object.get("last")) |l| {
            if (l == .integer) last = @intCast(l.integer);
        }
    }
    const raw = lib.fsRead("state/reasoning.jsonl") catch return errJson(out, "no reasoning traces yet");

    var traces: std.ArrayList(Trace) = .empty;
    defer traces.deinit(std.heap.wasm_allocator);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r\n");
        if (l.len == 0) continue;
        const t = std.json.parseFromSliceLeaky(Trace, std.heap.wasm_allocator, l, .{ .ignore_unknown_fields = true }) catch continue;
        try traces.append(std.heap.wasm_allocator, t);
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.heap.wasm_allocator);
    const start = if (traces.items.len > last) traces.items.len - last else 0;
    for (traces.items[start..]) |t| {
        try text.appendSlice(std.heap.wasm_allocator, "== ");
        try text.appendSlice(std.heap.wasm_allocator, t.provider);
        try text.appendSlice(std.heap.wasm_allocator, " / ");
        try text.appendSlice(std.heap.wasm_allocator, t.model);
        try text.appendSlice(std.heap.wasm_allocator, " — ");
        try text.appendSlice(std.heap.wasm_allocator, t.task);
        try text.appendSlice(std.heap.wasm_allocator, "\n");
        try text.appendSlice(std.heap.wasm_allocator, t.reasoning);
        try text.appendSlice(std.heap.wasm_allocator, "\n\n");
    }
    if (text.items.len == 0) try text.appendSlice(std.heap.wasm_allocator, "(no reasoning traces)");

    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(text.items);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
