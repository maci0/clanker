//! Persistent session store: serializes conversations to
//! `state/sessions/<id>.json` under an arbitrary base directory.

const std = @import("std");
const json = std.json;
const types = @import("../llm/types.zig");
const log = @import("../util/log.zig");
const atomic_write = @import("../util/atomic_write.zig");

pub const Session = struct {
    id: []const u8,
    title: []const u8,
    messages: []const types.Message,
    created: i64,
    updated: i64,
    /// Which workspace this conversation belongs to. A folder, not a tag: a
    /// conversation is in exactly one, and "" means the default one, so a
    /// session written before workspaces existed needs no migration.
    workspace: []const u8 = "",
    /// Whether this chat is archived / hidden from the default listing.
    /// False absences still decode as false, so pre-archive sessions need no migration.
    archived: bool = false,
};

const store_dir = "state/sessions";

/// Session ids are path fragments, not arbitrary labels. Enforce the storage
/// boundary here even when a caller forgets its own input validation.
pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// Writes a session to `base_dir/state/sessions/<id>.json`.
pub fn saveSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, session: Session) !void {
    _ = arena;
    if (!validSessionId(session.id)) return error.InvalidSessionId;
    try base.createDirPath(io, store_dir);

    // Grows to fit the conversation rather than a fixed cap: a fixed buffer
    // silently failed (and callers `catch {}`'d the failure away) once a
    // long-context model's history crossed it, so the session simply stopped
    // being saved with no visible error.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s = json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };

    try s.beginObject();
    try s.objectField("id");
    try s.write(session.id);
    try s.objectField("title");
    try s.write(session.title);
    try s.objectField("created");
    try s.write(session.created);
    try s.objectField("updated");
    try s.write(session.updated);
    if (session.workspace.len > 0) {
        try s.objectField("workspace");
        try s.write(session.workspace);
    }
    if (session.archived) {
        try s.objectField("archived");
        try s.write(true);
    }
    try s.objectField("messages");
    try s.beginArray();
    for (session.messages) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role.asStr());
        if (m.content) |c| {
            try s.objectField("content");
            try s.write(c);
        }
        if (m.tool_calls) |calls| {
            try s.objectField("tool_calls");
            try s.beginArray();
            for (calls) |tc| {
                try s.beginObject();
                try s.objectField("id");
                try s.write(tc.id);
                try s.objectField("name");
                try s.write(tc.name);
                try s.objectField("arguments");
                try s.write(tc.arguments);
                try s.endObject();
            }
            try s.endArray();
        }
        if (m.tool_call_id) |tid| {
            try s.objectField("tool_call_id");
            try s.write(tid);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ store_dir, session.id });
    defer gpa.free(path);
    // Atomic: a reader (including this same process resuming after a
    // hot-reload restart) must never observe a session file truncated
    // mid-write.
    try atomic_write.writeFile(io, base, path, out.written());
}

const StoredToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const StoredMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const StoredToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const StoredSession = struct {
    id: []const u8,
    title: []const u8,
    created: i64,
    updated: i64,
    workspace: []const u8 = "",
    archived: bool = false,
    messages: []const StoredMessage = &.{},
};

/// Loads a session from `base_dir/state/sessions/<id>.json`.
pub fn loadSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) !Session {
    _ = gpa;
    if (!validSessionId(id)) return error.InvalidSessionId;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_dir, id });
    const raw = try base.readFileAlloc(io, path, arena, .limited(1 << 24));
    const stored = try json.parseFromSliceLeaky(StoredSession, arena, raw, .{ .ignore_unknown_fields = true });

    var messages: std.ArrayList(types.Message) = .empty;
    for (stored.messages) |sm| {
        var msg = types.Message{
            .role = try roleFromStr(sm.role),
            .content = sm.content,
            .tool_call_id = sm.tool_call_id,
        };
        if (sm.tool_calls) |calls| {
            var tc_list: std.ArrayList(types.ToolCall) = .empty;
            for (calls) |tc| try tc_list.append(arena, .{ .id = tc.id, .name = tc.name, .arguments = tc.arguments });
            msg.tool_calls = try tc_list.toOwnedSlice(arena);
        }
        try messages.append(arena, msg);
    }

    return .{
        .id = stored.id,
        .title = stored.title,
        .created = stored.created,
        .updated = stored.updated,
        .workspace = stored.workspace,
        .archived = stored.archived,
        .messages = try messages.toOwnedSlice(arena),
    };
}

/// Removes a saved conversation. Its execution graphs stay: they are the
/// record of runs that really happened, and are addressed by run id rather
/// than by session.
pub fn deleteSession(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) !void {
    if (!validSessionId(id)) return error.InvalidSessionId;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_dir, id });
    try base.deleteFile(io, path);
}

/// Forks a conversation: the same messages written back under a new id,
/// titled "fork of <old title>". A fork is a branch you can abandon without
/// losing the conversation it came from. Returns the new id (arena-owned).
pub fn forkSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) ![]const u8 {
    if (!validSessionId(id)) return error.InvalidSessionId;
    const s = try loadSession(io, gpa, arena, base, id);
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    // Nanosecond suffix keeps two forks of the same session distinct and
    // stays within the alphanumeric/dash alphabet validSessionId accepts.
    const new_id = try std.fmt.allocPrint(arena, "{s}-fork-{d}", .{ id, std.Io.Timestamp.now(io, .real).nanoseconds });
    try saveSession(io, gpa, arena, base, .{
        .id = new_id,
        .title = try std.fmt.allocPrint(arena, "fork of {s}", .{s.title}),
        .workspace = s.workspace,
        .messages = s.messages,
        .created = now,
        .updated = now,
    });
    return new_id;
}

/// The message index just past turn `n`'s answer: the Nth user message plus
/// everything up to and including the assistant message that completes the
/// turn (tool-call steps and tool results in between included). A turn
/// whose reply is still pending — a stopped run with no final assistant
/// content — cuts before its user message, so a branch never strands half a
/// turn. `n` is 1-based; past the last turn is `error.TurnOutOfRange`.
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

/// Branches a conversation at a turn: the messages through the end of turn
/// `turn_no` copied under a new id, titled "branch of <old title>". Turns
/// before the branch point stay shared context; nothing after it exists in
/// the branch yet, so continuing it explores a different direction without
/// touching the original — the per-turn branch a chat UI offers, as opposed
/// to `forkSession`'s whole-conversation copy. Returns the new id
/// (arena-owned).
pub fn branchSession(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
    turn_no: usize,
) ![]const u8 {
    const s = try loadSession(io, gpa, arena, base, id);
    const cutoff = try turnCutoff(s.messages, turn_no);
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    // Nanosecond suffix keeps two branches of the same session distinct and
    // stays within the alphanumeric/dash alphabet validSessionId accepts.
    const new_id = try std.fmt.allocPrint(arena, "{s}-branch-{d}", .{ id, std.Io.Timestamp.now(io, .real).nanoseconds });
    try saveSession(io, gpa, arena, base, .{
        .id = new_id,
        .title = try std.fmt.allocPrint(arena, "branch of {s}", .{s.title}),
        .workspace = s.workspace,
        .messages = s.messages[0..cutoff],
        .created = now,
        .updated = now,
    });
    return new_id;
}

/// Retitles a conversation in place, leaving its messages untouched.
///
/// Titles are otherwise derived from the first 60 characters of the opening
/// task, which is why a picker full of them reads like a list of prefixes.
pub fn renameSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8, title: []const u8) !void {
    const s = try loadSession(io, gpa, arena, base, id);
    try saveSession(io, gpa, arena, base, .{
        .id = s.id,
        .title = title,
        .workspace = s.workspace,
        .messages = s.messages,
        .created = s.created,
        .updated = s.updated,
    });
}

/// Enough of a session to list it without reading every message: what a
/// picker needs to show one row.
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

/// Lists every saved session, most recently updated first — the order a
/// picker wants, since the session you were just in is the one you are most
/// likely to return to. A file that cannot be read or parsed is skipped
/// rather than failing the whole listing: one corrupt session should not make
/// the others unreachable.
pub fn listSessions(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) ![]SessionMeta {
    var out: std.ArrayList(SessionMeta) = .empty;

    var dir = base.openDir(io, store_dir, .{ .iterate = true }) catch return out.toOwnedSlice(arena);
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ store_dir, entry.name }) catch continue;
        const raw = base.readFileAlloc(io, path, arena, .limited(1 << 24)) catch continue;
        const stored = json.parseFromSliceLeaky(StoredSession, arena, raw, .{ .ignore_unknown_fields = true }) catch continue;
        var bytes: usize = 0;
        for (stored.messages) |sm| {
            if (sm.content) |c| bytes += c.len;
            if (sm.tool_calls) |calls| {
                for (calls) |tc| bytes += tc.arguments.len;
            }
        }
        out.append(arena, .{
            .id = stored.id,
            .title = stored.title,
            .created = stored.created,
            .updated = stored.updated,
            .workspace = stored.workspace,
            .archived = stored.archived,
            .messages = stored.messages.len,
            .bytes = bytes,
        }) catch continue;
    }

    std.mem.sort(SessionMeta, out.items, {}, struct {
        fn newestFirst(_: void, a: SessionMeta, b: SessionMeta) bool {
            return a.updated > b.updated;
        }
    }.newestFirst);
    return out.toOwnedSlice(arena);
}

/// The most recently updated session's id, or null when none exist — what
/// `--continue` means, for both `clanker run` and the REPL.
pub fn latestSessionId(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) ?[]const u8 {
    const metas = listSessions(io, arena, base) catch return null;
    return if (metas.len > 0) metas[0].id else null;
}

/// The compaction budget a session is trimmed to before every save.
pub const max_session_tokens = 128 * 1024;

fn estimatedTokens(message: types.Message) usize {
    var bytes: usize = if (message.content) |content| content.len else 0;
    if (message.tool_calls) |calls| {
        for (calls) |call| bytes +|= call.arguments.len;
    }
    // Round up so short messages and short tool arguments are not free.
    return bytes / 4 + @intFromBool(bytes % 4 != 0);
}

/// Drops oldest non-system messages until the estimated token count fits under
/// `max_tokens` so long sessions auto-compact instead of exceeding the context
/// window. Token count is estimated as chars/4 (a rough heuristic).
pub fn compactMessages(messages: *std.ArrayList(types.Message), max_tokens: usize) void {
    var total: usize = 0;
    for (messages.items) |m| total +|= estimatedTokens(m);
    if (total <= max_tokens) return;
    // A single left-to-right compaction pass: `orderedRemove` per dropped
    // message shifts the whole tail, which is O(n^2) once a long session
    // needs many messages trimmed. Writing survivors back in place is O(n).
    var write: usize = 0;
    for (messages.items) |m| {
        if (total > max_tokens and m.role != .system) {
            total -|= estimatedTokens(m);
            continue;
        }
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

// ------------------------------------------------------------------- tests --

test "session store rejects ids that can escape its directory" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bad_id = "../../escaped";
    try std.testing.expectError(error.InvalidSessionId, saveSession(io, std.testing.allocator, arena, tmp.dir, .{
        .id = bad_id,
        .title = "bad",
        .messages = &.{},
        .created = 0,
        .updated = 0,
    }));
    try std.testing.expectError(error.InvalidSessionId, loadSession(io, std.testing.allocator, arena, tmp.dir, bad_id));
    try std.testing.expectError(error.InvalidSessionId, deleteSession(io, arena, tmp.dir, bad_id));
    try std.testing.expectError(error.InvalidSessionId, forkSession(io, std.testing.allocator, arena, tmp.dir, bad_id));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "escaped.json", .{}));
}

test "session load rejects an unknown persisted message role" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "state/sessions");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/sessions/bad-role.json", .data =
        \\{"id":"bad-role","title":"bad","created":0,"updated":0,"messages":[{"role":"operator","content":"do not reinterpret me"}]}
    });
    try std.testing.expectError(error.InvalidRole, loadSession(io, std.testing.allocator, arena, tmp.dir, "bad-role"));
}

test "compactMessages counts short content and tool-call arguments" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try messages.appendSlice(std.testing.allocator, &.{
        .{ .role = .system, .content = "system" },
        .{ .role = .user, .content = "abc" },
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "call-1",
            .name = "read",
            .arguments = "12345678",
        }} },
        .{ .role = .assistant, .content = "keep" },
    });

    compactMessages(&messages, 3);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
    try std.testing.expectEqualStrings("keep", messages.items[1].content.?);
}

test "compactMessages counts tool-call arguments toward the token estimate" {
    // An assistant message whose own content is absent but whose tool-call
    // arguments are long must estimate tokens from those arguments, the way
    // listSessions counts byte weight. Without it, a session made almost
    // entirely of tool calls would never compact no matter how long the
    // arguments got.
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try messages.append(std.testing.allocator, .{ .role = .system, .content = "sys" });
    try messages.append(std.testing.allocator, .{
        .role = .assistant,
        .tool_calls = &.{.{
            .id = "c1",
            .name = "read_file",
            .arguments = "aaaaaaaaaaaaaaaa", // 16 bytes → 4 tokens
        }},
    });
    try messages.append(std.testing.allocator, .{ .role = .user, .content = "bbbb" });

    // System (1) + tool call (4) + user (1) = 6 tokens. A budget of 4 evicts
    // the oldest non-system message — the 4-token tool call — and leaves
    // system + the 1-token user message. If arguments were not counted the
    // tool call would be free, the total would be 2 ≤ 4, and nothing would
    // be dropped.
    compactMessages(&messages, 4);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
    try std.testing.expectEqual(types.Role.user, messages.items[1].role);
    try std.testing.expectEqualStrings("bbbb", messages.items[1].content.?);
}

test "estimatedTokens rounds up so short messages are not free" {
    try std.testing.expectEqual(@as(usize, 1), estimatedTokens(.{ .role = .user, .content = "a" }));
    try std.testing.expectEqual(@as(usize, 1), estimatedTokens(.{ .role = .user, .content = "abcd" }));
    try std.testing.expectEqual(@as(usize, 2), estimatedTokens(.{ .role = .user, .content = "abcde" }));
    // A tool-call-only message contributes its arguments toward the token
    // estimate: 10 bytes -> ceil(10/4) = 3 tokens.
    const m = types.Message{ .role = .assistant, .tool_calls = &.{.{
        .id = "c",
        .name = "read",
        .arguments = "abcdefghij",
    }} };
    try std.testing.expectEqual(@as(usize, 3), estimatedTokens(m));
}

test "compactMessages preserves system messages even when they exceed the budget" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try messages.appendSlice(std.testing.allocator, &.{
        .{ .role = .system, .content = "a system prompt larger than this budget" },
        .{ .role = .user, .content = "remove me" },
    });

    compactMessages(&messages, 0);

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
}

test "latestSessionId picks the most recently updated session" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No store yet: null, not an error.
    try std.testing.expect(latestSessionId(io, arena, tmp.dir) == null);

    try saveSession(io, std.testing.allocator, arena, tmp.dir, .{
        .id = "older",
        .title = "t",
        .messages = &.{},
        .created = 100,
        .updated = 100,
    });
    try saveSession(io, std.testing.allocator, arena, tmp.dir, .{
        .id = "newer",
        .title = "t",
        .messages = &.{},
        .created = 50,
        .updated = 200,
    });
    try std.testing.expectEqualStrings("newer", latestSessionId(io, arena, tmp.dir).?);
}

test "session save/load round trip" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const session = Session{
        .id = "s1",
        .title = "Test session",
        .messages = &.{
            .{ .role = .system, .content = "sys" },
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = null, .tool_calls = &.{.{
                .id = "tc1",
                .name = "calc",
                .arguments = "{}",
            }} },
            .{ .role = .tool, .tool_call_id = "tc1", .content = "42" },
        },
        .created = 100,
        .updated = 200,
    };
    try saveSession(io, gpa, arena, tmp.dir, session);

    const loaded = try loadSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expectEqualStrings("s1", loaded.id);
    try std.testing.expectEqualStrings("Test session", loaded.title);
    try std.testing.expectEqual(@as(i64, 100), loaded.created);
    try std.testing.expectEqual(@as(i64, 200), loaded.updated);
    try std.testing.expectEqual(@as(usize, 4), loaded.messages.len);
    try std.testing.expectEqual(types.Role.system, loaded.messages[0].role);
    try std.testing.expectEqual(types.Role.assistant, loaded.messages[2].role);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages[2].tool_calls.?.len);
    try std.testing.expectEqualStrings("calc", loaded.messages[2].tool_calls.?[0].name);
    try std.testing.expectEqual(types.Role.tool, loaded.messages[3].role);
    try std.testing.expectEqualStrings("42", loaded.messages[3].content.?);
    try std.testing.expectEqualStrings("tc1", loaded.messages[3].tool_call_id.?);
}

test "a session larger than the old fixed 1MB buffer still saves and loads" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chunk = try arena.alloc(u8, 64 * 1024);
    @memset(chunk, 'x');
    var messages: std.ArrayList(types.Message) = .empty;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try messages.append(arena, .{ .role = .user, .content = chunk });
    }

    const session = Session{
        .id = "big",
        .title = "Big session",
        .messages = messages.items,
        .created = 1,
        .updated = 2,
    };
    try saveSession(io, gpa, arena, tmp.dir, session);

    const loaded = try loadSession(io, gpa, arena, tmp.dir, "big");
    try std.testing.expectEqual(@as(usize, 20), loaded.messages.len);
    try std.testing.expectEqualStrings(chunk, loaded.messages[19].content.?);
}

test "forkSession copies a conversation under a new id and leaves the original alone" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s1",
        .title = "Original",
        .messages = &.{
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = "hi there" },
        },
        .created = 100,
        .updated = 200,
    });

    const new_id = try forkSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expect(!std.mem.eql(u8, new_id, "s1"));

    const forked = try loadSession(io, gpa, arena, tmp.dir, new_id);
    try std.testing.expectEqualStrings(new_id, forked.id);
    try std.testing.expectEqualStrings("fork of Original", forked.title);
    try std.testing.expectEqual(@as(usize, 2), forked.messages.len);
    try std.testing.expectEqualStrings("hello", forked.messages[0].content.?);
    try std.testing.expectEqualStrings("hi there", forked.messages[1].content.?);

    // Two forks of the same session get distinct ids.
    const second_id = try forkSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expect(!std.mem.eql(u8, new_id, second_id));

    // The source conversation is untouched.
    const original = try loadSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expectEqualStrings("Original", original.title);
    try std.testing.expectEqual(@as(usize, 2), original.messages.len);

    // Forking a session that does not exist fails rather than inventing one.
    try std.testing.expectError(error.FileNotFound, forkSession(io, gpa, arena, tmp.dir, "nope"));
}

test "branchSession cuts the conversation at a turn and leaves the original alone" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s1",
        .title = "Original",
        .messages = &.{
            .{ .role = .system, .content = "shared context" },
            .{ .role = .user, .content = "u1" },
            .{ .role = .assistant, .tool_calls = &.{.{
                .id = "c1",
                .name = "read",
                .arguments = "{}",
            }} },
            .{ .role = .tool, .tool_call_id = "c1", .content = "result" },
            .{ .role = .assistant, .content = "a1" },
            .{ .role = .user, .content = "u2" },
            .{ .role = .assistant, .content = "a2" },
            .{ .role = .user, .content = "u3" },
            .{ .role = .assistant, .content = "a3" },
        },
        .created = 100,
        .updated = 200,
    });

    // Branch at turn 2: the tool round of turn 1 is fully included, and
    // nothing after turn 2 is.
    const new_id = try branchSession(io, gpa, arena, tmp.dir, "s1", 2);
    const branched = try loadSession(io, gpa, arena, tmp.dir, new_id);
    try std.testing.expectEqualStrings("branch of Original", branched.title);
    try std.testing.expectEqual(@as(usize, 7), branched.messages.len);
    try std.testing.expectEqualStrings("a2", branched.messages[branched.messages.len - 1].content.?);
    try std.testing.expectEqualStrings("shared context", branched.messages[0].content.?);

    // The source conversation is untouched, all nine messages.
    const original = try loadSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expectEqualStrings("Original", original.title);
    try std.testing.expectEqual(@as(usize, 9), original.messages.len);

    // Branching at the last turn copies the whole conversation.
    const whole = try branchSession(io, gpa, arena, tmp.dir, "s1", 3);
    const whole_session = try loadSession(io, gpa, arena, tmp.dir, whole);
    try std.testing.expectEqual(@as(usize, 9), whole_session.messages.len);

    // Two branches of the same session get distinct ids.
    const second_id = try branchSession(io, gpa, arena, tmp.dir, "s1", 1);
    try std.testing.expect(!std.mem.eql(u8, new_id, second_id));

    // Turn 0 and past-the-end are refused, not silently clamped.
    try std.testing.expectError(error.TurnOutOfRange, branchSession(io, gpa, arena, tmp.dir, "s1", 0));
    try std.testing.expectError(error.TurnOutOfRange, branchSession(io, gpa, arena, tmp.dir, "s1", 4));
    // A pending turn (user message with no answer) cuts before it instead.
    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s2",
        .title = "Pending",
        .messages = &.{
            .{ .role = .user, .content = "done turn" },
            .{ .role = .assistant, .content = "answered" },
            .{ .role = .user, .content = "in flight" },
        },
        .created = 100,
        .updated = 200,
    });
    const pending = try branchSession(io, gpa, arena, tmp.dir, "s2", 2);
    const pending_session = try loadSession(io, gpa, arena, tmp.dir, pending);
    try std.testing.expectEqual(@as(usize, 2), pending_session.messages.len);
    try std.testing.expectEqualStrings("answered", pending_session.messages[1].content.?);

    // Branching a session that does not exist fails rather than inventing one.
    try std.testing.expectError(error.FileNotFound, branchSession(io, gpa, arena, tmp.dir, "nope", 1));
}

test "listSessions reports the byte weight of each conversation" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s1",
        .title = "weighted",
        .messages = &.{
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = "hi there" },
        },
        .created = 1,
        .updated = 2,
    });

    const list = try listSessions(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("s1", list[0].id);
    // 5 + 8 bytes of message content.
    try std.testing.expectEqual(@as(usize, 13), list[0].bytes);
    try std.testing.expectEqual(@as(usize, 2), list[0].messages);

    // An empty store lists nothing rather than failing.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const empty = try listSessions(io, arena, tmp2.dir);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "listSessions counts tool-call argument bytes toward the session weight" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveSession(io, allocator, arena, tmp.dir, .{
        .id = "tool-weight",
        .title = "tool calls",
        .messages = &.{
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .tool_calls = &.{.{
                .id = "c1",
                .name = "read_file",
                .arguments = "{\"path\":\"build.zig\"}",
            }} },
        },
        .created = 1,
        .updated = 2,
    });

    const list = try listSessions(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    // "hello" (5) + the tool-call arguments (20) = 25 bytes of transcript weight.
    try std.testing.expectEqual(@as(usize, 25), list[0].bytes);
    try std.testing.expectEqual(@as(usize, 2), list[0].messages);
}

test "rename and delete change only the selected saved session" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const u8{ "first", "second" }) |id| {
        try saveSession(io, allocator, arena, tmp.dir, .{
            .id = id,
            .title = id,
            .messages = &.{.{ .role = .user, .content = "preserved" }},
            .created = 10,
            .updated = 20,
        });
    }

    try renameSession(io, allocator, arena, tmp.dir, "first", "renamed");
    const renamed = try loadSession(io, allocator, arena, tmp.dir, "first");
    try std.testing.expectEqualStrings("renamed", renamed.title);
    try std.testing.expectEqualStrings("preserved", renamed.messages[0].content.?);
    try std.testing.expectEqual(@as(i64, 10), renamed.created);
    try std.testing.expectEqual(@as(i64, 20), renamed.updated);
    try std.testing.expectEqualStrings("second", (try loadSession(io, allocator, arena, tmp.dir, "second")).title);

    try deleteSession(io, arena, tmp.dir, "first");
    try std.testing.expectError(error.FileNotFound, loadSession(io, allocator, arena, tmp.dir, "first"));
    try std.testing.expectEqualStrings("second", (try loadSession(io, allocator, arena, tmp.dir, "second")).id);
}

test "listSessions skips corrupt entries without hiding valid sessions" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveSession(io, allocator, arena, tmp.dir, .{
        .id = "valid",
        .title = "available",
        .messages = &.{},
        .created = 1,
        .updated = 2,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/sessions/corrupt.json", .data = "not json" });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/sessions/ignored.txt", .data = "not json" });

    const sessions = try listSessions(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("valid", sessions[0].id);
}

pub fn setArchived(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8, archived: bool) !void {
    var s = try loadSession(io, gpa, arena, base, id);
    s.archived = archived;
    try saveSession(io, gpa, arena, base, s);
}

/// Imports an OpenAI/OpenWebUI-style chat export into a new local session.
/// Accepts an array of {"role":"user"|"assistant","content":string} (unknown
/// roles/tools are skipped) so both providers' exports and our own
/// /api/sessions/<id> JSON can be pasted without conversion.
pub fn importChat(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, title: []const u8, messages_in: []const StoredMessage) ![]const u8 {
    var out: std.ArrayList(types.Message) = .empty;
    for (messages_in) |sm| {
        if (sm.content == null or sm.content.?.len == 0) continue;
        const role = roleFromStr(sm.role) catch continue;
        if (role != .user and role != .assistant) continue;
        try out.append(arena, .{ .role = role, .content = sm.content });
    }
    if (out.items.len == 0) return error.MissingField;
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    const new_id = try std.fmt.allocPrint(arena, "sess-{d}-{d}", .{ now, @rem(std.Io.Timestamp.now(io, .real).nanoseconds, 1000000) });
    try saveSession(io, gpa, arena, base, .{
        .id = new_id,
        .title = if (title.len > 0) title else "imported chat",
        .messages = try out.toOwnedSlice(arena),
        .created = now,
        .updated = now,
        .archived = false,
    });
    return new_id;
}

/// Moves a conversation to a workspace. "" is the default one.
pub fn setWorkspace(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
    workspace: []const u8,
) !void {
    var s = try loadSession(io, gpa, arena, base, id);
    s.workspace = workspace;
    try saveSession(io, gpa, arena, base, s);
}

test "a workspace survives a save and load" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveSession(io, allocator, arena, tmp.dir, .{
        .id = "ws-test",
        .title = "In a folder",
        .messages = &.{},
        .created = 1,
        .updated = 2,
        .workspace = "research",
    });
    const back = try loadSession(io, allocator, arena, tmp.dir, "ws-test");
    try std.testing.expectEqualStrings("research", back.workspace);

    // The default workspace is absence, so a session without one round-trips
    // to the empty string rather than to a literal name.
    try saveSession(io, allocator, arena, tmp.dir, .{
        .id = "ws-none",
        .title = "Loose",
        .messages = &.{},
        .created = 1,
        .updated = 2,
    });
    const loose = try loadSession(io, allocator, arena, tmp.dir, "ws-none");
    try std.testing.expectEqualStrings("", loose.workspace);
}

test "compactMessages keeps system messages and drops the oldest non-system ones" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);

    // Three non-system messages of 12 chars each estimate 3 tokens (chars/4),
    // plus one system message that must survive compaction.
    try messages.append(std.testing.allocator, .{ .role = .system, .content = "sys" });
    try messages.append(std.testing.allocator, .{ .role = .user, .content = "abcdefghijkl" });
    try messages.append(std.testing.allocator, .{ .role = .user, .content = "abcdefghijkl" });
    try messages.append(std.testing.allocator, .{ .role = .assistant, .content = "abcdefghijkl" });

    // Estimated total = 9 tokens; budget 4 drops the two oldest non-system
    // messages (6 tokens) and leaves system + the newest assistant message.
    compactMessages(&messages, 4);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("abcdefghijkl", messages.items[1].content.?);
}

test "compactMessages under a tiny budget still never drops the system message" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);

    try messages.append(std.testing.allocator, .{ .role = .system, .content = "sys" });
    try messages.append(std.testing.allocator, .{ .role = .user, .content = "abcdefghijkl" });

    compactMessages(&messages, 0);
    // Only the system message can survive a zero budget.
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
}

test "renameSession retitles in place and deleteSession removes the file" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s1",
        .title = "Old",
        .messages = &.{.{ .role = .user, .content = "hello" }},
        .created = 1,
        .updated = 2,
    });

    try renameSession(io, gpa, arena, tmp.dir, "s1", "New");
    const renamed = try loadSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expectEqualStrings("New", renamed.title);
    try std.testing.expectEqual(@as(usize, 1), renamed.messages.len);

    try deleteSession(io, arena, tmp.dir, "s1");
    try std.testing.expectError(error.FileNotFound, loadSession(io, gpa, arena, tmp.dir, "s1"));
}
test "setWorkspace moves a session into a workspace and back" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "ws-move",
        .title = "Move me",
        .messages = &.{},
        .created = 1,
        .updated = 2,
    });

    // Move into a workspace.
    try setWorkspace(io, gpa, arena, tmp.dir, "ws-move", "research");
    const moved = try loadSession(io, gpa, arena, tmp.dir, "ws-move");
    try std.testing.expectEqualStrings("research", moved.workspace);

    // Moving back to "" is the default workspace.
    try setWorkspace(io, gpa, arena, tmp.dir, "ws-move", "");
    const loose = try loadSession(io, gpa, arena, tmp.dir, "ws-move");
    try std.testing.expectEqualStrings("", loose.workspace);
}

test "listSessions orders by most recently updated" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "older",
        .title = "older",
        .messages = &.{},
        .created = 100,
        .updated = 100,
    });
    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "newer",
        .title = "newer",
        .messages = &.{},
        .created = 50,
        .updated = 200,
    });

    const list = try listSessions(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("newer", list[0].id);
    try std.testing.expectEqualStrings("older", list[1].id);
}

test "deleteSession on a missing session returns FileNotFound without touching the repo" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No session exists, so deletion must fail cleanly. Everything stays
    // inside the temporary dir: nothing in the checkout (e.g. state/) may be
    // created or modified, which is what keeps this test from interfering
    // with the git tool's deny checks in the eval suite.
    try std.testing.expectError(error.FileNotFound, deleteSession(io, arena, tmp.dir, "nope"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "state", .{}));
}

test "compactMessages is a no-op on an empty message list" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    compactMessages(&messages, 0);
    try std.testing.expectEqual(@as(usize, 0), messages.items.len);
}
