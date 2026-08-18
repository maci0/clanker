//! Serve-owned mesh sockets (PRD 0011). Codec stays in peers/mesh.zig.
//! `trySendChat` is what chatrooms.fanOut prefers; HTTP is the fallback.

const std = @import("std");
const mesh = @import("../peers/mesh.zig");
const config = @import("../config.zig");
const log = @import("../util/log.zig");
const json_util = @import("../util/json.zig");
const live = @import("live.zig");

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
    max_pending: u16,
    prompt_timeout_ns: i64,
    on_chat: ?OnChat,
    mu: struct {
        raw: std.atomic.Mutex = .unlocked,
        fn lock(self: *@This()) void {
            while (!self.raw.tryLock()) {
                std.Thread.yield() catch {};
            }
        }
        fn unlock(self: *@This()) void {
            self.raw.unlock();
        }
    } = .{},
    members: [mesh.max_members]Member = @splat(.{}),
    pending: [8]Pending = @splat(.{}),
    stop: std.atomic.Value(bool) = .init(false),
    server: ?std.Io.net.Server = null,
};

const Pending = struct {
    used: bool = false,
    id: [64]u8 = undefined,
    id_len: u8 = 0,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    ack_id: [64]u8 = undefined,
    ack_id_len: u8 = 0,
    arrived_ns: i64 = 0,
    stream: ?std.Io.net.Stream = null,
};

var runtime: ?*Runtime = null;

pub fn active() bool {
    return runtime != null;
}

pub fn publishLive(msg: ChatBody) void {
    live.noteChat(msg.room, msg.id, msg.from, msg.text, msg.ts);
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

fn nowNs(rt: *Runtime) i64 {
    return @intCast(std.Io.Timestamp.now(rt.io, .real).nanoseconds);
}

pub fn pendingTimedOut(arrived_ns: i64, now_ns: i64, timeout_ns: i64) bool {
    return now_ns - arrived_ns >= timeout_ns;
}

fn pid(p: *const Pending) []const u8 {
    return p.id[0..p.id_len];
}
fn pname(p: *const Pending) []const u8 {
    return p.name[0..p.name_len];
}

fn expirePendingLocked(rt: *Runtime, now_ns: i64) void {
    for (&rt.pending) |*p| {
        if (!p.used) continue;
        if (!pendingTimedOut(p.arrived_ns, now_ns, rt.prompt_timeout_ns)) continue;
        if (p.stream) |st| {
            _ = writeJoinAck(rt, st.socket.handle, p.ack_id[0..p.ack_id_len], false);
            st.close(rt.io);
        }
        p.* = .{};
    }
}

fn findPendingLocked(rt: *Runtime, key: []const u8) ?*Pending {
    if (key.len == 0) return null;
    for (&rt.pending) |*p| {
        if (!p.used) continue;
        if (std.mem.eql(u8, pid(p), key) or std.mem.eql(u8, pname(p), key)) return p;
    }
    return null;
}

fn enqueuePending(rt: *Runtime, id: []const u8, name: []const u8, ack_id: []const u8, stream: std.Io.net.Stream) bool {
    rt.mu.lock();
    defer rt.mu.unlock();
    expirePendingLocked(rt, nowNs(rt));
    if (findPendingLocked(rt, id)) |old| {
        if (old.stream) |st| {
            _ = writeJoinAck(rt, st.socket.handle, old.ack_id[0..old.ack_id_len], false);
            st.close(rt.io);
        }
        old.* = .{};
    }
    var used: u16 = 0;
    var slot: ?*Pending = null;
    for (&rt.pending) |*p| {
        if (p.used) {
            used += 1;
        } else if (slot == null) {
            slot = p;
        }
    }
    if (used >= rt.max_pending) return false;
    const p = slot orelse return false;
    p.* = .{ .used = true, .arrived_ns = nowNs(rt), .stream = stream };
    p.id_len = copyField(&p.id, id);
    p.name_len = copyField(&p.name, name);
    p.ack_id_len = copyField(&p.ack_id, ack_id);
    return true;
}

fn writeJoinAck(rt: *Runtime, fd: std.posix.fd_t, ack_id: []const u8, accepted: bool) bool {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(arena_state.allocator());
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return false;
    s.objectField("version") catch return false;
    s.write(mesh.protocol_version) catch return false;
    s.objectField("kind") catch return false;
    s.write("JOIN_ACK") catch return false;
    s.objectField("id") catch return false;
    s.write(ack_id) catch return false;
    s.objectField("from") catch return false;
    s.write(rt.our_id) catch return false;
    s.objectField("payload") catch return false;
    s.write(.{ .accepted = accepted }) catch return false;
    s.endObject() catch return false;
    return writeFrame(fd, rt.gpa, out.written());
}

fn writeLeave(rt: *Runtime, fd: std.posix.fd_t) void {
    if (fd < 0) return;
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(arena_state.allocator());
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("version") catch return;
    s.write(mesh.protocol_version) catch return;
    s.objectField("kind") catch return;
    s.write("LEAVE") catch return;
    s.objectField("id") catch return;
    s.write("leave") catch return;
    s.objectField("from") catch return;
    s.write(rt.our_id) catch return;
    s.objectField("payload") catch return;
    s.write(.{ .reason = "operator" }) catch return;
    s.endObject() catch return;
    _ = writeFrame(fd, rt.gpa, out.written());
}

fn forgetMemberLocked(rt: *Runtime, key: []const u8) bool {
    const m = findMember(rt, key) orelse return false;
    if (m.fd >= 0) {
        writeLeave(rt, m.fd);
        _ = std.c.close(m.fd);
    }
    m.* = .{};
    return true;
}

fn remember(rt: *Runtime, id: []const u8, name: []const u8, fd: std.posix.fd_t) void {
    if (findMember(rt, id) orelse findMember(rt, name)) |m| {
        if (m.fd >= 0 and m.fd != fd) _ = std.c.close(m.fd);
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
    if (std.mem.findScalar(u8, host, ':') != null)
        return std.Io.net.IpAddress.parseIp6(host, port);
    return std.Io.net.IpAddress.parseIp4(host, port);
}

pub fn parseHostPort(s: []const u8) !struct { host: []const u8, port: u16 } {
    if (s.len == 0) return error.BadAddress;
    if (s[0] == '[') {
        const end = std.mem.findScalar(u8, s, ']') orelse return error.BadAddress;
        if (end + 2 > s.len or s[end + 1] != ':') return error.BadAddress;
        return .{ .host = s[1..end], .port = std.fmt.parseInt(u16, s[end + 2 ..], 10) catch return error.BadAddress };
    }
    const colon = std.mem.findScalarLast(u8, s, ':') orelse return error.BadAddress;
    return .{ .host = s[0..colon], .port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return error.BadAddress };
}

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

/// Deliver on a live mesh link. False means the caller should use HTTP.
pub fn trySendChat(gpa: std.mem.Allocator, peer_id: []const u8, peer_name: []const u8, msg: ChatBody) bool {
    const rt = runtime orelse return false;
    rt.mu.lock();
    const m = findMember(rt, peer_id) orelse findMember(rt, peer_name);
    const fd = if (m) |row| row.fd else -1;
    var to_buf: [64]u8 = undefined;
    const to_len: usize = if (m) |row| row.id_len else 0;
    if (m) |row| @memcpy(to_buf[0..to_len], row.id[0..to_len]);
    // Residual posix: the member fd is owned by the connection thread, which
    // can close it (and the number be recycled by a newly accepted peer) as
    // soon as this lock drops. dup under the lock so the write below targets
    // this socket even if the connection dies mid-send: the duplicate keeps
    // the open file description alive and cannot be redirected by fd reuse.
    const send_fd = if (fd >= 0) std.c.dup(fd) else -1;
    rt.mu.unlock();
    if (send_fd < 0) return false;
    defer _ = std.c.close(send_fd);
    if (to_len == 0) return false;
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
    return writeFrame(send_fd, gpa, out.written());
}

fn handleInbound(rt: *Runtime, raw: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const header = mesh.parseHeader(arena, raw) catch return;
    if (header.kind != .chat) return;
    const p = payloadObj(arena, raw) catch return;
    if (rt.on_chat) |cb| cb(.{
        .room = json_util.strFieldOrEmpty(p, "room"),
        .from = json_util.strFieldOrEmpty(p, "from"),
        .text = json_util.strFieldOrEmpty(p, "text"),
        .id = json_util.strFieldOrEmpty(p, "id"),
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
        // Residual posix: raw TCP mesh socket pump, same hand-rolled socket
        // family as the HTTP server.
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
    // Residual posix: raw TCP mesh socket recv-timeout option, same hand-rolled
    // socket family as readLoop above.
    const tv: std.posix.timeval = .{ .sec = 10, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch |err|
        log.log(.warn, "mesh: read timeout not set on inbound peer socket, reads are unbounded: {s}", .{@errorName(err)});
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
            const id = json_util.strFieldOrEmpty(p, "id");
            break :blk if (id.len > 0) id else header.from;
        };
        const join_name = json_util.strFieldOrEmpty(p, "name");
        const decision = mesh.admit(rt.admission, rt.our_id, join_id, join_name, rt.seeds);
        if (decision == .pending) {
            if (enqueuePending(rt, join_id, join_name, header.id, stream)) {
                live.noteMesh("pending", join_id);
                return;
            }
            _ = writeJoinAck(rt, fd, header.id, false);
            break;
        }
        const ok = decision == .accept;
        _ = writeJoinAck(rt, fd, header.id, ok);
        if (!ok) break;
        rt.mu.lock();
        remember(rt, join_id, join_name, fd);
        rt.mu.unlock();
        live.noteMesh("join", join_id);
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
    const server = if (rt.server) |*s| s else return;
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
        .max_pending = @min(cfg.mesh.max_pending_joins, 8),
        .prompt_timeout_ns = @as(i64, cfg.mesh.prompt_timeout_seconds) * std.time.ns_per_s,
        .on_chat = on_chat,
        .server = server,
    };
    runtime = rt;
    const th = try std.Thread.spawn(.{}, acceptLoop, .{rt});
    th.detach();
    log.log(.info, "mesh listening on {s}", .{listen_s});
}

/// One bounded window for the whole JOIN exchange: the connect below and the
/// ack read (`SO_RCVTIMEO` further down) each get this much, so a dead peer is
/// reported after ~10s instead of waiting out the kernel's own connect
/// timeout (~2 minutes on Linux when SYNs are dropped) on the CLI thread.
const join_wait_ns: i96 = 10 * std.time.ns_per_s;

/// `addr.connect` runs the TCP handshake on the caller's thread, and the
/// Threaded io has no connect timeout of its own (its `ConnectOptions.timeout`
/// is an unimplemented stub that panics). An unreachable peer therefore hung
/// the JOIN on the kernel connect timeout. Run the connect as a concurrent
/// task and cancel it at the deadline, the same shape as `httpGetDeadline` in
/// cli.zig: cancel interrupts the blocking syscall and joins the task, and the
/// connect itself errdefers its socket, so nothing leaks out of the window.
fn connectBounded(io: std.Io, addr: std.Io.net.IpAddress) !std.Io.net.Stream {
    var done: std.Io.Event = .unset;
    var fut = io.concurrent(connectTask, .{ io, addr, &done }) catch return error.ConcurrencyUnavailable;
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .clock = .awake,
        .raw = .{ .nanoseconds = join_wait_ns },
    });
    while (!done.isSet()) {
        done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            // Spurious wakeups report Timeout too, so the deadline decides
            // whether the budget is really spent, not this return.
            error.Timeout => {
                if (done.isSet()) break;
                if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue;
                _ = fut.cancel(io) catch {};
                return error.Timeout;
            },
            error.Canceled => {
                _ = fut.cancel(io) catch {};
                return error.Canceled;
            },
        };
    }
    return fut.await(io);
}

fn connectTask(io: std.Io, addr: std.Io.net.IpAddress, done: *std.Io.Event) anyerror!std.Io.net.Stream {
    defer done.set(io);
    var a = addr;
    return a.connect(io, .{ .mode = .stream });
}

pub fn join(gpa: std.mem.Allocator, address: []const u8) !void {
    const rt = runtime orelse return error.MeshOff;
    const hp = try parseHostPort(address);
    const addr = try parseAddr(hp.host, hp.port);
    const stream = try connectBounded(rt.io, addr);
    // Every failure below leaves this scope, and the socket has to go with it.
    // The explicit closes only covered the branches written out longhand; the
    // `try`s -- a short allocation, a peer whose frame is malformed or over
    // rt.max_frame -- returned straight past them, so a peer that reliably
    // failed the handshake leaked one descriptor per join attempt. The stream
    // is only handed on once spawnRead takes it, and errdefer does not run on
    // the success path.
    errdefer stream.close(rt.io);
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
        return error.JoinWrite;
    }
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    var tmp: [4096]u8 = undefined;
    // Residual posix: raw TCP mesh socket recv-timeout option, same hand-rolled
    // socket family as readLoop above. Same window as the connect above, so the
    // whole JOIN exchange is bounded to ~2 * join_wait_ns on a dead peer.
    const tv: std.posix.timeval = .{ .sec = @intCast(@divTrunc(join_wait_ns, std.time.ns_per_s)), .usec = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch |err|
        log.log(.warn, "mesh: read timeout not set while joining a peer, the join wait is unbounded: {s}", .{@errorName(err)});
    var accepted = false;
    var peer_from: []const u8 = "";
    while (!accepted) {
        const n = std.posix.read(stream.socket.handle, &tmp) catch {
            return error.JoinRead;
        };
        if (n == 0) {
            return error.JoinClosed;
        }
        try acc.appendSlice(gpa, tmp[0..n]);
        const dec = (try mesh.decodeFrame(acc.items, rt.max_frame)) orelse continue;
        const header = mesh.parseHeader(arena, dec.payload) catch {
            return error.JoinBadAck;
        };
        if (header.kind != .join_ack) {
            return error.JoinBadAck;
        }
        const p = payloadObj(arena, dec.payload) catch {
            return error.JoinBadAck;
        };
        if (p.get("accepted")) |av| if (av == .bool and !av.bool) {
            return error.JoinRefused;
        };
        peer_from = header.from;
        accepted = true;
    }
    // Registered only once the reader owns the socket. The other order left a
    // member pointing at a descriptor no thread was reading and the errdefer
    // above had just closed, so the next fanOut wrote to whatever number the
    // OS handed out next.
    try spawnRead(rt, stream);
    rt.mu.lock();
    remember(rt, peer_from, peer_from, stream.socket.handle);
    rt.mu.unlock();
    live.noteMesh("join", peer_from);
}

fn spawnRead(rt: *Runtime, stream: std.Io.net.Stream) !void {
    const arg = try rt.gpa.create(Conn);
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

pub fn listenAddr() []const u8 {
    const rt = runtime orelse return "";
    return rt.listen;
}

pub fn admissionMode() []const u8 {
    const rt = runtime orelse return "";
    return switch (rt.admission) {
        .allowlist => "allowlist",
        .prompt => "prompt",
        .open => "open",
    };
}

pub fn ourId() []const u8 {
    const rt = runtime orelse return "";
    return rt.our_id;
}

pub fn leave(peer_id: []const u8) !void {
    const rt = runtime orelse return error.MeshOff;
    const note_id = blk: {
        rt.mu.lock();
        defer rt.mu.unlock();
        if (peer_id.len == 0) {
            for (&rt.members) |*m| {
                if (!m.used) continue;
                if (m.fd >= 0) {
                    writeLeave(rt, m.fd);
                    _ = std.c.close(m.fd);
                }
                m.* = .{};
            }
            break :blk rt.our_id;
        }
        if (!forgetMemberLocked(rt, peer_id)) return error.NoSuchPeer;
        break :blk peer_id;
    };
    live.noteMesh("leave", note_id);
}

pub const PendingRow = struct { id: []const u8, name: []const u8, age_s: i64 };

pub fn pendingSnapshot(alloc: std.mem.Allocator) ![]const PendingRow {
    const rt = runtime orelse return &.{};
    rt.mu.lock();
    defer rt.mu.unlock();
    const now = nowNs(rt);
    expirePendingLocked(rt, now);
    var list: std.ArrayList(PendingRow) = .empty;
    for (&rt.pending) |*p| {
        if (!p.used) continue;
        const age = @divTrunc(now - p.arrived_ns, std.time.ns_per_s);
        try list.append(alloc, .{
            .id = try alloc.dupe(u8, pid(p)),
            .name = try alloc.dupe(u8, pname(p)),
            .age_s = age,
        });
    }
    return list.items;
}

pub fn resolvePending(id: []const u8, allow: bool) !void {
    const rt = runtime orelse return error.MeshOff;
    rt.mu.lock();
    expirePendingLocked(rt, nowNs(rt));
    const p = findPendingLocked(rt, id) orelse {
        rt.mu.unlock();
        return error.NoSuchPeer;
    };
    const stream = p.stream;
    var id_buf: [64]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    var ack_buf: [64]u8 = undefined;
    const id_len = p.id_len;
    const name_len = p.name_len;
    const ack_len = p.ack_id_len;
    @memcpy(id_buf[0..id_len], p.id[0..id_len]);
    @memcpy(name_buf[0..name_len], p.name[0..name_len]);
    @memcpy(ack_buf[0..ack_len], p.ack_id[0..ack_len]);
    p.* = .{};
    rt.mu.unlock();

    const st = stream orelse return error.NoSuchPeer;
    if (!allow) {
        _ = writeJoinAck(rt, st.socket.handle, ack_buf[0..ack_len], false);
        st.close(rt.io);
        live.noteMesh("deny", id_buf[0..id_len]);
        return;
    }
    _ = writeJoinAck(rt, st.socket.handle, ack_buf[0..ack_len], true);
    rt.mu.lock();
    remember(rt, id_buf[0..id_len], name_buf[0..name_len], st.socket.handle);
    rt.mu.unlock();
    spawnRead(rt, st) catch {
        st.close(rt.io);
        return error.JoinWrite;
    };
    live.noteMesh("join", id_buf[0..id_len]);
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

test "pendingTimedOut honors the prompt window" {
    const timeout = 120 * std.time.ns_per_s;
    try std.testing.expect(!pendingTimedOut(0, timeout - 1, timeout));
    try std.testing.expect(pendingTimedOut(0, timeout, timeout));
    try std.testing.expect(pendingTimedOut(1_000, 1_000 + timeout + 1, timeout));
}
