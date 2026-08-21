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
;

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

/// Replaces a session's index rows: remove the old, insert one row per
/// message that has content. Fail-open: a missing index only costs speed.
pub fn replaceSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, session_id: []const u8, messages: []const types.Message) void {
    _ = io;
    _ = gpa;
    var conn = open(arena) catch return;
    defer conn.close();
    {
        var del = conn.prepare("DELETE FROM session_fts WHERE session_id = ?1;") catch return;
        defer del.finalize();
        del.bindText(1, session_id) catch return;
        _ = del.step() catch return;
    }
    var ins = conn.prepare("INSERT INTO session_fts (session_id, role, content) VALUES (?1, ?2, ?3);") catch return;
    defer ins.finalize();
    for (messages) |m| {
        const content = m.content orelse continue;
        if (content.len == 0) continue;
        ins.reset();
        ins.bindText(1, session_id) catch continue;
        ins.bindText(2, m.role.asStr()) catch continue;
        ins.bindText(3, content) catch continue;
        _ = ins.step() catch continue;
    }
}

/// Removes a deleted session's rows from the index: without this, the full
/// text of a conversation the operator deleted stays findable in
/// `state/session_fts.db` forever. Fail-open like the writer — a missing
/// index means there is nothing to forget.
pub fn removeSession(arena: std.mem.Allocator, session_id: []const u8) void {
    var conn = open(arena) catch return;
    defer conn.close();
    var del = conn.prepare("DELETE FROM session_fts WHERE session_id = ?1;") catch return;
    defer del.finalize();
    del.bindText(1, session_id) catch return;
    _ = del.step() catch return;
}

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
    var stmt = conn.prepare("SELECT DISTINCT session_id FROM session_fts WHERE session_fts MATCH ?1;") catch return null;
    defer stmt.finalize();
    stmt.bindText(1, quoted.items) catch return null;
    var out: std.ArrayList([]const u8) = .empty;
    while (true) {
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
