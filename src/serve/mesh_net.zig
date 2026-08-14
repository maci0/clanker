//! Serve-owned mesh sockets (PRD 0011). Codec stays in peers/mesh.zig.
//! `trySendChat` is what chatrooms.fanOut prefers; HTTP is the fallback.

const std = @import("std");
const mesh = @import("../peers/mesh.zig");
const config = @import("../config.zig");
const log = @import("../util/log.zig");

pub const ChatBody = struct {
    room: []const u8,
    from: []const u8,
    text: []const u8,
    id: []const u8,
    ts: i64,
};

pub const OnChat = *const fn (ChatBody) void;

const Member = struct {
    used: bool = false,
    id: [64]u8 = undefined,
    id_len: u8 = 0,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    fd: std.posix.fd_t = -1,
};

const Runtime = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    our_id: []const u8,
    our_name: []const u8,
    listen: []const u8,
    admission: mesh.Admission,
    seeds: []const mesh.PeerSeed,
    max_frame: u32,
    on_chat: ?OnChat,
    mu: std.Thread.Mutex = .{},
    members: [mesh.max_members]Member = @splat(.{}),
    stop: std.atomic.Value(bool) = .init(false),
    server: ?std.Io.net.Server = null,
};

var runtime: ?*Runtime = null;

pub fn active() bool {
    return runtime != null;
}

fn copyField(dst: []u8, src: []const u8) u8 {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

fn mid(m: *const Member) []const u8 {
    return m.id[0..m.id_len];
}
fn mname(m: *const Member) []const u8 {
    return m.name[0..m.name_len];
}

fn findMember(rt: *Runtime, key: []const u8) ?*Member {
    if (key.len == 0) return null;
    for (&rt.members) |*m| {
        if (!m.used) continue;
        if (std.mem.eql(u8, mid(m), key) or std.mem.eql(u8, mname(m), key)) return m;
    }
    return null;
}

fn remember(rt: *Runtime, id: []const u8, name: []const u8, fd: std.posix.fd_t) void {
    if (findMember(rt, id) orelse findMember(rt, name)) |m| {
        if (m.fd >= 0 and m.fd != fd) std.posix.close(m.fd);
        m.fd = fd;
        return;
    }
    for (&rt.members) |*m| {
        if (m.used) continue;
        m.* = .{ .used = true, .fd = fd };
        m.id_len = copyField(&m.id, id);
        m.name_len = copyField(&m.name, name);
        return;
    }
}

fn writeFrame(fd: std.posix.fd_t, gpa: std.mem.Allocator, payload: []const u8) bool {
    const frame = mesh.encodeFrame(gpa, payload) catch return false;
    defer gpa.free(frame);
    var off: usize = 0;
    while (off < frame.len) {
        const n = std.c.write(fd, frame[off..].ptr, frame.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn parseAddr(host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.mem.indexOfScalar(u8, host, ':') != null)
        return std.Io.net.IpAddress.parseIp6(host, port);
    return std.Io.net.IpAddress.parseIp4(host, port);
}

pub fn parseHostPort(s: []const u8) !struct { host: []const u8, port: u16 } {
    if (s.len == 0) return error.BadAddress;
    if (s[0] == '[') {
        const end = std.mem.indexOfScalar(u8, s, ']') orelse return error.BadAddress;
        if (end + 2 > s.len or s[end + 1] != ':') return error.BadAddress;
        return .{ .host = s[1..end], .port = std.fmt.parseInt(u16, s[end + 2 ..], 10) catch return error.BadAddress };
    }
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.BadAddress;
    return .{ .host = s[0..colon], .port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return error.BadAddress };
}

const JoinFields = struct { id: []const u8 = "", name: []const u8 = "" };
const ChatFields = struct { room: []const u8 = "", from: []const u8 = "", text: []const u8 = "", id: []const u8 = "", ts: i64 = 0 };

fn payloadObj(arena: std.mem.Allocator, raw: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidFrame,
    };
    return switch (obj.get("payload") orelse return error.InvalidFrame) {
        .object => |o| o,
        else => return error.InvalidFrame,
    };
}

fn strField(obj: std.json.ObjectMap, k: []const u8) []const u8 {
    const v = obj.get(k) orelse return "";
    return if (v == .string) v.string else "";
}

/// Deliver on a live mesh link. False means the caller should use HTTP.
pub fn trySendChat(gpa: std.mem.Allocator, peer_id: []const u8, peer_name: []const u8, msg: ChatBody) bool {
    const rt = runtime orelse return false;
    rt.mu.lock();
    const m = findMember(rt, peer_id) orelse findMember(rt, peer_name);
    const fd = if (m) |row| row.fd else -1;
    var to_buf: [64]u8 = undefined;
    const to_len: usize = if (m) |row| row.id_len else 0;
    if (m) |row| @memcpy(to_buf[0..to_len], row.id[0..to_len]);
    rt.mu.unlock();
    if (fd < 0 or to_len == 0) return false;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(arena_state.allocator());
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return false;
    s.objectField("version") catch return false;
    s.write(mesh.protocol_version) catch return false;
    s.objectField("kind") catch return false;
    s.write("CHAT") catch return false;
    s.objectField("id") catch return false;
    s.write(msg.id) catch return false;
    s.objectField("from") catch return false;
    s.write(rt.our_id) catch return false;
    s.objectField("to") catch return false;
    s.write(to_buf[0..to_len]) catch return false;
    s.objectField("payload") catch return false;
    s.write(.{ .room = msg.room, .from = msg.from, .text = msg.text, .id = msg.id, .ts = msg.ts }) catch return false;
    s.endObject() catch return false;
    return writeFrame(fd, gpa, out.written());
}

fn handleInbound(rt: *Runtime, raw: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const header = mesh.parseHeader(arena, raw) catch return;
    if (header.kind != .chat) return;
    const p = payloadObj(arena, raw) catch return;
    if (rt.on_chat) |cb| cb(.{
        .room = strField(p, "room"),
        .from = strField(p, "from"),
        .text = strField(p, "text"),
        .id = strField(p, "id"),
        .ts = if (p.get("ts")) |v| (if (v == .integer) v.integer else 0) else 0,
    });
}

fn drainFrames(rt: *Runtime, acc: *std.ArrayList(u8)) void {
    while (true) {
        const dec = mesh.decodeFrame(acc.items, rt.max_frame) catch break;
        const got = dec orelse break;
        handleInbound(rt, got.payload);
        const rest = acc.items[got.consumed..];
        std.mem.copyForwards(u8, acc.items[0..rest.len], rest);
        acc.shrinkRetainingCapacity(rest.len);
    }
}

fn readLoop(rt: *Runtime, stream: std.Io.net.Stream) void {
    defer stream.close(rt.io);
    const fd = stream.socket.handle;
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(rt.gpa);
    var tmp: [4096]u8 = undefined;
    while (!rt.stop.load(.monotonic)) {
        const n = std.posix.read(fd, &tmp) catch break;
        if (n == 0) break;
        acc.appendSlice(rt.gpa, tmp[0..n]) catch break;
        drainFrames(rt, &acc);
    }
    rt.mu.lock();
    defer rt.mu.unlock();
    for (&rt.members) |*m| {
        if (m.used and m.fd == fd) m.fd = -1;
    }
}

const Conn = struct { rt: *Runtime, stream: std.Io.net.Stream };

fn acceptOne(arg: *Conn) void {
    const rt = arg.rt;
    const stream = arg.stream;
    rt.gpa.destroy(arg);
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(rt.gpa);
    var tmp: [4096]u8 = undefined;
    const fd = stream.socket.handle;
    const tv: std.posix.timeval = .{ .sec = 10, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    var joined = false;
    while (!joined and !rt.stop.load(.monotonic)) {
        const n = std.posix.read(fd, &tmp) catch break;
        if (n == 0) break;
        acc.appendSlice(rt.gpa, tmp[0..n]) catch break;
        const dec = mesh.decodeFrame(acc.items, rt.max_frame) catch break;
        const got = dec orelse continue;
        var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const header = mesh.parseHeader(arena, got.payload) catch break;
        if (header.kind != .join) break;
        const p = payloadObj(arena, got.payload) catch break;
        const join_id = blk: {
            const id = strField(p, "id");
            break :blk if (id.len > 0) id else header.from;
        };
        const join_name = strField(p, "name");
        const ok = mesh.admit(rt.admission, rt.our_id, join_id, join_name, rt.seeds) == .accept;
        var ack_out: std.Io.Writer.Allocating = .init(arena);
        var ack_s = std.json.Stringify{ .writer = &ack_out.writer, .options = .{ .emit_null_optional_fields = false } };
        ack_s.beginObject() catch break;
        ack_s.objectField("version") catch break;
        ack_s.write(mesh.protocol_version) catch break;
        ack_s.objectField("kind") catch break;
        ack_s.write("JOIN_ACK") catch break;
        ack_s.objectField("id") catch break;
        ack_s.write(header.id) catch break;
        ack_s.objectField("from") catch break;
        ack_s.write(rt.our_id) catch break;
        ack_s.objectField("payload") catch break;
        ack_s.write(.{ .accepted = ok }) catch break;
        ack_s.endObject() catch break;
        _ = writeFrame(fd, rt.gpa, ack_out.written());
        if (!ok) break;
        rt.mu.lock();
        remember(rt, join_id, join_name, fd);
        rt.mu.unlock();
        joined = true;
        const rest = acc.items[got.consumed..];
        std.mem.copyForwards(u8, acc.items[0..rest.len], rest);
        acc.shrinkRetainingCapacity(rest.len);
    }
    if (!joined) {
        stream.close(rt.io);
        return;
    }
    drainFrames(rt, &acc);
    readLoop(rt, stream);
}

fn acceptLoop(rt: *Runtime) void {
    const server = rt.server orelse return;
    while (!rt.stop.load(.monotonic)) {
        const stream = server.accept(rt.io) catch {
            if (rt.stop.load(.monotonic)) break;
            continue;
        };
        const arg = rt.gpa.create(Conn) catch {
            stream.close(rt.io);
            continue;
        };
        arg.* = .{ .rt = rt, .stream = stream };
        const th = std.Thread.spawn(.{}, acceptOne, .{arg}) catch {
            stream.close(rt.io);
            rt.gpa.destroy(arg);
            continue;
        };
        th.detach();
    }
}

pub fn start(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, on_chat: ?OnChat) !void {
    if (!cfg.modules.mesh) return;
    if (cfg.instance.id.len == 0) return error.MissingInstanceId;
    const listen_s = try std.fmt.allocPrint(gpa, "{s}:{d}", .{ cfg.mesh.listen_host, cfg.mesh.listen_port });
    const seeds = try gpa.alloc(mesh.PeerSeed, cfg.peers.len);
    for (cfg.peers, 0..) |p, i| seeds[i] = .{ .name = p.name, .id = p.id };
    const addr = parseAddr(cfg.mesh.listen_host, cfg.mesh.listen_port) catch
        try std.Io.net.IpAddress.parseIp4("127.0.0.1", cfg.mesh.listen_port);
    const server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    const rt = try gpa.create(Runtime);
    rt.* = .{
        .io = io,
        .gpa = gpa,
        .our_id = cfg.instance.id,
        .our_name = if (cfg.instance.name.len > 0) cfg.instance.name else cfg.instance.id,
        .listen = listen_s,
        .admission = std.meta.stringToEnum(mesh.Admission, cfg.mesh.admission) orelse .allowlist,
        .seeds = seeds,
        .max_frame = cfg.mesh.max_frame_bytes,
        .on_chat = on_chat,
        .server = server,
    };
    runtime = rt;
    const th = try std.Thread.spawn(.{}, acceptLoop, .{rt});
    th.detach();
    log.log(.info, "mesh listening on {s}", .{listen_s});
}

pub fn join(gpa: std.mem.Allocator, address: []const u8) !void {
    const rt = runtime orelse return error.MeshOff;
    const hp = try parseHostPort(address);
    const addr = try parseAddr(hp.host, hp.port);
    const stream = try addr.connect(rt.io, .{ .mode = .stream });
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var join_out: std.Io.Writer.Allocating = .init(arena);
    var join_s = std.json.Stringify{ .writer = &join_out.writer, .options = .{ .emit_null_optional_fields = false } };
    try join_s.beginObject();
    try join_s.objectField("version");
    try join_s.write(mesh.protocol_version);
    try join_s.objectField("kind");
    try join_s.write("JOIN");
    try join_s.objectField("id");
    try join_s.write("join");
    try join_s.objectField("from");
    try join_s.write(rt.our_id);
    try join_s.objectField("payload");
    try join_s.write(.{ .id = rt.our_id, .name = rt.our_name, .listen = rt.listen });
    try join_s.endObject();
    const payload = join_out.written();
    if (!writeFrame(stream.socket.handle, gpa, payload)) {
        stream.close(rt.io);
        return error.JoinWrite;
    }
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    var tmp: [4096]u8 = undefined;
    const tv: std.posix.timeval = .{ .sec = 10, .usec = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    var accepted = false;
    var peer_from: []const u8 = "";
    while (!accepted) {
        const n = std.posix.read(stream.socket.handle, &tmp) catch {
            stream.close(rt.io);
            return error.JoinRead;
        };
        if (n == 0) {
            stream.close(rt.io);
            return error.JoinClosed;
        }
        try acc.appendSlice(gpa, tmp[0..n]);
        const dec = (try mesh.decodeFrame(acc.items, rt.max_frame)) orelse continue;
        const header = mesh.parseHeader(arena, dec.payload) catch {
            stream.close(rt.io);
            return error.JoinBadAck;
        };
        if (header.kind != .join_ack) {
            stream.close(rt.io);
            return error.JoinBadAck;
        }
        const p = payloadObj(arena, dec.payload) catch {
            stream.close(rt.io);
            return error.JoinBadAck;
        };
        if (p.get("accepted")) |av| if (av == .bool and !av.bool) {
            stream.close(rt.io);
            return error.JoinRefused;
        };
        peer_from = header.from;
        accepted = true;
    }
    rt.mu.lock();
    remember(rt, peer_from, peer_from, stream.socket.handle);
    rt.mu.unlock();
    const arg = try gpa.create(Conn);
    arg.* = .{ .rt = rt, .stream = stream };
    const th = try std.Thread.spawn(.{}, struct {
        fn run(a: *Conn) void {
            const r = a.rt;
            const st = a.stream;
            r.gpa.destroy(a);
            readLoop(r, st);
        }
    }.run, .{arg});
    th.detach();
}

pub const Row = struct { id: []const u8, name: []const u8, up: bool };

pub fn memberSnapshot(alloc: std.mem.Allocator) ![]const Row {
    const rt = runtime orelse return &.{};
    rt.mu.lock();
    defer rt.mu.unlock();
    var list: std.ArrayList(Row) = .empty;
    for (&rt.members) |*m| {
        if (!m.used) continue;
        try list.append(alloc, .{
            .id = try alloc.dupe(u8, mid(m)),
            .name = try alloc.dupe(u8, mname(m)),
            .up = m.fd >= 0,
        });
    }
    return list.items;
}

test "parseHostPort v4 and bracketed v6" {
    const a = try parseHostPort("127.0.0.1:7420");
    try std.testing.expectEqualStrings("127.0.0.1", a.host);
    try std.testing.expectEqual(@as(u16, 7420), a.port);
    const b = try parseHostPort("[::1]:9");
    try std.testing.expectEqualStrings("::1", b.host);
    try std.testing.expectEqual(@as(u16, 9), b.port);
    try std.testing.expectError(error.BadAddress, parseHostPort("no-port"));
}
