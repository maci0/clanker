//! Per-run private todo lists: a run's own scratch checklist, distinct from
//! the shared Kanban board (the `board` tool; see
//! docs/adrs/0002-private-todos-vs-shared-board.md). `Agent.run` attaches a
//! fresh list for every top-level run and detaches it on return; a nested
//! run gets its own from `subagent.runNested`. Private to one run and
//! held in memory only, never written to the chatroom log, never fanned out
//! to peers, and discarded when the run returns. What survives is a summary
//! appended to the sub-agent's final answer, so the parent can see how far a
//! multi-step run got even when it hit the iteration cap.
//!
//! Tool surface: the same todo_* tools as the shared lists. A todo_* call
//! without a "room" lands here when a list is attached (ck_chat routes it),
//! so an agent uses one vocabulary for both kinds of list. Ids are "p1",
//! "p2", ..., the p marks them private, so a model cannot confuse them with
//! the message-id keys of a shared room list.

const std = @import("std");

pub const max_title_len = 512;
/// A nested run has a 6-iteration budget; a list past this size is a runaway
/// loop, not a plan.
pub const max_items = 100;

pub const Item = struct {
    id: u32,
    /// Owned by List.alloc.
    title: []const u8,
    claimed: bool = false,
    closed: bool = false,

    pub fn status(self: *const Item) []const u8 {
        if (self.closed) return "closed";
        if (self.claimed) return "claimed";
        return "open";
    }
};

/// One run's list. Created by Agent.run or subagent.runNested on their arena
/// and handed to every tool sandbox of that run via Sandbox.private_todos;
/// no other run ever sees the pointer. Unsynchronized on purpose: runs
/// execute tools strictly sequentially (Agent.serial_tools on nested runs;
/// todo_* tools are sequential on every run), so two tool calls of the
/// same run never touch the list concurrently.
pub const List = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,
    next_id: u32 = 1,
    /// Bumped by every op that actually changes an item, so a watcher can tell
    /// "the list moved" from "the model called todo_list again" without
    /// diffing the whole thing. The agent loop uses it to decide whether to
    /// push a checklist event down a streaming run (src/cli.zig's
    /// runStreamTodos); a claim of an already-claimed item does not bump,
    /// because nothing changed.
    rev: u32 = 0,

    /// Frees the items and their titles. Unnecessary when `alloc` is an
    /// arena (the runNested case); tests use the testing allocator.
    pub fn deinit(self: *List) void {
        for (self.items.items) |it| self.alloc.free(it.title);
        self.items.deinit(self.alloc);
    }

    fn find(self: *List, id: []const u8) ?*Item {
        if (!std.mem.startsWith(u8, id, "p")) return null;
        const wanted = std.fmt.parseInt(u32, id[1..], 10) catch return null;
        for (self.items.items) |*it| {
            if (it.id == wanted) return it;
        }
        return null;
    }
};

fn fail(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
}

/// Applies one todo_* op to the private list and returns the response JSON,
/// arena-owned. Response shapes mirror ck_chat's shared-list responses so the
/// model sees one vocabulary; fields that carry no information on a
/// single-owner list (created_by, claimed_by, ts) are simply absent.
pub fn applyTodoOp(
    list: *List,
    arena: std.mem.Allocator,
    op: []const u8,
    title: ?[]const u8,
    todo_id: ?[]const u8,
) ![]const u8 {
    // Arena-backed allocating writer: the reply for a full list of long
    // titled items can exceed any fixed buffer (max_items * max_title_len
    // with JSON escaping ≈ 100 KB), and a fixed buffer would silently
    // truncate or panic on the largest legal list.
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };

    if (std.mem.eql(u8, op, "todo_add")) {
        const t = title orelse "";
        if (t.len == 0 or t.len > max_title_len) return fail(arena, "todo_add needs a \\\"title\\\" (max 512 chars)");
        if (list.items.items.len >= max_items) return fail(arena, "private todo list is full; close items instead of adding more");
        const id = list.next_id;
        list.next_id += 1;
        try list.items.append(list.alloc, .{ .id = id, .title = try list.alloc.dupe(u8, t) });
        list.rev += 1;
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("todo");
        try s.print("\"p{d}\"", .{id});
        try s.endObject();
        return arena.dupe(u8, out.written());
    } else if (std.mem.eql(u8, op, "todo_claim") or std.mem.eql(u8, op, "todo_close")) {
        const id = todo_id orelse "";
        if (id.len == 0) return fail(arena, "this op needs \\\"todo\\\" (an id from todo_list)");
        const it = list.find(id) orelse
            return fail(arena, "unknown todo id in your private list; call todo_list first");
        if (std.mem.eql(u8, op, "todo_claim")) {
            if (!it.closed and !it.claimed) {
                it.claimed = true;
                list.rev += 1;
            }
        } else {
            if (!it.closed) {
                it.closed = true;
                list.rev += 1;
            }
        }
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("todo");
        try s.write(id);
        try s.objectField("status");
        try s.write(it.status());
        if (std.mem.eql(u8, op, "todo_claim")) {
            // A private list has exactly one owner, so a claim never loses.
            try s.objectField("yours");
            try s.write(true);
        }
        try s.endObject();
        return arena.dupe(u8, out.written());
    } else if (std.mem.eql(u8, op, "todo_list")) {
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("todos");
        try writeTodoArray(&s, list);
        try s.endObject();
        return arena.dupe(u8, out.written());
    }
    return fail(arena, "unknown private todo op");
}

/// The `todos` array as the model and the browser both see it. Factored out so
/// `todo_list`'s reply and the streamed checklist event can never disagree
/// about field names or status spellings, one writer, two callers.
fn writeTodoArray(s: *std.json.Stringify, list: *List) !void {
    try s.beginArray();
    for (list.items.items) |*it| {
        try s.beginObject();
        try s.objectField("todo");
        try s.print("\"p{d}\"", .{it.id});
        try s.objectField("title");
        try s.write(it.title);
        try s.objectField("status");
        try s.write(it.status());
        try s.endObject();
    }
    try s.endArray();
}

/// The list as a bare JSON array, arena-owned, for a caller that frames it
/// itself (the /api/run stream's `todos` control event). Allocating rather than
/// fixed-buffer for the same reason `applyTodoOp` is: 100 items at 512 chars
/// each overflows any stack buffer worth having.
pub fn listJson(list: *List, arena: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try writeTodoArray(&s, list);
    return arena.dupe(u8, out.written());
}

/// Renders the list's final state for the parent, or "" when the run never
/// added anything (the common case; no list means no noise in the result).
pub fn summary(list: *const List, arena: std.mem.Allocator) ![]const u8 {
    if (list.items.items.len == 0) return "";

    var closed: usize = 0;
    for (list.items.items) |it| {
        if (it.closed) closed += 1;
    }
    // Worst case: max_items titles of max_title_len plus per-line framing.
    var buf: [128 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("[sub-agent todo list at return: {d}/{d} closed]", .{ closed, list.items.items.len });
    for (list.items.items) |it| {
        try w.print("\n- [{s}] p{d} {s}", .{ if (it.closed) "x" else " ", it.id, it.title });
    }
    return arena.dupe(u8, buf[0..w.end]);
}

// ------------------------------------------------------------------- tests --

const t_alloc = std.testing.allocator;

test "add, claim, close, list round-trip with private ids" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list = List{ .alloc = t_alloc };
    defer list.deinit();

    const added = try applyTodoOp(&list, arena, "todo_add", "read the file", null);
    try std.testing.expect(std.mem.find(u8, added, "\"todo\":\"p1\"") != null);
    _ = try applyTodoOp(&list, arena, "todo_add", "write the tests", null);

    const claimed = try applyTodoOp(&list, arena, "todo_claim", null, "p1");
    try std.testing.expect(std.mem.find(u8, claimed, "\"status\":\"claimed\"") != null);
    try std.testing.expect(std.mem.find(u8, claimed, "\"yours\":true") != null);

    const closed = try applyTodoOp(&list, arena, "todo_close", null, "p1");
    try std.testing.expect(std.mem.find(u8, closed, "\"status\":\"closed\"") != null);

    const listed = try applyTodoOp(&list, arena, "todo_list", null, null);
    try std.testing.expect(std.mem.find(u8, listed, "\"todo\":\"p1\"") != null);
    try std.testing.expect(std.mem.find(u8, listed, "\"title\":\"write the tests\"") != null);
    try std.testing.expect(std.mem.find(u8, listed, "\"status\":\"open\"") != null);
}

test "bad arguments answer ok:false instead of erroring" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list = List{ .alloc = t_alloc };
    defer list.deinit();

    const no_title = try applyTodoOp(&list, arena, "todo_add", null, null);
    try std.testing.expect(std.mem.find(u8, no_title, "\"ok\":false") != null);
    const unknown = try applyTodoOp(&list, arena, "todo_close", null, "p99");
    try std.testing.expect(std.mem.find(u8, unknown, "unknown todo id") != null);
    // A shared-list message id must not resolve against the private list.
    const shared_id = try applyTodoOp(&list, arena, "todo_claim", null, "m1");
    try std.testing.expect(std.mem.find(u8, shared_id, "\"ok\":false") != null);
}

test "summary reports progress and is empty for an unused list" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list = List{ .alloc = t_alloc };
    defer list.deinit();
    try std.testing.expectEqualStrings("", try summary(&list, arena));

    _ = try applyTodoOp(&list, arena, "todo_add", "step one", null);
    _ = try applyTodoOp(&list, arena, "todo_add", "step two", null);
    _ = try applyTodoOp(&list, arena, "todo_close", null, "p1");

    const sum = try summary(&list, arena);
    try std.testing.expect(std.mem.find(u8, sum, "1/2 closed") != null);
    try std.testing.expect(std.mem.find(u8, sum, "- [x] p1 step one") != null);
    try std.testing.expect(std.mem.find(u8, sum, "- [ ] p2 step two") != null);
}

test "todo_list reply for a full list of long escaped titles exceeds any fixed buffer" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list = List{ .alloc = t_alloc };
    defer list.deinit();

    // Titles of max length whose every char is a double-quote, so the JSON
    // escapes each to two bytes (\"): 100 items × ~1 KB each makes the
    // serialized list >64 KiB, the size of the old fixed reply buffer.
    const title = try arena.alloc(u8, max_title_len);
    @memset(title, '"');
    var i: usize = 0;
    while (i < max_items) : (i += 1) {
        _ = try applyTodoOp(&list, arena, "todo_add", title, null);
    }

    const listed = try applyTodoOp(&list, arena, "todo_list", null, null);
    try std.testing.expect(std.mem.find(u8, listed, "\"ok\":true") != null);
    // The first item's quoted title survives; it would be truncated/panicked
    // in a fixed buffer.
    try std.testing.expect(std.mem.find(u8, listed, "\\\"\\\"") != null);
    try std.testing.expect(std.mem.find(u8, listed, "\"p1\"") != null);
}

test "rev tracks real changes only, so a watcher is not woken by todo_list" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list = List{ .alloc = t_alloc };
    defer list.deinit();

    try std.testing.expectEqual(@as(u32, 0), list.rev);
    _ = try applyTodoOp(&list, arena, "todo_add", "read the file", null);
    try std.testing.expectEqual(@as(u32, 1), list.rev);

    // Reading the list is not a change.
    _ = try applyTodoOp(&list, arena, "todo_list", null, null);
    try std.testing.expectEqual(@as(u32, 1), list.rev);

    _ = try applyTodoOp(&list, arena, "todo_claim", null, "p1");
    try std.testing.expectEqual(@as(u32, 2), list.rev);
    // Re-claiming an item this run already holds changes nothing.
    _ = try applyTodoOp(&list, arena, "todo_claim", null, "p1");
    try std.testing.expectEqual(@as(u32, 2), list.rev);

    _ = try applyTodoOp(&list, arena, "todo_close", null, "p1");
    try std.testing.expectEqual(@as(u32, 3), list.rev);
    _ = try applyTodoOp(&list, arena, "todo_close", null, "p1");
    try std.testing.expectEqual(@as(u32, 3), list.rev);

    // A rejected op must not bump either: no title, no item, no change.
    _ = try applyTodoOp(&list, arena, "todo_add", "", null);
    try std.testing.expectEqual(@as(u32, 3), list.rev);
}

test "listJson is the bare array todo_list embeds, ready to splice into an event" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list = List{ .alloc = t_alloc };
    defer list.deinit();

    try std.testing.expectEqualStrings("[]", try listJson(&list, arena));

    _ = try applyTodoOp(&list, arena, "todo_add", "check the gate", null);
    _ = try applyTodoOp(&list, arena, "todo_add", "patch \"it\"", null);
    _ = try applyTodoOp(&list, arena, "todo_close", null, "p1");

    const json = try listJson(&list, arena);
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[json.len - 1] == ']');
    try std.testing.expectEqualStrings(
        "[{\"todo\":\"p1\",\"title\":\"check the gate\",\"status\":\"closed\"}," ++
            "{\"todo\":\"p2\",\"title\":\"patch \\\"it\\\"\",\"status\":\"open\"}]",
        json,
    );

    // The same array the model sees, so the browser and the model can never
    // be shown different ids, titles or status spellings.
    const listed = try applyTodoOp(&list, arena, "todo_list", null, null);
    try std.testing.expectEqualStrings("{\"ok\":true,\"todos\":" ++ "", listed[0.."{\"ok\":true,\"todos\":".len]);
    try std.testing.expect(std.mem.find(u8, listed, json) != null);
}

test "todo_add rejects titles over the max length" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list = List{ .alloc = t_alloc };
    defer list.deinit();

    const long_title = try arena.alloc(u8, max_title_len + 1);
    @memset(long_title, 'x');
    const result = try applyTodoOp(&list, arena, "todo_add", long_title, null);
    try std.testing.expect(std.mem.find(u8, result, "\"ok\":false") != null);
}
