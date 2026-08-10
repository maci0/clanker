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
        .messages = try messages.toOwnedSlice(arena),
    };
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
