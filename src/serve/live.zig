//! In-process live bus for `clanker serve`.
//!
//! HTTP `/api/*` stays the command surface. The web UI watches this bus over
//! `GET /api/events` (SSE) instead of polling. Publishers are native: chat
//! send/receive, run start/end, mesh talk. A slow subscriber drops the oldest
//! queued event rather than blocking a sender.

const std = @import("std");

pub const Topic = enum { chat, mesh, arena, run };

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
    return topicBit(.chat) | topicBit(.mesh) | topicBit(.arena) | topicBit(.run);
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
    s.write(.{ .t = "talk", .from = from, .room = room, .ts = ts }) catch return;
    publish(.mesh, buf[0..w.end]);
}

pub fn noteRun(working: bool) void {
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"t\":\"run\",\"working\":{}}}", .{working}) catch return;
    publish(.run, json);
}

/// Long-lived SSE write loop. Caller must have already decided this
/// connection is not keep-alive.
pub fn serveSse(fd: std.posix.fd_t, topics: []const u8) void {
    const id = subscribe(parseTopics(topics)) orelse {
        const body = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 52\r\n\r\n{\"ok\":false,\"error\":\"too many live subscribers\"}";
        writeAllOrErr(fd, body) catch {};
        return;
    };
    defer unsubscribe(id);
    writeAllOrErr(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\nretry: 2000\n\n") catch return;
    var evbuf: [event_cap]u8 = undefined;
    var ssebuf: [event_cap + 32]u8 = undefined;
    var idle: u32 = 0;
    while (true) {
        if (take(id, &evbuf)) |ev| {
            const framed = writeSse(&ssebuf, ev.json) orelse continue;
            writeAllOrErr(fd, framed) catch return;
            idle = 0;
            continue;
        }
        const ts: std.posix.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
        idle += 1;
        if (idle >= 300) {
            writeAllOrErr(fd, ": ping\n\n") catch return;
            idle = 0;
        }
    }
}

pub fn writeAllOrErr(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.Closed;
        off += @intCast(n);
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
    try std.testing.expect(std.mem.indexOf(u8, got.json, "\"n\":") != null);
}

test "parseTopics empty is all, unknown names ignored" {
    try std.testing.expectEqual(allTopics(), parseTopics(""));
    try std.testing.expectEqual(topicBit(.chat) | topicBit(.mesh), parseTopics("chat,mesh"));
    try std.testing.expectEqual(allTopics(), parseTopics("nope"));
}

test "writeSse frames one event" {
    var buf: [64]u8 = undefined;
    const got = writeSse(&buf, "{\"t\":\"ping\"}") orelse return error.Short;
    try std.testing.expectEqualStrings("event: live\ndata: {\"t\":\"ping\"}\n\n", got);
}
