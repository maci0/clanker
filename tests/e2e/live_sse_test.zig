//! Black-box `GET /api/events`: a subscription that opens, streams, and is
//! closed by the client is an ordinary 200, not a server error. The handler
//! writes its own response bytes rather than going through `respond`, so the
//! only place that can say so is `/api/metrics`.

const std = @import("std");
const harness = @import("harness.zig");
const raw_http = @import("raw_http");

fn liveUrl(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/health/live", .{port});
}

fn metricsUrl(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/api/metrics", .{port});
}

/// `{"errors_total":N}` out of the `/api/metrics` `http` object. The `llm`,
/// `tools` and `schedule` objects carry the same key, so anchor on the first
/// one, which is the HTTP block.
fn errorsTotal(body: []const u8) !u64 {
    const key = "\"errors_total\":";
    const at = std.mem.find(u8, body, key) orelse return error.NoErrorsTotal;
    var rest = body[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return error.NoErrorsTotal;
    return std.fmt.parseInt(u64, rest[0..end], 10);
}

/// `{"in_flight":N}` out of the same `http` object -- the only key of that
/// name in the snapshot.
fn inFlight(body: []const u8) !u64 {
    const key = "\"in_flight\":";
    const at = std.mem.find(u8, body, key) orelse return error.NoInFlight;
    const rest = body[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return error.NoInFlight;
    return std.fmt.parseInt(u64, rest[0..end], 10);
}

/// One SSE subscription taken far enough to see the response line, then hung
/// up on. std.http.Client is no use here: the stream never ends.
fn openAndCloseSse(io: std.Io, port: u16) !void {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const conn = try addr.connect(io, .{ .mode = .stream });
    defer conn.close(io);
    var req_buf: [160]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAccept: text/event-stream\r\n\r\n", .{port});
    try raw_http.writeAll(conn.socket.handle, req);
    const tv: std.posix.timeval = .{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(conn.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    var buf: [256]u8 = undefined;
    const n = try std.posix.read(conn.socket.handle, &buf);
    if (std.mem.find(u8, buf[0..n], "200 OK") == null) return error.NotOk;
}

test "a closed /api/events subscription is not counted as an http error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const webui = try harness.pickPort(io);
    const mesh_p = try harness.pickPort(io);
    try harness.writeMeshConfig(io, tmp.dir, gpa, .{
        .id = "sse",
        .webui_port = webui,
        .mesh_port = mesh_p,
        .mesh = false,
    });
    try harness.linkZigOut(io, tmp.dir);

    var srv = try harness.spawnServe(io, tmp.dir, webui);
    defer srv.stop(io);
    var url_buf: [80]u8 = undefined;
    try harness.waitHttp(io, gpa, try liveUrl(&url_buf, webui), 8000);

    var metrics_buf: [80]u8 = undefined;
    const metrics = try metricsUrl(&metrics_buf, webui);
    const before_body = try harness.httpGet(io, gpa, metrics);
    defer gpa.free(before_body);
    const before = try errorsTotal(before_body);

    try openAndCloseSse(io, webui);
    // A subscriber loop that has nothing to send writes nothing, so it only
    // learns about the hangup on its next write -- otherwise the 15s keepalive
    // ping. Publishing gives it something to write, and the second write is
    // the one that fails.
    var pub_buf: [80]u8 = undefined;
    const live_url = try std.fmt.bufPrint(&pub_buf, "http://127.0.0.1:{d}/api/live", .{webui});
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const ack = try harness.httpPost(io, gpa, live_url, "{\"from\":\"e2e\",\"data\":{\"n\":1}}");
        gpa.free(ack);
        std.Io.sleep(io, .{ .nanoseconds = 150 * std.time.ns_per_ms }, .awake) catch {};
    }

    const after_body = try harness.httpGet(io, gpa, metrics);
    defer gpa.free(after_body);
    const after = try errorsTotal(after_body);
    try std.testing.expectEqual(before, after);
}

test "a hung-up /api/events subscriber releases its slot without waiting for a write" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const webui = try harness.pickPort(io);
    const mesh_p = try harness.pickPort(io);
    try harness.writeMeshConfig(io, tmp.dir, gpa, .{
        .id = "sse-hangup",
        .webui_port = webui,
        .mesh_port = mesh_p,
        .mesh = false,
    });
    try harness.linkZigOut(io, tmp.dir);

    var srv = try harness.spawnServe(io, tmp.dir, webui);
    defer srv.stop(io);
    var url_buf: [80]u8 = undefined;
    try harness.waitHttp(io, gpa, try liveUrl(&url_buf, webui), 8000);

    var metrics_buf: [80]u8 = undefined;
    const metrics = try metricsUrl(&metrics_buf, webui);
    const before_body = try harness.httpGet(io, gpa, metrics);
    defer gpa.free(before_body);
    const before = try inFlight(before_body);

    try openAndCloseSse(io, webui);
    // No publisher and no keepalive ping is due, so nothing will write to the
    // dead socket. The subscriber has to notice the hangup on its own; each of
    // `max_subs` slots it fails to release is one the next page cannot have.
    std.Io.sleep(io, .{ .nanoseconds = 600 * std.time.ns_per_ms }, .awake) catch {};

    const after_body = try harness.httpGet(io, gpa, metrics);
    defer gpa.free(after_body);
    try std.testing.expectEqual(before, try inFlight(after_body));
}
