//! board: the shared Kanban board.
//!
//! This started as HTTP handlers in src/cli.zig, so the board was a thing only
//! the web UI could touch: a clanker could not read its own board, let alone
//! move a card on it. Then it was a tool with its own file, state/board.json,
//! which fixed the reach but left two stores for one idea — a room's todo list
//! held the same work item with a title, a claim and a closed flag, and the web
//! UI showed both panels side by side.
//!
//! There is one now, and it lives in the room's chat log. A card action is a
//! chat message (`@todo {...}`, see cards.zig), so the board replicates to
//! peers over the fan-out that already exists, resolves concurrent edits by
//! rules that do not depend on arrival order, and needs no file of its own. The
//! host appends and fans out; the folding and every rule about what a card is
//! happen here, inside the sandbox, because that is application logic and the
//! host's job is transport.
//!
//! An action message is also its own announcement: anyone subscribed to the
//! room sees the change without a second "something moved" message.
//!
//! Input:  {"op": "...", "room": "board", ...}   op defaults to config.op
//! Output: {"ok": true, "board": {"columns": [...], "cards": [...]}}
//!         add/create also returns "card_id": "<id>" for the card it just
//!         created (the chat message id, per `apply`), so a caller such as
//!         bugreport can hand the caller the new card without re-deriving it.
//!         A create that names a `goal` already mirrored by a live card
//!         returns that card instead of posting a second add: a retried
//!         POST and the web UI's goal mirror both converge on one card.

const std = @import("std");
const lib = @import("lib.zig");
const cards = @import("cards.zig");

/// The guest asks for history in pages because the host answers into a 64 KB
/// buffer, and a fold needs the whole log rather than its tail. The cap stops
/// a pathological log from looping forever; a board that reaches it is reported
/// rather than silently truncated, since a partial fold would quietly resurrect
/// deleted cards and lose moves. Owned by cards.zig (host-tested) so the guard
/// ships next to the tests that pin it.
const max_pages = cards.max_pages;
const pageCapExceeded = cards.pageCapExceeded;

/// The legacy room a board lives in when neither the caller nor the host names
/// one: the empty default workspace keeps `board` so today's log does not move
/// (RFC 0001). A non-empty workspace gets `ws:<id>` via the injected config.
const legacy_board_room = "board";

const Req = struct {
    op: []const u8 = "",
    room: ?[]const u8 = null,
    id: []const u8 = "",
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    column: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    deadline: ?i64 = null,
    who: ?[]const u8 = null,
    /// Manifested name for the assign field (web UI and kanban_update schema).
    /// Alias of `who`; either reassigns, and on create either stamps an initial
    /// assignment folded as if the add itself assigned.
    assignee: ?[]const u8 = null,
    text: ?[]const u8 = null,
    subtask: ?[]const u8 = null,
    subtask_id: ?[]const u8 = null,
    parent_subtask_id: ?[]const u8 = null,
    done: ?bool = null,
    on: ?[]const u8 = null,
    depends_on: ?[]const u8 = null,
    off: ?bool = null,
    what: ?[]const u8 = null,
    /// Id of the goal (state/goals.json) the card mirrors; "" unlinks on
    /// update. Set at creation by the web UI's goal->board mirroring.
    goal: ?[]const u8 = null,
    /// Goal-as-card fields, carried on create/update so a card can be the
    /// goal record (RFC 0001).
    completion_criterion: ?[]const u8 = null,
    proof: ?[]const u8 = null,
    stop_rule: ?[]const u8 = null,
    boundaries: ?[]const u8 = null,
    max_iterations: ?u32 = null,
    worktree: ?[]const u8 = null,
    labels: ?[]const cards.Label = null,
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    cost: ?f64 = null,
    run: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
};

const Config = struct { op: ?[]const u8 = null, room: ?[]const u8 = null };

const History = struct {
    ok: bool = false,
    messages: []const cards.Message = &.{},
    has_more: bool = false,
};

const Sent = struct {
    ok: bool = false,
    id: []const u8 = "",
    ts: i64 = 0,
};

/// Reads the room's whole log, oldest first, following `after` until a page
/// comes back empty. Messages are deduplicated by id: paging by timestamp can
/// hand back the boundary message twice, and folding a claim twice would be
/// harmless but folding a cost twice would not.
fn history(alloc: std.mem.Allocator, room: []const u8) ![]cards.Message {
    var all: std.ArrayList(cards.Message) = .empty;
    var seen: std.array_hash_map.String(void) = .empty;
    var after: i64 = 0;

    var pages_read: usize = 0;
    while (pages_read < max_pages) : (pages_read += 1) {
        var req: std.Io.Writer.Allocating = .init(alloc);
        var s = std.json.Stringify{ .writer = &req.writer };
        try s.beginObject();
        try s.objectField("op");
        try s.write("history");
        try s.objectField("room");
        try s.write(room);
        try s.objectField("after");
        try s.write(after);
        // Oldest-first is load-bearing, not cosmetic: this loop's only cursor
        // is `ts > after`, so a newest-first page would jump it past every
        // older message and fold a partial log with no error.
        try s.objectField("oldest");
        try s.write(true);
        try s.endObject();

        const raw = try lib.chat(req.written());
        const parsed = std.json.parseFromSliceLeaky(History, alloc, raw, .{ .ignore_unknown_fields = true }) catch
            return error.BadHistory;
        if (!parsed.ok) return error.BadHistory;

        var added: usize = 0;
        for (parsed.messages) |m| {
            const gop = try seen.getOrPut(alloc, m.id);
            if (gop.found_existing) continue;
            try all.append(alloc, m);
            if (m.ts > after) after = m.ts;
            added += 1;
        }
        // Pages arrive oldest-first (requested above), but the fold still
        // sorts at the end rather than assuming anything about order.
        if (added == 0 or parsed.messages.len == 0 or !parsed.has_more) break;
        // `has_more` is host-derived from an extra record, so a full final
        // page remains valid while a 65th page is an explicit, safe failure.
        if (pageCapExceeded(pages_read + 1, parsed.has_more)) return error.TooLarge;
    }

    std.mem.sort(cards.Message, all.items, {}, struct {
        fn lt(_: void, a: cards.Message, b: cards.Message) bool {
            if (a.ts != b.ts) return a.ts < b.ts;
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lt);
    return all.items;
}

/// Appends one action to the room. The message id becomes the card id for an
/// add, which is why the send's answer is returned rather than discarded.
fn apply(alloc: std.mem.Allocator, room: []const u8, act: cards.Action) !Sent {
    const text = try cards.encode(alloc, act);
    var req: std.Io.Writer.Allocating = .init(alloc);
    var s = std.json.Stringify{ .writer = &req.writer };
    try s.beginObject();
    try s.objectField("op");
    try s.write("send");
    try s.objectField("room");
    try s.write(room);
    try s.objectField("text");
    try s.write(text);
    try s.endObject();

    const raw = try lib.chat(req.written());
    return std.json.parseFromSliceLeaky(Sent, alloc, raw, .{ .ignore_unknown_fields = true }) catch error.BadSend;
}

/// The board as the web UI and an agent both read it: the fixed column set,
/// then every card. Re-derived from the log after a write rather than assumed,
/// because a concurrent claim from a peer may have won.
fn respond(out: *lib.Out, room: []const u8, list: []cards.Card, only_for: []const u8, card_id: ?[]const u8) !void {
    var w = lib.writer(out);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("room");
    try s.write(room);
    if (card_id) |cid| {
        try s.objectField("card_id");
        try s.write(cid);
    }
    try s.objectField("board");
    try s.beginObject();
    try s.objectField("columns");
    try s.beginArray();
    for (cards.columns) |c| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(c);
        try s.objectField("title");
        // Column ids are lowercase words; the title is the same word capitalised
        // rather than a second list to keep in step with the first.
        var titled: [32]u8 = undefined;
        const n = @min(c.len, titled.len);
        @memcpy(titled[0..n], c[0..n]);
        if (n > 0) titled[0] = std.ascii.toUpper(titled[0]);
        try s.write(titled[0..n]);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("cards");
    try s.beginArray();
    for (list) |c| {
        if (!cards.concerns(&c, only_for)) continue;
        try s.beginObject();
        try s.objectField("id");
        try s.write(c.id);
        try s.objectField("title");
        try s.write(c.title);
        try s.objectField("body");
        try s.write(c.body);
        try s.objectField("column");
        try s.write(c.column);
        try s.objectField("status");
        try s.write(c.status());
        try s.objectField("priority");
        try s.write(c.priority);
        try s.objectField("assignee");
        try s.write(c.assignee);
        try s.objectField("assigned_by");
        try s.write(c.assigned_by);
        try s.objectField("created_by");
        try s.write(c.created_by);
        try s.objectField("created");
        try s.write(c.ts);
        try s.objectField("deadline");
        try s.write(c.deadline);
        try s.objectField("goal");
        try s.write(c.goal);
        try s.objectField("completion_criterion");
        try s.write(c.completion_criterion);
        try s.objectField("proof");
        try s.write(c.proof);
        try s.objectField("stop_rule");
        try s.write(c.stop_rule);
        try s.objectField("boundaries");
        try s.write(c.boundaries);
        try s.objectField("max_iterations");
        if (c.max_iterations) |n| try s.print("{d}", .{n}) else try s.write(null);
        try s.objectField("worktree");
        try s.write(c.worktree);
        try s.objectField("labels");
        try s.write(c.labels);
        try s.objectField("subtasks");
        try s.write(c.subtasks);
        try s.objectField("depends_on");
        try s.write(c.depends_on);
        try s.objectField("blocked_by");
        try s.write(try cards.blockedBy(list, &c, lib.alloc));
        try s.objectField("log");
        try s.write(c.log);
        try s.objectField("usage");
        try s.write(c.usage);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
    lib.commit(out, &w);
}

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const req = std.json.parseFromSliceLeaky(Req, alloc, input, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "expected a JSON object");

    // The descriptor pins the op for a single-purpose tool (kanban_move and the
    // rest); the internal entry point the web UI calls names it in the request.
    const cfg = std.json.parseFromSliceLeaky(Config, alloc, lib.config(), .{ .ignore_unknown_fields = true }) catch Config{};
    const op = if (cfg.op) |o| o else if (req.op.len > 0) req.op else "list";
    // The project's `#general` room (`ws:<id>`, RFC 0001) when the host named
    // one; the legacy `board` room for the empty default workspace, so today's
    // log does not move.
    const default_room = if (cfg.room) |r| (if (r.len > 0) r else legacy_board_room) else legacy_board_room;
    const room = if (req.room) |r| (if (r.len > 0) r else default_room) else default_room;
    // A list can be narrowed to what one clanker is concerned with. It narrows
    // the answer, not the reach: everyone subscribed to the room holds the same
    // messages, so this is a view. Work that genuinely must not be seen belongs
    // in a room the wrong readers are not in.
    const only_for = if (std.mem.eql(u8, op, "list")) (req.who orelse "") else "";

    const msgs = history(alloc, room) catch |err| return lib.fail(out, switch (err) {
        // Make the failure actionable. The board is a chatroom, so a board
        // that cannot reach chatrooms for *either* reason says "disabled" and
        // nothing about what to do. Distinguish the two denials the host can
        // return: chatrooms switched off (a config the operator set, fix by
        // flipping the flag + restart) versus this board tool being denied
        // chat access (a code/version mismatch — e.g. the host binary predates
        // a tool rename — fix by rebuilding/restarting clanker). Reporting the
        // wrong one as a config problem is what sent an operator hunting for a
        // modules flag that was already on.
        error.SandboxDenied => "chatrooms are disabled, but the board is a chatroom — enable them to use the board: set modules.chatrooms = true (and chatrooms.on = true) in config.toml or config.local.toml, then restart clanker",
        error.NoAccess => "the board tool is denied chat access to its room (not the chatrooms module — that is on); this is a tool-permission / clanker-version mismatch, rebuild clanker and restart it",
        error.TooLarge => "this room's log no longer fits in one read; the board cannot be folded from a partial log",
        else => "could not read the board's room",
    });
    const list = try cards.derive(alloc, msgs);

    if (std.mem.eql(u8, op, "list")) return respond(out, room, list, only_for, null);

    // Everything else writes, and everything except create names a card. The op
    // is checked before the id so a request wrong in both ways is told the op is
    // not real: no id would have made it work.
    const known = [_][]const u8{
        "create",        "add",            "update",         "move",           "claim",
        "assign",        "close",          "delete",         "log",            "usage",
        "subtask_add",   "subtask_toggle", "subtask_remove", "subtask_depend", "depend_add",
        "depend_remove",
    };
    var ok_op = false;
    for (known) |k| {
        if (std.mem.eql(u8, op, k)) ok_op = true;
    }
    if (!ok_op) return lib.fail(out, "unknown op");

    if (std.mem.eql(u8, op, "create") or std.mem.eql(u8, op, "add")) {
        const title = std.mem.trim(u8, req.title orelse "", " \t\r\n");
        if (title.len == 0 or title.len > cards.max_title_len)
            return lib.fail(out, "title must be 1-512 characters");
        const body = req.body orelse "";
        if (body.len > cards.max_body_len) return lib.fail(out, "body is too long");
        if (req.column) |c| {
            if (!cards.validColumn(c)) return lib.fail(out, "no such column");
        }
        if (req.priority) |p| {
            if (!cards.validPriority(p)) return lib.fail(out, "priority must be low, normal or high");
        }
        // Manifest calls it `assignee`; empty means none. `who` is kept as an
        // alias so older callers that already sent it on create still work.
        const assignee: ?[]const u8 = blk: {
            const raw = req.assignee orelse req.who;
            break :blk if (raw) |a| (if (a.len > 0) a else null) else null;
        };
        // One live card per goal. The fold drops a second add with the same
        // goal, but posting it still fans a duplicate message to every peer;
        // returning the existing card here is the same answer without the
        // write. Two racing creates can both miss this check; the fold is
        // what makes them converge.
        if (req.goal) |gid| {
            if (gid.len > 0) {
                if (cards.liveByGoal(list, gid)) |existing| {
                    return respond(out, room, list, "", existing.id);
                }
            }
        }
        const sent = apply(alloc, room, .{
            .action = "add",
            .title = title,
            .body = if (body.len > 0) body else null,
            .column = req.column,
            .priority = req.priority,
            .deadline = req.deadline,
            .who = assignee,
            .goal = req.goal,
            .completion_criterion = req.completion_criterion,
            .proof = req.proof,
            .stop_rule = req.stop_rule,
            .boundaries = req.boundaries,
            .max_iterations = req.max_iterations,
            .worktree = req.worktree,
            .labels = req.labels,
        }) catch return lib.fail(out, "could not post the card to the room");
        return respond(out, room, try cards.derive(alloc, try history(alloc, room)), "", sent.id);
    }

    if (req.id.len == 0) return lib.fail(out, "which card? pass its id from kanban_list");
    if (cards.get(list, req.id) == null) return lib.fail(out, "no such card");

    // Aliases: the manifests and the web UI grew two names for two of these
    // fields before the models merged, and old callers should keep working.
    const subtask_id = req.subtask orelse req.subtask_id;
    const dep_id = req.on orelse req.depends_on;
    const run_id = req.run orelse req.run_id;

    const act: cards.Action = if (std.mem.eql(u8, op, "update")) blk: {
        if (req.title) |t| {
            const trimmed = std.mem.trim(u8, t, " \t\r\n");
            if (trimmed.len == 0 or trimmed.len > cards.max_title_len)
                return lib.fail(out, "title must be 1-512 characters");
        }
        if (req.body) |b| {
            if (b.len > cards.max_body_len) return lib.fail(out, "body is too long");
        }
        if (req.priority) |p| {
            if (!cards.validPriority(p)) return lib.fail(out, "priority must be low, normal or high");
        }
        if (req.column) |c| {
            if (!cards.validColumn(c)) return lib.fail(out, "no such column");
        }
        break :blk .{
            .action = "update",
            .todo = req.id,
            .title = req.title,
            .body = req.body,
            .column = req.column,
            .priority = req.priority,
            .deadline = req.deadline,
            // `who` is the manifest field; `assignee` is what the web UI sends.
            // Either reassigns, and "" clears.
            .who = req.who orelse req.assignee,
            .goal = req.goal,
            .completion_criterion = req.completion_criterion,
            .proof = req.proof,
            .stop_rule = req.stop_rule,
            .boundaries = req.boundaries,
            .max_iterations = req.max_iterations,
            .worktree = req.worktree,
            .labels = req.labels,
        };
    } else if (std.mem.eql(u8, op, "move")) blk: {
        const col = req.column orelse return lib.fail(out, "which column?");
        if (!cards.validColumn(col)) return lib.fail(out, "no such column");
        if (std.mem.eql(u8, col, cards.done_column) and !cards.checklistComplete(cards.get(list, req.id).?))
            return lib.fail(out, "finish every checklist item before moving this card to Done");
        break :blk .{ .action = "move", .todo = req.id, .column = col };
    } else if (std.mem.eql(u8, op, "claim"))
        .{ .action = "claim", .todo = req.id }
    else if (std.mem.eql(u8, op, "assign"))
        .{ .action = "assign", .todo = req.id, .who = req.who orelse "" }
    else if (std.mem.eql(u8, op, "close")) blk: {
        if (!cards.checklistComplete(cards.get(list, req.id).?))
            return lib.fail(out, "finish every checklist item before closing this card");
        break :blk .{ .action = "close", .todo = req.id };
    } else if (std.mem.eql(u8, op, "delete"))
        .{ .action = "delete", .todo = req.id }
    else if (std.mem.eql(u8, op, "subtask_add")) blk: {
        const text = std.mem.trim(u8, req.text orelse "", " \t\r\n");
        if (text.len == 0 or text.len > cards.max_title_len)
            return lib.fail(out, "subtask text must be 1-512 characters");
        if (req.parent_subtask_id) |parent| {
            const card = cards.get(list, req.id).?;
            if (!cards.hasSubtask(card, parent)) return lib.fail(out, "no such parent checklist item on this card");
        }
        break :blk .{ .action = "subtask_add", .todo = req.id, .text = text, .subtask = subtask_id, .parent = req.parent_subtask_id };
    } else if (std.mem.eql(u8, op, "subtask_toggle")) blk: {
        const sid = subtask_id orelse return lib.fail(out, "which subtask?");
        const card = cards.get(list, req.id).?;
        if (!cards.hasSubtask(card, sid)) return lib.fail(out, "no such checklist item on this card");
        if ((req.done orelse true) and !cards.checklistItemReady(card, sid))
            return lib.fail(out, "finish this checklist item's dependencies first");
        break :blk .{ .action = "subtask_toggle", .todo = req.id, .subtask = sid, .done = req.done orelse true };
    } else if (std.mem.eql(u8, op, "subtask_remove")) blk: {
        const sid = subtask_id orelse return lib.fail(out, "which subtask?");
        const card = cards.get(list, req.id).?;
        if (!cards.hasSubtask(card, sid)) return lib.fail(out, "no such checklist item on this card");
        break :blk .{ .action = "subtask_remove", .todo = req.id, .subtask = sid };
    } else if (std.mem.eql(u8, op, "subtask_depend")) blk: {
        const sid = subtask_id orelse return lib.fail(out, "which checklist item?");
        const on = dep_id orelse return lib.fail(out, "which checklist item should it wait on?");
        if (std.mem.eql(u8, sid, on)) return lib.fail(out, "a checklist item cannot wait on itself");
        const card = cards.get(list, req.id).?;
        if (!cards.hasSubtask(card, sid) or !cards.hasSubtask(card, on))
            return lib.fail(out, "checklist dependency must name two items on this card");
        if (!(req.off orelse false) and try cards.checklistReaches(lib.alloc, card, on, sid))
            return lib.fail(out, "checklist dependency would create a cycle");
        break :blk .{ .action = "subtask_depend", .todo = req.id, .subtask = sid, .on = on, .off = req.off orelse false };
    } else if (std.mem.eql(u8, op, "depend_add") or std.mem.eql(u8, op, "depend_remove")) blk: {
        const on = dep_id orelse return lib.fail(out, "which card does it wait on?");
        if (std.mem.eql(u8, on, req.id)) return lib.fail(out, "a card cannot wait on itself");
        if (cards.get(list, on) == null) return lib.fail(out, "no such card to depend on");
        break :blk .{
            .action = "depend",
            .todo = req.id,
            .on = on,
            .off = std.mem.eql(u8, op, "depend_remove"),
        };
    } else if (std.mem.eql(u8, op, "log")) blk: {
        const what = std.mem.trim(u8, req.what orelse req.text orelse "", " \t\r\n");
        if (what.len == 0 or what.len > cards.max_body_len)
            return lib.fail(out, "say what was done");
        break :blk .{ .action = "log", .todo = req.id, .what = what };
    } else blk: {
        // usage
        if (req.cost) |c| {
            if (!std.math.isFinite(c) or c < 0) return lib.fail(out, "cost must be a non-negative number");
        }
        break :blk .{
            .action = "usage",
            .todo = req.id,
            .prompt_tokens = req.prompt_tokens,
            .completion_tokens = req.completion_tokens,
            .cost = req.cost,
            .run = run_id,
        };
    };

    _ = apply(alloc, room, act) catch return lib.fail(out, "could not post the change to the room");
    return respond(out, room, try cards.derive(alloc, try history(alloc, room)), "", null);
}
