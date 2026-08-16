//! Black-box mesh: real `clanker serve` processes, real TCP join/leave,
//! and the loopback `clanker mesh` CLI. No NIC beyond 127.0.0.1.

const std = @import("std");
const harness = @import("harness.zig");

fn liveUrl(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/health/live", .{port});
}

fn statusUrl(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/api/mesh/status", .{port});
}

fn pendingUrl(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/api/mesh/pending", .{port});
}

fn mapUrl(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/api/mesh/map", .{port});
}

fn meshAddr(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "127.0.0.1:{d}", .{port});
}

fn portFlag(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{port});
}

test "clanker mesh status fails when serve is down" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const webui = try harness.pickPort(io);
    const mesh_p = try harness.pickPort(io);
    try harness.writeMeshConfig(io, tmp.dir, gpa, .{
        .id = "lonely",
        .webui_port = webui,
        .mesh_port = mesh_p,
    });
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "mesh", "status" });
    defer result.deinit(gpa);
    try std.testing.expect(!result.ok());
    const hay = if (result.stderr.len > 0) result.stderr else result.stdout;
    try std.testing.expect(std.mem.find(u8, hay, "serve") != null);
}

test "clanker mesh status names modules.mesh when the module is off" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const webui = try harness.pickPort(io);
    const mesh_p = try harness.pickPort(io);
    try harness.writeMeshConfig(io, tmp.dir, gpa, .{
        .id = "off",
        .webui_port = webui,
        .mesh_port = mesh_p,
        .mesh = false,
    });
    try harness.linkZigOut(io, tmp.dir);

    var srv = try harness.spawnServe(io, tmp.dir, webui);
    defer srv.stop(io);
    var url_buf: [80]u8 = undefined;
    try harness.waitHttp(io, gpa, try liveUrl(&url_buf, webui), 8000);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "mesh", "status" });
    defer result.deinit(gpa);
    try std.testing.expect(!result.ok());
    const hay = if (result.stderr.len > 0) result.stderr else result.stdout;
    try std.testing.expect(std.mem.find(u8, hay, "modules.mesh") != null);
}

test "two serves join over loopback and leave" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    const web_a = try harness.pickPort(io);
    const web_b = try harness.pickPort(io);
    const mesh_a = try harness.pickPort(io);
    const mesh_b = try harness.pickPort(io);

    try harness.writeMeshConfig(io, tmp_a.dir, gpa, .{
        .id = "alpha",
        .name = "alpha",
        .webui_port = web_a,
        .mesh_port = mesh_a,
        .admission = "open",
    });
    try harness.writeMeshConfig(io, tmp_b.dir, gpa, .{
        .id = "beta",
        .name = "beta",
        .webui_port = web_b,
        .mesh_port = mesh_b,
        .admission = "open",
    });
    try harness.linkZigOut(io, tmp_a.dir);
    try harness.linkZigOut(io, tmp_b.dir);

    var srv_a = try harness.spawnServe(io, tmp_a.dir, web_a);
    defer srv_a.stop(io);
    var srv_b = try harness.spawnServe(io, tmp_b.dir, web_b);
    defer srv_b.stop(io);

    var url_buf: [96]u8 = undefined;
    try harness.waitHttp(io, gpa, try liveUrl(&url_buf, web_a), 8000);
    try harness.waitHttp(io, gpa, try liveUrl(&url_buf, web_b), 8000);
    try harness.waitHttp(io, gpa, try statusUrl(&url_buf, web_a), 4000);
    try harness.waitHttp(io, gpa, try statusUrl(&url_buf, web_b), 4000);
    try harness.waitTcp(io, mesh_a, 4000);
    try harness.waitTcp(io, mesh_b, 4000);

    var addr_buf: [32]u8 = undefined;
    var port_buf: [8]u8 = undefined;
    const addr = try meshAddr(&addr_buf, mesh_a);
    const web_b_s = try portFlag(&port_buf, web_b);
    var joined = try harness.run(gpa, io, tmp_b.dir, &.{ "mesh", "join", addr, "--webui-port", web_b_s });
    defer joined.deinit(gpa);
    if (!joined.ok()) std.debug.print("mesh join failed\nstdout: {s}\nstderr: {s}\n", .{ joined.stdout, joined.stderr });
    try std.testing.expect(joined.ok());

    const status_body = try harness.waitHttpHas(io, gpa, try statusUrl(&url_buf, web_a), "beta", 4000);
    defer gpa.free(status_body);

    const map_body = try harness.httpGet(io, gpa, try mapUrl(&url_buf, web_a));
    defer gpa.free(map_body);
    try std.testing.expect(std.mem.find(u8, map_body, "alpha") != null);

    var left = try harness.run(gpa, io, tmp_b.dir, &.{ "mesh", "leave", "--webui-port", web_b_s });
    defer left.deinit(gpa);
    if (!left.ok()) std.debug.print("mesh leave failed\nstdout: {s}\nstderr: {s}\n", .{ left.stdout, left.stderr });
    try std.testing.expect(left.ok());

    const after = try harness.httpGet(io, gpa, try statusUrl(&url_buf, web_b));
    defer gpa.free(after);
    try std.testing.expect(std.mem.find(u8, after, "\"members\":[]") != null);
}

test "prompt admission queues a join until admit" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    const web_a = try harness.pickPort(io);
    const web_b = try harness.pickPort(io);
    const mesh_a = try harness.pickPort(io);
    const mesh_b = try harness.pickPort(io);

    try harness.writeMeshConfig(io, tmp_a.dir, gpa, .{
        .id = "gate",
        .name = "gate",
        .webui_port = web_a,
        .mesh_port = mesh_a,
        .admission = "prompt",
    });
    try harness.writeMeshConfig(io, tmp_b.dir, gpa, .{
        .id = "guest",
        .name = "guest",
        .webui_port = web_b,
        .mesh_port = mesh_b,
        .admission = "open",
    });
    try harness.linkZigOut(io, tmp_a.dir);
    try harness.linkZigOut(io, tmp_b.dir);

    var srv_a = try harness.spawnServe(io, tmp_a.dir, web_a);
    defer srv_a.stop(io);
    var srv_b = try harness.spawnServe(io, tmp_b.dir, web_b);
    defer srv_b.stop(io);

    var url_buf: [96]u8 = undefined;
    try harness.waitHttp(io, gpa, try liveUrl(&url_buf, web_a), 8000);
    try harness.waitHttp(io, gpa, try liveUrl(&url_buf, web_b), 8000);
    try harness.waitHttp(io, gpa, try statusUrl(&url_buf, web_a), 4000);
    try harness.waitHttp(io, gpa, try statusUrl(&url_buf, web_b), 4000);
    try harness.waitTcp(io, mesh_a, 4000);
    try harness.waitTcp(io, mesh_b, 4000);

    var addr_buf: [32]u8 = undefined;
    const addr = try meshAddr(&addr_buf, mesh_a);
    const join_payload = try std.fmt.allocPrint(gpa, "{{\"address\":{f}}}", .{std.json.fmt(addr, .{})});
    defer gpa.free(join_payload);
    var join_url_buf: [80]u8 = undefined;
    const join_url = try std.fmt.bufPrint(&join_url_buf, "http://127.0.0.1:{d}/api/mesh/join", .{web_b});

    const JoinJob = struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        url: []const u8,
        payload: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        ok: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            if (harness.httpPost(self.io, self.gpa, self.url, self.payload)) |body| {
                self.gpa.free(body);
                self.ok.store(true, .release);
            } else |_| {}
            self.done.store(true, .release);
        }
    };
    var job = JoinJob{ .io = io, .gpa = gpa, .url = join_url, .payload = join_payload };
    const th = try std.Thread.spawn(.{}, JoinJob.run, .{&job});
    defer th.join();

    const pending_body = try harness.waitHttpHas(io, gpa, try pendingUrl(&url_buf, web_a), "guest", 8000);
    defer gpa.free(pending_body);

    var port_a_buf: [8]u8 = undefined;
    const web_a_s = try portFlag(&port_a_buf, web_a);
    var listed = try harness.run(gpa, io, tmp_a.dir, &.{ "mesh", "pending", "--webui-port", web_a_s });
    defer listed.deinit(gpa);
    if (!listed.ok()) std.debug.print("mesh pending failed\nstdout: {s}\nstderr: {s}\n", .{ listed.stdout, listed.stderr });
    try std.testing.expect(listed.ok());
    try std.testing.expect(std.mem.find(u8, listed.stdout, "guest") != null);

    const admitted = try harness.httpPost(io, gpa, try pendingUrl(&url_buf, web_a), "{\"id\":\"guest\",\"allow\":true}");
    defer gpa.free(admitted);

    const wait_join = std.Io.Timestamp.now(io, .awake).nanoseconds;
    while (!job.done.load(.acquire)) {
        if (std.Io.Timestamp.now(io, .awake).nanoseconds - wait_join > 8 * std.time.ns_per_s) break;
        std.Io.sleep(io, .{ .nanoseconds = 40 * std.time.ns_per_ms }, .awake) catch {};
    }
    try std.testing.expect(job.ok.load(.acquire));

    const status_body = try harness.waitHttpHas(io, gpa, try statusUrl(&url_buf, web_a), "guest", 4000);
    defer gpa.free(status_body);
}

test "prompt admission deny closes the join" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    const web_a = try harness.pickPort(io);
    const web_b = try harness.pickPort(io);
    const mesh_a = try harness.pickPort(io);
    const mesh_b = try harness.pickPort(io);

    try harness.writeMeshConfig(io, tmp_a.dir, gpa, .{
        .id = "gate",
        .name = "gate",
        .webui_port = web_a,
        .mesh_port = mesh_a,
        .admission = "prompt",
    });
    try harness.writeMeshConfig(io, tmp_b.dir, gpa, .{
        .id = "guest",
        .name = "guest",
        .webui_port = web_b,
        .mesh_port = mesh_b,
        .admission = "open",
    });
    try harness.linkZigOut(io, tmp_a.dir);
    try harness.linkZigOut(io, tmp_b.dir);

    var srv_a = try harness.spawnServe(io, tmp_a.dir, web_a);
    defer srv_a.stop(io);
    var srv_b = try harness.spawnServe(io, tmp_b.dir, web_b);
    defer srv_b.stop(io);

    var url_buf: [96]u8 = undefined;
    try harness.waitHttp(io, gpa, try liveUrl(&url_buf, web_a), 8000);
    try harness.waitHttp(io, gpa, try liveUrl(&url_buf, web_b), 8000);
    try harness.waitHttp(io, gpa, try statusUrl(&url_buf, web_a), 4000);
    try harness.waitHttp(io, gpa, try statusUrl(&url_buf, web_b), 4000);
    try harness.waitTcp(io, mesh_a, 4000);
    try harness.waitTcp(io, mesh_b, 4000);

    var addr_buf: [32]u8 = undefined;
    const addr = try meshAddr(&addr_buf, mesh_a);
    const join_payload = try std.fmt.allocPrint(gpa, "{{\"address\":{f}}}", .{std.json.fmt(addr, .{})});
    defer gpa.free(join_payload);
    var join_url_buf: [80]u8 = undefined;
    const join_url = try std.fmt.bufPrint(&join_url_buf, "http://127.0.0.1:{d}/api/mesh/join", .{web_b});

    const JoinJob = struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        url: []const u8,
        payload: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        ok: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            if (harness.httpPost(self.io, self.gpa, self.url, self.payload)) |body| {
                self.gpa.free(body);
                self.ok.store(true, .release);
            } else |_| {}
            self.done.store(true, .release);
        }
    };
    var job = JoinJob{ .io = io, .gpa = gpa, .url = join_url, .payload = join_payload };
    const th = try std.Thread.spawn(.{}, JoinJob.run, .{&job});
    defer th.join();

    const pending_body = try harness.waitHttpHas(io, gpa, try pendingUrl(&url_buf, web_a), "guest", 8000);
    defer gpa.free(pending_body);

    var port_a_buf: [8]u8 = undefined;
    const web_a_s = try portFlag(&port_a_buf, web_a);
    var denied = try harness.run(gpa, io, tmp_a.dir, &.{ "mesh", "deny", "guest", "--webui-port", web_a_s });
    defer denied.deinit(gpa);
    if (!denied.ok()) std.debug.print("mesh deny failed\nstdout: {s}\nstderr: {s}\n", .{ denied.stdout, denied.stderr });
    try std.testing.expect(denied.ok());

    const wait_join = std.Io.Timestamp.now(io, .awake).nanoseconds;
    while (!job.done.load(.acquire)) {
        if (std.Io.Timestamp.now(io, .awake).nanoseconds - wait_join > 8 * std.time.ns_per_s) break;
        std.Io.sleep(io, .{ .nanoseconds = 40 * std.time.ns_per_ms }, .awake) catch {};
    }
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expect(!job.ok.load(.acquire));

    const status_body = try harness.httpGet(io, gpa, try statusUrl(&url_buf, web_a));
    defer gpa.free(status_body);
    try std.testing.expect(std.mem.find(u8, status_body, "guest") == null);
}
