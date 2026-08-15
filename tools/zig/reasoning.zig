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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    var last: usize = 5;
    if (parsed == .object) {
        if (parsed.object.get("last")) |l| {
            if (l == .integer and l.integer > 0) last = @intCast(l.integer);
        }
    }
    // Newest traces only: the log can grow to 8 MiB, and a full ck_fs_read
    // fails once it exceeds the 1 MiB host arena.
    const raw = lib.fsReadTail("state/reasoning.jsonl", 256 * 1024) catch return lib.fail(out, "no reasoning traces yet");

    var traces: std.ArrayList(Trace) = .empty;
    defer traces.deinit(lib.alloc);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r\n");
        if (l.len == 0) continue;
        const t = std.json.parseFromSliceLeaky(Trace, lib.alloc, l, .{ .ignore_unknown_fields = true }) catch continue;
        try traces.append(lib.alloc, t);
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(lib.alloc);
    const start = if (traces.items.len > last) traces.items.len - last else 0;
    for (traces.items[start..]) |t| {
        try text.appendSlice(lib.alloc, "== ");
        try text.appendSlice(lib.alloc, t.provider);
        try text.appendSlice(lib.alloc, " / ");
        try text.appendSlice(lib.alloc, t.model);
        try text.appendSlice(lib.alloc, " — ");
        try text.appendSlice(lib.alloc, t.task);
        try text.appendSlice(lib.alloc, "\n");
        try text.appendSlice(lib.alloc, t.reasoning);
        try text.appendSlice(lib.alloc, "\n\n");
    }
    if (text.items.len == 0) try text.appendSlice(lib.alloc, "(no reasoning traces)");

    return lib.okText(out, text.items);
}
