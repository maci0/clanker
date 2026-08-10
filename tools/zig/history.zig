//! history: review the improve history (state/history/improvements.jsonl —
//! successes, failures, summaries) so clanker can learn from past attempts.
//! Input:  {"last": 10}
//! Output: {"ok": true, "text": "<recent improvement records>"}

const std = @import("std");
const lib = @import("lib.zig");

const Rec = struct {
    id: []const u8 = "",
    status: []const u8 = "",
    instruction: []const u8 = "",
    summary: []const u8 = "",
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    var last: usize = 10;
    if (parsed == .object) {
        if (parsed.object.get("last")) |l| {
            if (l == .integer) last = @intCast(l.integer);
        }
    }
    const raw = lib.fsRead("state/improvements.jsonl") catch return errJson(out, "no history yet");

    var recs: std.ArrayList(Rec) = .empty;
    defer recs.deinit(std.heap.wasm_allocator);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r\n");
        if (l.len == 0) continue;
        const r = std.json.parseFromSliceLeaky(Rec, std.heap.wasm_allocator, l, .{ .ignore_unknown_fields = true }) catch continue;
        try recs.append(std.heap.wasm_allocator, r);
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.heap.wasm_allocator);
    const start = if (recs.items.len > last) recs.items.len - last else 0;
    for (recs.items[start..]) |r| {
        try text.appendSlice(std.heap.wasm_allocator, r.id);
        try text.appendSlice(std.heap.wasm_allocator, "  ");
        try text.appendSlice(std.heap.wasm_allocator, r.status);
        try text.appendSlice(std.heap.wasm_allocator, "  ");
        try text.appendSlice(std.heap.wasm_allocator, r.summary);
        if (r.instruction.len > 0) {
            try text.appendSlice(std.heap.wasm_allocator, "  |  ");
            try text.appendSlice(std.heap.wasm_allocator, r.instruction);
        }
        try text.append(std.heap.wasm_allocator, '\n');
    }

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
