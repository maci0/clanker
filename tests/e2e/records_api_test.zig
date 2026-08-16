//! `GET|POST /api/{reports,rfc,adr,prd,research}` — the record stores over
//! HTTP (ADR 0019, PRD 0038). Drives the real binary's `clanker serve`
//! against a temp checkout carrying a copy of each store's scaffolding, so
//! every assertion is about JSON the shipped handler and its guest produced.

const std = @import("std");
const harness = @import("harness.zig");

fn url(buf: []u8, port: u16, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path });
}

/// A serve on a temp checkout with the record stores scaffolded but empty.
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
        try harness.copyRecordStores(io, gpa, tmp.dir);

        var srv = try harness.spawnServe(io, tmp.dir, port);
        errdefer srv.stop(io);
        try harness.waitTcp(io, port, 8000);
        var buf: [96]u8 = undefined;
        // `/api/workflows` is an unrelated, always-present endpoint: waiting
        // on one of the endpoints under test would turn a broken route into
        // a timeout instead of a failed assertion.
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

test "record endpoints relay reads on GET and writes on POST" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(io, gpa);
    defer fx.deinit(io);

    // Every store lists on a bare GET: the endpoint sends an explicit
    // `list`, so a guest whose own default is another action still lists.
    const stores = [_]struct { path: []const u8, key: []const u8 }{
        .{ .path = "/api/reports", .key = "\"reports_index\"" },
        .{ .path = "/api/rfc", .key = "\"rfcs\"" },
        .{ .path = "/api/adr", .key = "\"adrs\"" },
        .{ .path = "/api/prd", .key = "\"prds\"" },
        .{ .path = "/api/research", .key = "\"documents\"" },
    };
    for (stores) |store| {
        var listed = try fx.get(io, gpa, store.path);
        defer listed.deinit(gpa);
        try std.testing.expectEqual(@as(u16, 200), listed.status);
        try std.testing.expect(listed.has("\"ok\":true"));
        try std.testing.expect(listed.has(store.key));
    }

    // A write goes through as the guest's own input object, and the record
    // it created is readable back through the read action.
    var created = try fx.post(io, gpa, "/api/prd",
        \\{"action":"create","title":"Relay journey","problem":"p","goals":"1. g"}
    );
    defer created.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), created.status);
    try std.testing.expect(created.has("\"created\":true"));
    try std.testing.expect(created.has("docs/prds/0001-relay-journey.md"));

    var opened = try fx.get(io, gpa, "/api/prd?action=open&path=docs/prds/0001-relay-journey.md");
    defer opened.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), opened.status);
    try std.testing.expect(opened.has("Relay journey"));

    // Query parameters carry the guest's own field names, percent-decoded.
    var found = try fx.get(io, gpa, "/api/prd?action=search&query=Relay%20journey");
    defer found.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), found.status);
    try std.testing.expect(found.has("docs/prds/0001-relay-journey.md"));
}

test "a write action on GET is refused before the guest runs" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(io, gpa);
    defer fx.deinit(io);

    var forged = try fx.get(io, gpa, "/api/prd?action=create&title=Forged&problem=p&goals=g");
    defer forged.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 400), forged.status);
    try std.testing.expect(forged.has("POST"));

    // The refusal has to mean nothing happened: a GET must not be able to
    // mutate a record, so the store is still empty.
    var listed = try fx.get(io, gpa, "/api/prd");
    defer listed.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), listed.status);
    try std.testing.expect(!listed.has("Forged"));
    try std.testing.expect(listed.has("\"next_number\":1"));

    // The split holds in the other direction, and a POST with no action is
    // refused rather than falling through to a guest default that reads.
    var read_on_post = try fx.post(io, gpa, "/api/adr", "{\"action\":\"list\"}");
    defer read_on_post.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 400), read_on_post.status);
    try std.testing.expect(read_on_post.has("GET"));

    var no_action = try fx.post(io, gpa, "/api/adr", "{\"title\":\"t\"}");
    defer no_action.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 400), no_action.status);

    // `research sweep` is on neither method: it is the one action left off
    // the HTTP surface, because it performs network egress.
    var swept = try fx.get(io, gpa, "/api/research?action=sweep&topic=wasm");
    defer swept.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 400), swept.status);

    var method = try harness.httpRequest(io, gpa, .PUT, blk: {
        var buf: [96]u8 = undefined;
        break :blk try url(&buf, fx.port, "/api/rfc");
    }, "{}");
    defer method.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 405), method.status);
}

test "a missing record is 404 and a stale update is a refusal, not an overwrite" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init(io, gpa);
    defer fx.deinit(io);

    // toolRefusalStatus maps the guest's "no such"/"not found" refusal to
    // 404 and every other refusal to 400.
    var missing = try fx.get(io, gpa, "/api/adr?action=open&path=docs/adrs/9999-nope.md");
    defer missing.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 404), missing.status);
    try std.testing.expect(missing.has("\"ok\":false"));

    var incomplete = try fx.post(io, gpa, "/api/adr", "{\"action\":\"create\",\"title\":\"No context\"}");
    defer incomplete.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 400), incomplete.status);

    var created = try fx.post(io, gpa, "/api/rfc",
        \\{"action":"create","title":"Stale update","overview":"why now"}
    );
    defer created.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), created.status);
    try std.testing.expect(created.has("docs/rfcs/0001-stale-update.md"));

    const edit =
        \\{"action":"update","path":"docs/rfcs/0001-stale-update.md","old":"why now","new":"the reason, stated"}
    ;
    var first = try fx.post(io, gpa, "/api/rfc", edit);
    defer first.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), first.status);

    // Replaying the same edit is the caller working from text the record no
    // longer has. It must come back as a refusal that says to re-open — not
    // a silent second overwrite, and not a 500.
    var replay = try fx.post(io, gpa, "/api/rfc", edit);
    defer replay.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 400), replay.status);
    try std.testing.expect(replay.has("\"ok\":false"));
    try std.testing.expect(replay.has("open"));

    var opened = try fx.get(io, gpa, "/api/rfc?action=open&path=docs/rfcs/0001-stale-update.md");
    defer opened.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 200), opened.status);
    try std.testing.expect(opened.has("the reason, stated"));
}
