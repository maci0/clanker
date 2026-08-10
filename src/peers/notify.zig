//! Peer notification fan-out: POST an event to every configured peer.

const std = @import("std");
const config = @import("../config.zig");
const log = @import("../util/log.zig");

pub fn notifyAll(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, kind: []const u8, payload: []const u8) void {
    if (!cfg.notify.on) return;
    if (cfg.peers.len == 0) return;

    for (cfg.peers) |peer| {
        const url = std.fmt.allocPrint(gpa, "{s}/api/notify", .{std.mem.trimEnd(u8, peer.url, "/")}) catch |err| {
            log.log(.error_, "notify to '{s}' failed: {s}", .{ peer.name, @errorName(err) });
            continue;
        };
        defer gpa.free(url);

        const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));

        var body_buf: [64 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&body_buf);
        var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
        s.beginObject() catch continue;
        s.objectField("from") catch continue;
        s.write(cfg.instance.name) catch continue;
        s.objectField("kind") catch continue;
        s.write(kind) catch continue;
        s.objectField("topic") catch continue;
        s.write(cfg.notify.topic) catch continue;
        s.objectField("payload") catch continue;
        s.write(payload) catch continue;
        s.objectField("ts") catch continue;
        s.print("{d}", .{ts}) catch continue;
        s.endObject() catch continue;
        const body = body_buf[0..w.end];

        var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer http_client.deinit();
        var response_buf: [64 * 1024]u8 = undefined;
        var rw: std.Io.Writer = .fixed(&response_buf);
        const result = http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" }, .user_agent = .{ .override = "clanker/0.1.0" } },
            .response_writer = &rw,
        }) catch |err| {
            log.log(.error_, "notify to '{s}' failed: {s}", .{ peer.name, @errorName(err) });
            continue;
        };
        const status = result.status;
        const response = response_buf[0..rw.end];
        log.log(.info, "notify {s}: HTTP {d} ({s})", .{ peer.name, @intFromEnum(status), response });
    }
}
