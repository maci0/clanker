//! In-process live bus for `clanker serve`.
//!
//! HTTP `/api/*` stays the command surface. The web UI watches this bus over
//! `GET /api/events` (SSE) instead of polling. Publishers are native: chat
//! send/receive, run start/end, mesh talk. A slow subscriber drops the oldest
//! queued event rather than blocking a sender.

const std = @import("std");
const builtin = @import("builtin");
const raw_http = @import("../util/raw_http.zig");

pub const Topic = enum { chat, mesh, arena, run, metrics, plugin };

pub const max_subs = 32;
pub const queue_cap = 64;
pub const event_cap = 8 * 1024;

const Slot = struct {
    used: bool = false,
    mask: u8 = 0,
    q: [queue_cap]Event = undefined,
    head: u16 = 0,
    tail: u16 = 0,
    dropped: u32 = 0,
};

const Event = struct {
    topic: Topic = .chat,
    len: u16 = 0,
    bytes: [event_cap]u8 = undefined,
};

const Spin = struct {
    raw: std.atomic.Mutex = .unlocked,
    fn lock(self: *Spin) void {
        while (!self.raw.tryLock()) {
            std.Thread.yield() catch {};
        }
    }
    fn unlock(self: *Spin) void {
        self.raw.unlock();
    }
};

var mutex: Spin = .{};
var slots: [max_subs]Slot = @splat(.{});

pub fn topicBit(t: Topic) u8 {
    return @as(u8, 1) << @intFromEnum(t);
}

pub fn allTopics() u8 {
    return topicBit(.chat) | topicBit(.mesh) | topicBit(.arena) | topicBit(.run) | topicBit(.metrics) | topicBit(.plugin);
}

pub fn topicsFromTarget(target: []const u8) []const u8 {
    const qmark = std.mem.findScalar(u8, target, '?') orelse return "";
    var it = std.mem.splitScalar(u8, target[qmark + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "topics=")) return pair["topics=".len..];
    }
    return "";
}

pub fn parseTopics(s: []const u8) u8 {
    if (s.len == 0) return allTopics();
    var mask: u8 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, p, "chat")) mask |= topicBit(.chat);
        if (std.mem.eql(u8, p, "mesh")) mask |= topicBit(.mesh);
        if (std.mem.eql(u8, p, "arena")) mask |= topicBit(.arena);
        if (std.mem.eql(u8, p, "run")) mask |= topicBit(.run);
        if (std.mem.eql(u8, p, "metrics")) mask |= topicBit(.metrics);
        if (std.mem.eql(u8, p, "plugin")) mask |= topicBit(.plugin);
    }
    return if (mask == 0) allTopics() else mask;
}

pub fn subscribe(mask: u8) ?usize {
    mutex.lock();
    defer mutex.unlock();
    for (&slots, 0..) |*slot, i| {
        if (slot.used) continue;
        slot.* = .{ .used = true, .mask = if (mask == 0) allTopics() else mask };
        return i;
    }
    return null;
}

pub fn unsubscribe(id: usize) void {
    if (id >= max_subs) return;
    mutex.lock();
    defer mutex.unlock();
    slots[id] = .{};
}

fn qLen(slot: *const Slot) u16 {
    return slot.tail -% slot.head;
}

pub fn publish(topic: Topic, json: []const u8) void {
    if (json.len == 0 or json.len > event_cap) return;
    const bit = topicBit(topic);
    mutex.lock();
    defer mutex.unlock();
    for (&slots) |*slot| {
        if (!slot.used) continue;
        if (slot.mask & bit == 0) continue;
        if (qLen(slot) >= queue_cap) {
            slot.head +%= 1;
            slot.dropped += 1;
        }
        const idx = slot.tail % queue_cap;
        slot.q[idx].topic = topic;
        slot.q[idx].len = @intCast(json.len);
        @memcpy(slot.q[idx].bytes[0..json.len], json);
        slot.tail +%= 1;
    }
}

pub const Taken = struct {
    topic: Topic,
    json: []const u8,
};

pub fn take(id: usize, buf: *[event_cap]u8) ?Taken {
    if (id >= max_subs) return null;
    mutex.lock();
    defer mutex.unlock();
    const slot = &slots[id];
    if (!slot.used or qLen(slot) == 0) return null;
    const ev = slot.q[slot.head % queue_cap];
    slot.head +%= 1;
    @memcpy(buf[0..ev.len], ev.bytes[0..ev.len]);
    return .{ .topic = ev.topic, .json = buf[0..ev.len] };
}

/// `event: live\ndata: <json>\n\n`
pub fn writeSse(out: []u8, json: []const u8) ?[]const u8 {
    const prefix = "event: live\ndata: ";
    const suffix = "\n\n";
    if (out.len < prefix.len + json.len + suffix.len) return null;
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len .. prefix.len + json.len], json);
    @memcpy(out[prefix.len + json.len .. prefix.len + json.len + suffix.len], suffix);
    return out[0 .. prefix.len + json.len + suffix.len];
}

pub fn noteChat(room: []const u8, id: []const u8, from: []const u8, text: []const u8, ts: i64) void {
    var buf: [event_cap]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.write(.{ .t = "chat", .room = room, .id = id, .from = from, .text = text, .ts = ts }) catch return;
    publish(.chat, buf[0..w.end]);
    w.end = 0;
    // A Stringify tracks completion internally (next_punctuation), so the
    // instance from the first write() is "done" and asserts on reuse — a
    // fresh Stringify is required per document, not just a rewound writer.
    var s2 = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s2.write(.{ .t = "talk", .from = from, .room = room, .ts = ts }) catch return;
    publish(.mesh, buf[0..w.end]);
}

pub fn noteRun(working: bool) void {
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"t\":\"run\",\"working\":{}}}", .{working}) catch return;
    publish(.run, json);
}

/// Membership and pending JOINs. Fleet and the Mesh plugin reload on `t:mesh`.
pub fn noteMesh(kind: []const u8, id: []const u8) void {
    var buf: [event_cap]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.write(.{ .t = "mesh", .kind = kind, .id = id }) catch return;
    publish(.mesh, buf[0..w.end]);
}

/// Snapshot already includes `"t":"metrics"`. Throttle lives at the caller
/// so a page load of static assets does not fill the bus.
pub fn noteMetrics(json: []const u8) void {
    publish(.metrics, json);
}

/// Wrap a guest or UI-plugin payload as `{"t":"plugin","from":...,"data":...}`.
/// `from` is JSON-stringified (so a quote in a tool name cannot break the
/// frame); `data_json` is already a JSON value and is spliced in raw.
pub fn pluginEvent(buf: []u8, from: []const u8, data_json: []const u8) ?[]const u8 {
    if (from.len == 0 or data_json.len == 0) return null;
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("{\"t\":\"plugin\",\"from\":") catch return null;
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.write(from) catch return null;
    w.writeAll(",\"data\":") catch return null;
    w.writeAll(data_json) catch return null;
    w.writeByte('}') catch return null;
    return buf[0..w.end];
}

/// Guests (`ck_publish`) and UI plugins (`POST /api/live`) land here. They
/// cannot pick `chat`/`run`/`metrics`: the host stamps `t` and `from`.
pub fn notePlugin(from: []const u8, data_json: []const u8) void {
    var buf: [event_cap]u8 = undefined;
    const json = pluginEvent(&buf, from, data_json) orelse return;
    publish(.plugin, json);
}

/// POLLRDHUP, the event a plain client-side close raises while our own half of
/// the socket is still open. It has to be asked for, unlike POLLHUP/POLLERR/
/// POLLNVAL, and POLLHUP does not stand in for it: POLLHUP wants both halves
/// shut, which never happens here because the server half stays open. Zig
/// carries the constant on `EPOLL` but not on `POLL` (0x2000 on every Linux
/// architecture clanker targets), so it is spelled out. Elsewhere this is 0 and
/// the loop falls back to noticing the hangup on its next write.
const poll_hangup: i16 = if (@hasDecl(std.posix.POLL, "RDHUP"))
    std.posix.POLL.RDHUP
else if (builtin.os.tag == .linux)
    0x2000
else
    0;
const poll_dead: i16 = poll_hangup | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;

/// The subscriber's 50ms idle tick, waited out on the socket instead of on the
/// clock, so a client that has gone away is noticed now rather than at the next
/// write. Nothing writes to an idle bus, so without this a hung-up subscriber
/// held one of `max_subs` slots and one connection thread until the 15s
/// keepalive ping -- and the web UI opens two streams per page load (a probe
/// fetch it cancels, then the EventSource), so reloads stacked up dead slots.
/// Returns true when the peer is gone. Residual posix: raw-fd SSE push bus.
fn idleTickSawHangup(fd: std.posix.fd_t) bool {
    var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = poll_hangup, .revents = 0 }};
    // poll retries EINTR itself, so what is left is NetworkDown /
    // SystemResources / Unexpected. None of those prove the peer is gone;
    // pace the tick on the clock instead and look again next time round.
    const ready = std.posix.poll(&pfd, 50) catch {
        const ts: std.posix.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
        return false;
    };
    return ready > 0 and (pfd[0].revents & poll_dead) != 0;
}

/// Long-lived SSE write loop. Caller must have already decided this
/// connection is not keep-alive. Residual posix: raw-fd SSE push bus, same
/// hand-rolled HTTP family as cli.zig's server.
///
/// Returns the status line it wrote, because it writes the response itself
/// rather than going through cli.zig's `respond`. The caller must store it in
/// `request_status`: a subscription that ran to a client hangup is an ordinary
/// 200, and leaving the status at 0 logged every one of them at ERROR and
/// counted it in `/api/metrics`' `http.errors_total`.
pub fn serveSse(fd: std.posix.fd_t, topics: []const u8) u16 {
    const id = subscribe(parseTopics(topics)) orelse {
        const body = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 52\r\n\r\n{\"ok\":false,\"error\":\"too many live subscribers\"}";
        raw_http.writeAll(fd, body) catch {};
        return 503;
    };
    defer unsubscribe(id);
    raw_http.writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\nretry: 2000\n\n") catch return 200;
    var evbuf: [event_cap]u8 = undefined;
    var ssebuf: [event_cap + 32]u8 = undefined;
    var idle: u32 = 0;
    while (true) {
        if (take(id, &evbuf)) |ev| {
            const framed = writeSse(&ssebuf, ev.json) orelse continue;
            raw_http.writeAll(fd, framed) catch return 200;
            idle = 0;
            continue;
        }
        if (idleTickSawHangup(fd)) return 200;
        idle += 1;
        if (idle >= 300) {
            raw_http.writeAll(fd, ": ping\n\n") catch return 200;
            idle = 0;
        }
    }
}

test "subscribe publish take, overflow drops oldest" {
    const a = subscribe(topicBit(.chat)) orelse return error.NoSlot;
    defer unsubscribe(a);
    publish(.mesh, "{\"t\":\"mesh\"}");
    var buf: [event_cap]u8 = undefined;
    try std.testing.expect(take(a, &buf) == null);
    publish(.chat, "{\"t\":\"chat\",\"n\":1}");
    const first = take(a, &buf) orelse return error.Missing;
    try std.testing.expectEqualStrings("{\"t\":\"chat\",\"n\":1}", first.json);
    var i: usize = 0;
    while (i < queue_cap + 3) : (i += 1) {
        var tmp: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&tmp, "{{\"n\":{d}}}", .{i}) catch unreachable;
        publish(.chat, line);
    }
    const got = take(a, &buf) orelse return error.MissingAfterDrop;
    try std.testing.expect(std.mem.find(u8, got.json, "\"n\":") != null);
}

test "parseTopics empty is all, unknown names ignored" {
    try std.testing.expectEqual(allTopics(), parseTopics(""));
    try std.testing.expectEqual(topicBit(.chat) | topicBit(.mesh), parseTopics("chat,mesh"));
    try std.testing.expectEqual(topicBit(.metrics), parseTopics("metrics"));
    try std.testing.expectEqual(topicBit(.plugin), parseTopics("plugin"));
    try std.testing.expectEqual(allTopics(), parseTopics("nope"));
}

test "pluginEvent wraps data and escapes from" {
    var buf: [event_cap]u8 = undefined;
    const got = pluginEvent(&buf, "music", "{\"n\":1}") orelse return error.Short;
    try std.testing.expectEqualStrings("{\"t\":\"plugin\",\"from\":\"music\",\"data\":{\"n\":1}}", got);
    const quoted = pluginEvent(&buf, "a\"b", "true") orelse return error.Short;
    try std.testing.expectEqualStrings("{\"t\":\"plugin\",\"from\":\"a\\\"b\",\"data\":true}", quoted);
    try std.testing.expect(pluginEvent(&buf, "", "{}") == null);
}

test "notePlugin publishes on the plugin topic" {
    const a = subscribe(topicBit(.plugin)) orelse return error.NoSlot;
    defer unsubscribe(a);
    notePlugin("health", "{\"ok\":true}");
    var buf: [event_cap]u8 = undefined;
    const ev = take(a, &buf) orelse return error.Missing;
    try std.testing.expectEqual(Topic.plugin, ev.topic);
    try std.testing.expect(std.mem.find(u8, ev.json, "\"t\":\"plugin\"") != null);
    try std.testing.expect(std.mem.find(u8, ev.json, "\"from\":\"health\"") != null);
}

test "writeSse frames one event" {
    var buf: [64]u8 = undefined;
    const got = writeSse(&buf, "{\"t\":\"ping\"}") orelse return error.Short;
    try std.testing.expectEqualStrings("event: live\ndata: {\"t\":\"ping\"}\n\n", got);
}

test "noteMesh publishes on the mesh topic" {
    const a = subscribe(topicBit(.mesh)) orelse return error.NoSlot;
    defer unsubscribe(a);
    noteMesh("pending", "guest");
    var buf: [event_cap]u8 = undefined;
    const ev = take(a, &buf) orelse return error.Missing;
    try std.testing.expectEqual(Topic.mesh, ev.topic);
    try std.testing.expect(std.mem.find(u8, ev.json, "\"t\":\"mesh\"") != null);
    try std.testing.expect(std.mem.find(u8, ev.json, "\"kind\":\"pending\"") != null);
    try std.testing.expect(std.mem.find(u8, ev.json, "\"id\":\"guest\"") != null);
}

test "noteMetrics publishes on the metrics topic" {
    const a = subscribe(topicBit(.metrics)) orelse return error.NoSlot;
    defer unsubscribe(a);
    noteMetrics("{\"t\":\"metrics\",\"http\":{}}");
    var buf: [event_cap]u8 = undefined;
    const ev = take(a, &buf) orelse return error.Missing;
    try std.testing.expectEqual(Topic.metrics, ev.topic);
    try std.testing.expect(std.mem.find(u8, ev.json, "\"t\":\"metrics\"") != null);
}

test "noteChat publishes both a chat and a mesh event without reusing a completed Stringify" {
    const a = subscribe(topicBit(.chat) | topicBit(.mesh)) orelse return error.NoSlot;
    defer unsubscribe(a);
    noteChat("general", "m1", "clanker-a", "hi", 123);
    var buf: [event_cap]u8 = undefined;
    const chat_ev = take(a, &buf) orelse return error.MissingChat;
    try std.testing.expectEqual(Topic.chat, chat_ev.topic);
    try std.testing.expect(std.mem.find(u8, chat_ev.json, "\"t\":\"chat\"") != null);
    var buf2: [event_cap]u8 = undefined;
    const mesh_ev = take(a, &buf2) orelse return error.MissingMesh;
    try std.testing.expectEqual(Topic.mesh, mesh_ev.topic);
    try std.testing.expect(std.mem.find(u8, mesh_ev.json, "\"t\":\"talk\"") != null);
}
