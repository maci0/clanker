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
const session_events = @import("../agent/session_events.zig");
const session_mod = @import("../agent/session.zig");
const log = @import("../util/log.zig");

pub const replica_root = "state/mesh";

/// Process-local counters for mesh session replication. Every step below is
/// fire-and-forget: the caller that triggers a push or a backfill is already
/// answering or has already returned, and nothing retries until the next
/// session write, so a replica that stops converging is otherwise
/// indistinguishable from a healthy idle one. No per-peer or per-session
/// labels; those live in the correlated log lines, keeping cardinality
/// bounded the way the HTTP, tool, job, and schedule counters already do.
var fanouts_total = std.atomic.Value(u64).init(0);
var fanout_failures_total = std.atomic.Value(u64).init(0);
var backfill_failures_total = std.atomic.Value(u64).init(0);

pub const SyncMetrics = struct {
    /// Peer fan-outs that carried the whole tail, cursor recorded.
    fanouts_total: u64,
    /// Fan-outs abandoned before the tail was delivered, at the first failure.
    fanout_failures_total: u64,
    /// Pull-side failures: a peer that is down, or a store that would not open.
    backfill_failures_total: u64,
};

pub fn snapshotSyncMetrics() SyncMetrics {
    return .{
        .fanouts_total = fanouts_total.load(.monotonic),
        .fanout_failures_total = fanout_failures_total.load(.monotonic),
        .backfill_failures_total = backfill_failures_total.load(.monotonic),
    };
}

/// One swallowed replication failure, counted and named. The stage says which
/// step gave up, the peer says which dependency did not answer, and the
/// session says what stayed unconverged; without all three an operator has a
/// counter that moved and nothing to grep for.
fn fanoutFailed(comptime stage: []const u8, owner: []const u8, peer: []const u8, id: []const u8, err: anyerror) void {
    _ = fanout_failures_total.fetchAdd(1, .monotonic);
    log.log(.warn, "mesh session sync: {s} failed owner={s} peer={s} session={s} err={s}", .{ stage, owner, peer, id, @errorName(err) });
}

fn backfillFailed(comptime stage: []const u8, owner: []const u8, peer: []const u8, id: []const u8, err: anyerror) void {
    _ = backfill_failures_total.fetchAdd(1, .monotonic);
    log.log(.warn, "mesh session sync: {s} failed owner={s} peer={s} session={s} err={s}", .{ stage, owner, peer, id, @errorName(err) });
}

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
    // The batch is one transaction: a crash or store error mid-batch leaves
    // the replica at its old cursor, and the sender's retry re-offers the
    // whole tail (duplicates are skipped by the cursor check).
    var tx = try sqlite.Transaction.begin(&store.conn);
    defer tx.rollback();
    for (events) |e| {
        if (e.seq <= cursor) continue; // duplicate
        if (e.seq != next + 1) {
            tx.rollback();
            return .{ .gap = cursor };
        }
        _ = try store.append(e.ts_ms, e.kind, e.payload);
        next = e.seq;
    }
    try tx.commit();
    return .{ .accepted = next };
}

const config_mod = @import("../config.zig");
const http_client = @import("../util/http_client.zig");

/// The fetch keeps the transport's own error: every caller here reports
/// through `fanoutFailed`/`backfillFailed`, which log `@errorName(err)`, and
/// flattening a timeout, a refused connect and a 500 into one `HttpStatus`
/// made every mesh sync failure read the same in the log and the failure
/// counter.
fn httpFetch(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8) ![]const u8 {
    return http_client.fetch(io, gpa, arena, method, url, body, null, http_client.default_timeout_ms);
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
    const owner = ownerId(cfg);
    var store = session_events.Store.open(arena, sessionDbPathZ(arena, session_id) catch |err| {
        fanoutFailed("build local store path", owner, "-", session_id, err);
        return;
    }) catch |err| {
        fanoutFailed("open local store", owner, "-", session_id, err);
        return;
    };
    defer store.close();
    const last_fanned = std.fmt.parseInt(i64, store.getMeta("mesh_last_fanned") orelse "0", 10) catch 0;
    const events = store.since(last_fanned) catch |err| {
        fanoutFailed("read local events", owner, "-", session_id, err);
        return;
    };
    if (events.len == 0) return;
    const from: i64 = last_fanned;
    for (peers) |peer| {
        var cursor: i64 = from;
        // A failure abandons this peer's fan-out rather than the others, but
        // it has to be visible: the tail below stays un-fanned, so the next
        // push retries it and the peer stays behind with nothing said.
        var delivered = true;
        while (cursor < events[events.len - 1].seq) {
            const tail = store.since(cursor) catch |err| {
                fanoutFailed("read local events", owner, peer.name, session_id, err);
                delivered = false;
                break;
            };
            if (tail.len == 0) break;
            const batch = encodeBatch(arena, owner, tail) catch |err| {
                fanoutFailed("encode batch", owner, peer.name, session_id, err);
                delivered = false;
                break;
            };
            const url = std.fmt.allocPrint(arena, "{s}/api/sessions/{s}/events", .{ peer.url, session_id }) catch |err| {
                fanoutFailed("build peer url", owner, peer.name, session_id, err);
                delivered = false;
                break;
            };
            const resp = httpFetch(io, gpa, arena, .POST, url, batch) catch |err| {
                fanoutFailed("push tail", owner, peer.name, session_id, err);
                delivered = false;
                break;
            };
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{ .ignore_unknown_fields = true }) catch |err| {
                fanoutFailed("parse peer reply", owner, peer.name, session_id, err);
                delivered = false;
                break;
            };
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
        if (!delivered) continue;
        _ = fanouts_total.fetchAdd(1, .monotonic);
    }
    store.setMeta("mesh_last_fanned", std.fmt.allocPrint(arena, "{d}", .{events[events.len - 1].seq}) catch "0") catch |err| {
        fanoutFailed("record fan-out cursor", owner, "-", session_id, err);
    };
}

pub fn backfill(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: *const config_mod.Config) void {
    const peers = peersOf(cfg, arena);
    if (peers.len == 0) return;
    var owner_url: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer owner_url.deinit(gpa);
    for (peers) |p| owner_url.put(gpa, p.name, p.url) catch |err| {
        backfillFailed("index peers", p.name, p.name, "-", err);
    };
    var dir = std.Io.Dir.cwd().openDir(io, replica_root, .{ .iterate = true }) catch |err| {
        backfillFailed("open replica root", "-", "-", "-", err);
        return;
    };
    defer dir.close(io);
    var owners = dir.iterate();
    while (true) {
        // A walk that dies mid-iteration used to end the loop with no line and
        // no counter, which reads as "nothing to back off" rather than "the
        // rest of this owner's replicas were not attempted".
        const owner_entry = owners.next(io) catch |err| {
            backfillFailed("walk replica root", "-", "-", "-", err);
            break;
        } orelse break;
        if (owner_entry.kind != .directory) continue;
        const owner = owner_entry.name;
        const url = owner_url.get(owner) orelse continue;
        const sessions_sub = std.fmt.allocPrint(arena, "{s}/sessions", .{owner}) catch |err| {
            backfillFailed("build replica path", owner, owner, "-", err);
            continue;
        };
        var sdir = dir.openDir(io, sessions_sub, .{ .iterate = true }) catch |err| {
            backfillFailed("open replica sessions", owner, owner, "-", err);
            continue;
        };
        defer sdir.close(io);
        var sit = sdir.iterate();
        // A session that cannot be pulled is skipped, not fatal: the rest of
        // the owner's replicas are still worth backfilling, which is what the
        // bare `catch continue` did while saying nothing about it.
        sessions: while (true) {
            const s_entry = sit.next(io) catch |err| {
                backfillFailed("walk replica sessions", owner, owner, "-", err);
                break;
            } orelse break;
            if (s_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, s_entry.name, ".db")) continue;
            const id = s_entry.name[0 .. s_entry.name.len - 3];
            var store = session_events.Store.open(arena, replicaPathZ(arena, owner, id) catch |err| {
                backfillFailed("build replica path", owner, owner, id, err);
                continue :sessions;
            }) catch |err| {
                backfillFailed("open replica store", owner, owner, id, err);
                continue :sessions;
            };
            defer store.close();
            const after = store.lastSeq() catch |err| {
                backfillFailed("read replica cursor", owner, owner, id, err);
                continue :sessions;
            };
            const pull_url = std.fmt.allocPrint(arena, "{s}/api/sessions/{s}/events?after={d}", .{ url, id, after }) catch |err| {
                backfillFailed("build pull url", owner, owner, id, err);
                continue :sessions;
            };
            const body = httpFetch(io, gpa, arena, .GET, pull_url, null) catch |err| {
                backfillFailed("pull events", owner, owner, id, err);
                continue :sessions;
            };
            const parsed = std.json.parseFromSliceLeaky(PullResponse, arena, body, .{ .ignore_unknown_fields = true }) catch |err| {
                backfillFailed("parse event pull", owner, owner, id, err);
                continue :sessions;
            };
            var accepted: i64 = after;
            for (parsed.events) |e| {
                if (e.seq <= after) continue;
                if (e.seq != accepted + 1) break;
                _ = store.append(e.ts_ms, e.kind, e.payload) catch |err| {
                    backfillFailed("append pulled event", owner, owner, id, err);
                    break;
                };
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

test "snapshotSyncMetrics reports the live counters" {
    const before = snapshotSyncMetrics();
    _ = fanouts_total.fetchAdd(1, .monotonic);
    _ = fanout_failures_total.fetchAdd(1, .monotonic);
    _ = backfill_failures_total.fetchAdd(1, .monotonic);
    defer {
        _ = fanouts_total.fetchSub(1, .monotonic);
        _ = fanout_failures_total.fetchSub(1, .monotonic);
        _ = backfill_failures_total.fetchSub(1, .monotonic);
    }
    const after = snapshotSyncMetrics();
    try std.testing.expectEqual(before.fanouts_total + 1, after.fanouts_total);
    try std.testing.expectEqual(before.fanout_failures_total + 1, after.fanout_failures_total);
    try std.testing.expectEqual(before.backfill_failures_total + 1, after.backfill_failures_total);
}

test "a failed pull leaves the counter moved, so a silent peer is visible" {
    const gpa = std.testing.allocator;
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const owner = try std.fmt.allocPrint(arena, "silent-{s}", .{&env.tmp.sub_path});

    const before = snapshotSyncMetrics().backfill_failures_total;
    // No listener on this port, so the pull fails where an operator would
    // otherwise see nothing at all.
    pullTranscript(io, gpa, arena, "http://127.0.0.1:1", owner, "session");
    try std.testing.expectEqual(before + 1, snapshotSyncMetrics().backfill_failures_total);
}

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

test "receive reports the committed cursor after rolling back a gapped batch" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const owner = try std.fmt.allocPrint(arena, "rollback-{s}", .{&env.tmp.sub_path});
    const owner_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ replica_root, owner });
    defer std.Io.Dir.cwd().deleteTree(io, owner_dir) catch {};

    const first = [_]session_events.Event{
        .{ .seq = 1, .ts_ms = 1000, .kind = "task", .payload = "first" },
    };
    try std.testing.expectEqual(@as(i64, 1), (try receive(io, arena, owner, "session", &first)).accepted);

    const gapped = [_]session_events.Event{
        .{ .seq = 2, .ts_ms = 2000, .kind = "assistant", .payload = "second" },
        .{ .seq = 4, .ts_ms = 4000, .kind = "assistant", .payload = "fourth" },
    };
    const result = try receive(io, arena, owner, "session", &gapped);
    var store = try replicaStore(io, arena, owner, "session");
    defer store.close();
    try std.testing.expectEqual(@as(i64, 1), try store.lastSeq());
    try std.testing.expectEqual(@as(i64, 1), result.gap);

    const repaired = [_]session_events.Event{
        gapped[0],
        .{ .seq = 3, .ts_ms = 3000, .kind = "task", .payload = "third" },
        gapped[1],
    };
    try std.testing.expectEqual(@as(i64, 4), (try receive(io, arena, owner, "session", &repaired)).accepted);
    const saved = try store.since(result.gap);
    try std.testing.expectEqual(@as(usize, 3), saved.len);
    for (saved, repaired) |actual, expected| {
        try std.testing.expectEqual(expected.seq, actual.seq);
        try std.testing.expectEqual(expected.ts_ms, actual.ts_ms);
        try std.testing.expectEqualStrings(expected.kind, actual.kind);
        try std.testing.expectEqualStrings(expected.payload, actual.payload);
    }
}

test "the replica messages table matches the owner schema" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/replica.db", .{&env.tmp.sub_path});
    var store = try session_events.Store.open(arena, try arena.dupeZ(u8, path));
    defer store.close();
    ensureMessages(&store);

    // The owner read path selects every transcript column by name; a
    // drifted replica shape fails it, and with it any resume from the
    // replica's copy of the conversation.
    var rd = try store.conn.prepare(
        \\SELECT role, content, images, tool_calls, tool_call_id, steered FROM messages ORDER BY seq;
    );
    defer rd.finalize();
    try std.testing.expectEqual(sqlite.Step.done, try rd.step());

    // A pulled row (role + content only) reads back with column defaults
    // intact, so the projection needs no knowledge of newer columns.
    var ins = try store.conn.prepare("INSERT INTO messages (role, content) VALUES ('user', 'pulled');");
    defer ins.finalize();
    _ = try ins.step();
    var chk = try store.conn.prepare("SELECT steered FROM messages WHERE role = 'user';");
    defer chk.finalize();
    try std.testing.expectEqual(sqlite.Step.row, try chk.step());
    try std.testing.expectEqual(@as(i64, 0), chk.columnInt(0));
}

/// Ensures the replica database also has the messages table, in the owner's
/// shape, so a replica can hold the transcript projection and resume a
/// session (or serve it through the same read path), not only audit it.
/// The owner's DDL is used rather than a copy of it: the replica is read by
/// the same `loadStored` projection, and a second copy of the table is a shape
/// that can drift from the one that reads it (the owner read path selects every
/// column by name, so a drifted replica fails every read). Its CHECKs come with
/// it: a peer that sends a row the read path cannot decode is refused at the
/// insert, which rolls the pull back to the previous snapshot rather than
/// storing an unreadable transcript.
fn ensureMessages(store: *session_events.Store) void {
    store.conn.exec(session_mod.messages_ddl) catch {};
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
/// The whole snapshot is one transaction: a pull that dies halfway leaves the
/// previous snapshot intact, never half a transcript. Fail-open: any failure
/// only means resume happens from an older snapshot, so every one of them is
/// counted and named rather than dropped, or a replica silently resumes from
/// a stale conversation with no record of why.
pub fn pullTranscript(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    owner_url: []const u8,
    owner: []const u8,
    id: []const u8,
) void {
    var store = replicaStore(io, arena, owner, id) catch |err| {
        backfillFailed("open replica store", owner, owner_url, id, err);
        return;
    };
    defer store.close();
    ensureMessages(&store);
    const url = std.fmt.allocPrint(arena, "{s}/api/sessions/{s}", .{ owner_url, id }) catch |err| {
        backfillFailed("build pull url", owner, owner_url, id, err);
        return;
    };
    const body = httpFetch(io, gpa, arena, .GET, url, null) catch |err| {
        backfillFailed("pull transcript", owner, owner_url, id, err);
        return;
    };
    const parsed = std.json.parseFromSliceLeaky(TranscriptResponse, arena, body, .{ .ignore_unknown_fields = true }) catch |err| {
        backfillFailed("parse transcript", owner, owner_url, id, err);
        return;
    };
    var tx = sqlite.Transaction.begin(&store.conn) catch |err| {
        backfillFailed("begin transcript write", owner, owner_url, id, err);
        return;
    };
    defer tx.rollback();
    store.setMeta("id", parsed.id) catch |err| {
        backfillFailed("store transcript id", owner, owner_url, id, err);
        return;
    };
    store.setMeta("title", parsed.title) catch |err| {
        backfillFailed("store transcript title", owner, owner_url, id, err);
        return;
    };
    var buf: [24]u8 = undefined;
    store.setMeta("created", std.fmt.bufPrint(&buf, "{d}", .{parsed.created}) catch "0") catch |err| {
        backfillFailed("store transcript created", owner, owner_url, id, err);
        return;
    };
    store.setMeta("updated", std.fmt.bufPrint(&buf, "{d}", .{parsed.updated}) catch "0") catch |err| {
        backfillFailed("store transcript updated", owner, owner_url, id, err);
        return;
    };
    store.conn.exec("DELETE FROM messages;") catch |err| {
        backfillFailed("clear replica messages", owner, owner_url, id, err);
        return;
    };
    var ins = store.conn.prepare("INSERT INTO messages (role, content) VALUES (?1, ?2);") catch |err| {
        backfillFailed("prepare message insert", owner, owner_url, id, err);
        return;
    };
    defer ins.finalize();
    var stored_bytes: usize = 0;
    for (parsed.messages) |m| {
        ins.reset();
        ins.bindText(1, m.role) catch |err| {
            backfillFailed("bind message role", owner, owner_url, id, err);
            return;
        };
        ins.bindText(2, m.content) catch |err| {
            backfillFailed("bind message content", owner, owner_url, id, err);
            return;
        };
        _ = ins.step() catch |err| {
            backfillFailed("insert message", owner, owner_url, id, err);
            return;
        };
        stored_bytes += m.content.len;
    }
    // Keep the listing's cached counts beside the rows they describe, the
    // same invariant saveSession maintains; a stale figure here would make
    // every later listing scan this transcript instead of trusting meta.
    var nbuf: [24]u8 = undefined;
    store.setMeta("message_count", std.fmt.bufPrint(&nbuf, "{d}", .{parsed.messages.len}) catch "0") catch |err| {
        backfillFailed("store message count", owner, owner_url, id, err);
        return;
    };
    var bbuf: [24]u8 = undefined;
    store.setMeta("message_bytes", std.fmt.bufPrint(&bbuf, "{d}", .{stored_bytes}) catch "0") catch |err| {
        backfillFailed("store message bytes", owner, owner_url, id, err);
        return;
    };
    tx.commit() catch |err| {
        backfillFailed("commit transcript", owner, owner_url, id, err);
    };
}
