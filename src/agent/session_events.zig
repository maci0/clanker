//! Per-session append-only event store (SQLite).
//!
//! One SQLite database per session, `state/sessions/<id>.db`, holding
//! an INSERT-only `events` stream — the traceable record of what the model
//! saw: system prompt snapshots, the task, assistant replies, tool calls and
//! results, LLM calls, reasoning, subagent launches and context injections —
//! plus a `meta` table for the session record. The JSON transcript stays the
//! mutable visible-chat projection; this store is append-only by trigger, so
//! UPDATE/DELETE on `events` are refused at the database.
//!
//! Stream semantics follow RFC 0019 option T / the stage-1 spike: the owner
//! instance appends locally and the dense `seq` is the per-session cursor; a
//! replica accepts a record only at cursor+1 and backfills gaps over the mesh
//! HTTP API. Replicas live at `state/mesh/<owner>/sessions/<id>.db`.

const std = @import("std");
const sqlite = @import("../util/sqlite.zig");
const log = @import("../util/log.zig");

/// The suffix appended to a session id to name its event database. The JSON
/// The events table lives in the session's own database (`<id>.db`); this
/// module is the append-only writer for it.
/// One event in a session's stream. `payload` is a JSON object; the exact
/// fields are per-kind and recorded in EventKind's docs.
pub const Event = struct {
    seq: i64,
    ts_ms: i64,
    kind: []const u8,
    payload: []const u8,
};

/// The event kinds the harness records. Payload field names are stable once
/// shipped; adding a kind is additive, never a rename.
pub const EventKind = struct {
    /// The built system prompt (preset persona + injected context) the model
    /// saw. Payload: {"prompt": string}.
    pub const system_prompt = "system_prompt";
    /// The user task / submitted line. Payload: {"task": string}.
    pub const task = "task";
    /// The assistant's reply text. Payload: {"text": string}.
    pub const assistant = "assistant";
    /// A tool invocation. Payload: {"name": string, "arguments": string}.
    pub const tool_call = "tool_call";
    /// A tool result. Payload: {"name": string, "ok": bool, "preview": string}.
    pub const tool_result = "tool_result";
    /// An LLM completion (agent turn or internal ck_llm/improve/arena call).
    /// Payload: {"provider": string, "model": string, "prompt_tokens": int,
    /// "completion_tokens": int, "ok": bool}.
    pub const llm = "llm";
    /// A reasoning trace. Payload: {"provider": string, "model": string,
    /// "reasoning": string}.
    pub const reasoning = "reasoning";
    /// A subagent launch. Payload: {"run_id": string, "task": string}.
    pub const subagent = "subagent";
    /// A context injection (TTSR rule, learnings, hook additionalContext).
    /// Payload: {"source": string, "text": string}.
    pub const injection = "injection";
    /// History compaction dropped/replaced messages. Payload: {"dropped":
    /// int, "replaced_with": string}.
    pub const compaction = "compaction";
};

const schema: [:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS events (
    \\  seq INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  ts_ms INTEGER NOT NULL,
    \\  kind TEXT NOT NULL,
    \\  payload TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS meta (
    \\  key TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\);
    \\CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
    \\BEGIN SELECT RAISE(ABORT, 'events is append-only'); END;
    \\CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
    \\BEGIN SELECT RAISE(ABORT, 'events is append-only'); END;
;

pub const Store = struct {
    conn: sqlite.Connection = .{},
    arena: std.mem.Allocator,
    path: []const u8,

    /// Opens (creating if needed) the per-session database at `path`. The
    /// path must be sentinel-terminated (callers build it with allocPrintZ).
    pub fn open(arena: std.mem.Allocator, path: [:0]const u8) !Store {
        var s = Store{ .arena = arena, .path = path };
        try s.conn.open(path);
        s.conn.exec(schema) catch |err| {
            s.conn.close();
            return err;
        };
        return s;
    }

    pub fn close(self: *Store) void {
        self.conn.close();
    }

    /// Appends one event, returning its dense sequence number. Append-only:
    /// the trigger refuses any later UPDATE/DELETE of this row.
    pub fn append(self: *Store, ts_ms: i64, kind: []const u8, payload: []const u8) !i64 {
        var stmt = try self.conn.prepare(
            \\INSERT INTO events (ts_ms, kind, payload) VALUES (?1, ?2, ?3);
        );
        defer stmt.finalize();
        try stmt.bindInt(1, ts_ms);
        try stmt.bindText(2, kind);
        try stmt.bindText(3, payload);
        _ = try stmt.step();
        return self.conn.lastInsertRowid();
    }

    /// Events with seq > `after`, in stream order. Copies are arena-owned.
    pub fn since(self: *Store, after: i64) ![]Event {
        var out: std.ArrayList(Event) = .empty;
        var stmt = try self.conn.prepare(
            \\SELECT seq, ts_ms, kind, payload FROM events WHERE seq > ?1 ORDER BY seq;
        );
        defer stmt.finalize();
        try stmt.bindInt(1, after);
        while (true) {
            if ((try stmt.step()) != .row) break;
            try out.append(self.arena, .{
                .seq = stmt.columnInt(0),
                .ts_ms = stmt.columnInt(1),
                .kind = try self.arena.dupe(u8, stmt.columnText(2) orelse ""),
                .payload = try self.arena.dupe(u8, stmt.columnText(3) orelse ""),
            });
        }
        return out.toOwnedSlice(self.arena);
    }

    /// The highest sequence appended so far (0 when the stream is empty).
    pub fn lastSeq(self: *Store) !i64 {
        var stmt = try self.conn.prepare(
            \\SELECT COALESCE(MAX(seq), 0) FROM events;
        );
        defer stmt.finalize();
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    pub fn count(self: *Store) !i64 {
        var stmt = try self.conn.prepare(
            \\SELECT COUNT(*) FROM events;
        );
        defer stmt.finalize();
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    /// Session-record metadata (owner instance id, created, title...).
    pub fn setMeta(self: *Store, key: []const u8, value: []const u8) !void {
        var stmt = try self.conn.prepare(
            \\INSERT INTO meta (key, value) VALUES (?1, ?2)
            \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        );
        defer stmt.finalize();
        try stmt.bindText(1, key);
        try stmt.bindText(2, value);
        _ = try stmt.step();
    }

    pub fn getMeta(self: *Store, key: []const u8) ?[]const u8 {
        var stmt = self.conn.prepare(
            \\SELECT value FROM meta WHERE key = ?1;
        ) catch return null;
        defer stmt.finalize();
        stmt.bindText(1, key) catch return null;
        while (true) {
            const s = stmt.step() catch return null;
            if (s != .row) break;
            return self.arena.dupe(u8, stmt.columnText(0) orelse "") catch null;
        }
        return null;
    }
};

// ------------------------------------------------------------------- tests --

const test_env = @import("../util/test_env.zig");

/// Path for a store test database, inside the test env's tmp tree
/// (`.zig-cache/tmp/<sub>`), so a failing test leaves nothing in state/.
fn dbPath(arena: std.mem.Allocator, env: *test_env.Env, name: []const u8) ![:0]const u8 {
    const s = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/{s}.db", .{ &env.tmp.sub_path, name });
    return arena.dupeZ(u8, s);
}

test "events append in stream order with a dense seq cursor" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const path = try dbPath(arena, &env, "seq");

    var store = try Store.open(arena, path);
    defer store.close();

    const s1 = try store.append(1000, EventKind.task, "{\"task\":\"hello\"}");
    const s2 = try store.append(1001, EventKind.tool_call, "{\"name\":\"read_file\",\"arguments\":\"{}\"}");
    const s3 = try store.append(1002, EventKind.tool_result, "{\"ok\":true}");
    try std.testing.expectEqual(@as(i64, 1), s1);
    try std.testing.expectEqual(@as(i64, 2), s2);
    try std.testing.expectEqual(@as(i64, 3), s3);
    try std.testing.expectEqual(@as(i64, 3), try store.lastSeq());
    try std.testing.expectEqual(@as(i64, 3), try store.count());

    // since(0) returns everything in order; since(1) resumes mid-stream.
    const all = try store.since(0);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings(EventKind.task, all[0].kind);
    try std.testing.expectEqualStrings(EventKind.tool_result, all[2].kind);
    try std.testing.expectEqual(@as(i64, 1002), all[2].ts_ms);
    const tail = try store.since(1);
    try std.testing.expectEqual(@as(usize, 2), tail.len);
    try std.testing.expectEqual(@as(i64, 2), tail[0].seq);
}

test "the store is append-only: UPDATE and DELETE are refused by trigger" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const path = try dbPath(arena, &env, "appendonly");

    var store = try Store.open(arena, path);
    defer store.close();

    _ = try store.append(1000, EventKind.task, "{}");

    // UPDATE is refused.
    var upd = try store.conn.prepare("UPDATE events SET payload = 'x' WHERE seq = 1;");
    defer upd.finalize();
    try std.testing.expectError(sqlite.Error.StepFailed, upd.step());

    // DELETE is refused.
    var del = try store.conn.prepare("DELETE FROM events WHERE seq = 1;");
    defer del.finalize();
    try std.testing.expectError(sqlite.Error.StepFailed, del.step());

    // The row is still there, untouched.
    try std.testing.expectEqual(@as(i64, 1), try store.count());
}

test "meta round-trips the session record" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const path = try dbPath(arena, &env, "meta");

    var store = try Store.open(arena, path);
    defer store.close();
    try store.setMeta("owner", "host-1");
    try store.setMeta("title", "hello");
    try std.testing.expectEqualStrings("host-1", store.getMeta("owner").?);
    try std.testing.expectEqualStrings("hello", store.getMeta("title").?);
    try std.testing.expect(store.getMeta("absent") == null);
}

/// A fail-open recorder the agent loop holds for the duration of a run.
/// Events land in the per-session database `<session_id>.db` under
/// the session store directory; any error (disk full, unreadable dir) is
/// logged at debug and dropped — recording must never fail a run.
///
/// The database is opened lazily on the first record and closed by the
/// caller (Agent.deinit), so a session that never records anything touches
/// no files.
pub const Recorder = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    session_id: []const u8,
    store: ?Store = null,
    opened: bool = false,

    pub fn init(io: std.Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, session_id: []const u8) Recorder {
        return .{ .io = io, .arena = arena, .gpa = gpa, .session_id = session_id };
    }

    pub fn close(self: *Recorder) void {
        if (self.store) |*s| s.close();
        self.store = null;
        self.opened = false;
    }

    fn openIfNeeded(self: *Recorder) void {
        if (self.opened) return;
        self.opened = true;
        // The session's own database: the events table and its append-only
        // triggers are part of the session schema (session.zig).
        const rel = std.fmt.allocPrint(self.arena, "state/sessions/{s}.db", .{self.session_id}) catch return;
        const path = self.arena.dupeZ(u8, rel) catch return;
        std.Io.Dir.cwd().createDirPath(self.io, "state/sessions") catch |err| {
            log.log(.debug, "session '{s}': events not recorded, 'state/sessions' cannot be created: {s}", .{ self.session_id, @errorName(err) });
            return;
        };
        self.store = Store.open(self.arena, path) catch |err| {
            log.log(.debug, "session '{s}': events not recorded, '{s}' cannot be opened: {s}", .{ self.session_id, rel, @errorName(err) });
            return;
        };
    }

    /// Records one event. Fail-open: nothing here may propagate.
    pub fn record(self: *Recorder, kind: []const u8, payload: []const u8) void {
        if (self.session_id.len == 0) return;
        self.openIfNeeded();
        const s = &(self.store orelse return);
        const ts_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms));
        _ = s.append(ts_ms, kind, payload) catch |err| {
            log.log(.debug, "session '{s}': {s} event not recorded: {s}", .{ self.session_id, kind, @errorName(err) });
        };
    }

    /// Builds a payload object from fields and records it.
    pub fn recordObject(self: *Recorder, kind: []const u8, fields: []const Field) void {
        const arena = self.arena;
        var w: std.Io.Writer.Allocating = .init(self.gpa);
        defer w.deinit();
        var j = std.json.Stringify{ .writer = &w.writer, .options = .{} };
        j.beginObject() catch return;
        for (fields) |f| {
            j.objectField(f.name) catch return;
            switch (f.value) {
                .text => |t| j.write(t) catch return,
                .int => |n| j.write(n) catch return,
                .bool_ => |b| j.write(b) catch return,
            }
        }
        j.endObject() catch return;
        const owned = arena.dupe(u8, w.written()) catch return;
        self.record(kind, owned);
    }

    pub const Field = struct {
        name: []const u8,
        value: Value,
    };

    pub const Value = union(enum) {
        text: []const u8,
        int: i64,
        bool_: bool,
    };
};
