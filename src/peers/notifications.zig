//! `state/notifications.jsonl`, the durable inbox behind `POST /api/notify`.
//!
//! Lives here rather than in `cli.zig` for the reason `chatrooms.zig` does:
//! a notification is a peer-mesh record, and `cli.zig` owns the HTTP route,
//! not the store. The route keeps the wire body and the status codes; the
//! record shape, the retention ceiling, and the append (locked, deduped by
//! delivery id, trimmed on a line boundary) are this module's.
//!
//! A notification is not a chat message: nothing fans it out, and nothing
//! replies to it.

const std = @import("std");
const atomic_write = @import("../util/atomic_write.zig");
const ensure_dir = @import("../util/ensure_dir.zig");
const file_lock = @import("../util/file_lock.zig");

pub const path = "state/notifications.jsonl";

/// The log is the ledger, so it is bounded rather than rotated: past this,
/// the oldest whole lines are dropped.
pub const max_bytes = 1 << 20;

pub const Record = struct {
    from: []const u8,
    kind: []const u8,
    topic: []const u8,
    payload: std.json.Value,
    ts: i64,
    received_at: i64,
    /// Delivery id, when the sender supplied one. Present means the append is
    /// idempotent: a redelivery with an id already in the log is dropped.
    id: ?[]const u8 = null,
};

/// Append `record` under `base`, creating `state/` if it is the first one.
pub fn store(io: std.Io, gpa: std.mem.Allocator, base: std.Io.Dir, record: Record) !void {
    try ensure_dir.ensureDir(base, io, "state");
    var guard = file_lock.acquire(io, base, "state", "notifications", gpa);
    defer guard.release();

    const maybe_existing = base.readFileAlloc(io, path, gpa, .limited(max_bytes)) catch null;
    defer if (maybe_existing) |e| gpa.free(e);
    const existing = maybe_existing orelse &[_]u8{};

    // The log itself is the bounded delivery ledger. The check and rewrite
    // share one lock, so simultaneous redeliveries cannot both append.
    if (record.id) |id| if (id.len > 0) {
        var lines = std.mem.splitScalar(u8, existing, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parsed_arena = std.heap.ArenaAllocator.init(gpa);
            defer parsed_arena.deinit();
            const prior = std.json.parseFromSliceLeaky(Record, parsed_arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
            if (prior.id) |prior_id| if (std.mem.eql(u8, prior_id, id)) return;
        }
    };

    var line_buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.write(record);

    var out_list = std.ArrayList(u8).empty;
    defer out_list.deinit(gpa);
    try out_list.appendSlice(gpa, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out_list.append(gpa, '\n');
    try out_list.appendSlice(gpa, line_buf[0..w.end]);
    try out_list.append(gpa, '\n');
    if (out_list.items.len > max_bytes) {
        const floor = out_list.items.len - max_bytes;
        const newline = std.mem.findScalarPos(u8, out_list.items, floor, '\n') orelse floor;
        const keep = @min(newline + 1, out_list.items.len);
        std.mem.copyForwards(u8, out_list.items[0 .. out_list.items.len - keep], out_list.items[keep..]);
        out_list.shrinkRetainingCapacity(out_list.items.len - keep);
    }
    try atomic_write.writeFile(io, base, path, out_list.items);
}

test "notification redelivery is stored once" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = Record{
        .from = "peer",
        .kind = "message",
        .topic = "",
        .payload = .{ .string = "hello" },
        .ts = 1,
        .received_at = 2,
        .id = "delivery-1",
    };
    try store(io, std.testing.allocator, tmp.dir, first);
    try store(io, std.testing.allocator, tmp.dir, first);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw = try tmp.dir.readFileAlloc(io, path, arena_state.allocator(), .limited(max_bytes));
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| if (line.len > 0) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), count);
}
