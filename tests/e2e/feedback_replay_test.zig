//! `POST /api/feedback` twice is one rating. The web UI fires this from a
//! thumb button, so a double click, a replayed fetch and a retried request all
//! land here twice in a row; the store keys the rating on
//! (session, turn, rating) and answers the replay as a duplicate instead of
//! appending a second row. Drives the real binary's `clanker serve` and reads
//! the log back through the endpoint that shows it.

const std = @import("std");
const harness = @import("harness.zig");

fn url(buf: []u8, port: u16, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path });
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    srv: harness.Serve,
    port: u16,

    fn init(io: std.Io, gpa: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const mock_port = try harness.pickPort(io);
        const port = try harness.pickPort(io);
        try harness.writeMockConfig(io, tmp.dir, gpa, mock_port);
        try harness.linkZigOut(io, tmp.dir);

        var srv = try harness.spawnServe(io, tmp.dir, port);
        errdefer srv.stop(io);
        try harness.waitTcp(io, port, 8000);
        var buf: [96]u8 = undefined;
        try harness.waitHttp(io, gpa, try url(&buf, port, "/api/workflows"), 8000);
        return .{ .tmp = tmp, .srv = srv, .port = port };
    }

    fn deinit(self: *Fixture, io: std.Io) void {
        self.srv.stop(io);
        self.tmp.cleanup();
    }

    fn get(self: *Fixture, io: std.Io, gpa: std.mem.Allocator, path: []const u8) !harness.Answer {
        var buf: [512]u8 = undefined;
        return harness.httpRequest(io, gpa, .GET, try url(&buf, self.port, path), null);
    }

    fn post(self: *Fixture, io: std.Io, gpa: std.mem.Allocator, path: []const u8, payload: []const u8) !harness.Answer {
        var buf: [512]u8 = undefined;
        return harness.httpRequest(io, gpa, .POST, try url(&buf, self.port, path), payload);
    }
};

test "recording the same thumb twice stores one rating" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(io, gpa);
    defer fx.deinit(io);

    const payload = "{\"rating\":\"up\",\"session\":\"sess-a\",\"turn\":4}";

    var first = try fx.post(io, gpa, "/api/feedback", payload);
    defer first.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), first.status);
    try std.testing.expect(first.has("\"ok\":true"));

    // The replay a lost response or a double click produces.
    var second = try fx.post(io, gpa, "/api/feedback", payload);
    defer second.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), second.status);
    try std.testing.expect(second.has("\"duplicate\":true"));

    var listed = try fx.get(io, gpa, "/api/feedback");
    defer listed.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), listed.status);
    // The log rides back as JSON string content, so its own quotes arrive
    // escaped.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, listed.body, "\\\"rating\\\""));
    try std.testing.expect(listed.has("sess-a"));

    // Changing the mind is a second statement, and another turn is another
    // one: the dedup key is the rating of one turn, not the turn alone.
    var changed = try fx.post(io, gpa, "/api/feedback", "{\"rating\":\"down\",\"session\":\"sess-a\",\"turn\":4}");
    defer changed.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), changed.status);
    try std.testing.expect(changed.has("\"duplicate\":true") == false);

    var next_turn = try fx.post(io, gpa, "/api/feedback", "{\"rating\":\"up\",\"session\":\"sess-a\",\"turn\":5}");
    defer next_turn.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), next_turn.status);

    var final_list = try fx.get(io, gpa, "/api/feedback");
    defer final_list.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, final_list.body, "\\\"rating\\\""));
}
