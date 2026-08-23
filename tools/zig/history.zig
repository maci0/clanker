//! improve_history: review the self-improve history (state/improvements.jsonl —
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
            if (l == .integer and l.integer > 0) last = @intCast(l.integer);
        }
    }
    // Over a host channel, not the sandbox filesystem. In a `clanker
    // improve-self` worktree -- the only place this tool has anything to say --
    // `state/improvements.jsonl` is a symlink to the checkout's file, and the
    // sandbox's no-follow walk refuses a symlinked leaf even though the
    // manifest granted that exact path. Reading it here used to fail there and
    // land in the catch below, so every improve run was told it had no history
    // at all. `ck_improve_history` reads it host-side, where following the link
    // is allowed, and caps it on a line boundary.
    //
    // An empty reply means the ledger is genuinely absent; a failure is a real
    // read error and is reported as one rather than as an empty history.
    const raw = lib.improveHistory() catch |err|
        return lib.fail(out, switch (err) {
            error.SandboxDenied, error.NoAccess => "the improve history is not readable by this tool",
            else => "the improve history could not be read",
        });
    if (raw.len == 0) return lib.okText(out, "(no improvements recorded yet)");

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
