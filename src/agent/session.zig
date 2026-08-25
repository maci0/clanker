//! Persistent session store: one SQLite database per conversation at
//! `<sessions_dir>/<id>.db`, holding the session record (meta table), the
//! mutable transcript (messages table, rewritten on save) and the
//! append-only event stream (events table, INSERT-only by trigger). The
//! transcript is the visible projection; the events table is the traceable
//! record of what the model saw, replicated to mesh peers.

const std = @import("std");
const types = @import("../llm/types.zig");
const sqlite = @import("../util/sqlite.zig");
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

const schema: [:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS meta (
    \\  key TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS messages (
    \\  seq INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  role TEXT NOT NULL,
    \\  content TEXT,
    \\  images TEXT,
    \\  tool_calls TEXT,
    \\  tool_call_id TEXT,
    \\  steered INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE TABLE IF NOT EXISTS events (
    \\  seq INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  ts_ms INTEGER NOT NULL,
    \\  kind TEXT NOT NULL,
    \\  payload TEXT NOT NULL
    \\);
    \\CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
    \\BEGIN SELECT RAISE(ABORT, 'events is append-only'); END;
    \\CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
    \\BEGIN SELECT RAISE(ABORT, 'events is append-only'); END;
;

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
const added_message_columns = [_][:0]const u8{
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
    conn.exec(schema) catch |err| {
        conn.close();
        return err;
    };
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
pub fn saveSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, sessions_dir: []const u8, session: Session) !void {
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

    try conn.exec("DELETE FROM messages;");
    var ins = try conn.prepare(
        \\INSERT INTO messages (role, content, images, tool_calls, tool_call_id, steered)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6);
    );
    defer ins.finalize();
    var stored_bytes: usize = 0;
    for (session.messages) |m| {
        ins.reset();
        const content = try utf8.sanitize(arena, m.content orelse "");
        try ins.bindText(1, m.role.asStr());
        try ins.bindText(2, content);
        try ins.bindText(3, try encodeImages(arena, m.images));
        try ins.bindText(4, try encodeToolCalls(arena, m.tool_calls));
        try ins.bindText(5, try utf8.sanitize(arena, m.tool_call_id orelse ""));
        try ins.bindInt(6, if (m.steered) 1 else 0);
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
    try tx.commit();
    // Cross-session full-text index (fail-open: a missing index only costs
    // the next search its speedup).
    session_fts.replaceSession(io, gpa, arena, session.id, session.messages);
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
/// are arena-owned.
fn loadStored(conn: *sqlite.Connection, arena: std.mem.Allocator, id: []const u8) !StoredMessageList {
    _ = id;
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
        const tc_id: ?[]const u8 = if (stmt.columnText(4)) |c| try arena.dupe(u8, c) else null;
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
    const stored = try loadStored(&conn, arena, id);

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
    try saveSession(io, gpa, arena, sessions_dir, .{
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
    try saveSession(io, gpa, arena, sessions_dir, .{
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
pub fn keepTitle(existing: []const u8) bool {
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
fn sessionMetaFromDb(arena: std.mem.Allocator, sessions_dir: []const u8, id: []const u8) ?SessionMeta {
    var conn = openDb(arena, sessions_dir, id) catch return null;
    defer conn.close();
    const title = metaGet(&conn, arena, "title") orelse return null;
    const created = std.fmt.parseInt(i64, metaGet(&conn, arena, "created") orelse "0", 10) catch 0;
    const updated = std.fmt.parseInt(i64, metaGet(&conn, arena, "updated") orelse "0", 10) catch 0;
    const workspace = metaGet(&conn, arena, "workspace") orelse "";
    const archived = std.mem.eql(u8, metaGet(&conn, arena, "archived") orelse "", "true");

    var count: i64 = 0;
    var bytes: i64 = 0;
    // `saveSession` stamps the counts beside the rows it writes; reading
    // them is O(1) where the aggregate below re-reads every message body.
    // Databases written before the keys existed fall back to the scan.
    const cached_count = metaGet(&conn, arena, "message_count");
    const cached_bytes = metaGet(&conn, arena, "message_bytes");
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

/// Lists every saved session, most recently updated first. A database that
/// cannot be opened or has no id is skipped rather than failing the whole
/// listing: one corrupt session should not make the others unreachable.
pub fn listSessions(io: std.Io, arena: std.mem.Allocator, sessions_dir: []const u8) ![]SessionMeta {
    var out: std.ArrayList(SessionMeta) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch return out.toOwnedSlice(arena);
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, db_suffix)) continue;
        const id = entry.name[0 .. entry.name.len - db_suffix.len];
        if (!validSessionId(id)) continue;
        if (sessionMetaFromDb(arena, sessions_dir, id)) |meta| try out.append(arena, meta);
    }

    std.mem.sort(SessionMeta, out.items, {}, struct {
        fn lt(_: void, a: SessionMeta, b: SessionMeta) bool {
            return a.updated > b.updated;
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

pub const SessionMeta = struct {
    id: []const u8,
    title: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    workspace: []const u8 = "",
    archived: bool = false,
    messages: usize = 0,
    /// Total byte length of the transcript's message content (plus tool-call
    /// arguments). Compaction thresholds are in bytes, so a picker can show
    /// this: it is how close a conversation is to being compacted.
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
pub fn snippetAround(arena: std.mem.Allocator, text: []const u8, at: usize, match_len: usize) []const u8 {
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
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    sessions_dir: []const u8,
    query: []const u8,
    max_hits: usize,
) ![]SearchHit {
    var out: std.ArrayList(SearchHit) = .empty;
    const metas = try listSessions(io, arena, sessions_dir);
    // Fast path: the FTS index names candidate sessions (substring
    // semantics via the trigram tokenizer); each candidate is then scanned
    // exactly for the turn/role/snippet the caller expects. No index ->
    // full linear scan.
    const fts_ids = session_fts.candidates(io, gpa, arena, query);
    // Membership test per session against the candidate list; a hash set
    // keeps this O(1) instead of rescanning the list per session.
    var indexed: ?std.StringHashMap(void) = null;
    if (fts_ids) |ids| {
        var set: std.StringHashMap(void) = .init(arena);
        for (ids) |cid| try set.put(cid, {});
        indexed = set;
    }
    for (metas) |meta| {
        if (out.items.len >= max_hits) break;
        // Indexed: only candidate sessions are scanned. No index: every
        // session is scanned (the title is never a pre-filter, a query may
        // match only inside messages).
        if (indexed) |*set| {
            if (!set.contains(meta.id)) continue;
        }
        var conn = openDb(arena, sessions_dir, meta.id) catch continue;
        defer conn.close();
        var stmt = conn.prepare("SELECT role, content FROM messages ORDER BY seq;") catch continue;
        defer stmt.finalize();
        var any = false;
        var more: usize = 0;
        var turn: usize = 0;
        var role: []const u8 = "";
        var best_content: []const u8 = "";
        var best_at: usize = 0;
        var best_len: usize = 0;
        var best_turn: usize = 0;
        while (true) {
            if ((stmt.step() catch null) != .row) break;
            const content = stmt.columnText(1) orelse continue;
            if (!rawMayContainQuery(content, query)) {
                turn += 1;
                continue;
            }
            if (findFold(content, query)) |at| {
                any = true;
                more += 1;
                if (best_len == 0 or at < best_at) {
                    best_at = at;
                    best_len = query.len;
                    best_content = arena.dupe(u8, content) catch content;
                    role = arena.dupe(u8, stmt.columnText(0) orelse "") catch "";
                    best_turn = turn;
                }
            }
            turn += 1;
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
pub fn importChat(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, sessions_dir: []const u8, title: []const u8, messages_in: []const StoredMessage) ![]const u8 {
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
    try saveSession(io, gpa, arena, sessions_dir, .{
        .id = new_id,
        .title = if (title.len > 0) title else "imported chat",
        .messages = try out.toOwnedSlice(arena),
        .created = now,
        .updated = now,
    });
    return new_id;
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
    try std.testing.expectError(error.InvalidSessionId, saveSession(io, std.testing.allocator, arena, dir, .{
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
    try saveSession(io, std.testing.allocator, arena, dir, .{
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
    try saveSession(io, std.testing.allocator, arena, dir, .{
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
    try saveSession(io, std.testing.allocator, arena, dir, .{
        .id = "legacy",
        .title = "legacy",
        .messages = &messages,
        .created = 1,
        .updated = 2,
    });
    const after = try loadSession(io, std.testing.allocator, arena, dir, "legacy");
    try std.testing.expect(after.messages[1].steered);
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
    try saveSession(io, std.testing.allocator, arena, dir, .{
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
    try saveSession(io, std.testing.allocator, arena, dir, .{
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

    const hits = try searchSessions(io, std.testing.allocator, arena, dir, "hi there", 10);
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

    try saveSession(io, std.testing.allocator, arena, dir, .{
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

test "a session database opens in WAL journal mode" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const dir = try testDir(arena, &env);

    try saveSession(io, std.testing.allocator, arena, dir, .{
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

    try saveSession(io, std.testing.allocator, arena, dir, .{
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
