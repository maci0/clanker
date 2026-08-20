//! Session event-stream replication over the mesh (RFC 0019 option T, stage 1).
//!
//! A session's event stream is owned by one instance (the home-instance
//! rule): the owner appends locally (dense per-session seq) and fans out to
//! peers; a replica accepts a record only at cursor+1 and backfills gaps. All
//! over HTTP (no mesh socket), following the stage-1 spike's three journeys:
//! burst convergence, backfill after downtime, hostile wire input held off by
//! the cursor.
//!
//! Owner side: `pushTail` POSTs the owner's new events (since its last
//! fan-out) to each configured peer. Replica side: `receive` accepts appends
//! into `state/mesh/<owner>/sessions/<id>.db` at cursor+1; `pull` backfills a
//! gap via GET /api/sessions/<id>/events?after=.

const std = @import("std");
const sqlite = @import("../util/sqlite.zig");
const log = @import("../util/log.zig");
const session_events = @import("../agent/session_events.zig");

pub const replica_root = "state/mesh";

/// Opens (creating if needed) the replica database for `owner`'s session
/// `<id>`, with the append-only events table.
pub fn replicaStore(io: std.Io, arena: std.mem.Allocator, owner: []const u8, id: []const u8) !session_events.Store {
    const rel = try std.fmt.allocPrint(arena, "{s}/{s}/sessions/{s}.db", .{ replica_root, owner, id });
    const path = try arena.dupeZ(u8, rel);
    // SQLite cannot create parent directories; the whole replica tree must
    // exist before the file is opened.
    const dir_rel = try std.fmt.allocPrint(arena, "{s}/{s}/sessions", .{ replica_root, owner });
    std.Io.Dir.cwd().createDirPath(io, dir_rel) catch {};
    return session_events.Store.open(arena, path);
}

pub const ReceiveResult = union(enum) {
    /// Appends accepted; the replica's last seq after the batch.
    accepted: i64,
    /// A gap: the replica has `have`, the stream needs `have + 1`.
    gap: i64,
};

/// A replica accepts an incoming append batch for one session: every event
/// is inserted only if it is exactly cursor+1; anything ahead signals a gap
/// (the caller should backfill), anything at or behind the cursor is a
/// duplicate and dropped. Fail-closed: any store error is reported, never
/// swallowed as accepted.
pub fn receive(
    io: std.Io,
    arena: std.mem.Allocator,
    owner: []const u8,
    id: []const u8,
    events: []const session_events.Event,
) !ReceiveResult {
    var store = try replicaStore(io, arena, owner, id);
    defer store.close();
    const cursor = try store.lastSeq();
    var next: i64 = cursor;
    for (events) |e| {
        if (e.seq <= cursor) continue; // duplicate
        if (e.seq != next + 1) return .{ .gap = next }; // hole
        _ = try store.append(e.ts_ms, e.kind, e.payload);
        next = e.seq;
    }
    return .{ .accepted = next };
}

const config_mod = @import("../config.zig");

fn httpFetch(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var req = try client.request(method, uri, .{ .redirect_behavior = .unhandled });
    defer req.deinit();
    if (body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        var w = try req.sendBodyUnflushed(&.{});
        try w.writer.writeAll(b);
        try w.end();
        try req.connection.?.flush();
    }
    var redirect_buffer: [1024]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buffer);
    if (resp.head.status.class() != .success) return error.HttpStatus;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var transfer_buffer: [64]u8 = undefined;
    const reader = resp.reader(&transfer_buffer);
    _ = reader.streamRemaining(&out.writer) catch return error.HttpStatus;
    return arena.dupe(u8, out.written());
}

fn ownerId(cfg: *const config_mod.Config) []const u8 {
    if (cfg.instance.id.len > 0) return cfg.instance.id;
    if (cfg.instance.name.len > 0) return cfg.instance.name;
    return "self";
}

const PeerView = struct { name: []const u8, url: []const u8 };

fn peersOf(cfg: *const config_mod.Config, arena: std.mem.Allocator) []const PeerView {
    var out: std.ArrayList(PeerView) = .empty;
    for (cfg.peers) |p| {
        if (p.url.len > 0) out.append(arena, .{ .name = p.name, .url = p.url }) catch {};
    }
    return out.toOwnedSlice(arena) catch &.{};
}

fn sessionDbPathZ(arena: std.mem.Allocator, id: []const u8) ![:0]const u8 {
    const rel = try std.fmt.allocPrint(arena, "state/sessions/{s}.db", .{id});
    return arena.dupeZ(u8, rel);
}

fn replicaPathZ(arena: std.mem.Allocator, owner: []const u8, id: []const u8) ![:0]const u8 {
    const rel = try std.fmt.allocPrint(arena, "state/mesh/{s}/sessions/{s}.db", .{ owner, id });
    return arena.dupeZ(u8, rel);
}

fn encodeBatch(arena: std.mem.Allocator, owner: []const u8, events: []const session_events.Event) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer w.deinit();
    var j = std.json.Stringify{ .writer = &w.writer, .options = .{} };
    try j.beginObject();
    try j.objectField("owner");
    try j.write(owner);
    try j.objectField("events");
    try j.beginArray();
    for (events) |e| {
        try j.beginObject();
        try j.objectField("seq");
        try j.write(e.seq);
        try j.objectField("ts_ms");
        try j.write(e.ts_ms);
        try j.objectField("kind");
        try j.write(e.kind);
        try j.objectField("payload");
        try j.write(e.payload);
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
    return arena.dupe(u8, w.written());
}

pub fn pushTail(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: *const config_mod.Config, session_id: []const u8) void {
    if (session_id.len == 0) return;
    const peers = peersOf(cfg, arena);
    if (peers.len == 0) return;
    var store = session_events.Store.open(arena, sessionDbPathZ(arena, session_id) catch return) catch return;
    defer store.close();
    const last_fanned = std.fmt.parseInt(i64, store.getMeta("mesh_last_fanned") orelse "0", 10) catch 0;
    const events = store.since(last_fanned) catch return;
    if (events.len == 0) return;
    const owner = ownerId(cfg);
    const from: i64 = last_fanned;
    for (peers) |peer| {
        var cursor: i64 = from;
        while (cursor < events[events.len - 1].seq) {
            const tail = store.since(cursor) catch break;
            if (tail.len == 0) break;
            const batch = encodeBatch(arena, owner, tail) catch break;
            const url = std.fmt.allocPrint(arena, "{s}/api/sessions/{s}/events", .{ peer.url, session_id }) catch break;
            const resp = httpFetch(io, gpa, arena, .POST, url, batch) catch break;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{ .ignore_unknown_fields = true }) catch break;
            var advanced = false;
            if (parsed == .object) {
                if (parsed.object.get("gap")) |g| {
                    if (g == .bool and g.bool) {
                        if (parsed.object.get("have")) |h| {
                            if (h == .integer) {
                                cursor = h.integer;
                                continue;
                            }
                        }
                    }
                }
                if (parsed.object.get("last_seq")) |ls| {
                    if (ls == .integer) {
                        cursor = ls.integer;
                        advanced = true;
                    }
                }
            }
            if (!advanced) cursor = tail[tail.len - 1].seq;
        }
    }
    store.setMeta("mesh_last_fanned", std.fmt.allocPrint(arena, "{d}", .{events[events.len - 1].seq}) catch "0") catch {};
}

pub fn backfill(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: *const config_mod.Config) void {
    const peers = peersOf(cfg, arena);
    if (peers.len == 0) return;
    var owner_url = std.StringHashMap([]const u8).init(gpa);
    defer owner_url.deinit();
    for (peers) |p| owner_url.put(p.name, p.url) catch {};
    var dir = std.Io.Dir.cwd().openDir(io, "state/mesh", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var owners = dir.iterate();
    while (owners.next(io) catch null) |owner_entry| {
        if (owner_entry.kind != .directory) continue;
        const owner = owner_entry.name;
        const url = owner_url.get(owner) orelse continue;
        const sessions_sub = std.fmt.allocPrint(arena, "{s}/sessions", .{owner}) catch continue;
        var sdir = dir.openDir(io, sessions_sub, .{ .iterate = true }) catch continue;
        defer sdir.close(io);
        var sit = sdir.iterate();
        while (sit.next(io) catch null) |s_entry| {
            if (s_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, s_entry.name, ".db")) continue;
            const id = s_entry.name[0 .. s_entry.name.len - 3];
            var store = session_events.Store.open(arena, replicaPathZ(arena, owner, id) catch continue) catch continue;
            defer store.close();
            const after = store.lastSeq() catch continue;
            const pull_url = std.fmt.allocPrint(arena, "{s}/api/sessions/{s}/events?after={d}", .{ url, id, after }) catch continue;
            const body = httpFetch(io, gpa, arena, .GET, pull_url, null) catch continue;
            const parsed = std.json.parseFromSliceLeaky(PullResponse, arena, body, .{ .ignore_unknown_fields = true }) catch continue;
            var accepted: i64 = after;
            for (parsed.events) |e| {
                if (e.seq <= after) continue;
                if (e.seq != accepted + 1) break;
                _ = store.append(e.ts_ms, e.kind, e.payload) catch break;
                accepted = e.seq;
            }
            // The transcript projection too, so a peer can resume the
            // conversation, not only audit its events.
            pullTranscript(io, gpa, arena, url, owner, id);
        }
    }
}

const PullResponse = struct {
    ok: bool = true,
    events: []const session_events.Event = &.{},
};

// ------------------------------------------------------------------- tests --

const test_env = @import("../util/test_env.zig");

test "receive accepts appends at cursor+1, drops duplicates, and reports gaps" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    const events1 = [_]session_events.Event{
        .{ .seq = 1, .ts_ms = 1000, .kind = "task", .payload = "{}" },
        .{ .seq = 2, .ts_ms = 2000, .kind = "assistant", .payload = "{}" },
    };
    const r1 = try receive(io, arena, "host-a", "sess-1", &events1);
    try std.testing.expectEqual(@as(i64, 2), r1.accepted);

    // A duplicate batch is a no-op; the cursor does not move.
    const dup = [_]session_events.Event{.{ .seq = 1, .ts_ms = 1000, .kind = "task", .payload = "{}" }};
    const r2 = try receive(io, arena, "host-a", "sess-1", &dup);
    try std.testing.expectEqual(@as(i64, 2), r2.accepted);

    // A hole reports the gap at the first missing seq.
    const gap = [_]session_events.Event{.{ .seq = 4, .ts_ms = 4000, .kind = "task", .payload = "{}" }};
    const r3 = try receive(io, arena, "host-a", "sess-1", &gap);
    try std.testing.expectEqual(@as(i64, 2), r3.gap);

    // The replica's store holds exactly the accepted events, in order.
    var store = try replicaStore(io, arena, "host-a", "sess-1");
    defer store.close();
    try std.testing.expectEqual(@as(i64, 2), try store.lastSeq());
}

/// Ensures the replica database also has the messages table, so a replica can
/// hold the transcript projection and resume a session, not only audit it.
fn ensureMessages(store: *session_events.Store) void {
    store.conn.exec(
        \\CREATE TABLE IF NOT EXISTS messages (
        \\  seq INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  role TEXT NOT NULL,
        \\  content TEXT,
        \\  images TEXT,
        \\  tool_calls TEXT,
        \\  tool_call_id TEXT
        \\);\n;
    ) catch {};
}

const TranscriptRow = struct {
    role: []const u8 = "",
    content: []const u8 = "",
};

const TranscriptResponse = struct {
    ok: bool = true,
    id: []const u8 = "",
    title: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    messages: []const TranscriptRow = &.{},
};

/// Pulls the owner's transcript projection (GET /api/sessions/<id>) into the
/// replica's meta + messages tables, so a peer can resume the conversation.
/// Fail-open: a stale transcript only means resume happens from an older
/// snapshot.
pub fn pullTranscript(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    owner_url: []const u8,
    owner: []const u8,
    id: []const u8,
) void {
    var store = replicaStore(io, arena, owner, id) catch return;
    defer store.close();
    ensureMessages(&store);
    const url = std.fmt.allocPrint(arena, "{s}/api/sessions/{s}", .{ owner_url, id }) catch return;
    const body = httpFetch(io, gpa, arena, .GET, url, null) catch return;
    const parsed = std.json.parseFromSliceLeaky(TranscriptResponse, arena, body, .{ .ignore_unknown_fields = true }) catch return;
    store.setMeta("id", parsed.id) catch {};
    store.setMeta("title", parsed.title) catch {};
    var buf: [24]u8 = undefined;
    store.setMeta("created", std.fmt.bufPrint(&buf, "{d}", .{parsed.created}) catch "0") catch {};
    store.setMeta("updated", std.fmt.bufPrint(&buf, "{d}", .{parsed.updated}) catch "0") catch {};
    store.conn.exec("DELETE FROM messages;") catch return;
    var ins = store.conn.prepare("INSERT INTO messages (role, content) VALUES (?1, ?2);") catch return;
    defer ins.finalize();
    for (parsed.messages) |m| {
        ins.reset();
        ins.bindText(1, m.role) catch continue;
        ins.bindText(2, m.content) catch continue;
        _ = ins.step() catch continue;
    }
}
