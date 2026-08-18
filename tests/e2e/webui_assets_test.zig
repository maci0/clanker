//! The web UI's static assets all render through one `webui` guest, and that
//! guest is now compiled once for the process instead of once per asset path.
//! A shared instance is only safe if every path still gets its own body, so
//! this fetches several of them from one live server, in one connection burst
//! and again afterwards, and checks each answered with its own content.

const std = @import("std");
const harness = @import("harness.zig");

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
