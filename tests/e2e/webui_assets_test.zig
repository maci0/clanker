//! The web UI's static assets all render through one `webui` guest, and that
//! guest is now compiled once for the process instead of once per asset path.
//! A shared instance is only safe if every path still gets its own body, so
//! this fetches several of them from one live server, in one connection burst
//! and again afterwards, and checks each answered with its own content.

const std = @import("std");
const harness = @import("harness.zig");
const raw_http = @import("raw_http");

fn url(buf: []u8, port: u16, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path });
}

test "every webui asset path renders its own body from the shared guest" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const webui = try harness.pickPort(io);
    const mesh_p = try harness.pickPort(io);
    try harness.writeMeshConfig(io, tmp.dir, gpa, .{
        .id = "assets",
        .webui_port = webui,
        .mesh_port = mesh_p,
        .mesh = false,
    });
    try harness.linkZigOut(io, tmp.dir);

    var srv = try harness.spawnServe(io, tmp.dir, webui);
    defer srv.stop(io);

    var buf: [128]u8 = undefined;
    try harness.waitHttp(io, gpa, try url(&buf, webui, "/webui/app.css"), 8000);

    // One marker per path that only that file can produce, so a guest handing
    // back a previous call's output would fail rather than look plausible.
    const cases = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "/webui/app.css", .needle = "{" },
        .{ .path = "/webui/app.js", .needle = "import" },
        .{ .path = "/webui/core/utils.js", .needle = "export" },
        .{ .path = "/webui/lib/markdown.js", .needle = "export" },
        .{ .path = "/", .needle = "<!doctype html" },
    };

    var bodies: [cases.len][]u8 = undefined;
    var fetched: usize = 0;
    defer for (bodies[0..fetched]) |b| gpa.free(b);

    // Twice: the first pass builds the guest and fills each RenderCache, the
    // second is served from those caches. Both must agree.
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        for (cases, 0..) |c, i| {
            var path_buf: [128]u8 = undefined;
            const body = try harness.httpGet(io, gpa, try url(&path_buf, webui, c.path));
            errdefer gpa.free(body);
            std.testing.expect(body.len > 0) catch |err| {
                gpa.free(body);
                return err;
            };
            if (pass == 0) {
                bodies[i] = body;
                fetched += 1;
            } else {
                defer gpa.free(body);
                try std.testing.expectEqualStrings(bodies[i], body);
            }
        }
    }

    // Distinct paths, distinct bodies: a shared instance leaking one render
    // into the next would collapse these onto each other.
    for (cases, 0..) |c, i| {
        std.testing.expect(std.mem.find(u8, bodies[i], c.needle) != null) catch |err| {
            std.debug.print("no '{s}' in the body of {s}\n", .{ c.needle, c.path });
            return err;
        };
        for (cases[i + 1 ..], i + 1..) |_, j| {
            try std.testing.expect(!std.mem.eql(u8, bodies[i], bodies[j]));
        }
    }
}

test "a HEAD request answers headers and no body" {
    // RFC 9110 §9.3.2: a HEAD response carries the headers (including the
    // Content-Length of what GET would return) but no content. The asset,
    // static and JSON responders used to write the full gzipped body anyway —
    // a HEAD of /webui/vendor/mermaid.min.js pushed ~950 KB down the wire and
    // discarded it, and on a kept-alive connection those bytes were read back
    // as the next response. The document responder already skipped the body;
    // this pins that every other one does too.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const webui = try harness.pickPort(io);
    const mesh_p = try harness.pickPort(io);
    try harness.writeMeshConfig(io, tmp.dir, gpa, .{
        .id = "head",
        .webui_port = webui,
        .mesh_port = mesh_p,
        .mesh = false,
    });
    try harness.linkZigOut(io, tmp.dir);

    var srv = try harness.spawnServe(io, tmp.dir, webui);
    defer srv.stop(io);

    var buf: [128]u8 = undefined;
    try harness.waitHttp(io, gpa, try url(&buf, webui, "/webui/app.js"), 8000);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", webui);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const fd = stream.socket.handle;

    var req_buf: [160]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "HEAD /webui/app.js HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n", .{webui});
    try raw_http.writeAll(fd, req);

    // Read the header block: poll before each read so a silent server cannot
    // hang the test, and give the whole exchange a bounded budget.
    var resp: [4096]u8 = undefined;
    var got: usize = 0;
    const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const budget = 8000 * std.time.ns_per_ms;
    while (std.mem.find(u8, resp[0..got], "\r\n\r\n") == null) {
        if (std.Io.Timestamp.now(io, .awake).nanoseconds - start > budget) return error.HeadTimeout;
        var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, 2000) catch return error.PollFailed;
        if (ready == 0) return error.HeadTimeout;
        if (got == resp.len) return error.HeaderOverflow;
        const n = std.posix.read(fd, resp[got..]) catch return error.ReadFailed;
        if (n == 0) return error.ServedNoHeaders;
        got += n;
    }

    const header_block = resp[0..got];
    try std.testing.expect(std.mem.startsWith(u8, header_block, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.find(u8, header_block, "Content-Length:") != null);
    try std.testing.expect(std.mem.find(u8, header_block, "Content-Encoding: gzip") != null);

    // Any bytes after the header block are the body this request must not have.
    // The server was asked Connection: close, so a compliant answer reaches
    // EOF here; the poll catches the fixed server's nothing and the unfixed
    // server's ~66 KB of gzipped app.js.
    var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pfd, 2000) catch return error.PollFailed;
    if (ready == 0) return error.HeadBodySuspense; // server neither closed nor sent a body
    var tail: [256]u8 = undefined;
    const n = std.posix.read(fd, &tail) catch return error.ReadFailed;
    try std.testing.expectEqual(@as(usize, 0), n);
}
