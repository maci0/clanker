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
