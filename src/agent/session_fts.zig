//! Cross-session full-text index (FTS5, trigram tokenizer) over message
//! content, in one global database `state/session_fts.db`. The trigram
//! tokenizer matches arbitrary substrings of 3+ characters, so the index
//! preserves the linear scan's substring semantics exactly.
//!
//! Maintained by session.saveSession (delete the session's rows, insert each
//! message's content); read by session.searchSessions to get candidate
//! sessions before the per-session exact scan. A missing or corrupt index
//! degrades to the linear scan.

const std = @import("std");
const sqlite = @import("../util/sqlite.zig");
const types = @import("../llm/types.zig");

/// The index database path; a module var so tests can point it at a temp
/// file instead of the real store.
pub var index_path: []const u8 = "state/session_fts.db";

const schema: [:0]const u8 =
    \\CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(
    \\  session_id UNINDEXED,
    \\  role UNINDEXED,
    \\  content,
    \\  tokenize = 'trigram'
    \\);
    \\CREATE TABLE IF NOT EXISTS fts_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
;

/// Per-session progress record for incremental indexing, in `fts_meta` under
/// key `idx:<session_id>`: `<message-count> <wyhash64>`. The count covers all
/// messages (empty-content ones included) and the hash is over the first
/// `count` message contents, length-delimited. On the next save the stored
/// pair is re-derived from the messages being written: a match means that
/// prefix is already indexed and only the tail needs inserting, so a long
/// conversation costs one append per turn instead of re-tokenizing its whole
/// transcript into trigrams on every save.
///
/// Sessions are append-only once saved (`types.Message` content of an already
/// sent message is never rewritten), which is what makes the prefix check
/// sound. Any other shape — shorter list (compaction), changed middle
/// content, missing or corrupt record — falls back to the full delete +
/// reinsert rebuild, so the index can drift stale but never wrong.
fn indexKey(arena: std.mem.Allocator, session_id: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(arena, "idx:{s}", .{session_id}) catch null;
}

const IndexState = struct {
    count: usize,
    hash: u64,
};

fn readIndexState(conn: *sqlite.Connection, arena: std.mem.Allocator, key: []const u8) ?IndexState {
    var stmt = conn.prepare("SELECT value FROM fts_meta WHERE key = ?1;") catch return null;
    defer stmt.finalize();
    stmt.bindText(1, key) catch return null;
    if ((stmt.step() catch return null) != .row) return null;
    const raw = arena.dupe(u8, stmt.columnText(0) orelse "") catch return null;
    const sp = std.mem.findScalar(u8, raw, ' ') orelse return null;
    const count = std.fmt.parseInt(usize, raw[0..sp], 10) catch return null;
    const hash = std.fmt.parseInt(u64, raw[sp + 1 ..], 10) catch return null;
    return .{ .count = count, .hash = hash };
}

fn writeIndexState(conn: *sqlite.Connection, key: []const u8, st: IndexState) void {
    var buf: [48]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d} {d}", .{ st.count, st.hash }) catch return;
    var stmt = conn.prepare(
        \\INSERT INTO fts_meta (key, value) VALUES (?1, ?2)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
    ) catch return;
    defer stmt.finalize();
    stmt.bindText(1, key) catch return;
    stmt.bindText(2, value) catch return;
    _ = stmt.step() catch return;
}

/// Wyhash over message contents, length-delimited so boundaries cannot alias:
/// ("ab","c") must never hash like ("a","bc").
fn hashContents(messages: []const types.Message) u64 {
    var h = std.hash.Wyhash.init(0);
    for (messages) |m| {
        const content = m.content orelse "";
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, content.len, .little);
        h.update(&len_buf);
        h.update(content);
    }
    return h.final();
}

pub fn open(arena: std.mem.Allocator) !sqlite.Connection {
    var conn: sqlite.Connection = .{};
    const path = try arena.dupeZ(u8, index_path);
    try conn.open(path);
    conn.exec(schema) catch |err| {
        conn.close();
        return err;
    };
    return conn;
}

/// Brings a session's index rows in line with `messages`: appends only the
/// messages past the indexed prefix when that prefix verifies against the
/// stored state, else rebuilds from scratch. Fail-open: a missing index only
/// costs speed.
///
/// The whole swap is one transaction. Without it every insert autocommits,
/// and in SQLite's default rollback-journal mode each autocommit is its own
/// journal write and fsync cycle: a long transcript's rebuild cost one commit
/// per message on every `saveSession` (every turn). The wrap also makes the
/// swap atomic, so a crash mid-rebuild cannot leave the session half-deleted
/// in the index — and it covers the `fts_meta` progress record with the rows,
/// so a rolled-back append also rolls back the count and is re-derived (and
/// re-inserted) next time.
pub fn replaceSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, session_id: []const u8, messages: []const types.Message) void {
    _ = io;
    _ = gpa;
    var conn = open(arena) catch return;
    defer conn.close();
    const key = indexKey(arena, session_id) orelse return;
    var tx = sqlite.Transaction.begin(&conn) catch return;
    defer tx.rollback();

    // Incremental append only when the stored prefix state matches what the
    // caller is writing. Anything else (first save, compaction-shrunk list,
    // edited content, corrupt record) takes the full rebuild.
    const stored = readIndexState(&conn, arena, key);
    const prefix_ok = if (stored) |st|
        st.count <= messages.len and hashContents(messages[0..st.count]) == st.hash
    else
        false;

    var ins = conn.prepare("INSERT INTO session_fts (session_id, role, content) VALUES (?1, ?2, ?3);") catch return;
    defer ins.finalize();
    const from: usize = if (prefix_ok)
        stored.?.count
    else blk: {
        var del = conn.prepare("DELETE FROM session_fts WHERE session_id = ?1;") catch return;
        defer del.finalize();
        del.bindText(1, session_id) catch return;
        _ = del.step() catch return;
        break :blk 0;
    };
    for (messages[from..]) |m| {
        const content = m.content orelse continue;
        if (content.len == 0) continue;
        ins.reset();
        // A failed bind or insert aborts the whole swap: stamping the
        // progress record past a row that never landed would mark text the
        // index does not hold as indexed forever. The defer rolls back the
        // partial inserts and any rebuild's deletes, leaving the previous
        // committed state; the next save re-derives and retries.
        ins.bindText(1, session_id) catch return;
        ins.bindText(2, m.role.asStr()) catch return;
        ins.bindText(3, content) catch return;
        _ = ins.step() catch return;
    }
    writeIndexState(&conn, key, .{ .count = messages.len, .hash = hashContents(messages) });
    tx.commit() catch return;
}

/// Removes a deleted session's rows from the index: without this, the full
/// text of a conversation the operator deleted stays findable in
/// `state/session_fts.db` forever. The progress record goes too, so a later
/// session reusing the id rebuilds instead of appending onto nothing.
/// Fail-open like the writer — a missing index means there is nothing to
/// forget.
pub fn removeSession(arena: std.mem.Allocator, session_id: []const u8) void {
    var conn = open(arena) catch return;
    defer conn.close();
    var tx = sqlite.Transaction.begin(&conn) catch return;
    defer tx.rollback();
    if (indexKey(arena, session_id)) |key| {
        var delm = conn.prepare("DELETE FROM fts_meta WHERE key = ?1;") catch return;
        defer delm.finalize();
        delm.bindText(1, key) catch return;
        _ = delm.step() catch return;
    }
    var del = conn.prepare("DELETE FROM session_fts WHERE session_id = ?1;") catch return;
    defer del.finalize();
    del.bindText(1, session_id) catch return;
    _ = del.step() catch return;
    tx.commit() catch return;
}

/// Safety bound on one FTS candidate page. Without it a common substring
/// matching every conversation allocates an id per session and the caller
/// then opens that many databases. Newest-first order is applied after this
/// list is loaded (the index does not store `updated`), so this is a ceiling,
/// not a "first N newest" page.
const candidate_cap: usize = 4096;

/// Session ids whose content matches `query` (3+ chars, substring semantics
/// via the trigram tokenizer). Returns null when the index is unavailable,
/// signalling the caller to fall back to the linear scan.
pub fn candidates(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, query: []const u8) ?[]const []const u8 {
    _ = io;
    _ = gpa;
    if (query.len < 3) return null;
    var conn = open(arena) catch return null;
    defer conn.close();
    var quoted: std.ArrayList(u8) = .empty;
    quotePhrase(&quoted, arena, query) catch return null;
    var stmt = conn.prepare("SELECT DISTINCT session_id FROM session_fts WHERE session_fts MATCH ?1 LIMIT ?2;") catch return null;
    defer stmt.finalize();
    stmt.bindText(1, quoted.items) catch return null;
    stmt.bindInt(2, @intCast(candidate_cap)) catch return null;
    var out: std.ArrayList([]const u8) = .empty;
    while (out.items.len < candidate_cap) {
        if ((stmt.step() catch return null) != .row) break;
        out.append(arena, arena.dupe(u8, stmt.columnText(0) orelse "") catch return null) catch return null;
    }
    return out.toOwnedSlice(arena) catch null;
}

/// FTS5 phrase quoting: wrap in double quotes, doubling embedded ones.
fn quotePhrase(out: *std.ArrayList(u8), arena: std.mem.Allocator, query: []const u8) !void {
    try out.append(arena, '"');
    for (query) |ch| {
        if (ch == '"') try out.appendSlice(arena, "\"\"");
        try out.append(arena, ch);
    }
    try out.append(arena, '"');
}

// ------------------------------------------------------------------- tests --

const test_env = @import("../util/test_env.zig");

fn testIndexPath(arena: std.mem.Allocator, env: *test_env.Env) ![:0]const u8 {
    const rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/session_fts.db", .{&env.tmp.sub_path});
    return arena.dupeZ(u8, rel);
}

test "fts candidates find substring matches across sessions" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const saved_index_path = index_path;
    index_path = try testIndexPath(arena, &env);
    defer index_path = saved_index_path; // restore before env.deinit frees the path

    const messages = [_]types.Message{.{ .role = .user, .content = "the needleword is hidden here" }};
    replaceSession(io, std.testing.allocator, arena, "sess-a", &messages);
    const none = [_]types.Message{.{ .role = .user, .content = "nothing to see" }};
    replaceSession(io, std.testing.allocator, arena, "sess-b", &none);

    const hits = candidates(io, std.testing.allocator, arena, "needleword") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("sess-a", hits[0]);

    // A mid-word substring still matches via the trigram tokenizer.
    const mid = candidates(io, std.testing.allocator, arena, "needle") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 1), mid.len);
}

test "replaceSession drops a session's previous text" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const saved_index_path = index_path;
    index_path = try testIndexPath(arena, &env);
    defer index_path = saved_index_path; // restore before env.deinit frees the path

    const first = [_]types.Message{.{ .role = .user, .content = "the staleword lives here" }};
    replaceSession(io, std.testing.allocator, arena, "sess-r", &first);
    const second = [_]types.Message{.{ .role = .user, .content = "the freshword lives here" }};
    replaceSession(io, std.testing.allocator, arena, "sess-r", &second);

    const gone = candidates(io, std.testing.allocator, arena, "staleword") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 0), gone.len);
    const hits = candidates(io, std.testing.allocator, arena, "freshword") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("sess-r", hits[0]);
}

test "removeSession forgets a session's text; other sessions keep theirs" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const saved_index_path = index_path;
    index_path = try testIndexPath(arena, &env);
    defer index_path = saved_index_path; // restore before env.deinit frees the path

    const gone = [_]types.Message{.{ .role = .user, .content = "the doomedword lives here" }};
    replaceSession(io, std.testing.allocator, arena, "sess-gone", &gone);
    const kept = [_]types.Message{.{ .role = .user, .content = "the survivorword lives here" }};
    replaceSession(io, std.testing.allocator, arena, "sess-kept", &kept);

    removeSession(arena, "sess-gone");

    const hits = candidates(io, std.testing.allocator, arena, "doomedword") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 0), hits.len);
    const still = candidates(io, std.testing.allocator, arena, "survivorword") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 1), still.len);
    try std.testing.expectEqualStrings("sess-kept", still[0]);
}

/// Row count for one session in the raw index table, so tests can tell an
/// append from a duplicate-inserting one.
fn indexedRowCount(arena: std.mem.Allocator, session_id: []const u8) !usize {
    var conn = try open(arena);
    defer conn.close();
    var stmt = try conn.prepare("SELECT COUNT(*) FROM session_fts WHERE session_id = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, session_id);
    if ((try stmt.step()) != .row) return error.TestUnexpectedResult;
    return @intCast(stmt.columnInt(0));
}

test "an appended turn indexes incrementally without duplicating earlier rows" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const saved_index_path = index_path;
    index_path = try testIndexPath(arena, &env);
    defer index_path = saved_index_path;

    const first = [_]types.Message{
        .{ .role = .user, .content = "first turn about lighthouses" },
        .{ .role = .assistant, .content = "" }, // empty content is never a row
    };
    replaceSession(io, std.testing.allocator, arena, "sess-inc", &first);
    try std.testing.expectEqual(@as(usize, 1), try indexedRowCount(arena, "sess-inc"));

    // The everyday save: same prefix, one more message. The prefix must not
    // be reinserted behind its already-indexed copy.
    const second = first ++ [_]types.Message{.{ .role = .assistant, .content = "second turn about giraffes" }};
    replaceSession(io, std.testing.allocator, arena, "sess-inc", &second);
    try std.testing.expectEqual(@as(usize, 2), try indexedRowCount(arena, "sess-inc"));

    const old = candidates(io, std.testing.allocator, arena, "lighthouses") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 1), old.len);
    const fresh = candidates(io, std.testing.allocator, arena, "giraffes") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 1), fresh.len);

    // An id reused after deletion rebuilds rather than appending onto
    // nothing.
    removeSession(arena, "sess-inc");
    replaceSession(io, std.testing.allocator, arena, "sess-inc", &first);
    try std.testing.expectEqual(@as(usize, 1), try indexedRowCount(arena, "sess-inc"));
}

test "same-count edited content fails the prefix check and rebuilds" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();
    const saved_index_path = index_path;
    index_path = try testIndexPath(arena, &env);
    defer index_path = saved_index_path;

    const original = [_]types.Message{.{ .role = .user, .content = "meeting moved to tuesday" }};
    replaceSession(io, std.testing.allocator, arena, "sess-edit", &original);
    const edited = [_]types.Message{.{ .role = .user, .content = "meeting moved to wednesday" }};
    replaceSession(io, std.testing.allocator, arena, "sess-edit", &edited);

    const stale = candidates(io, std.testing.allocator, arena, "tuesday") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 0), stale.len);
    const fresh = candidates(io, std.testing.allocator, arena, "wednesday") orelse return error.FtsUnavailable;
    try std.testing.expectEqual(@as(usize, 1), fresh.len);
    try std.testing.expectEqual(@as(usize, 1), try indexedRowCount(arena, "sess-edit"));
}
