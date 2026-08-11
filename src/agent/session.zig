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
};

const store_dir = "state/sessions";

/// Writes a session to `base_dir/state/sessions/<id>.json`.
pub fn saveSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, session: Session) !void {
    _ = arena;
    try base.createDirPath(io, store_dir);

    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var w: std.Io.Writer = .fixed(buf);
    var s = json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };

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
    try atomic_write.writeFile(io, base, path, w.buffer[0..w.end]);
}

const StoredToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

const StoredMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const StoredToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

const StoredSession = struct {
    id: []const u8,
    title: []const u8,
    created: i64,
    updated: i64,
    workspace: []const u8 = "",
    messages: []const StoredMessage = &.{},
};

/// Loads a session from `base_dir/state/sessions/<id>.json`.
pub fn loadSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) !Session {
    _ = gpa;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_dir, id });
    const raw = try base.readFileAlloc(io, path, arena, .limited(1 << 24));
    const stored = try json.parseFromSliceLeaky(StoredSession, arena, raw, .{ .ignore_unknown_fields = true });

    var messages: std.ArrayList(types.Message) = .empty;
    for (stored.messages) |sm| {
        var msg = types.Message{
            .role = roleFromStr(sm.role),
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
        .messages = try messages.toOwnedSlice(arena),
    };
}

/// Removes a saved conversation. Its execution graphs stay: they are the
/// record of runs that really happened, and are addressed by run id rather
/// than by session.
pub fn deleteSession(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_dir, id });
    try base.deleteFile(io, path);
}

/// Forks a conversation: the same messages written back under a new id,
/// titled "fork of <old title>". A fork is a branch you can abandon without
/// losing the conversation it came from. Returns the new id (arena-owned).
pub fn forkSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) ![]const u8 {
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

fn roleFromStr(s: []const u8) types.Role {
    return if (std.mem.eql(u8, s, "system")) .system else if (std.mem.eql(u8, s, "user")) .user else if (std.mem.eql(u8, s, "assistant")) .assistant else if (std.mem.eql(u8, s, "tool")) .tool else .user;
}

// ------------------------------------------------------------------- tests --

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
