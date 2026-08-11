//! board: the shared Kanban board at state/board.json.
//!
//! This lived in src/cli.zig as HTTP handlers, which meant the board was a
//! thing only the web UI could touch: a clanker could not read its own board,
//! let alone move a card on it, and four hundred lines of application logic sat
//! inside the HTTP layer. PRODUCT.md says an agent's reach is a policy decision
//! rather than an accident of what the harness links, and that the CLI and the
//! web UI describe the same state in the same terms. Both are true only if the
//! board is a tool.
//!
//! The HTTP endpoint now calls this the way /api/runs calls cmd_graph, so there
//! is one implementation, sandboxed, reachable by an agent and by the page.
//!
//! Input:  {"op": "...", ...}      op defaults to the manifest's config.op
//! Output: {"ok": true, "board": {...}}   the whole board after the change

const std = @import("std");
const lib = @import("lib.zig");

const board_path = "state/board.json";
const todos_path = "state/todos.json";

const Subtask = struct {
    id: []const u8,
    text: []const u8,
    done: bool = false,
};

const LogEntry = struct {
    ts: i64 = 0,
    who: []const u8 = "",
    what: []const u8 = "",
};

const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cost: f64 = 0,
    runs: []const []const u8 = &.{},
};

const Column = struct {
    id: []const u8,
    title: []const u8,
    wip: u32 = 0,
};

const Card = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8 = "",
    column: []const u8 = "backlog",
    order: i64 = 0,
    assignee: []const u8 = "",
    labels: []const []const u8 = &.{},
    priority: []const u8 = "normal",
    deadline: i64 = 0,
    created: i64 = 0,
    updated: i64 = 0,
    subtasks: []const Subtask = &.{},
    depends_on: []const []const u8 = &.{},
    log: []const LogEntry = &.{},
    usage: Usage = .{},
};

const Board = struct {
    columns: []const Column = &.{},
    cards: []const Card = &.{},
    announce_room: []const u8 = "board",
};

const default_columns = [_]Column{
    .{ .id = "backlog", .title = "Backlog" },
    .{ .id = "ready", .title = "Ready" },
    .{ .id = "doing", .title = "Doing", .wip = 3 },
    .{ .id = "review", .title = "Review" },
    .{ .id = "done", .title = "Done" },
};

const Req = struct {
    op: []const u8 = "",
    id: []const u8 = "",
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    column: ?[]const u8 = null,
    position: ?i64 = null,
    assignee: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    deadline: ?i64 = null,
    labels: ?[]const []const u8 = null,
    text: ?[]const u8 = null,
    subtask_id: ?[]const u8 = null,
    done: ?bool = null,
    depends_on: ?[]const u8 = null,
    who: ?[]const u8 = null,
    what: ?[]const u8 = null,
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    cost: ?f64 = null,
    run_id: ?[]const u8 = null,
};

fn validPriority(s: []const u8) bool {
    return std.mem.eql(u8, s, "low") or std.mem.eql(u8, s, "normal") or std.mem.eql(u8, s, "high");
}

fn columnExists(cols: []const Column, id: []const u8) bool {
    for (cols) |c| {
        if (std.mem.eql(u8, c.id, id)) return true;
    }
    return false;
}

/// Where a card lands when dropped at `want` among `count` cards. Odd values
/// interleave with the even ones `resequence` assigns. Clamped first: the value
/// comes from the caller, and `want * 2 - 1` at i64 max overflows.
fn slot(want: i64, count: usize) i64 {
    const limit: i64 = @intCast(@min(count, @as(usize, @intCast(std.math.maxInt(i32)))));
    const capped = @min(@max(want, 0), limit);
    return capped * 2 - 1;
}

fn cardLessThan(_: void, a: Card, b: Card) bool {
    const col = std.mem.order(u8, a.column, b.column);
    if (col != .eq) return col == .lt;
    return a.order < b.order;
}

/// Renumbers a column 0,1,2… so `order` stays a total order rather than a pile
/// of ties after an insert.
fn resequence(cards: []Card, column: []const u8) void {
    var n: i64 = 0;
    for (cards) |*c| {
        if (!std.mem.eql(u8, c.column, column)) continue;
        c.order = n;
        n += 1;
    }
}

/// Reads the board, seeding it on first use and carrying any state/todos.json
/// into the backlog so the checklist this replaced is not silently dropped.
fn load(alloc: std.mem.Allocator) Board {
    if (lib.fsRead(board_path)) |raw| {
        if (std.json.parseFromSliceLeaky(Board, alloc, raw, .{ .ignore_unknown_fields = true })) |b| {
            if (b.columns.len > 0) return b;
            return .{ .columns = &default_columns, .cards = b.cards, .announce_room = b.announce_room };
        } else |_| {}
    } else |_| {}

    var cards: std.ArrayList(Card) = .empty;
    if (lib.fsRead(todos_path)) |raw| {
        const OldTodo = struct { id: []const u8, text: []const u8, done: bool = false, created: i64 = 0 };
        if (std.json.parseFromSliceLeaky([]OldTodo, alloc, raw, .{ .ignore_unknown_fields = true })) |old| {
            for (old, 0..) |t, i| {
                cards.append(alloc, .{
                    .id = t.id,
                    .title = t.text,
                    .column = if (t.done) "done" else "backlog",
                    .order = @intCast(i),
                    .created = t.created,
                    .updated = t.created,
                }) catch {};
            }
        } else |_| {}
    } else |_| {}
    return .{ .columns = &default_columns, .cards = cards.items };
}

fn save(alloc: std.mem.Allocator, b: Board) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    try std.json.Stringify.value(b, .{}, &out.writer);
    try lib.fsWrite(board_path, out.written());
}

/// Tells the board's room what changed. A courtesy, never part of the write:
/// a room that cannot be reached must not fail an update that already
/// succeeded, so every failure here is swallowed on purpose.
fn announce(alloc: std.mem.Allocator, b: Board, action: []const u8, card: Card, detail: []const u8, actor: []const u8) void {
    if (b.announce_room.len == 0) return;
    var text: std.Io.Writer.Allocating = .init(alloc);
    text.writer.writeAll("@board ") catch return;
    var s = std.json.Stringify{ .writer = &text.writer };
    s.beginObject() catch return;
    s.objectField("action") catch return;
    s.write(action) catch return;
    s.objectField("card") catch return;
    s.write(card.id) catch return;
    s.objectField("title") catch return;
    s.write(card.title) catch return;
    s.objectField("column") catch return;
    s.write(card.column) catch return;
    s.objectField("by") catch return;
    s.write(actor) catch return;
    s.endObject() catch return;
    text.writer.writeAll(" ") catch return;
    text.writer.writeAll(detail) catch return;

    var req: std.Io.Writer.Allocating = .init(alloc);
    var r = std.json.Stringify{ .writer = &req.writer };
    r.beginObject() catch return;
    r.objectField("op") catch return;
    r.write("send") catch return;
    r.objectField("room") catch return;
    r.write(b.announce_room) catch return;
    r.objectField("text") catch return;
    r.write(text.written()) catch return;
    r.endObject() catch return;
    _ = lib.chat(req.written()) catch return;
}

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const req = std.json.parseFromSliceLeaky(Req, alloc, input, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "expected a JSON object");

    const loaded = load(alloc);
    var cards: std.ArrayList(Card) = .empty;
    try cards.appendSlice(alloc, loaded.cards);
    var b = Board{ .columns = loaded.columns, .cards = cards.items, .announce_room = loaded.announce_room };

    // The host stamps time; a guest has no clock of its own. Seconds, as an
    // integer, because every timestamp on the board is compared and sorted.
    const now: i64 = @intFromFloat(lib.nowSeconds());
    const actor = if (req.who) |w| w else "clanker";

    if (req.op.len == 0 or std.mem.eql(u8, req.op, "list")) {
        return respond(out, b);
    }

    if (std.mem.eql(u8, req.op, "create")) {
        const title = std.mem.trim(u8, req.title orelse "", " \t\r\n");
        if (title.len == 0 or title.len > 500) return lib.fail(out, "title must be 1-500 characters");
        const col = req.column orelse "backlog";
        if (!columnExists(b.columns, col)) return lib.fail(out, "no such column");
        if (req.priority) |pr| {
            if (!validPriority(pr)) return lib.fail(out, "priority must be low, normal or high");
        }
        var order: i64 = 0;
        for (cards.items) |c| {
            if (std.mem.eql(u8, c.column, col)) order += 1;
        }
        const id = try std.fmt.allocPrint(alloc, "c-{d}-{d}", .{ now, cards.items.len });
        var log0: std.ArrayList(LogEntry) = .empty;
        try log0.append(alloc, .{ .ts = now, .who = actor, .what = "created" });
        try cards.append(alloc, .{
            .id = id,
            .title = title,
            .body = req.body orelse "",
            .column = col,
            .order = order,
            .assignee = req.assignee orelse "",
            .priority = req.priority orelse "normal",
            .deadline = req.deadline orelse 0,
            .labels = req.labels orelse &.{},
            .created = now,
            .updated = now,
            .log = log0.items,
        });
        b.cards = cards.items;
        try save(alloc, b);
        const made = cards.items[cards.items.len - 1];
        announce(alloc, b, "created", made, try std.fmt.allocPrint(alloc, "{s} added \"{s}\" to {s}.", .{ actor, title, col }), actor);
        return respond(out, b);
    }

    // Every remaining op names one card, but the op is checked first: a request
    // with both a bad op and a bad id should be told the op is not real, since
    // no id would have made it work.
    const card_ops = [_][]const u8{
        "update",         "move",       "delete",        "subtask_add", "subtask_toggle",
        "subtask_remove", "depend_add", "depend_remove", "log",         "usage",
    };
    var known = false;
    for (card_ops) |name| {
        if (std.mem.eql(u8, req.op, name)) known = true;
    }
    if (!known) return lib.fail(out, "unknown op");

    var at: ?usize = null;
    for (cards.items, 0..) |c, i| {
        if (std.mem.eql(u8, c.id, req.id)) at = i;
    }
    const idx = at orelse return lib.fail(out, "no such card");
    const card = &cards.items[idx];

    var announce_action: []const u8 = "";
    var announce_detail: []const u8 = "";
    var moved_from: ?[]const u8 = null;
    var moved_to: ?[]const u8 = null;

    if (std.mem.eql(u8, req.op, "update")) {
        if (req.title) |t| {
            const trimmed = std.mem.trim(u8, t, " \t\r\n");
            if (trimmed.len == 0 or trimmed.len > 500) return lib.fail(out, "title must be 1-500 characters");
            card.title = trimmed;
        }
        if (req.body) |v| card.body = v;
        if (req.assignee) |v| card.assignee = v;
        if (req.deadline) |v| card.deadline = v;
        if (req.labels) |v| card.labels = v;
        if (req.priority) |pr| {
            if (!validPriority(pr)) return lib.fail(out, "priority must be low, normal or high");
            card.priority = pr;
        }
        // Assignment and deadlines change whether someone else should act;
        // notes and titles do not, and a board that announces every keystroke
        // is a board people mute.
        if (req.assignee) |who| {
            announce_action = "assigned";
            announce_detail = if (who.len > 0)
                try std.fmt.allocPrint(alloc, "{s} assigned \"{s}\" to {s}.", .{ actor, card.title, who })
            else
                try std.fmt.allocPrint(alloc, "{s} unassigned \"{s}\".", .{ actor, card.title });
        } else if (req.deadline != null) {
            announce_action = "deadline";
            announce_detail = try std.fmt.allocPrint(alloc, "{s} set a deadline on \"{s}\".", .{ actor, card.title });
        }
    } else if (std.mem.eql(u8, req.op, "move")) {
        const col = req.column orelse card.column;
        if (!columnExists(b.columns, col)) return lib.fail(out, "no such column");
        const from = card.column;
        card.column = col;
        const want = req.position orelse -1;
        card.order = if (want < 0) std.math.maxInt(i64) else slot(want, cards.items.len);
        var entry: std.ArrayList(LogEntry) = .empty;
        try entry.appendSlice(alloc, card.log);
        try entry.append(alloc, .{ .ts = now, .who = actor, .what = try std.fmt.allocPrint(alloc, "moved to {s}", .{col}) });
        card.log = entry.items;
        announce_action = "moved";
        announce_detail = try std.fmt.allocPrint(alloc, "{s} moved \"{s}\" from {s} to {s}.", .{ actor, card.title, from, col });
        moved_from = from;
        moved_to = col;
    } else if (std.mem.eql(u8, req.op, "delete")) {
        const gone = cards.orderedRemove(idx);
        b.cards = cards.items;
        try save(alloc, b);
        announce(alloc, b, "deleted", gone, try std.fmt.allocPrint(alloc, "{s} deleted \"{s}\".", .{ actor, gone.title }), actor);
        return respond(out, b);
    } else if (std.mem.eql(u8, req.op, "subtask_add")) {
        const text = std.mem.trim(u8, req.text orelse "", " \t\r\n");
        if (text.len == 0 or text.len > 500) return lib.fail(out, "subtask text must be 1-500 characters");
        var subs: std.ArrayList(Subtask) = .empty;
        try subs.appendSlice(alloc, card.subtasks);
        try subs.append(alloc, .{
            .id = try std.fmt.allocPrint(alloc, "s-{d}-{d}", .{ now, subs.items.len }),
            .text = text,
        });
        card.subtasks = subs.items;
    } else if (std.mem.eql(u8, req.op, "subtask_toggle") or std.mem.eql(u8, req.op, "subtask_remove")) {
        const sid = req.subtask_id orelse return lib.fail(out, "missing subtask_id");
        var subs: std.ArrayList(Subtask) = .empty;
        var hit = false;
        for (card.subtasks) |s| {
            if (!std.mem.eql(u8, s.id, sid)) {
                try subs.append(alloc, s);
                continue;
            }
            hit = true;
            if (std.mem.eql(u8, req.op, "subtask_remove")) continue;
            var updated = s;
            updated.done = req.done orelse !s.done;
            try subs.append(alloc, updated);
        }
        if (!hit) return lib.fail(out, "no such subtask");
        card.subtasks = subs.items;
    } else if (std.mem.eql(u8, req.op, "depend_add") or std.mem.eql(u8, req.op, "depend_remove")) {
        const dep = req.depends_on orelse return lib.fail(out, "missing depends_on");
        if (std.mem.eql(u8, dep, card.id)) return lib.fail(out, "a card cannot depend on itself");
        var deps: std.ArrayList([]const u8) = .empty;
        var present = false;
        for (card.depends_on) |d| {
            if (std.mem.eql(u8, d, dep)) {
                present = true;
                if (std.mem.eql(u8, req.op, "depend_remove")) continue;
            }
            try deps.append(alloc, d);
        }
        if (std.mem.eql(u8, req.op, "depend_add") and !present) {
            var exists = false;
            for (cards.items) |c| {
                if (std.mem.eql(u8, c.id, dep)) exists = true;
            }
            if (!exists) return lib.fail(out, "no such card to depend on");
            try deps.append(alloc, dep);
        }
        card.depends_on = deps.items;
    } else if (std.mem.eql(u8, req.op, "log")) {
        const what = std.mem.trim(u8, req.what orelse "", " \t\r\n");
        if (what.len == 0 or what.len > 2000) return lib.fail(out, "log text must be 1-2000 characters");
        var entry: std.ArrayList(LogEntry) = .empty;
        try entry.appendSlice(alloc, card.log);
        try entry.append(alloc, .{ .ts = now, .who = actor, .what = what });
        card.log = entry.items;
        announce_action = "logged";
        announce_detail = try std.fmt.allocPrint(alloc, "{s} on \"{s}\": {s}", .{ actor, card.title, what });
    } else if (std.mem.eql(u8, req.op, "usage")) {
        // Accrued, not replaced: a card is worked on by more than one run.
        // Saturating, because the addends come from the caller.
        card.usage.prompt_tokens +|= req.prompt_tokens orelse 0;
        card.usage.completion_tokens +|= req.completion_tokens orelse 0;
        const add_cost = req.cost orelse 0;
        if (std.math.isFinite(add_cost)) card.usage.cost += add_cost;
        if (req.run_id) |rid| {
            var runs: std.ArrayList([]const u8) = .empty;
            var seen = false;
            for (card.usage.runs) |r| {
                try runs.append(alloc, r);
                if (std.mem.eql(u8, r, rid)) seen = true;
            }
            if (!seen) try runs.append(alloc, rid);
            card.usage.runs = runs.items;
        }
    } else {
        return lib.fail(out, "unknown op");
    }

    card.updated = now;
    const changed = card.*;
    // Sorting reorders the array `card` points into, so it happens only after
    // every write to the card is done.
    if (moved_to) |to| {
        std.mem.sort(Card, cards.items, {}, cardLessThan);
        resequence(cards.items, to);
        if (!std.mem.eql(u8, moved_from.?, to)) resequence(cards.items, moved_from.?);
    }
    b.cards = cards.items;
    try save(alloc, b);
    if (announce_action.len > 0) announce(alloc, b, announce_action, changed, announce_detail, actor);
    return respond(out, b);
}

fn respond(out: *lib.Out, b: Board) !void {
    var w = lib.writer(out);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("board");
    try s.write(b);
    try s.endObject();
    lib.commit(out, &w);
}

test slot {
    try std.testing.expectEqual(@as(i64, -1), slot(0, 5));
    try std.testing.expectEqual(@as(i64, 9), slot(5, 5));
    try std.testing.expectEqual(@as(i64, 9), slot(1000, 5));
    // The value that overflowed and killed the server when this was native.
    try std.testing.expectEqual(@as(i64, 9), slot(std.math.maxInt(i64), 5));
    try std.testing.expectEqual(@as(i64, -1), slot(std.math.minInt(i64), 5));
}

test validPriority {
    try std.testing.expect(validPriority("high"));
    try std.testing.expect(!validPriority("urgent"));
}
