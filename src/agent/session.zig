//! Persistent session store: one SQLite database per conversation at
//! `<sessions_dir>/<id>.db`, holding the session record (meta table), the
//! mutable transcript (messages table, rewritten on save) and the
//! append-only event stream (events table, INSERT-only by trigger). The
//! transcript is the visible projection; the events table is the traceable
//! record of what the model saw, replicated to mesh peers.

const std = @import("std");
const types = @import("../llm/types.zig");
const sqlite = @import("../util/sqlite.zig");
const session_events = @import("session_events.zig");
const session_fts = @import("session_fts.zig");
const test_env = @import("../util/test_env.zig");
const utf8 = @import("../util/utf8.zig");

pub const Session = struct {
    id: []const u8,
    title: []const u8,
    messages: []const types.Message,
    created: i64,
    updated: i64,
    /// Which workspace this conversation belongs to. The id of a row in
    /// `state/workspaces.json`, or a leftover label from before folders were
    /// registered. "" is the default workspace (the serve cwd).
    workspace: []const u8 = "",
    /// Whether this chat is archived / hidden from the default listing.
    archived: bool = false,
    /// The system prompt (and the context built from it) the model was
    /// actually running against when this session was last saved.
    system_prompt: ?[]const u8 = null,
};

/// The suffix naming a session's database: `<id>.db` (the JSON transcript
/// format is gone).
pub const db_suffix = ".db";

/// The transcript projection's table. The CHECKs are the same invariants
/// `types.Role` and the boolean columns already carry, enforced where a foreign
/// writer (the mesh transcript pull) writes rows nobody validated. A role the
/// read path cannot decode fails `loadStored` for the whole conversation, so it
/// is refused at the insert instead. Only databases created after this change
/// carry them: tightening an existing table is a rebuild, not an ALTER, and
/// `CREATE TABLE IF NOT EXISTS` leaves the old shape alone.
///
/// Exported because a mesh replica holds the same projection in its own
/// database and the owner read path selects these columns by name: a second
/// copy of this DDL is a shape that can drift from the one that reads it.
pub const messages_ddl =
    \\CREATE TABLE IF NOT EXISTS messages (
    \\  seq INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  role TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
    \\  content TEXT,
    \\  images TEXT,
    \\  tool_calls TEXT,
    \\  tool_call_id TEXT,
    \\  steered INTEGER NOT NULL DEFAULT 0 CHECK (steered IN (0, 1))
    \\);
;

const meta_ddl =
    \\CREATE TABLE IF NOT EXISTS meta (
    \\  key TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\);
;

/// Everything a session database is created with, in order: the session
/// record, the transcript projection, and the append-only event stream. The
/// event stream's DDL is the one `session_events.Store` writes and the one
/// mesh replicas open with, so it is defined there rather than spelled out a
/// second time here; the transcript table is this module's own, exported for
/// the replica that holds the same projection.
const schema_parts = [_][:0]const u8{ meta_ddl, messages_ddl, session_events.schema };

/// Session ids are path fragments, not arbitrary labels. Enforce the storage
/// boundary here even when a caller forgets its own input validation. One
/// definition in `util/session_id.zig`, shared with the guests that also
/// build paths from ids.
pub const validSessionId = @import("../util/session_id.zig").validSessionId;

/// Columns added to `messages` after the table's first shipped shape. Applied
/// on every open, in order, each ignoring the duplicate-column error an
/// already-migrated database raises. Append here as well as to `schema`:
/// `CREATE TABLE IF NOT EXISTS` never touches a database that already has
/// the table, so a column added only to `schema` is missing from every
/// session written by an older build and every read of it fails.
///
/// Exported for the same reason `messages_ddl` is: a mesh replica holds this
/// projection in its own database, and a replica written by a build that
/// predates a column needs the same ALTER or the owner's read path (which
/// selects every column by name) fails against it forever.
pub const added_message_columns = [_][:0]const u8{
    "ALTER TABLE messages ADD COLUMN steered INTEGER NOT NULL DEFAULT 0;",
};

/// Opens (creating if needed) the per-session database at
/// `<sessions_dir>/<id>.db` with the schema in place. The path is built and
/// sentinel-terminated in the arena.
fn openDb(arena: std.mem.Allocator, sessions_dir: []const u8, id: []const u8) !sqlite.Connection {
    var conn: sqlite.Connection = .{};
    const path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ sessions_dir, id, db_suffix });
    const pathz = try arena.dupeZ(u8, path);
    try conn.open(pathz);
    for (schema_parts) |ddl| {
        conn.exec(ddl) catch |err| {
            conn.close();
            return err;
        };
    }
    // `CREATE TABLE IF NOT EXISTS` leaves a database created before a column
    // existed untouched, so every added column needs its own ALTER here.
    // SQLite refuses a duplicate column, which is exactly the "already
    // migrated" case: that error is the idempotence. Any other failure
    // (read-only path, disk full, a `messages` that is not a table) surfaces
    // here, not later as a confusing missing-column bind error on first write.
    for (added_message_columns) |ddl| conn.exec(ddl) catch |err| {
        const known = std.mem.find(u8, conn.last_error, "duplicate column name") != null;
        if (!known) {
            conn.close();
            return err;
        }
    };
    return conn;
}

/// Opens `<sessions_dir>/<id>.db` for a metadata edit, refusing to create it:
/// an edit addressed to a conversation that was never saved must fail (the
/// HTTP routes turn it into a 404), not mint an empty database that the
/// listing then silently filters out for having no title. The JSON store
/// returned FileNotFound here by construction; SQLite's open-with-create
/// lost that behavior in the port.
fn openExistingDb(io: std.Io, arena: std.mem.Allocator, sessions_dir: []const u8, id: []const u8) !sqlite.Connection {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ sessions_dir, id, db_suffix });
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.FileNotFound;
    return openDb(arena, sessions_dir, id);
}

fn metaSet(conn: *sqlite.Connection, key: []const u8, value: []const u8) !void {
    var stmt = try conn.prepare(
        \\INSERT INTO meta (key, value) VALUES (?1, ?2)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
    );
    defer stmt.finalize();
    try stmt.bindText(1, key);
    try stmt.bindText(2, value);
    _ = try stmt.step();
}

fn metaGet(conn: *sqlite.Connection, arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
    var stmt = conn.prepare(
        \\SELECT value FROM meta WHERE key = ?1;
    ) catch return null;
    defer stmt.finalize();
    stmt.bindText(1, key) catch return null;
    while (true) {
        const s = stmt.step() catch return null;
        if (s != .row) break;
        return arena.dupe(u8, stmt.columnText(0) orelse "") catch null;
    }
    return null;
}

/// `meta` key holding `<message-count> <hash>` for the last transcript write.
/// See `saveSession` for what it buys.
const msg_state_key = "msg_state";

const WrittenState = struct {
    count: usize,
    hash: u64,
};

fn readWrittenState(conn: *sqlite.Connection, arena: std.mem.Allocator) ?WrittenState {
    const raw = metaGet(conn, arena, msg_state_key) orelse return null;
    const sp = std.mem.findScalar(u8, raw, ' ') orelse return null;
    const count = std.fmt.parseInt(usize, raw[0..sp], 10) catch return null;
    const hash = std.fmt.parseInt(u64, raw[sp + 1 ..], 10) catch return null;
    return .{ .count = count, .hash = hash };
}

/// Wyhash over the fields that become one `messages` row, length-delimited so
/// boundaries cannot alias: ("ab","c") must never hash like ("a","bc"), or a
/// rewrite in the middle of the transcript would read as an append.
///
/// Hashed over the caller's fields, not the stored (sanitized, JSON-encoded)
/// ones, so a save can check the prefix without encoding the whole transcript
/// first. Those encoders are pure, so an equal row implies an equal field; the
/// converse can fail (two byte strings that sanitize to the same text hash
/// differently), and that fails toward a full rebuild, which is the safe side.
fn hashMessages(messages: []const types.Message) u64 {
    var h = std.hash.Wyhash.init(0);
    var len_buf: [8]u8 = undefined;
    const feed = struct {
        fn f(wh: *std.hash.Wyhash, buf: *[8]u8, slice: []const u8) void {
            std.mem.writeInt(u64, buf, slice.len, .little);
            wh.update(buf);
            wh.update(slice);
        }
    }.f;
    for (messages) |m| {
        feed(&h, &len_buf, m.role.asStr());
        feed(&h, &len_buf, m.content orelse "");
        feed(&h, &len_buf, m.tool_call_id orelse "");
        const images: []const types.ImagePart = m.images orelse &.{};
        std.mem.writeInt(u64, &len_buf, images.len, .little);
        h.update(&len_buf);
        for (images) |img| {
            feed(&h, &len_buf, img.mime);
            feed(&h, &len_buf, img.b64);
        }
        const calls: []const types.ToolCall = m.tool_calls orelse &.{};
        std.mem.writeInt(u64, &len_buf, calls.len, .little);
        h.update(&len_buf);
        for (calls) |tc| {
            feed(&h, &len_buf, tc.id);
            feed(&h, &len_buf, tc.name);
            feed(&h, &len_buf, tc.arguments);
        }
        const flag = [1]u8{@intFromBool(m.steered)};
        feed(&h, &len_buf, &flag);
    }
    return h.final();
}

/// JSON-encodes a message's images (or "[]" when absent).
fn encodeImages(arena: std.mem.Allocator, images: ?[]const types.ImagePart) ![]const u8 {
    const imgs = images orelse return "[]";
    if (imgs.len == 0) return "[]";
    var w: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer w.deinit();
    var j = std.json.Stringify{ .writer = &w.writer, .options = .{} };
    try j.beginArray();
    for (imgs) |img| {
        try j.beginObject();
        try j.objectField("mime");
        try j.write(img.mime);
        try j.objectField("b64");
        try j.write(img.b64);
        try j.endObject();
    }
    try j.endArray();
    return arena.dupe(u8, w.written());
}

/// JSON-encodes a message's tool calls (or "[]" when absent).
fn encodeToolCalls(arena: std.mem.Allocator, calls: ?[]const types.ToolCall) ![]const u8 {
    const cs = calls orelse return "[]";
    if (cs.len == 0) return "[]";
    var w: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer w.deinit();
    var j = std.json.Stringify{ .writer = &w.writer, .options = .{} };
    try j.beginArray();
    for (cs) |tc| {
        try j.beginObject();
        try j.objectField("id");
        try j.write(tc.id);
        try j.objectField("name");
        try j.write(tc.name);
        try j.objectField("arguments");
        try j.write(tc.arguments);
        try j.endObject();
    }
    try j.endArray();
    return arena.dupe(u8, w.written());
}

/// Writes a session to `<sessions_dir>/<id>.db`: the meta record upserted,
/// the transcript replaced (the messages table is the mutable projection),
/// in one transaction. The events table is never touched here.
pub fn saveSession(io: std.Io, arena: std.mem.Allocator, sessions_dir: []const u8, session: Session) !void {
    if (!validSessionId(session.id)) return error.InvalidSessionId;
    std.Io.Dir.cwd().createDirPath(io, sessions_dir) catch {};

    var conn = try openDb(arena, sessions_dir, session.id);
    defer conn.close();
    var tx = try sqlite.Transaction.begin(&conn);
    defer tx.rollback();

    try metaSet(&conn, "id", session.id);
    try metaSet(&conn, "title", try utf8.sanitize(arena, session.title));
    var buf: [24]u8 = undefined;
    try metaSet(&conn, "created", try std.fmt.bufPrint(&buf, "{d}", .{session.created}));
    try metaSet(&conn, "updated", try std.fmt.bufPrint(&buf, "{d}", .{session.updated}));
    if (session.workspace.len > 0) try metaSet(&conn, "workspace", session.workspace);
    try metaSet(&conn, "archived", if (session.archived) "true" else "false");
    if (session.system_prompt) |sp| try metaSet(&conn, "system_prompt", try utf8.sanitize(arena, sp));

    // The transcript is a projection of the caller's message list, so a save
    // used to delete every row and reinsert the whole conversation. That is a
    // full rewrite of a multi-MB table on every turn, and the cost per session
    // grows with its length. A conversation is append-only in practice (a
    // message already sent to a provider is never rewritten, and compaction
    // drops a prefix), so the everyday save only needs the tail.
    //
    // `msg_state` says what the last save wrote: the number of messages, plus
    // a hash over their fields. When that prefix still matches the list being
    // written, only messages past it are inserted and the earlier rows keep
    // their `seq`. Anything else (first save, a database written before the
    // key existed, compaction that shortened the list, an edited or steered
    // earlier message) takes the full rebuild, so the table can lag the hash
    // but never disagree with it.
    const written = readWrittenState(&conn, arena);
    // The byte total is summed from what is bound, so an appended save needs
    // the previous figure to add to; without it, rebuild.
    const previous_bytes: ?usize = blk: {
        const raw = if (written != null) metaGet(&conn, arena, "message_bytes") else null;
        const value = raw orelse break :blk null;
        break :blk std.fmt.parseInt(usize, value, 10) catch null;
    };
    const appendable = if (written) |st|
        previous_bytes != null and
            st.count <= session.messages.len and
            hashMessages(session.messages[0..st.count]) == st.hash
    else
        false;

    const from: usize = if (appendable)
        written.?.count
    else blk: {
        try conn.exec("DELETE FROM messages;");
        break :blk 0;
    };
    var stored_bytes: usize = if (appendable) previous_bytes.? else 0;

    var ins = try conn.prepare(
        \\INSERT INTO messages (role, content, images, tool_calls, tool_call_id, steered)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6);
    );
    defer ins.finalize();
    for (session.messages[from..]) |m| {
        ins.reset();
        const content = try utf8.sanitize(arena, m.content orelse "");
        try ins.bindText(1, m.role.asStr());
        try ins.bindText(2, content);
        try ins.bindText(3, try encodeImages(arena, m.images));
        try ins.bindText(4, try encodeToolCalls(arena, m.tool_calls));
        try ins.bindText(5, try utf8.sanitize(arena, m.tool_call_id orelse ""));
        try ins.bindInt(6, @intFromBool(m.steered));
        _ = try ins.step();
        // The listing's per-session byte total (LENGTH of the stored
        // content), computed from what is actually bound so the cached
        // figure stays exact even when sanitization shrinks a message.
        stored_bytes += content.len;
    }
    // The listing reads these instead of scanning every message row
    // (`SELECT COUNT(*), SUM(LENGTH(content))` over a multi-MB transcript on
    // every picker open). Same transaction as the rows, so they can never
    // disagree with what was just written.
    try metaSet(&conn, "message_count", try std.fmt.bufPrint(&buf, "{d}", .{session.messages.len}));
    try metaSet(&conn, "message_bytes", try std.fmt.bufPrint(&buf, "{d}", .{stored_bytes}));
    var state_buf: [48]u8 = undefined;
    try metaSet(&conn, msg_state_key, try std.fmt.bufPrint(&state_buf, "{d} {d}", .{
        session.messages.len,
        hashMessages(session.messages),
    }));
    try tx.commit();
    // Cross-session full-text index (fail-open: a missing index only costs
    // the next search its speedup).
    session_fts.replaceSession(arena, session.id, session.messages);
}

pub const StoredToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const StoredImage = struct {
    mime: []const u8,
    b64: []const u8,
};

/// The wire/persistence shape of one message, used by `importChat` and the
/// read path before conversion to `types.Message`.
pub const StoredMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    images: ?[]const StoredImage = null,
    tool_calls: ?[]const StoredToolCall = null,
    tool_call_id: ?[]const u8 = null,
    /// A message the user interjected mid-run rather than typed as a turn of
    /// its own; see `types.Message.steered`.
    steered: bool = false,
};

/// Reads a session's meta + transcript rows from an open connection. Copies
/// are arena-owned. Every row is taken: the connection is one session's own
/// database, so the messages table holds that session and nothing else.
fn loadStored(conn: *sqlite.Connection, arena: std.mem.Allocator) !StoredMessageList {
    var out: std.ArrayList(StoredMessage) = .empty;
    var stmt = try conn.prepare(
        \\SELECT role, content, images, tool_calls, tool_call_id, steered FROM messages ORDER BY seq;
    );
    defer stmt.finalize();
    while (true) {
        if ((try stmt.step()) != .row) break;
        const role = try arena.dupe(u8, stmt.columnText(0) orelse "");
        const content: ?[]const u8 = if (stmt.columnText(1)) |c| try arena.dupe(u8, c) else null;
        // columnText is transient (valid until the next step); the JSON
        // decoder borrows it, so own an arena copy first.
        const imgs_raw = try arena.dupe(u8, stmt.columnText(2) orelse "[]");
        const calls_raw = try arena.dupe(u8, stmt.columnText(3) orelse "[]");
        const imgs = try decodeImages(arena, imgs_raw);
        const calls = try decodeToolCalls(arena, calls_raw);
        // A null `tool_call_id` is stored as "", so restore the null. Otherwise
        // every non-tool message comes back carrying an empty id, which the
        // wire codecs emit as `"tool_call_id": ""` on roles that have no tool
        // call to answer. Same empty-means-absent rule as the two siblings.
        const tc_id: ?[]const u8 = if (stmt.columnText(4)) |c| blk: {
            const owned = try arena.dupe(u8, c);
            break :blk if (owned.len == 0) null else owned;
        } else null;
        try out.append(arena, .{
            .role = role,
            .content = content,
            .images = if (imgs.len > 0) imgs else null,
            .tool_calls = if (calls.len > 0) calls else null,
            .tool_call_id = tc_id,
            .steered = stmt.columnInt(5) != 0,
        });
    }
    return .{ .items = try out.toOwnedSlice(arena) };
}

const StoredMessageList = struct { items: []const StoredMessage };

fn decodeImages(arena: std.mem.Allocator, raw: []const u8) ![]const StoredImage {
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0 or std.mem.eql(u8, raw, "[]")) return &.{};
    return std.json.parseFromSliceLeaky([]StoredImage, arena, raw, .{ .ignore_unknown_fields = true }) catch &.{};
}

fn decodeToolCalls(arena: std.mem.Allocator, raw: []const u8) ![]const StoredToolCall {
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0 or std.mem.eql(u8, raw, "[]")) return &.{};
    return std.json.parseFromSliceLeaky([]StoredToolCall, arena, raw, .{ .ignore_unknown_fields = true }) catch &.{};
}

/// Loads a session from `<sessions_dir>/<id>.db`.
pub fn loadSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, sessions_dir: []const u8, id: []const u8) !Session {
    _ = gpa;
    if (!validSessionId(id)) return error.InvalidSessionId;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ sessions_dir, id, db_suffix });
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.FileNotFound;
    var conn = try openDb(arena, sessions_dir, id);
    defer conn.close();

    const title = metaGet(&conn, arena, "title") orelse "";
    const created = std.fmt.parseInt(i64, metaGet(&conn, arena, "created") orelse "0", 10) catch 0;
    const updated = std.fmt.parseInt(i64, metaGet(&conn, arena, "updated") orelse "0", 10) catch 0;
    const workspace = metaGet(&conn, arena, "workspace") orelse "";
    const archived = std.mem.eql(u8, metaGet(&conn, arena, "archived") orelse "", "true");
    const system_prompt = metaGet(&conn, arena, "system_prompt");
    const stored = try loadStored(&conn, arena);

    var messages: std.ArrayList(types.Message) = .empty;
    for (stored.items) |sm| {
        var msg = types.Message{
            .role = try roleFromStr(sm.role),
            .content = sm.content,
            .tool_call_id = sm.tool_call_id,
            .steered = sm.steered,
        };
        if (sm.images) |imgs| {
            if (imgs.len > 0) {
                var img_list: std.ArrayList(types.ImagePart) = .empty;
                for (imgs) |img| try img_list.append(arena, .{ .mime = img.mime, .b64 = img.b64 });
                msg.images = try img_list.toOwnedSlice(arena);
            }
        }
        if (sm.tool_calls) |calls| {
            var tc_list: std.ArrayList(types.ToolCall) = .empty;
            for (calls) |tc| try tc_list.append(arena, .{ .id = tc.id, .name = tc.name, .arguments = tc.arguments });
            msg.tool_calls = try tc_list.toOwnedSlice(arena);
        }
        try messages.append(arena, msg);
    }

    return .{
        .id = id,
        .title = title,
        .created = created,
        .updated = updated,
        .workspace = workspace,
        .archived = archived,
        .system_prompt = system_prompt,
        .messages = try messages.toOwnedSlice(arena),
    };
}

/// Removes a saved conversation: the database file is deleted, and so are
/// its rows in the cross-session search index — a deleted transcript's text
/// must not stay findable there. Its execution graphs stay: they are the
/// record of runs that really happened, and are addressed by run id rather
/// than by session.
pub fn deleteSession(io: std.Io, arena: std.mem.Allocator, sessions_dir: []const u8, id: []const u8) !void {
    if (!validSessionId(id)) return error.InvalidSessionId;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ sessions_dir, id, db_suffix });
    try std.Io.Dir.cwd().deleteFile(io, path);
    // The journal/WAL sidecars of the deleted database are garbage once the
    // main file is gone; a fresh session reusing the id must not inherit them.
    for ([_][]const u8{ "-journal", "-wal", "-shm" }) |side_suffix| {
        const side = try std.fmt.allocPrint(arena, "{s}{s}", .{ path, side_suffix });
        std.Io.Dir.cwd().deleteFile(io, side) catch {};
    }
    session_fts.removeSession(arena, id);
}

/// Forks a conversation: the same messages written back under a new id,
/// titled "fork of <old title>". A fork is a branch you can abandon without
/// losing the conversation it came from. Returns the new id (arena-owned).
pub fn forkSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, sessions_dir: []const u8, id: []const u8) ![]const u8 {
    if (!validSessionId(id)) return error.InvalidSessionId;
    const s = try loadSession(io, gpa, arena, sessions_dir, id);
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    const new_id = try std.fmt.allocPrint(arena, "{s}-fork-{d}", .{ id, std.Io.Timestamp.now(io, .real).nanoseconds });
    try saveSession(io, arena, sessions_dir, .{
        .id = new_id,
        .title = try std.fmt.allocPrint(arena, "fork of {s}", .{s.title}),
        .workspace = s.workspace,
        .messages = s.messages,
        .created = now,
        .updated = now,
    });
    return new_id;
}

fn turnCutoff(messages: []const types.Message, n: usize) !usize {
    var users: usize = 0;
    for (messages, 0..) |m, i| {
        if (m.role != .user) continue;
        users += 1;
        if (users != n) continue;
        // End of the turn: the next user message, or the end of the list.
        var j = i + 1;
        while (j < messages.len and messages[j].role != .user) j += 1;
        // The turn's last word is its final assistant message; a pending
        // turn (user with no answer) or a dangling tool round must not leak
        // into the branch, so cut before the user message in those cases.
        var last_assistant: ?usize = null;
        var k = i + 1;
        while (k < j) : (k += 1) {
            if (messages[k].role == .assistant) last_assistant = k;
        }
        if (last_assistant) |p| return p + 1;
        return i;
    }
    return error.TurnOutOfRange;
}

pub fn branchSession(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    sessions_dir: []const u8,
    id: []const u8,
    turn_no: usize,
) ![]const u8 {
    const s = try loadSession(io, gpa, arena, sessions_dir, id);
    const cutoff = try turnCutoff(s.messages, turn_no);
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    // Nanosecond suffix keeps two branches of the same session distinct and
    // stays within the alphanumeric/dash alphabet validSessionId accepts.
    const new_id = try std.fmt.allocPrint(arena, "{s}-branch-{d}", .{ id, std.Io.Timestamp.now(io, .real).nanoseconds });
    try saveSession(io, arena, sessions_dir, .{
        .id = new_id,
        .title = try std.fmt.allocPrint(arena, "branch of {s}", .{s.title}),
        .workspace = s.workspace,
        .messages = s.messages[0..cutoff],
        .created = now,
        .updated = now,
    });
    return new_id;
}

/// Two or three content words from `task`, for the rail. Skips filler so
/// "please add a websocket for the live map" becomes "add websocket live",
/// not a 60-character prefix of the opening sentence.
pub const title_max = 28;

fn isTitleWordByte(c: u8) bool {
    // Bytes >= 0x80 are (or start) a UTF-8 sequence: treat a run of them as
    // one word, so a non-Latin task ("修复登录 bug") earns a title instead of
    // "(untitled)". ASCII separators still break words inside CJK text that
    // spaces them ("修复 登录").
    if (c >= 0x80) return true;
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '\'';
}

fn isTitleSkip(word: []const u8) bool {
    const map = std.StaticStringMap(void).initComptime(.{
        .{ "a", {} },
        .{ "an", {} },
        .{ "the", {} },
        .{ "to", {} },
        .{ "of", {} },
        .{ "for", {} },
        .{ "and", {} },
        .{ "or", {} },
        .{ "in", {} },
        .{ "on", {} },
        .{ "at", {} },
        .{ "is", {} },
        .{ "are", {} },
        .{ "be", {} },
        .{ "been", {} },
        .{ "being", {} },
        .{ "should", {} },
        .{ "would", {} },
        .{ "could", {} },
        .{ "can", {} },
        .{ "will", {} },
        .{ "just", {} },
        .{ "please", {} },
        .{ "this", {} },
        .{ "that", {} },
        .{ "it", {} },
        .{ "with", {} },
        .{ "from", {} },
        .{ "as", {} },
        .{ "by", {} },
        .{ "if", {} },
        .{ "so", {} },
        .{ "do", {} },
        .{ "does", {} },
        .{ "did", {} },
        .{ "not", {} },
        .{ "no", {} },
        .{ "we", {} },
        .{ "i", {} },
        .{ "you", {} },
        .{ "my", {} },
        .{ "our", {} },
        .{ "me", {} },
        .{ "have", {} },
        .{ "has", {} },
        .{ "had", {} },
        .{ "how", {} },
        .{ "what", {} },
        .{ "when", {} },
        .{ "where", {} },
        .{ "why", {} },
        .{ "also", {} },
        .{ "need", {} },
        .{ "want", {} },
        .{ "make", {} },
        .{ "add", {} },
    });
    var buf: [16]u8 = undefined;
    if (word.len == 0 or word.len > buf.len) return false;
    _ = std.ascii.lowerString(buf[0..word.len], word);
    return map.has(buf[0..word.len]);
}

fn appendTitleWord(out: []u8, used: *usize, word: []const u8) bool {
    if (word.len == 0) return false;
    const need_space: usize = if (used.* > 0) 1 else 0;
    if (used.* + need_space >= out.len) return false;
    if (need_space == 1) {
        out[used.*] = ' ';
        used.* += 1;
    }
    // A multibyte word cut mid-sequence would write invalid UTF-8 into the
    // title; snap the take to a codepoint boundary. ASCII words are unchanged.
    const take = utf8.cap(word, @min(word.len, out.len - used.*)).len;
    if (take == 0) return false;
    @memcpy(out[used.*..][0..take], word[0..take]);
    used.* += take;
    return true;
}

/// Writes a couple-word label into `out`. The return is a prefix of `out`.
pub fn titleFromTask(out: []u8, task: []const u8) []const u8 {
    const cap = @min(out.len, title_max);
    const dest = out[0..cap];
    var used: usize = 0;
    var words: u8 = 0;
    var i: usize = 0;
    while (i < task.len and words < 3 and used < dest.len) {
        while (i < task.len and !isTitleWordByte(task[i])) i += 1;
        const start = i;
        while (i < task.len and isTitleWordByte(task[i])) i += 1;
        const word = task[start..i];
        if (word.len == 0) break;
        if (isTitleSkip(word)) continue;
        if (!appendTitleWord(dest, &used, word)) break;
        words += 1;
    }
    if (words == 0) {
        i = 0;
        while (i < task.len and words < 2 and used < dest.len) {
            while (i < task.len and !isTitleWordByte(task[i])) i += 1;
            const start = i;
            while (i < task.len and isTitleWordByte(task[i])) i += 1;
            const word = task[start..i];
            if (word.len == 0) break;
            if (!appendTitleWord(dest, &used, word)) break;
            words += 1;
        }
    }
    if (used == 0) return "(untitled)";
    return dest[0..used];
}

/// A renamed title, a fork/branch label, or an already-short summary stays.
/// Long auto prefixes (the old first-60-chars titles) are replaced.
fn keepTitle(existing: []const u8) bool {
    const t = std.mem.trim(u8, existing, " \t\r\n");
    if (t.len == 0) return false;
    if (std.mem.startsWith(u8, t, "fork of ") or std.mem.startsWith(u8, t, "branch of ")) return true;
    if (t.len > 32) return false;
    var n: u8 = 0;
    var in_word = false;
    for (t) |c| {
        if (c == ' ') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            n += 1;
            if (n > 4) return false;
        }
    }
    return true;
}

/// Keep `existing` when it looks chosen; otherwise summarise `task`.
pub fn nextTitle(out: []u8, existing: []const u8, task: []const u8) []const u8 {
    if (keepTitle(existing)) return std.mem.trim(u8, existing, " \t\r\n");
    return titleFromTask(out, task);
}

/// First user line in the transcript, else `task`.
pub fn titleSource(messages: []const types.Message, task: []const u8) []const u8 {
    for (messages) |m| {
        if (m.role != .user) continue;
        if (m.content) |c| {
            const t = std.mem.trim(u8, c, " \t\r\n");
            if (t.len > 0) return t;
        }
    }
    return task;
}

test "titleFromTask is a couple of content words" {
    var buf: [title_max]u8 = undefined;
    try std.testing.expectEqualStrings("left bar chat", titleFromTask(&buf, "left bar chat title should be a couple word summary of the chat"));
    try std.testing.expectEqualStrings("Implement remaining clanker", titleFromTask(&buf, "Implement remaining clanker PRDs starting with persist"));
    try std.testing.expectEqualStrings("websocket live map", titleFromTask(&buf, "please add a websocket for the live map"));
    try std.testing.expectEqualStrings("a", titleFromTask(&buf, "a"));
    try std.testing.expectEqualStrings("(untitled)", titleFromTask(&buf, "   "));
    try std.testing.expect(keepTitle("Mesh map"));
    try std.testing.expect(keepTitle("fork of Original"));
    try std.testing.expect(!keepTitle("left bar chat title should be a couple word summary of the"));
    try std.testing.expectEqualStrings("Mesh map", nextTitle(&buf, "Mesh map", "something else entirely"));
}

test "titleFromTask handles non-Latin tasks" {
    var buf: [title_max]u8 = undefined;
    // Space-separated CJK words earn a title like Latin text does (up to 3).
    try std.testing.expectEqualStrings("修复 登录 bug", titleFromTask(&buf, "修复 登录 bug 页面"));
    // An unsplit CJK sentence is one long word: the title is its start,
    // truncated on a codepoint boundary (never mid-character).
    const long_cjk = "这是一个很长的中文句子用于测试标题截断";
    const t = titleFromTask(&buf, long_cjk);
    try std.testing.expect(std.unicode.utf8ValidateSlice(t));
    try std.testing.expect(t.len <= title_max);
    try std.testing.expectEqualStrings("这是一个很长的中文", t);
    // A mixed run keeps its non-ASCII characters whole.
    try std.testing.expectEqualStrings("héllo world", titleFromTask(&buf, "héllo world"));
}

/// Retitles a conversation in place, leaving its messages untouched.
///
/// Auto titles are a couple of content words from the opening task. A
/// picker full of 60-character prefixes is what this replaced.
pub fn renameSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, sessions_dir: []const u8, id: []const u8, title: []const u8) !void {
    _ = gpa;
    if (!validSessionId(id)) return error.InvalidSessionId;
    var conn = try openExistingDb(io, arena, sessions_dir, id);
    defer conn.close();
    try metaSet(&conn, "title", try utf8.sanitize(arena, title));
}

/// Reads one session's listing row (meta + counts) through a short-lived
/// connection. Returns null when the file is unreadable or has no id.
fn sessionMetaFromDb(io: std.Io, arena: std.mem.Allocator, sessions_dir: []const u8, id: []const u8) ?SessionMeta {
    // Refuse to create: `openDb` opens with create, and a search reaches this
    // with ids the FTS index named, not ids the directory holds. A session
    // deleted while its index rows survived (the index write is fail-open)
    // would otherwise have a fresh titleless `<id>.db` minted for it on every
    // search, littering state/sessions with conversations that do not exist.
    const path = std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ sessions_dir, id, db_suffix }) catch return null;
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    var conn = openDb(arena, sessions_dir, id) catch return null;
    defer conn.close();
    return sessionMetaFromConnection(arena, &conn, id);
}

fn sessionMetaFromConnection(arena: std.mem.Allocator, conn: *sqlite.Connection, id: []const u8) ?SessionMeta {
    var metadata = conn.prepare(
        \\SELECT key, value FROM meta
        \\WHERE key IN ('title', 'created', 'updated', 'workspace', 'archived', 'message_count', 'message_bytes');
    ) catch return null;
    defer metadata.finalize();
    const keys = .{ "title", "created", "updated", "workspace", "archived", "message_count", "message_bytes" };
    var values: [keys.len]?[]const u8 = @splat(null);
    while ((metadata.step() catch return null) == .row) {
        const key = metadata.columnText(0) orelse continue;
        inline for (keys, 0..) |name, i| {
            if (std.mem.eql(u8, key, name)) {
                values[i] = arena.dupe(u8, metadata.columnText(1) orelse "") catch return null;
            }
        }
    }
    const title = values[0] orelse return null;
    const created = std.fmt.parseInt(i64, values[1] orelse "0", 10) catch 0;
    const updated = std.fmt.parseInt(i64, values[2] orelse "0", 10) catch 0;
    const workspace = values[3] orelse "";
    const archived = std.mem.eql(u8, values[4] orelse "", "true");

    var count: i64 = 0;
    var bytes: i64 = 0;
    // `saveSession` stamps the counts beside the rows it writes; reading
    // them is O(1) where the aggregate below re-reads every message body.
    // Databases written before the keys existed fall back to the scan.
    const cached_count = values[5];
    const cached_bytes = values[6];
    if (cached_count != null and cached_bytes != null) {
        count = std.fmt.parseInt(i64, cached_count.?, 10) catch 0;
        bytes = std.fmt.parseInt(i64, cached_bytes.?, 10) catch 0;
    } else {
        var c = conn.prepare("SELECT COUNT(*), COALESCE(SUM(LENGTH(COALESCE(content, ''))), 0) FROM messages;") catch null;
        if (c) |*stmt| {
            defer stmt.finalize();
            if (stmt.step() catch null == .row) {
                count = stmt.columnInt(0);
                bytes = stmt.columnInt(1);
            }
        }
    }
    return .{
        .id = arena.dupe(u8, id) catch return null,
        .title = title,
        .created = created,
        .updated = updated,
        .workspace = workspace,
        .archived = archived,
        .messages = @intCast(count),
        .bytes = @intCast(bytes),
    };
}

/// Rows a listing surface may ask for. The store only ever grows (nothing
/// prunes it on its own), so an unbounded listing is a per-request cost
/// that rises for the life of the installation. The newest rows are what
/// every listing caller shows, so the cap drops the oldest.
pub const list_max: usize = 200;

/// Lists every saved session, most recently updated first. A database that
/// cannot be opened or has no id is skipped rather than failing the whole
/// listing: one corrupt session should not make the others unreachable.
pub fn listSessions(io: std.Io, arena: std.mem.Allocator, sessions_dir: []const u8) ![]SessionMeta {
    return listSessionsLimited(io, arena, sessions_dir, 0);
}

/// `listSessions` keeping only the newest `limit` rows; 0 is every row.
/// Applied after the sort, so the surviving rows are the most recently
/// updated ones rather than whichever the directory walk happened to yield.
pub fn listSessionsLimited(io: std.Io, arena: std.mem.Allocator, sessions_dir: []const u8, limit: usize) ![]SessionMeta {
    var out: std.ArrayList(SessionMeta) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch return out.toOwnedSlice(arena);
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, db_suffix)) continue;
        const id = entry.name[0 .. entry.name.len - db_suffix.len];
        if (!validSessionId(id)) continue;
        if (sessionMetaFromDb(io, arena, sessions_dir, id)) |meta| try out.append(arena, meta);
    }

    sortNewestFirst(out.items);
    if (limit > 0 and out.items.len > limit) out.shrinkRetainingCapacity(limit);
    return out.toOwnedSlice(arena);
}

/// Newest update first, id ascending within one timestamp.
///
/// `updated` is whole seconds, so a burst of turns (or two sessions saved in
/// the same second) ties, and a comparator that answers false for both
/// directions leaves the tie to whatever order the rows arrived in. That
/// order is the directory walk's, which is filesystem-dependent, so two
/// machines listing the same `state/sessions` disagreed, and `limit` kept an
/// arbitrary one of the tied rows instead of a named one. The id tiebreak
/// makes the order a total one, so the same store always lists the same way.
fn sortNewestFirst(metas: []SessionMeta) void {
    std.mem.sort(SessionMeta, metas, {}, struct {
        fn lt(_: void, a: SessionMeta, b: SessionMeta) bool {
            if (a.updated != b.updated) return a.updated > b.updated;
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lt);
}

pub const SessionMeta = struct {
    id: []const u8,
    title: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    workspace: []const u8 = "",
    archived: bool = false,
    messages: usize = 0,
    /// Total byte length of the transcript's message `content` columns, which
    /// is what `saveSession` sums and what the aggregate fallback recomputes.
    /// Tool-call arguments and images are not counted, so this reads low
    /// against `estimatedTokens`, which does count them.
    bytes: usize = 0,
};

/// Copies listing fields out of a parsed transcript so the file buffer can
/// be dropped. Peak memory for a picker is then one conversation, not the
/// sum of every saved one (each file may be up to 16 MiB).
pub const SearchHit = struct {
    id: []const u8,
    title: []const u8,
    updated: i64,
    archived: bool = false,
    /// Index into the stored message list, so the browser can say which turn
    /// and jump there rather than only naming the conversation.
    turn: usize,
    role: []const u8,
    snippet: []const u8,
    /// Matches in this conversation beyond the one reported. A conversation
    /// is one row however often the word appears in it, and this is what
    /// stops that from reading as "found once".
    more: usize = 0,
};

/// Characters of context kept either side of a match.
const snippet_radius = 90;

/// Case-insensitive substring position, ASCII-folded. Deliberately not a
/// fuzzy or subsequence match: the rail filter is already fuzzy over titles,
/// and a fuzzy match over whole transcripts finds a hit in nearly every
/// conversation, which is the same as finding nothing.
pub fn findFold(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    return std.ascii.findIgnoreCase(haystack, needle);
}

/// False when `query` cannot appear in this file's raw JSON, so the
/// transcript parse can be skipped. Queries that JSON would escape (`"`,
/// `\`, controls) must still be parsed: the stored form is not the needle.
fn rawMayContainQuery(raw: []const u8, query: []const u8) bool {
    for (query) |c| {
        if (c < 0x20 or c == '"' or c == '\\') return true;
    }
    return findFold(raw, query) != null;
}

/// The text around `at`, trimmed to a word boundary where one is close, with
/// ellipses marking each end that was cut. Newlines and tabs collapse to
/// spaces so a hit renders as one line whatever the message looked like.
fn snippetAround(arena: std.mem.Allocator, text: []const u8, at: usize, match_len: usize) []const u8 {
    const start_raw = if (at > snippet_radius) at - snippet_radius else 0;
    const end_raw = @min(text.len, at + match_len + snippet_radius);
    // Never cut inside the match itself while hunting for a space.
    var start = start_raw;
    if (start > 0) {
        if (std.mem.findScalarPos(u8, text[start..at], 0, ' ')) |sp| start += sp + 1;
    }
    var end = end_raw;
    if (end < text.len) {
        const tail_from = at + match_len;
        if (tail_from < end) {
            if (std.mem.findScalarLast(u8, text[tail_from..end], ' ')) |sp| end = tail_from + sp;
        }
    }
    // A radius cut can land mid-codepoint. Snap both cuts to codepoint
    // boundaries so the snippet stays valid UTF-8: it is re-encoded as JSON
    // for the web UI, where a split character renders as U+FFFD.
    if (start > 0 and start < end) {
        while (start < end and (text[start] & 0xC0) == 0x80) start += 1;
    }
    if (end < text.len) {
        while (end > start and (text[end] & 0xC0) == 0x80) end -= 1;
    }
    var out: std.ArrayList(u8) = .empty;
    if (start > 0) out.appendSlice(arena, "\u{2026}") catch return text[start..end];
    for (text[start..end]) |c| {
        const ch: u8 = switch (c) {
            '\n', '\r', '\t' => ' ',
            else => c,
        };
        // Control bytes never reach the page: this is model output and tool
        // results, the same untrusted text transcript.zig strips.
        if (ch < 0x20 or ch == 0x7f) continue;
        out.append(arena, ch) catch return text[start..end];
    }
    if (end < text.len) out.appendSlice(arena, "\u{2026}") catch {};
    return out.items;
}

/// Every stored conversation holding `query` in a message, newest first, one
/// row per conversation.
///
/// Reads the same directory `listSessions` walks and in the same way, so a
/// `state/` that is a symlink into the checkout resolves identically for both.
/// A file that fails to read or parse is skipped rather than failing the
/// search, matching how the listing treats a corrupt session.
pub fn searchSessions(
    io: std.Io,
    arena: std.mem.Allocator,
    sessions_dir: []const u8,
    query: []const u8,
    max_hits: usize,
) ![]SearchHit {
    var out: std.ArrayList(SearchHit) = .empty;
    // Fast path: the FTS index names candidate sessions (substring
    // semantics via the trigram tokenizer); each candidate is then scanned
    // exactly for the turn/role/snippet the caller expects. Opening every
    // conversation database just to throw most of them away was an N+1 on
    // the listing: load meta only for the ids the index named. No index ->
    // full linear scan.
    var metas: []SessionMeta = &.{};
    if (session_fts.candidates(arena, query)) |ids| {
        var listed: std.ArrayList(SessionMeta) = .empty;
        for (ids) |id| {
            if (sessionMetaFromDb(io, arena, sessions_dir, id)) |meta| try listed.append(arena, meta);
        }
        sortNewestFirst(listed.items);
        metas = listed.items;
    } else {
        metas = try listSessions(io, arena, sessions_dir);
    }
    for (metas) |meta| {
        if (out.items.len >= max_hits) break;
        var any = false;
        var more: usize = 0;
        var turn: usize = 0;
        var role: []const u8 = "";
        var best_content: []const u8 = "";
        var best_at: usize = 0;
        var best_len: usize = 0;
        var best_turn: usize = 0;
        // One connection and statement per candidate, closed at the end of
        // this block. A `defer` in the loop body itself runs when the search
        // returns, holding every candidate database open (each with its own
        // page cache) for the whole pass, and the FTS path can name up to
        // `session_fts`'s candidate cap of them. Everything kept past the block
        // is arena-owned, so nothing below outlives the statement it came from.
        {
            var conn = openDb(arena, sessions_dir, meta.id) catch continue;
            defer conn.close();
            var stmt = conn.prepare("SELECT role, content FROM messages ORDER BY seq;") catch continue;
            defer stmt.finalize();
            while (true) {
                if ((stmt.step() catch null) != .row) break;
                // columnText is valid only until the next step, so a kept
                // snippet is an arena copy; an allocation failure leaves this
                // candidate without a snippet rather than aliasing the
                // statement's buffer.
                const content = stmt.columnText(1) orelse continue;
                if (!rawMayContainQuery(content, query)) {
                    turn += 1;
                    continue;
                }
                if (findFold(content, query)) |at| {
                    any = true;
                    more += 1;
                    if (best_len == 0 or at < best_at) {
                        if (arena.dupe(u8, content)) |owned| {
                            best_at = at;
                            best_len = query.len;
                            best_content = owned;
                            role = arena.dupe(u8, stmt.columnText(0) orelse "") catch "";
                            best_turn = turn;
                        } else |_| {}
                    }
                }
                turn += 1;
            }
        }
        if (!any) continue;
        try out.append(arena, .{
            .id = meta.id,
            .title = meta.title,
            .updated = meta.updated,
            .archived = meta.archived,
            .turn = best_turn,
            .role = role,
            .snippet = snippetAround(arena, best_content, best_at, best_len),
            .more = more - 1,
        });
    }
    return out.toOwnedSlice(arena);
}

/// The id `--continue` means: the saved session touched most recently.
pub fn latestSessionId(io: std.Io, arena: std.mem.Allocator, sessions_dir: []const u8) ?[]const u8 {
    const metas = listSessions(io, arena, sessions_dir) catch return null;
    if (metas.len == 0) return null;
    var best = metas[0];
    for (metas[1..]) |m| {
        if (m.updated > best.updated) best = m;
    }
    return best.id;
}

/// A fresh conversation's id. Every surface that starts a new session mints
/// it here, so one conversation is spelled one way in the store: the REPL used
/// to mint `sess-<nanos>` at save time and `repl-<seconds>` at startup, and a
/// fork mints a third form. The nanosecond clock keeps rapid successive
/// sessions distinct and the result stays inside the alphabet
/// `validSessionId` accepts, since the id becomes a path fragment.
pub fn mintSessionId(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(arena, "sess-{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
}

pub const max_session_tokens = 128 * 1024;

/// Chars/4, rounded up. Short strings are not free. One function so
/// save-time trim, mid-turn compaction, and the context meter cannot drift.
pub fn estimateTextTokens(bytes: usize) usize {
    if (bytes == 0) return 0;
    return bytes / 4 + @intFromBool(bytes % 4 != 0);
}

pub fn estimatedTokens(message: types.Message) usize {
    var bytes: usize = if (message.content) |content| content.len else 0;
    if (message.tool_calls) |calls| {
        for (calls) |call| bytes +|= call.arguments.len;
    }
    return estimateTextTokens(bytes);
}

/// Drops oldest non-system messages until the estimated token count fits under
/// `max_tokens` so long sessions auto-compact instead of exceeding the context
/// window. Token count is estimated as chars/4 (a rough heuristic).
///
/// Dropping stops at a tool-call boundary. What is removed is always a prefix
/// of the non-system messages, so the budget cutoff can land between an
/// assistant message carrying `tool_calls` and the `tool` messages answering
/// it, leaving a tool result with nothing to answer to. Every provider rejects
/// that (OpenAI 400s on a `tool` message not preceded by `tool_calls`;
/// Anthropic rejects an unmatched `tool_result` block), and nothing downstream
/// repairs it — [[Agent.dropDanglingToolExchange]] only cleans the tail. So
/// once anything has been dropped, leading tool results go with it, the same
/// invariant [[Agent.tailStart]] guards on the other compactor.
pub fn compactMessages(messages: *std.ArrayList(types.Message), max_tokens: usize) void {
    var total: usize = 0;
    for (messages.items) |m| total +|= estimatedTokens(m);
    if (total <= max_tokens) return;
    // A single left-to-right compaction pass: `orderedRemove` per dropped
    // message shifts the whole tail, which is O(n^2) once a long session
    // needs many messages trimmed. Writing survivors back in place is O(n).
    var write: usize = 0;
    // True until a non-system message survives; only then can a `tool` message
    // have a call to answer.
    var orphaning = true;
    for (messages.items) |m| {
        if (m.role == .system) {
            messages.items[write] = m;
            write += 1;
            continue;
        }
        if (total > max_tokens or (orphaning and m.role == .tool)) {
            total -|= estimatedTokens(m);
            continue;
        }
        orphaning = false;
        messages.items[write] = m;
        write += 1;
    }
    messages.shrinkRetainingCapacity(write);
}

fn roleFromStr(s: []const u8) !types.Role {
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "tool")) return .tool;
    return error.InvalidRole;
}

pub fn setArchived(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, sessions_dir: []const u8, id: []const u8, archived: bool) !void {
    _ = gpa;
    if (!validSessionId(id)) return error.InvalidSessionId;
    var conn = try openExistingDb(io, arena, sessions_dir, id);
    defer conn.close();
    try metaSet(&conn, "archived", if (archived) "true" else "false");
}

/// Imports a JSON chat export (OpenAI format) into a new local session.
/// Accepts an array of {"role":"user"|"assistant","content":string} (unknown
/// roles/tools are skipped) so both providers' exports and our own session
/// JSON can be pasted without conversion.
pub fn importChat(io: std.Io, arena: std.mem.Allocator, sessions_dir: []const u8, title: []const u8, messages_in: []const StoredMessage) ![]const u8 {
    var out: std.ArrayList(types.Message) = .empty;
    for (messages_in) |sm| {
        if (sm.content == null or sm.content.?.len == 0) continue;
        const role = roleFromStr(sm.role) catch continue;
        if (role != .user and role != .assistant) continue;
        try out.append(arena, .{ .role = role, .content = sm.content, .steered = sm.steered });
    }
    if (out.items.len == 0) return error.MissingField;
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    const new_id = try std.fmt.allocPrint(arena, "sess-{d}-{d}", .{ now, @rem(std.Io.Timestamp.now(io, .real).nanoseconds, 1000000) });
    try saveSession(io, arena, sessions_dir, .{
        .id = new_id,
        .title = if (title.len > 0) title else "imported chat",
        .messages = try out.toOwnedSlice(arena),
        .created = now,
        .updated = now,
    });
    return new_id;
}

test "importChat keeps user and assistant turns and drops the rest" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    // A ChatGPT export leads with a system message; it must not survive as a
    // user turn. The web UI's import normalizer filters to the same two roles.
    const incoming = [_]StoredMessage{
        .{ .role = "system", .content = "you are ChatGPT" },
        .{ .role = "user", .content = "hello" },
        .{ .role = "tool", .content = "{\"ok\":true}" },
        .{ .role = "assistant", .content = "hi" },
        .{ .role = "nonsense", .content = "dropped as an unknown role" },
        .{ .role = "user", .content = "" },
    };
    const id = try importChat(io, arena, dir, "imported", &incoming);
    const s = try loadSession(io, std.testing.allocator, arena, dir, id);
    try std.testing.expectEqual(@as(usize, 2), s.messages.len);
    try std.testing.expectEqual(types.Role.user, s.messages[0].role);
    try std.testing.expectEqualStrings("hello", s.messages[0].content.?);
    try std.testing.expectEqual(types.Role.assistant, s.messages[1].role);
    try std.testing.expectEqualStrings("hi", s.messages[1].content.?);
}

/// Moves a conversation to a workspace. "" is the default one.
pub fn setWorkspace(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    sessions_dir: []const u8,
    id: []const u8,
    workspace: []const u8,
) !void {
    _ = gpa;
    if (!validSessionId(id)) return error.InvalidSessionId;
    var conn = try openExistingDb(io, arena, sessions_dir, id);
    defer conn.close();
    if (workspace.len > 0) {
        try metaSet(&conn, "workspace", workspace);
    } else {
        var stmt = try conn.prepare("DELETE FROM meta WHERE key = 'workspace';");
        defer stmt.finalize();
        _ = try stmt.step();
    }
}

// ------------------------------------------------------------------- tests --

/// The sessions dir for a test: inside the test env's tmp tree, so a failing
/// test leaves nothing in state/.
fn testDir(arena: std.mem.Allocator, env: *test_env.Env) ![]const u8 {
    return std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&env.tmp.sub_path});
}

test "session store rejects ids that can escape its directory" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    const bad_id = "../../escaped";
    try std.testing.expectError(error.InvalidSessionId, saveSession(io, arena, dir, .{
        .id = bad_id,
        .title = "bad",
        .messages = &.{},
        .created = 0,
        .updated = 0,
    }));
    try std.testing.expectError(error.InvalidSessionId, loadSession(io, std.testing.allocator, arena, dir, bad_id));
    try std.testing.expectError(error.InvalidSessionId, deleteSession(io, arena, dir, bad_id));
    try std.testing.expectError(error.InvalidSessionId, forkSession(io, std.testing.allocator, arena, dir, bad_id));
}

test "a saved session round-trips messages, attachments and the system prompt" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    var imgs = [_]types.ImagePart{.{ .mime = "image/png", .b64 = "aGk=" }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = "what is in this picture?", .images = &imgs },
        .{ .role = .assistant, .content = "a greeting", .tool_calls = &.{
            .{ .id = "call_1", .name = "read_file", .arguments = "{}" },
        } },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "{\"ok\":true}" },
    };
    try saveSession(io, arena, dir, .{
        .id = "vision",
        .title = "with image",
        .messages = &messages,
        .created = 1,
        .updated = 2,
        .system_prompt = "you are a test",
    });

    const s = try loadSession(io, std.testing.allocator, arena, dir, "vision");
    try std.testing.expectEqualStrings("with image", s.title);
    try std.testing.expectEqual(@as(usize, 3), s.messages.len);
    try std.testing.expectEqualStrings("aGk=", s.messages[0].images.?[0].b64);
    try std.testing.expectEqualStrings("read_file", s.messages[1].tool_calls.?[0].name);
    try std.testing.expectEqualStrings("call_1", s.messages[2].tool_call_id.?);
    try std.testing.expectEqualStrings("you are a test", s.system_prompt.?);
    // Absent stays absent: a null id must not come back as "", which the
    // OpenAI codec would then write onto a plain user turn.
    try std.testing.expect(s.messages[0].tool_call_id == null);
    try std.testing.expect(s.messages[1].tool_call_id == null);

    // The listing scores the row with counts.
    const metas = try listSessions(io, arena, dir);
    try std.testing.expectEqual(@as(usize, 1), metas.len);
    try std.testing.expectEqual(@as(usize, 3), metas[0].messages);
    try std.testing.expect(metas[0].bytes > 0);
}

test "a steered message round-trips as the user's own words plus the flag" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    const messages = [_]types.Message{
        .{ .role = .user, .content = "write the report" },
        .{ .role = .user, .content = "cite the source", .steered = true },
    };
    try saveSession(io, arena, dir, .{
        .id = "steered",
        .title = "interjection",
        .messages = &messages,
        .created = 1,
        .updated = 2,
    });

    const s = try loadSession(io, std.testing.allocator, arena, dir, "steered");
    try std.testing.expectEqual(@as(usize, 2), s.messages.len);
    // The stored text is what the user typed, with no harness framing in it.
    try std.testing.expectEqualStrings("cite the source", s.messages[1].content.?);
    // The flag survives, so the next turn's request re-applies the identical
    // framing instead of sending a prefix that changed under the provider.
    try std.testing.expect(s.messages[1].steered);
    try std.testing.expect(!s.messages[0].steered);
}

/// The `seq` of every message row, in order. Appended rows keep their
/// sequence across a later save; a rewrite renumbers from 1, so this is what
/// tells the two apart from the outside.
fn storedSeqs(arena: std.mem.Allocator, dir: []const u8, id: []const u8) ![]i64 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ dir, id, db_suffix });
    const pathz = try arena.dupeZ(u8, path);
    var conn: sqlite.Connection = .{};
    try conn.open(pathz);
    defer conn.close();
    var out: std.ArrayList(i64) = .empty;
    var stmt = try conn.prepare("SELECT seq FROM messages ORDER BY seq;");
    defer stmt.finalize();
    while ((try stmt.step()) == .row) try out.append(arena, stmt.columnInt(0));
    return out.toOwnedSlice(arena);
}

test "a save appends the new turn and leaves the earlier rows alone" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    const first = [_]types.Message{
        .{ .role = .user, .content = "the opening turn" },
        .{ .role = .assistant, .content = "the opening answer" },
    };
    try saveSession(io, arena, dir, .{ .id = "app", .title = "app", .messages = &first, .created = 1, .updated = 1 });
    const before = try storedSeqs(arena, dir, "app");
    try std.testing.expectEqual(@as(usize, 2), before.len);

    // The everyday turn: same prefix, one more message.
    const second = first ++ [_]types.Message{.{ .role = .user, .content = "a follow-up" }};
    try saveSession(io, arena, dir, .{ .id = "app", .title = "app", .messages = &second, .created = 1, .updated = 2 });
    const after = try storedSeqs(arena, dir, "app");
    try std.testing.expectEqual(@as(usize, 3), after.len);
    // Unchanged sequence numbers are the append: a rewrite would restamp the
    // whole table from 1 on every turn.
    try std.testing.expectEqual(before[0], after[0]);
    try std.testing.expectEqual(before[1], after[1]);

    const s = try loadSession(io, std.testing.allocator, arena, dir, "app");
    try std.testing.expectEqual(@as(usize, 3), s.messages.len);
    try std.testing.expectEqualStrings("the opening turn", s.messages[0].content.?);
    try std.testing.expectEqualStrings("a follow-up", s.messages[2].content.?);
    // The listing's cached byte total follows the append, or every picker
    // would report a size smaller than the transcript it opens.
    const meta = sessionMetaFromDb(io, arena, dir, "app").?;
    try std.testing.expectEqual(@as(usize, 3), meta.messages);
    try std.testing.expectEqual("the opening turn".len + "the opening answer".len + "a follow-up".len, meta.bytes);
}

test "an edited earlier message rewrites the transcript instead of appending onto it" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    const first = [_]types.Message{
        .{ .role = .user, .content = "the original turn" },
        .{ .role = .assistant, .content = "the original answer" },
    };
    try saveSession(io, arena, dir, .{ .id = "edit", .title = "edit", .messages = &first, .created = 1, .updated = 1 });

    // Same count, different content in the middle: the prefix hash must catch
    // it, or the old text stays in the table beside the new.
    const edited = [_]types.Message{
        .{ .role = .user, .content = "the original turn" },
        .{ .role = .assistant, .content = "the corrected answer" },
    };
    try saveSession(io, arena, dir, .{ .id = "edit", .title = "edit", .messages = &edited, .created = 1, .updated = 2 });
    const s = try loadSession(io, std.testing.allocator, arena, dir, "edit");
    try std.testing.expectEqual(@as(usize, 2), s.messages.len);
    try std.testing.expectEqualStrings("the corrected answer", s.messages[1].content.?);

    // A steered flag landing on an already-written message is a rewrite too.
    const steered = [_]types.Message{
        .{ .role = .user, .content = "the original turn", .steered = true },
        .{ .role = .assistant, .content = "the corrected answer" },
    };
    try saveSession(io, arena, dir, .{ .id = "edit", .title = "edit", .messages = &steered, .created = 1, .updated = 3 });
    const flagged = try loadSession(io, std.testing.allocator, arena, dir, "edit");
    try std.testing.expect(flagged.messages[0].steered);
    try std.testing.expectEqual(@as(usize, 2), flagged.messages.len);
}

test "a shortened transcript (compaction) rebuilds rather than appending" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    const first = [_]types.Message{
        .{ .role = .user, .content = "dropped turn" },
        .{ .role = .assistant, .content = "dropped answer" },
        .{ .role = .user, .content = "kept turn" },
    };
    try saveSession(io, arena, dir, .{ .id = "shrink", .title = "shrink", .messages = &first, .created = 1, .updated = 1 });

    const compacted = first[2..];
    try saveSession(io, arena, dir, .{ .id = "shrink", .title = "shrink", .messages = compacted, .created = 1, .updated = 2 });
    const s = try loadSession(io, std.testing.allocator, arena, dir, "shrink");
    try std.testing.expectEqual(@as(usize, 1), s.messages.len);
    try std.testing.expectEqualStrings("kept turn", s.messages[0].content.?);
    const meta = sessionMetaFromDb(io, arena, dir, "shrink").?;
    try std.testing.expectEqual(@as(usize, 1), meta.messages);
    try std.testing.expectEqual("kept turn".len, meta.bytes);
}

test "a session written before the steered column still opens and saves" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    // The pre-migration table shape, written by hand: this is what every
    // session on disk from before the column looks like, and `CREATE TABLE
    // IF NOT EXISTS` will not touch it.
    {
        const path = try std.fmt.allocPrint(arena, "{s}/legacy{s}", .{ dir, db_suffix });
        const pathz = try arena.dupeZ(u8, path);
        var conn: sqlite.Connection = .{};
        try conn.open(pathz);
        defer conn.close();
        try conn.exec(
            \\CREATE TABLE messages (
            \\  seq INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  role TEXT NOT NULL,
            \\  content TEXT,
            \\  images TEXT,
            \\  tool_calls TEXT,
            \\  tool_call_id TEXT
            \\);
            \\INSERT INTO messages (role, content) VALUES ('user', 'the old turn');
        );
    }

    // Reading it migrates the table rather than failing on the missing
    // column, and a message from before the flag existed reads as untouched.
    const before = try loadSession(io, std.testing.allocator, arena, dir, "legacy");
    try std.testing.expectEqual(@as(usize, 1), before.messages.len);
    try std.testing.expectEqualStrings("the old turn", before.messages[0].content.?);
    try std.testing.expect(!before.messages[0].steered);

    const messages = [_]types.Message{
        .{ .role = .user, .content = "the old turn" },
        .{ .role = .user, .content = "and an interjection", .steered = true },
    };
    try saveSession(io, arena, dir, .{
        .id = "legacy",
        .title = "legacy",
        .messages = &messages,
        .created = 1,
        .updated = 2,
    });
    const after = try loadSession(io, std.testing.allocator, arena, dir, "legacy");
    try std.testing.expect(after.messages[1].steered);
}

test "listing batches metadata into one query" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();
    const dir = try testDir(arena, &env);
    var conn = try openDb(arena, dir, "batched");
    defer conn.close();
    try metaSet(&conn, "workspace", "work");
    try metaSet(&conn, "message_bytes", "13");
    try metaSet(&conn, "title", "conversation");
    try metaSet(&conn, "archived", "true");
    try metaSet(&conn, "updated", "20");
    try metaSet(&conn, "message_count", "2");
    try metaSet(&conn, "created", "10");
    try metaSet(&conn, "system_prompt", "not listing metadata");
    const c = @import("sqlite3_h");
    const Trace = struct {
        fn count(_: c_uint, context: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const queries: *usize = @ptrCast(@alignCast(context.?));
            queries.* += 1;
            return 0;
        }
    };
    var queries: usize = 0;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_trace_v2(conn.db, c.SQLITE_TRACE_STMT, Trace.count, &queries));
    const meta = sessionMetaFromConnection(arena, &conn, "batched") orelse return error.MissingSession;
    try std.testing.expectEqualStrings("batched", meta.id);
    try std.testing.expectEqualStrings("conversation", meta.title);
    try std.testing.expectEqualStrings("work", meta.workspace);
    try std.testing.expectEqual(@as(i64, 10), meta.created);
    try std.testing.expectEqual(@as(i64, 20), meta.updated);
    try std.testing.expect(meta.archived);
    try std.testing.expectEqual(@as(usize, 2), meta.messages);
    try std.testing.expectEqual(@as(usize, 13), meta.bytes);
    try std.testing.expectEqual(@as(usize, 1), queries);
}

test "listing reads counts stamped at save and scans a database without them" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    const messages = [_]types.Message{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = "hi there" },
    };
    try saveSession(io, arena, dir, .{
        .id = "counted",
        .title = "counted",
        .messages = &messages,
        .created = 1,
        .updated = 2,
    });
    // The stamped figures match what the aggregate scan used to compute:
    // two messages, 5 + 8 content bytes.
    const stamped = try listSessions(io, arena, dir);
    try std.testing.expectEqual(@as(usize, 1), stamped.len);
    try std.testing.expectEqual(@as(usize, 2), stamped[0].messages);
    try std.testing.expectEqual(@as(usize, 13), stamped[0].bytes);

    // A database whose meta predates the cached keys (written by an older
    // build or a foreign writer) still lists correctly via the scan.
    {
        var conn = try openDb(arena, dir, "uncounted");
        defer conn.close();
        try metaSet(&conn, "title", "uncounted");
        var ins = try conn.prepare("INSERT INTO messages (role, content) VALUES ('user', 'legacy body');");
        defer ins.finalize();
        _ = try ins.step();
        try conn.exec("DELETE FROM meta WHERE key IN ('message_count','message_bytes');");
    }
    const both = try listSessions(io, arena, dir);
    try std.testing.expectEqual(@as(usize, 2), both.len);
    for (both) |meta| {
        if (std.mem.eql(u8, meta.id, "uncounted")) {
            try std.testing.expectEqual(@as(usize, 1), meta.messages);
            try std.testing.expectEqual(@as(usize, 11), meta.bytes);
        }
    }
}

test "a limited listing keeps the newest rows, not the first ones walked" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    for ([_]i64{ 10, 30, 20 }) |updated| {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "sess{d}", .{updated});
        try saveSession(io, arena, dir, .{
            .id = id,
            .title = id,
            .messages = &messages,
            .created = 1,
            .updated = updated,
        });
    }

    const capped = try listSessionsLimited(io, arena, dir, 2);
    try std.testing.expectEqual(@as(usize, 2), capped.len);
    try std.testing.expectEqualStrings("sess30", capped[0].id);
    try std.testing.expectEqualStrings("sess20", capped[1].id);

    const all = try listSessionsLimited(io, arena, dir, 0);
    try std.testing.expectEqual(@as(usize, 3), all.len);
}

test "sessions updated in the same second list in id order, not directory order" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    // Every row carries the same `updated`, which is the whole case: a
    // comparator on `updated` alone leaves the order to the walk, so the list
    // (and which row a `limit` keeps) is a property of the filesystem.
    for ([_][]const u8{ "sess-c", "sess-a", "sess-b" }) |id| {
        try saveSession(io, arena, dir, .{
            .id = id,
            .title = id,
            .messages = &messages,
            .created = 1,
            .updated = 100,
        });
    }

    const all = try listSessions(io, arena, dir);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("sess-a", all[0].id);
    try std.testing.expectEqualStrings("sess-b", all[1].id);
    try std.testing.expectEqualStrings("sess-c", all[2].id);

    // A capped listing keeps the same rows it would have shown, so the tie
    // cannot drop one conversation in favour of a walk-order accident.
    const capped = try listSessionsLimited(io, arena, dir, 2);
    try std.testing.expectEqual(@as(usize, 2), capped.len);
    try std.testing.expectEqualStrings("sess-a", capped[0].id);
    try std.testing.expectEqualStrings("sess-b", capped[1].id);
}

test "the events table is append-only: UPDATE and DELETE are refused" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    var conn = try openDb(arena, dir, "appendonly");
    defer conn.close();
    var ins = try conn.prepare("INSERT INTO events (ts_ms, kind, payload) VALUES (1, 'task', '{}');");
    defer ins.finalize();
    _ = try ins.step();

    var upd = try conn.prepare("UPDATE events SET payload = 'x' WHERE seq = 1;");
    defer upd.finalize();
    try std.testing.expectError(sqlite.Error.StepFailed, upd.step());

    var del = try conn.prepare("DELETE FROM events WHERE seq = 1;");
    defer del.finalize();
    try std.testing.expectError(sqlite.Error.StepFailed, del.step());
}

test "a fork copies the conversation; search finds text in the transcript" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    const messages = [_]types.Message{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = "hi there" },
    };
    try saveSession(io, arena, dir, .{
        .id = "orig",
        .title = "original",
        .messages = &messages,
        .created = 1,
        .updated = 2,
    });

    const fork_id = try forkSession(io, std.testing.allocator, arena, dir, "orig");
    const f = try loadSession(io, std.testing.allocator, arena, dir, fork_id);
    try std.testing.expect(std.mem.startsWith(u8, f.title, "fork of"));
    try std.testing.expectEqual(@as(usize, 2), f.messages.len);

    const hits = try searchSessions(io, arena, dir, "hi there", 10);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expect(std.mem.find(u8, hits[0].snippet, "hi there") != null);
    // The hit's turn indexes the message that matched ("hi there" is the
    // assistant message at index 1), not the total message count the old
    // `turn = turn` self-assignment left behind.
    try std.testing.expectEqual(@as(usize, 1), hits[0].turn);
}

test "setArchived, setWorkspace and renameSession update the record" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    try saveSession(io, arena, dir, .{
        .id = "meta-test",
        .title = "t",
        .messages = &.{},
        .created = 1,
        .updated = 2,
    });
    try renameSession(io, std.testing.allocator, arena, dir, "meta-test", "renamed");
    try setArchived(io, std.testing.allocator, arena, dir, "meta-test", true);
    try setWorkspace(io, std.testing.allocator, arena, dir, "meta-test", "research");

    const s = try loadSession(io, std.testing.allocator, arena, dir, "meta-test");
    try std.testing.expectEqualStrings("renamed", s.title);
    try std.testing.expect(s.archived);
    try std.testing.expectEqualStrings("research", s.workspace);
}

test "meta edits on an unknown id fail and mint no database" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    // The SQLite port's open-with-create made these silently succeed: the
    // route answered 200, the rail did not change, and a junk titleless
    // <id>.db was left behind that the listing then filtered out.
    try std.testing.expectError(error.FileNotFound, setArchived(io, std.testing.allocator, arena, dir, "never-saved", true));
    try std.testing.expectError(error.FileNotFound, renameSession(io, std.testing.allocator, arena, dir, "never-saved", "x"));
    try std.testing.expectError(error.FileNotFound, setWorkspace(io, std.testing.allocator, arena, dir, "never-saved", "ws"));
    const path = try std.fmt.allocPrint(arena, "{s}/never-saved{s}", .{ dir, db_suffix });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
}

test "the messages table refuses what the read path could not decode" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    var conn = try openDb(arena, dir, "checked");
    defer conn.close();

    // A role outside types.Role is a row `loadStored` fails the whole
    // conversation on; the table refuses it where the writer is.
    var bad_role = try conn.prepare("INSERT INTO messages (role, content) VALUES ('root', 'x');");
    defer bad_role.finalize();
    try std.testing.expectError(sqlite.Error.StepFailed, bad_role.step());

    // The boolean is a 0/1 column, not a truthy int.
    var bad_flag = try conn.prepare("INSERT INTO messages (role, steered) VALUES ('user', 7);");
    defer bad_flag.finalize();
    try std.testing.expectError(sqlite.Error.StepFailed, bad_flag.step());

    for ([_][:0]const u8{ "system", "user", "assistant", "tool" }) |role| {
        var ins = try conn.prepare("INSERT INTO messages (role, content) VALUES (?1, 'x');");
        defer ins.finalize();
        try ins.bindText(1, role);
        _ = try ins.step();
    }
    const rows = try loadStored(&conn, arena);
    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
}

test "a search over an indexed id with no database mints none" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    // `deleteSession`'s index write is fail-open, so a session removed while
    // the index was unopenable leaves its rows behind naming a conversation
    // that has no file. Reading one must not create it.
    try saveSession(io, arena, dir, .{
        .id = "real",
        .title = "real",
        .messages = &.{.{ .role = .user, .content = "hello" }},
        .created = 1,
        .updated = 2,
    });
    const saved_index_path = session_fts.index_path;
    defer session_fts.index_path = saved_index_path; // restore before env.deinit frees the path
    session_fts.index_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/session_fts.db", .{&env.tmp.sub_path});
    const ghost = [_]types.Message{.{ .role = .user, .content = "ghostneedle text" }};
    session_fts.replaceSession(arena, "ghost", &ghost);

    const hits = try searchSessions(io, arena, dir, "ghostneedle", 10);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
    const ghost_path = try std.fmt.allocPrint(arena, "{s}/ghost{s}", .{ dir, db_suffix });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, ghost_path, .{}));
    try std.testing.expectEqual(@as(usize, 1), (try listSessions(io, arena, dir)).len);
}

test "a session database opens in WAL journal mode" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    try saveSession(io, arena, dir, .{
        .id = "walmode",
        .title = "wal",
        .messages = &.{},
        .created = 1,
        .updated = 2,
    });

    // The mode persists in the database file: a fresh connection reads wal
    // without re-converting.
    var conn = try openDb(arena, dir, "walmode");
    defer conn.close();
    var stmt = try conn.prepare("PRAGMA journal_mode;");
    defer stmt.finalize();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("wal", stmt.columnText(0) orelse "");
}

test "a saved session database and its WAL sidecars are owner-only" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    try saveSession(io, arena, dir, .{
        .id = "private",
        .title = "private",
        .messages = &.{.{ .role = .user, .content = "my email is user@example.test" }},
        .created = 1,
        .updated = 2,
    });

    const path = try std.fmt.allocPrint(arena, "{s}/private{s}", .{ dir, db_suffix });
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), @as(std.posix.mode_t, @intFromEnum(st.permissions)) & 0o777);
    // Sidecars hold the same transcript pages; a 0644 -wal is the leak the
    // chmod on the main file would miss.
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        const side = try std.fmt.allocPrint(arena, "{s}{s}", .{ path, suffix });
        const side_st = std.Io.Dir.cwd().statFile(io, side, .{}) catch continue;
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), @as(std.posix.mode_t, @intFromEnum(side_st.permissions)) & 0o777);
    }
}

test "a migration failure that is not duplicate-column fails the open" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    // A `messages` that is a view is corruption the ALTER loop must report,
    // not swallow as if it were an already-migrated database.
    {
        const path = try std.fmt.allocPrint(arena, "{s}/broken{s}", .{ dir, db_suffix });
        const pathz = try arena.dupeZ(u8, path);
        var conn: sqlite.Connection = .{};
        try conn.open(pathz);
        defer conn.close();
        try conn.exec("CREATE VIEW messages AS SELECT 'user' AS role, '' AS content;");
    }

    try std.testing.expectError(sqlite.Error.ExecFailed, openDb(arena, dir, "broken"));
}

test "deleting a session removes its journal sidecars too" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    try saveSession(io, arena, dir, .{
        .id = "sidecar",
        .title = "sidecar",
        .messages = &.{},
        .created = 1,
        .updated = 2,
    });
    // Stale sidecars (a crash mid-write, or files left by another writer).
    for ([_][]const u8{ "-journal", "-wal", "-shm" }) |suffix| {
        const name = try std.fmt.allocPrint(arena, "sidecar.db{s}", .{suffix});
        try env.tmp.dir.writeFile(io, .{ .sub_path = name, .data = "junk" });
    }

    try deleteSession(io, arena, dir, "sidecar");

    for ([_][]const u8{ "sidecar.db", "sidecar.db-journal", "sidecar.db-wal", "sidecar.db-shm" }) |name| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
    }
}

test "mintSessionId produces a distinct id the store will accept each call" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    const a = try mintSessionId(io, arena);
    const b = try mintSessionId(io, arena);
    try std.testing.expect(validSessionId(a));
    try std.testing.expect(validSessionId(b));
    try std.testing.expect(std.mem.startsWith(u8, a, "sess-"));
    // Nanosecond-resolution ids of two consecutive mints are not equal.
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
