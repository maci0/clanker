//! Shared record shape and append logic for `state/notifications.jsonl`, the
//! durable inbox behind `POST /api/notify`.
//!
//! The store lives in the `notifications` WASM tool (tools/zig/notifications.zig):
//! the HTTP route validates the request, relays it, and maps the reply
//! to a status code. The record shape, the retention ceiling, and the append
//! (deduped by delivery id, trimmed on a line boundary) are this module's,
//! so `zig build test` pins them and the guest cannot drift from the tests.

const std = @import("std");

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

pub const AppendResult = struct {
    /// Full new file content (existing log plus the new line, trimmed to
    /// `cap` on a line boundary). Empty when `duplicate` is true: nothing was
    /// appended, so there is nothing to write.
    content: []const u8,
    /// True when `record.id` was already in the log.
    duplicate: bool,
};

/// Builds the next log content for one append of `record`.
///
/// `existing` is the log as read; `cap` bounds the result (the caller passes
/// `max_bytes`). The dedupe check and the rewrite share the caller's
/// compare-and-swap write (`ck_fs_write_if`), so simultaneous redeliveries
/// cannot both append: one CAS wins and the loser re-reads, sees the id, and
/// reports the duplicate.
pub fn append(alloc: std.mem.Allocator, existing: []const u8, record: Record, cap: usize) !AppendResult {
    if (record.id) |id| if (id.len > 0) {
        if (hasId(alloc, existing, id)) return .{ .content = &.{}, .duplicate = true };
    };

    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    var s = std.json.Stringify{ .writer = &line.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.write(record);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.append(alloc, '\n');
    try out.appendSlice(alloc, line.written());
    try out.append(alloc, '\n');
    if (out.items.len > cap) {
        const floor = out.items.len - cap;
        const newline = std.mem.findScalarPos(u8, out.items, floor, '\n') orelse floor;
        const keep = @min(newline + 1, out.items.len);
        std.mem.copyForwards(u8, out.items[0 .. out.items.len - keep], out.items[keep..]);
        out.shrinkRetainingCapacity(out.items.len - keep);
    }
    return .{ .content = try out.toOwnedSlice(alloc), .duplicate = false };
}

/// Whether `id` already appears in the log. A line with no `"id"` key at all
/// can never carry one, and skipping its parse is what keeps the common (no
/// redelivery) case off the parser entirely.
fn hasId(alloc: std.mem.Allocator, existing: []const u8, id: []const u8) bool {
    var parsed_arena = std.heap.ArenaAllocator.init(alloc);
    defer parsed_arena.deinit();
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.find(u8, line, "\"id\"") == null) continue;
        _ = parsed_arena.reset(.retain_capacity);
        const prior = std.json.parseFromSliceLeaky(Record, parsed_arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
        if (prior.id) |prior_id| if (std.mem.eql(u8, prior_id, id)) return true;
    }
    return false;
}

// ------------------------------------------------------------------- tests --

test "notification redelivery with a known id is stored once" {
    const alloc = std.testing.allocator;
    const first = Record{
        .from = "peer",
        .kind = "message",
        .topic = "",
        .payload = .{ .string = "hello" },
        .ts = 1,
        .received_at = 2,
        .id = "delivery-1",
    };
    const once = try append(alloc, "", first, max_bytes);
    defer alloc.free(once.content);
    try std.testing.expect(!once.duplicate);

    const twice = try append(alloc, once.content, first, max_bytes);
    try std.testing.expect(twice.duplicate);
    try std.testing.expectEqual(@as(usize, 0), twice.content.len);
}

test "notification without an id is never a duplicate" {
    const alloc = std.testing.allocator;
    const first = Record{ .from = "peer", .kind = "message", .topic = "", .payload = .{ .string = "hi" }, .ts = 1, .received_at = 2 };
    const once = try append(alloc, "", first, max_bytes);
    defer alloc.free(once.content);
    const again = try append(alloc, once.content, first, max_bytes);
    defer alloc.free(again.content);
    try std.testing.expect(!again.duplicate);
}

test "notification append writes a JSON line with every field" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try append(alloc, "", .{
        .from = "peer",
        .kind = "message",
        .topic = "ops",
        .payload = .{ .string = "hello" },
        .ts = 123,
        .received_at = 456,
        .id = "delivery-9",
    }, max_bytes);
    defer alloc.free(res.content);

    const parsed = try std.json.parseFromSliceLeaky(Record, arena, res.content, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("peer", parsed.from);
    try std.testing.expectEqualStrings("message", parsed.kind);
    try std.testing.expectEqualStrings("ops", parsed.topic);
    try std.testing.expectEqual(@as(i64, 123), parsed.ts);
    try std.testing.expectEqual(@as(i64, 456), parsed.received_at);
    try std.testing.expectEqualStrings("delivery-9", parsed.id.?);
    try std.testing.expectEqualStrings("hello", parsed.payload.string);
}

test "notification cap keeps the newest whole lines, never mid-line" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 20 lines of {"n":<i>}, 9 bytes each: 180 bytes total.
    var existing = std.ArrayList(u8).empty;
    defer existing.deinit(alloc);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const line = try std.fmt.allocPrint(arena, "{{\"n\":{d}}}\n", .{i});
        try existing.appendSlice(alloc, line);
    }
    const res = try append(alloc, existing.items, .{
        .from = "x",
        .kind = "k",
        .topic = "",
        .payload = .{ .string = "y" },
        .ts = 1,
        .received_at = 2,
    }, 128);
    defer alloc.free(res.content);

    try std.testing.expect(res.content.len <= 128);
    // The kept region starts on a line boundary.
    try std.testing.expect(res.content.len == 0 or res.content[0] == '{');
    // The newest lines survive: 6 of the old {"n":...} lines (14..19) plus the
    // appended record, so the oldest 14 were dropped whole rather than cut.
    var n_fields: usize = 0;
    var lines = std.mem.splitScalar(u8, res.content, '\n');
    var last_line: []const u8 = "";
    while (lines.next()) |ln| {
        if (ln.len == 0) continue;
        last_line = ln;
        if (std.mem.find(u8, ln, "\"n\"") != null) n_fields += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), n_fields);
    const parsed = try std.json.parseFromSliceLeaky(Record, arena, last_line, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("x", parsed.from);
}
