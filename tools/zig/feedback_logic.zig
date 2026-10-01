//! Pure feedback-sidecar helpers. Ratings never enter the model prompt.

const std = @import("std");

pub const Rating = enum { up, down };

pub const Entry = struct {
    ts: i64 = 0,
    session: []const u8 = "",
    turn: ?usize = null,
    rating: Rating = .up,
    note: []const u8 = "",
};

pub fn parseRating(s: []const u8) ?Rating {
    if (std.mem.eql(u8, s, "up") or std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "+")) return .up;
    if (std.mem.eql(u8, s, "down") or std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "-")) return .down;
    return null;
}

pub fn ratingName(r: Rating) []const u8 {
    return switch (r) {
        .up => "up",
        .down => "down",
    };
}

/// The log is the record of what the operator said, so it is bounded rather
/// than rotated: past this the oldest whole lines are dropped. A thumb press
/// is a few dozen bytes, so this holds years of ratings and keeps the dedup
/// read (below) from growing without bound.
pub const max_bytes = 1 << 20;

pub const AppendResult = struct {
    /// Full new file content (the existing log plus the new line, trimmed to
    /// `cap` on a line boundary). Empty when `duplicate` is true: nothing was
    /// appended, so there is nothing to write.
    content: []const u8,
    /// True when this exact rating of this exact turn is already in the log.
    duplicate: bool,
};

/// Builds the next log content for one append of `e`.
///
/// The dedup key is (session, turn, rating): a second POST of the same thumb
/// for the same turn -- a double click, a browser replay of the fetch, a
/// retried request whose first response was lost -- is the same statement
/// about the same turn and stores nothing further. The opposite rating on the
/// same turn is a different statement (an operator changing their mind) and is
/// stored. `ts` is deliberately not part of the key: two records that differ
/// only in when they arrived are still one rating.
///
/// The caller performs the write as a compare-and-swap on the hash of
/// `existing`, so two simultaneous posts cannot both append: one CAS wins and
/// the loser re-reads, sees the rating, and reports the duplicate.
pub fn append(alloc: std.mem.Allocator, existing: []const u8, e: Entry, cap: usize) !AppendResult {
    if (hasRating(alloc, existing, e)) return .{ .content = &.{}, .duplicate = true };

    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    try writeLine(&line.writer, e);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.append(alloc, '\n');
    // `writeLine` terminates its own line, so there is no second newline here.
    try out.appendSlice(alloc, line.written());
    if (out.items.len > cap) {
        const floor = out.items.len - cap;
        const newline = std.mem.findScalarPos(u8, out.items, floor, '\n') orelse floor;
        const keep = @min(newline + 1, out.items.len);
        std.mem.copyForwards(u8, out.items[0 .. out.items.len - keep], out.items[keep..]);
        out.shrinkRetainingCapacity(out.items.len - keep);
    }
    return .{ .content = try out.toOwnedSlice(alloc), .duplicate = false };
}

/// Whether `e`'s rating of `e`'s turn is already in the log. A line carrying
/// none of the key fields cannot match one that carries all of them, and
/// skipping its parse is what keeps the common (nothing to dedup) case off
/// the parser.
fn hasRating(alloc: std.mem.Allocator, existing: []const u8, e: Entry) bool {
    var parsed_arena = std.heap.ArenaAllocator.init(alloc);
    defer parsed_arena.deinit();
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.find(u8, line, "\"rating\"") == null) continue;
        _ = parsed_arena.reset(.retain_capacity);
        const prior = std.json.parseFromSliceLeaky(Entry, parsed_arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
        if (!std.mem.eql(u8, ratingName(prior.rating), ratingName(e.rating))) continue;
        if (!std.mem.eql(u8, prior.session, e.session)) continue;
        const prior_turn: ?usize = prior.turn;
        if (prior_turn != e.turn) continue;
        return true;
    }
    return false;
}

pub fn writeLine(w: *std.Io.Writer, e: Entry) !void {
    var s = std.json.Stringify{ .writer = w, .options = .{} };
    try s.beginObject();
    try s.objectField("ts");
    try s.write(e.ts);
    try s.objectField("session");
    try s.write(e.session);
    if (e.turn) |t| {
        try s.objectField("turn");
        try s.write(t);
    }
    try s.objectField("rating");
    try s.write(ratingName(e.rating));
    if (e.note.len > 0) {
        try s.objectField("note");
        try s.write(e.note);
    }
    try s.endObject();
    try w.writeByte('\n');
}

test "parseRating accepts a small closed set" {
    try std.testing.expectEqual(Rating.up, parseRating("up").?);
    try std.testing.expectEqual(Rating.down, parseRating("down").?);
    try std.testing.expect(parseRating("meh") == null);
}

test "writeLine is one json object per line" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeLine(&w, .{ .ts = 1, .session = "abc", .turn = 2, .rating = .down, .note = "nope" });
    try std.testing.expectEqualStrings("{\"ts\":1,\"session\":\"abc\",\"turn\":2,\"rating\":\"down\",\"note\":\"nope\"}\n", w.buffered());
}

test "recording the same rating of the same turn twice stores one line" {
    const alloc = std.testing.allocator;
    const e = Entry{ .ts = 1, .session = "sess-1", .turn = 7, .rating = .up };

    const once = try append(alloc, "", e, max_bytes);
    defer alloc.free(once.content);
    try std.testing.expect(!once.duplicate);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, once.content, "\n"));

    // The same append again -- what a double click, a replayed fetch or a
    // retried POST does. Nothing further is stored.
    const twice = try append(alloc, once.content, e, max_bytes);
    try std.testing.expect(twice.duplicate);
    try std.testing.expectEqual(@as(usize, 0), twice.content.len);

    // The same thumb pressed a minute later is the same statement, so the
    // arrival timestamp cannot resurrect it.
    const later = try append(alloc, once.content, .{ .ts = 99, .session = "sess-1", .turn = 7, .rating = .up }, max_bytes);
    try std.testing.expect(later.duplicate);
}

test "an operator changing their mind is a second rating, not a replay" {
    const alloc = std.testing.allocator;
    const up = try append(alloc, "", .{ .ts = 1, .session = "s", .turn = 3, .rating = .up }, max_bytes);
    defer alloc.free(up.content);
    const down = try append(alloc, up.content, .{ .ts = 2, .session = "s", .turn = 3, .rating = .down }, max_bytes);
    defer alloc.free(down.content);
    try std.testing.expect(!down.duplicate);

    // Another turn of the same conversation is another statement.
    const other_turn = try append(alloc, down.content, .{ .ts = 3, .session = "s", .turn = 4, .rating = .up }, max_bytes);
    defer alloc.free(other_turn.content);
    try std.testing.expect(!other_turn.duplicate);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, other_turn.content, "\n"));

    // Another conversation's turn 3 is not this one's turn 3 either.
    const other_session = try append(alloc, other_turn.content, .{ .ts = 4, .session = "t", .turn = 3, .rating = .up }, max_bytes);
    defer alloc.free(other_session.content);
    try std.testing.expect(!other_session.duplicate);
}

test "a turn-less rating dedups on the rating and the session alone" {
    const alloc = std.testing.allocator;
    const e = Entry{ .ts = 1, .session = "default", .rating = .down };
    const once = try append(alloc, "", e, max_bytes);
    defer alloc.free(once.content);
    const twice = try append(alloc, once.content, e, max_bytes);
    try std.testing.expect(twice.duplicate);
}

test "an unparseable line is kept and never matched" {
    const alloc = std.testing.allocator;
    const existing = "{\"ts\":1,\"session\":\"s\",\"rating\":\"up\"}\nnot json at all\n";
    const res = try append(alloc, existing, .{ .ts = 2, .session = "s", .turn = 1, .rating = .up }, max_bytes);
    defer alloc.free(res.content);
    try std.testing.expect(!res.duplicate);
    try std.testing.expect(std.mem.indexOf(u8, res.content, "not json at all") != null);
}

test "the log is trimmed to max_bytes on a line boundary" {
    const alloc = std.testing.allocator;
    var existing: std.ArrayList(u8) = .empty;
    defer existing.deinit(alloc);
    var i: usize = 0;
    while (existing.items.len <= 4096) : (i += 1) {
        const line = try std.fmt.allocPrint(alloc, "{{\"ts\":{d},\"session\":\"s\",\"turn\":{d},\"rating\":\"up\"}}\n", .{ i, i });
        defer alloc.free(line);
        try existing.appendSlice(alloc, line);
    }
    const res = try append(alloc, existing.items, .{ .ts = 9999, .session = "s", .turn = 9999, .rating = .down }, 512);
    defer alloc.free(res.content);
    try std.testing.expect(res.content.len <= 512);
    const last = res.content[res.content.len - 1];
    try std.testing.expectEqual(@as(u8, '\n'), last);
    // The newest line survives; the oldest whole lines are what went.
    try std.testing.expect(std.mem.indexOf(u8, res.content, "\"turn\":9999") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.content, "\"turn\":0}") == null);
}
