//! Shared todo lists across chatrooms: collaborative task management between
//! the agents in a room. There is no second transport and no second store —
//! a todo action is just a chat message in the room's log whose text is
//! `@todo {"action":...}`, so it rides the existing append + peer fan-out in
//! chatrooms.zig and every subscriber sees it. Current state is derived by
//! folding the room's log; nothing else is persisted.
//!
//! The log has no locking and peers may append the same messages in different
//! orders, so the fold must converge on every replica regardless of order:
//!   - adds are keyed by the creating message's unique id (the todo id);
//!   - claims race: the claim with the lowest (ts, id) wins, deterministically
//!     on message content rather than arrival order, so two agents claiming
//!     at once resolve to the same owner everywhere;
//!   - close is a latch (closed_by picked by the same lowest-(ts, id) rule).
//! Claims are folded even on a closed todo so replicas that saw the close
//! first do not diverge from replicas that saw the claim first.
//!
//! Actions in message text:
//!   @todo {"action":"add","title":"..."}     todo id := message id
//!   @todo {"action":"claim","todo":"<id>"}   claimant := message from
//!   @todo {"action":"close","todo":"<id>"}

const std = @import("std");
const chatrooms = @import("chatrooms.zig");

/// Message-text prefix marking a todo action. Kept human-readable so the
/// actions still make sense in plain chat_history output.
pub const marker = "@todo ";
pub const max_title_len = 512;

pub const Todo = struct {
    id: []const u8,
    title: []const u8,
    created_by: []const u8,
    ts: i64,
    claimed_by: []const u8 = "",
    claim_ts: i64 = 0,
    claim_id: []const u8 = "",
    closed: bool = false,
    closed_by: []const u8 = "",
    close_ts: i64 = 0,
    close_id: []const u8 = "",

    pub fn status(self: *const Todo) []const u8 {
        if (self.closed) return "closed";
        if (self.claimed_by.len > 0) return "claimed";
        return "open";
    }
};

// ----------------------------------------------------------------- encoding --

fn encodeAction(arena: std.mem.Allocator, action: []const u8, field: []const u8, value: []const u8) ![]const u8 {
    var buf: [8 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll(marker);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write(action);
    try s.objectField(field);
    try s.write(value);
    try s.endObject();
    return arena.dupe(u8, buf[0..w.end]);
}

pub fn encodeAdd(arena: std.mem.Allocator, title: []const u8) ![]const u8 {
    return encodeAction(arena, "add", "title", title);
}

pub fn encodeClaim(arena: std.mem.Allocator, todo_id: []const u8) ![]const u8 {
    return encodeAction(arena, "claim", "todo", todo_id);
}

pub fn encodeClose(arena: std.mem.Allocator, todo_id: []const u8) ![]const u8 {
    return encodeAction(arena, "close", "todo", todo_id);
}

// ------------------------------------------------------------------ deriving --

const Action = struct {
    action: []const u8 = "",
    title: []const u8 = "",
    todo: []const u8 = "",
};

fn parseAction(arena: std.mem.Allocator, text: []const u8) ?Action {
    if (!std.mem.startsWith(u8, text, marker)) return null;
    return std.json.parseFromSliceLeaky(Action, arena, text[marker.len..], .{ .ignore_unknown_fields = true }) catch null;
}

/// True when (ts_a, id_a) sorts before (ts_b, id_b) — the deterministic
/// winner rule for racing claims and closes.
fn wins(ts_a: i64, id_a: []const u8, ts_b: i64, id_b: []const u8) bool {
    if (ts_a != ts_b) return ts_a < ts_b;
    return std.mem.lessThan(u8, id_a, id_b);
}

/// Folds a room's messages into the current todo list. Two passes (adds
/// first, then claims/closes) so a claim that appears before its add in this
/// replica's log order still applies; combined with the lowest-(ts, id)
/// winner rule the result is independent of message order. Arena-owned,
/// sorted oldest-created first.
pub fn derive(arena: std.mem.Allocator, msgs: []const chatrooms.Message) ![]Todo {
    var by_id: std.StringArrayHashMapUnmanaged(Todo) = .empty;
    for (msgs) |m| {
        const act = parseAction(arena, m.text) orelse continue;
        if (!std.mem.eql(u8, act.action, "add")) continue;
        if (act.title.len == 0) continue;
        const gop = try by_id.getOrPut(arena, m.id);
        if (gop.found_existing) continue; // ids are unique; defensive
        gop.value_ptr.* = .{ .id = m.id, .title = act.title, .created_by = m.from, .ts = m.ts };
    }
    for (msgs) |m| {
        const act = parseAction(arena, m.text) orelse continue;
        if (std.mem.eql(u8, act.action, "claim")) {
            const t = by_id.getPtr(act.todo) orelse continue;
            if (t.claimed_by.len == 0 or wins(m.ts, m.id, t.claim_ts, t.claim_id)) {
                t.claimed_by = m.from;
                t.claim_ts = m.ts;
                t.claim_id = m.id;
            }
        } else if (std.mem.eql(u8, act.action, "close")) {
            const t = by_id.getPtr(act.todo) orelse continue;
            if (!t.closed or wins(m.ts, m.id, t.close_ts, t.close_id)) {
                t.closed = true;
                t.closed_by = m.from;
                t.close_ts = m.ts;
                t.close_id = m.id;
            }
        }
    }
    const out = try arena.alloc(Todo, by_id.count());
    var idx: usize = 0;
    var it = by_id.iterator();
    while (it.next()) |kv| {
        out[idx] = kv.value_ptr.*;
        idx += 1;
    }
    std.mem.sort(Todo, out, {}, struct {
        fn lt(_: void, a: Todo, b: Todo) bool {
            return wins(a.ts, a.id, b.ts, b.id);
        }
    }.lt);
    return out;
}

/// Reads the room's full log and derives its todo list. Arena-owned.
pub fn load(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, room: []const u8) ![]Todo {
    const msgs = try chatrooms.readHistory(base, io, gpa, arena, state_dir, room, 0, std.math.maxInt(usize));
    return derive(arena, msgs);
}

pub fn get(todos: []Todo, id: []const u8) ?*Todo {
    for (todos) |*t| {
        if (std.mem.eql(u8, t.id, id)) return t;
    }
    return null;
}

// ------------------------------------------------------------------- tests --

const t_alloc = std.testing.allocator;

fn msg(id: []const u8, from: []const u8, ts: i64, text: []const u8) chatrooms.Message {
    return .{ .room = "dev", .from = from, .text = text, .ts = ts, .id = id };
}

test "add + claim + close round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encodeAdd(arena, "ship the \"thing\"");
    const claim = try encodeClaim(arena, "m1");
    const close = try encodeClose(arena, "m1");
    const msgs = [_]chatrooms.Message{
        msg("m1", "alpha", 100, add),
        msg("m2", "beta", 101, claim),
        msg("m3", "beta", 102, close),
        msg("m4", "beta", 103, "plain chat, not a todo action"),
    };
    const todos = try derive(arena, &msgs);
    try std.testing.expectEqual(@as(usize, 1), todos.len);
    try std.testing.expectEqualStrings("m1", todos[0].id);
    try std.testing.expectEqualStrings("ship the \"thing\"", todos[0].title);
    try std.testing.expectEqualStrings("alpha", todos[0].created_by);
    try std.testing.expectEqualStrings("beta", todos[0].claimed_by);
    try std.testing.expect(todos[0].closed);
    try std.testing.expectEqualStrings("closed", todos[0].status());
}

test "concurrent claims resolve to the same winner in either log order" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encodeAdd(arena, "task");
    const claim = try encodeClaim(arena, "m1");
    // Same second — the message id breaks the tie.
    const a = msg("m2-a", "alpha", 200, claim);
    const b = msg("m2-b", "beta", 200, claim);

    const order1 = [_]chatrooms.Message{ msg("m1", "x", 100, add), a, b };
    const order2 = [_]chatrooms.Message{ msg("m1", "x", 100, add), b, a };
    const t1 = try derive(arena, &order1);
    const t2 = try derive(arena, &order2);
    try std.testing.expectEqualStrings("alpha", t1[0].claimed_by);
    try std.testing.expectEqualStrings("alpha", t2[0].claimed_by);
    try std.testing.expectEqualStrings("claimed", t1[0].status());
}

test "claim delivered before its add still applies" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encodeAdd(arena, "task");
    const claim = try encodeClaim(arena, "m1");
    const msgs = [_]chatrooms.Message{
        msg("m2", "beta", 101, claim), // fan-out beat the add to this replica
        msg("m1", "alpha", 100, add),
    };
    const todos = try derive(arena, &msgs);
    try std.testing.expectEqual(@as(usize, 1), todos.len);
    try std.testing.expectEqualStrings("beta", todos[0].claimed_by);
}

test "close is a latch and claims still fold after it" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encodeAdd(arena, "task");
    const close = try encodeClose(arena, "m1");
    const claim = try encodeClaim(arena, "m1");
    // Replica A saw close then claim; replica B saw claim then close.
    const order_a = [_]chatrooms.Message{ msg("m1", "x", 100, add), msg("m2", "alpha", 200, close), msg("m3", "beta", 150, claim) };
    const order_b = [_]chatrooms.Message{ msg("m1", "x", 100, add), msg("m3", "beta", 150, claim), msg("m2", "alpha", 200, close) };
    const ta = try derive(arena, &order_a);
    const tb = try derive(arena, &order_b);
    try std.testing.expect(ta[0].closed);
    try std.testing.expect(tb[0].closed);
    try std.testing.expectEqualStrings("beta", ta[0].claimed_by);
    try std.testing.expectEqualStrings("beta", tb[0].claimed_by);
    try std.testing.expectEqualStrings("alpha", ta[0].closed_by);
}

test "unknown ids and malformed actions are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]chatrooms.Message{
        msg("m1", "alpha", 100, "@todo {\"action\":\"claim\",\"todo\":\"nope\"}"),
        msg("m2", "alpha", 101, "@todo not even json"),
        msg("m3", "alpha", 102, "@todo {\"action\":\"add\",\"title\":\"\"}"),
    };
    const todos = try derive(arena, &msgs);
    try std.testing.expectEqual(@as(usize, 0), todos.len);
}

test "load derives from the chatroom log on disk" {
    var threaded = std.Io.Threaded.init(t_alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_mod = @import("../config.zig");
    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};
    cfg.chatrooms.max_history = 100;

    const add = try encodeAdd(arena, "from disk");
    try chatrooms.append(tmp.dir, io, t_alloc, arena, "", &cfg, msg("m1", "alpha", 100, add));
    const claim = try encodeClaim(arena, "m1");
    try chatrooms.append(tmp.dir, io, t_alloc, arena, "", &cfg, msg("m2", "beta", 101, claim));

    const todos = try load(tmp.dir, io, t_alloc, arena, "", "dev");
    try std.testing.expectEqual(@as(usize, 1), todos.len);
    try std.testing.expectEqualStrings("from disk", todos[0].title);
    try std.testing.expectEqualStrings("beta", todos[0].claimed_by);
}
