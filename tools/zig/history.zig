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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    var last: usize = 10;
    if (parsed == .object) {
        if (parsed.object.get("last")) |l| {
            if (l == .integer) last = @intCast(l.integer);
        }
    }
    const raw = lib.fsRead("state/improvements.jsonl") catch return lib.fail(out, "no history yet");

    var recs: std.ArrayList(Rec) = .empty;
    defer recs.deinit(lib.alloc);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r\n");
        if (l.len == 0) continue;
        const r = std.json.parseFromSliceLeaky(Rec, lib.alloc, l, .{ .ignore_unknown_fields = true }) catch continue;
        try recs.append(lib.alloc, r);
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(lib.alloc);
    const start = if (recs.items.len > last) recs.items.len - last else 0;
    for (recs.items[start..]) |r| {
        try text.appendSlice(lib.alloc, r.id);
        try text.appendSlice(lib.alloc, "  ");
        try text.appendSlice(lib.alloc, r.status);
        try text.appendSlice(lib.alloc, "  ");
        try text.appendSlice(lib.alloc, r.summary);
        if (r.instruction.len > 0) {
            try text.appendSlice(lib.alloc, "  |  ");
            try text.appendSlice(lib.alloc, r.instruction);
        }
        try text.append(lib.alloc, '\n');
    }

    return lib.okText(out, text.items);
}
