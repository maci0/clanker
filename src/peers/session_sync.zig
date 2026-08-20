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
