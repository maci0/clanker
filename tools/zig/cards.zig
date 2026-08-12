//! Shared work items ("cards") across chatrooms: the one model for work that
//! more than one clanker can see. Pure: it folds a room's messages into cards
//! and encodes the actions that change them, and it touches neither the host
//! nor the filesystem, so tools/zig/board.zig runs it inside the sandbox while
//! `zig build test` runs its tests on the host. This file was src/peers/todos.zig, which held
//! a title, a claim and a closed flag; the Kanban board held the same work item
//! again with columns, subtasks, dependencies, a log and a cost, in its own
//! file. Two stores for one concept, and the web UI showed both panels side by
//! side. They are now one: a board card *is* a room todo with more fields.
//!
//! There is still no second transport and no second store. A card action is a
//! chat message in the room's log whose text is `@todo {"action":...}`, so it
//! rides the existing append + peer fan-out in chatrooms.zig and every
//! subscriber sees it. Current state is derived by folding the room's log;
//! nothing else is persisted. That is what the board gained by merging: cards
//! replicate to peers, which state/board.json never did.
//!
//! The marker stays `@todo ` so logs written before the merge keep folding, and
//! an action message is its own announcement: a subscriber watching the room
//! sees the change without a second "something moved" message being sent.
//!
//! The log has no locking and peers may append the same messages in different
//! orders, so the fold must converge on every replica regardless of order.
//! Three rules, picked per field by what the field is for:
//!   - claim races: lowest (ts, id) wins. A claim is a mutex, so the first one
//!     takes it and a later claimant is told it lost.
//!   - edits (title, body, column, priority, deadline, assign, subtask ticks,
//!     dependency add/remove): highest (ts, id) wins. Last writer wins is what
//!     an edit means, and it is decided on message content rather than arrival
//!     order so replicas agree.
//!   - log entries and cost: grow-only. Entries union by message id, tokens and
//!     dollars sum. Re-folding the same log twice cannot double-count because
//!     each contribution is one message.
//! `closed` is gone: `column` is the only status, and close folds as
//! `column := "done"`. A board has to be able to move work back out of done,
//! which the old latch made unrepresentable.
//!
//! Actions in message text:
//!   @todo {"action":"add","title":"...","body":"...","column":"...",
//!          "priority":"...","deadline":0,"who":"...","goal":"..."}
//!                                               card id := message id;
//!                                               "who" assigns at creation
//!   @todo {"action":"update","todo":"<id>","title":"...","body":"...",
//!          "priority":"...","deadline":0,"goal":"..."}
//!   @todo {"action":"move","todo":"<id>","column":"doing"}
//!   @todo {"action":"claim","todo":"<id>"}      assignee := message from
//!   @todo {"action":"assign","todo":"<id>","who":"..."}   "" clears it
//!   @todo {"action":"close","todo":"<id>"}      column := "done"
//!   @todo {"action":"subtask_add","todo":"<id>","text":"..."}
//!   @todo {"action":"subtask_toggle","todo":"<id>","subtask":"<id>","done":true}
//!   @todo {"action":"subtask_remove","todo":"<id>","subtask":"<id>"}
//!   @todo {"action":"depend","todo":"<id>","on":"<id>","off":false}
//!   @todo {"action":"delete","todo":"<id>"}     a tombstone, never undone
//!   @todo {"action":"log","todo":"<id>","what":"..."}
//!   @todo {"action":"usage","todo":"<id>","prompt_tokens":0,
//!          "completion_tokens":0,"cost":0.0,"run":"<run id>"}

const std = @import("std");

/// One message from a room's log. Mirrors src/peers/chatrooms.zig's Message;
/// declared here so the fold depends on nothing but std and can be tested on
/// the host target rather than only inside a wasm sandbox.
pub const Message = struct {
    room: []const u8 = "",
    from: []const u8,
    text: []const u8,
    ts: i64,
    id: []const u8,
};

/// Message-text prefix marking a card action. Kept human-readable so the
/// actions still make sense in plain chat_history output.
pub const marker = "@todo ";
pub const max_title_len = 512;
pub const max_body_len = 8 * 1024;

/// The columns every room's board has. Not per-room state: a column set that
/// replicated would need its own convergence rules for a value no caller has
/// asked to change, so the workflow is fixed and the cards move through it.
pub const columns = [_][]const u8{ "backlog", "ready", "doing", "review", "done", "archive" };
pub const default_column = "backlog";
pub const done_column = "done";

pub fn validColumn(id: []const u8) bool {
    for (columns) |c| {
        if (std.mem.eql(u8, c, id)) return true;
    }
    return false;
}

pub fn validPriority(p: []const u8) bool {
    return std.mem.eql(u8, p, "low") or std.mem.eql(u8, p, "normal") or std.mem.eql(u8, p, "high");
}

/// When a field was last written, by which message. Two writes are ordered by
/// timestamp, and same-timestamp writes by message id, so every replica picks
/// the same winner no matter what order the messages arrived in.
const Stamp = struct {
    ts: i64 = 0,
    id: []const u8 = "",

    /// Whether an incoming write at (ts, id) is later than this one.
    fn beaten(self: Stamp, ts: i64, id: []const u8) bool {
        if (ts != self.ts) return ts > self.ts;
        return std.mem.lessThan(u8, self.id, id);
    }
};

pub const Subtask = struct {
    id: []const u8,
    text: []const u8,
    done: bool = false,
};

pub const LogEntry = struct {
    ts: i64 = 0,
    who: []const u8 = "",
    what: []const u8 = "",
};

pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cost: f64 = 0,
    runs: []const []const u8 = &.{},
};

pub const Card = struct {
    id: []const u8,
    title: []const u8,
    created_by: []const u8,
    ts: i64,
    body: []const u8 = "",
    column: []const u8 = default_column,
    priority: []const u8 = "normal",
    assignee: []const u8 = "",
    /// Who put it on them. Self-assignment through `claim` names the claimant
    /// twice, which is the honest answer: nobody handed them the work.
    assigned_by: []const u8 = "",
    deadline: i64 = 0,
    /// Id of the goal (state/goals.json) this card mirrors, or "" when the
    /// card is nobody's mirror. The web UI keeps a goal and its board card in
    /// step by this link; it folds like any other edit (last writer wins).
    goal: []const u8 = "",
    subtasks: []const Subtask = &.{},
    depends_on: []const []const u8 = &.{},
    log: []const LogEntry = &.{},
    usage: Usage = .{},

    /// The three words the todo tools have always answered with, now read off
    /// the column instead of a separate flag. Archived work is also closed:
    /// archive changes retention/visibility, not whether the work is pending.
    pub fn status(self: *const Card) []const u8 {
        if (std.mem.eql(u8, self.column, done_column) or std.mem.eql(u8, self.column, "archive")) return "closed";
        if (self.assignee.len > 0) return "claimed";
        return "open";
    }
};

// ----------------------------------------------------------------- encoding --

/// Every field an action can carry. Encoded with null fields omitted, so a
/// message says only what it changes and an absent field is "leave it".
pub const Action = struct {
    action: []const u8 = "",
    todo: ?[]const u8 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    column: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    deadline: ?i64 = null,
    who: ?[]const u8 = null,
    text: ?[]const u8 = null,
    subtask: ?[]const u8 = null,
    done: ?bool = null,
    on: ?[]const u8 = null,
    off: ?bool = null,
    what: ?[]const u8 = null,
    goal: ?[]const u8 = null,
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    cost: ?f64 = null,
    run: ?[]const u8 = null,
};

pub fn encode(arena: std.mem.Allocator, act: Action) ![]const u8 {
    var buf: [max_body_len + 4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll(marker);
    try std.json.Stringify.value(act, .{ .emit_null_optional_fields = false }, &w);
    return arena.dupe(u8, buf[0..w.end]);
}

pub fn encodeAdd(arena: std.mem.Allocator, title: []const u8) ![]const u8 {
    return encode(arena, .{ .action = "add", .title = title });
}

pub fn encodeClaim(arena: std.mem.Allocator, card_id: []const u8) ![]const u8 {
    return encode(arena, .{ .action = "claim", .todo = card_id });
}

pub fn encodeClose(arena: std.mem.Allocator, card_id: []const u8) ![]const u8 {
    return encode(arena, .{ .action = "close", .todo = card_id });
}

// ------------------------------------------------------------------ deriving --

fn parseAction(arena: std.mem.Allocator, text: []const u8) ?Action {
    if (!std.mem.startsWith(u8, text, marker)) return null;
    return std.json.parseFromSliceLeaky(Action, arena, text[marker.len..], .{ .ignore_unknown_fields = true }) catch null;
}

/// True when (ts_a, id_a) sorts before (ts_b, id_b) — the deterministic
/// winner rule for racing claims, and the display order for the card list.
fn wins(ts_a: i64, id_a: []const u8, ts_b: i64, id_b: []const u8) bool {
    if (ts_a != ts_b) return ts_a < ts_b;
    return std.mem.lessThan(u8, id_a, id_b);
}

const SubtaskState = struct {
    id: []const u8,
    text: []const u8,
    done: bool = false,
    removed: bool = false,
    done_at: Stamp = .{},
    removed_at: Stamp = .{},
};

const DepState = struct {
    on: []const u8,
    off: bool = false,
    at: Stamp = .{},
};

/// A card mid-fold: the visible fields plus the stamp that decided each one.
const State = struct {
    id: []const u8,
    title: []const u8,
    created_by: []const u8,
    ts: i64,
    body: []const u8 = "",
    column: []const u8 = default_column,
    priority: []const u8 = "normal",
    assignee: []const u8 = "",
    assigned_by: []const u8 = "",
    deadline: i64 = 0,
    goal: []const u8 = "",

    title_at: Stamp = .{},
    body_at: Stamp = .{},
    column_at: Stamp = .{},
    priority_at: Stamp = .{},
    deadline_at: Stamp = .{},
    goal_at: Stamp = .{},
    /// Claims use the lowest-(ts, id) rule, so this records the winner rather
    /// than the latest writer; an `assign` later than it overrides it.
    claim_at: Stamp = .{},
    assign_at: Stamp = .{},
    /// A latch, not a last-writer-wins field: an undelete would have to beat
    /// every replica that already dropped the card, and a card recovered on
    /// one peer but not another is worse than one that stays gone.
    removed: bool = false,

    subtasks: std.ArrayListUnmanaged(SubtaskState) = .empty,
    deps: std.ArrayListUnmanaged(DepState) = .empty,
    log: std.ArrayListUnmanaged(LogEntry) = .empty,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cost: f64 = 0,
    runs: std.ArrayListUnmanaged([]const u8) = .empty,

    fn subtask(self: *State, arena: std.mem.Allocator, id: []const u8, text: []const u8) !*SubtaskState {
        for (self.subtasks.items) |*s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        try self.subtasks.append(arena, .{ .id = id, .text = text });
        return &self.subtasks.items[self.subtasks.items.len - 1];
    }

    fn dep(self: *State, arena: std.mem.Allocator, on: []const u8) !*DepState {
        for (self.deps.items) |*d| {
            if (std.mem.eql(u8, d.on, on)) return d;
        }
        try self.deps.append(arena, .{ .on = on });
        return &self.deps.items[self.deps.items.len - 1];
    }
};

/// Folds a room's messages into its current cards. Two passes (adds first,
/// then everything else) so an action that appears before its add in this
/// replica's log order still applies; combined with the per-field winner rules
/// the result is independent of message order. Arena-owned, oldest-created
/// first.
pub fn derive(arena: std.mem.Allocator, msgs: []const Message) ![]Card {
    var by_id: std.StringArrayHashMapUnmanaged(State) = .empty;

    for (msgs) |m| {
        const act = parseAction(arena, m.text) orelse continue;
        if (!std.mem.eql(u8, act.action, "add")) continue;
        const title = act.title orelse continue;
        if (title.len == 0) continue;
        const gop = try by_id.getOrPut(arena, m.id);
        if (gop.found_existing) continue; // ids are unique; defensive
        gop.value_ptr.* = .{
            .id = m.id,
            .title = title,
            .created_by = m.from,
            .ts = m.ts,
            .body = act.body orelse "",
            .column = if (act.column) |c| (if (validColumn(c)) c else default_column) else default_column,
            .priority = if (act.priority) |p| (if (validPriority(p)) p else "normal") else "normal",
            .deadline = act.deadline orelse 0,
        };
        // A goal link at creation folds like an update stamped with the add
        // itself, so a later update overrides it by the usual rule.
        if (act.goal) |gid| {
            if (gid.len > 0) {
                gop.value_ptr.goal = gid;
                gop.value_ptr.goal_at = .{ .ts = m.ts, .id = m.id };
            }
        }
        // Assignment at creation folds like an assign stamped with the add
        // itself, so a later assign or claim overrides it by the usual rule.
        if (act.who) |w| {
            if (w.len > 0) {
                gop.value_ptr.assignee = w;
                gop.value_ptr.assigned_by = m.from;
                gop.value_ptr.assign_at = .{ .ts = m.ts, .id = m.id };
            }
        }
    }

    for (msgs) |m| {
        const act = parseAction(arena, m.text) orelse continue;
        if (std.mem.eql(u8, act.action, "add")) continue;
        const target = act.todo orelse continue;
        const c = by_id.getPtr(target) orelse continue;

        if (std.mem.eql(u8, act.action, "update")) {
            if (act.title) |v| {
                if (v.len > 0 and c.title_at.beaten(m.ts, m.id)) {
                    c.title = v;
                    c.title_at = .{ .ts = m.ts, .id = m.id };
                }
            }
            if (act.body) |v| {
                if (c.body_at.beaten(m.ts, m.id)) {
                    c.body = v;
                    c.body_at = .{ .ts = m.ts, .id = m.id };
                }
            }
            if (act.priority) |v| {
                if (validPriority(v) and c.priority_at.beaten(m.ts, m.id)) {
                    c.priority = v;
                    c.priority_at = .{ .ts = m.ts, .id = m.id };
                }
            }
            if (act.deadline) |v| {
                if (c.deadline_at.beaten(m.ts, m.id)) {
                    c.deadline = v;
                    c.deadline_at = .{ .ts = m.ts, .id = m.id };
                }
            }
            if (act.who) |v| {
                if (c.assign_at.beaten(m.ts, m.id)) {
                    c.assignee = v;
                    c.assigned_by = m.from;
                    c.assign_at = .{ .ts = m.ts, .id = m.id };
                }
            }
            if (act.column) |v| {
                if (validColumn(v) and c.column_at.beaten(m.ts, m.id)) {
                    c.column = v;
                    c.column_at = .{ .ts = m.ts, .id = m.id };
                }
            }
            if (act.goal) |v| {
                // "" unlinks; a non-empty value re-points the mirror.
                if (c.goal_at.beaten(m.ts, m.id)) {
                    c.goal = v;
                    c.goal_at = .{ .ts = m.ts, .id = m.id };
                }
            }
        } else if (std.mem.eql(u8, act.action, "move")) {
            const v = act.column orelse continue;
            if (validColumn(v) and c.column_at.beaten(m.ts, m.id)) {
                c.column = v;
                c.column_at = .{ .ts = m.ts, .id = m.id };
            }
        } else if (std.mem.eql(u8, act.action, "close")) {
            // Close is a move to done, so a later move can take it back out.
            if (c.column_at.beaten(m.ts, m.id)) {
                c.column = done_column;
                c.column_at = .{ .ts = m.ts, .id = m.id };
            }
        } else if (std.mem.eql(u8, act.action, "claim")) {
            // Lowest (ts, id) wins: the first claim holds the card.
            if (c.claim_at.id.len == 0 or wins(m.ts, m.id, c.claim_at.ts, c.claim_at.id)) {
                c.claim_at = .{ .ts = m.ts, .id = m.id };
                // A deliberate assign that is newer than this claim outranks it.
                if (!c.assign_at.beaten(m.ts, m.id)) continue;
                c.assignee = m.from;
                c.assigned_by = m.from;
            }
        } else if (std.mem.eql(u8, act.action, "assign")) {
            const v = act.who orelse "";
            if (c.assign_at.beaten(m.ts, m.id)) {
                c.assignee = v;
                c.assigned_by = m.from;
                c.assign_at = .{ .ts = m.ts, .id = m.id };
            }
        } else if (std.mem.eql(u8, act.action, "delete")) {
            c.removed = true;
        } else if (std.mem.eql(u8, act.action, "subtask_add")) {
            const text = act.text orelse continue;
            if (text.len == 0) continue;
            _ = try c.subtask(arena, m.id, text);
        } else if (std.mem.eql(u8, act.action, "subtask_toggle")) {
            const sid = act.subtask orelse continue;
            const s = try c.subtask(arena, sid, "");
            if (s.done_at.beaten(m.ts, m.id)) {
                s.done = act.done orelse true;
                s.done_at = .{ .ts = m.ts, .id = m.id };
            }
        } else if (std.mem.eql(u8, act.action, "subtask_remove")) {
            const sid = act.subtask orelse continue;
            const s = try c.subtask(arena, sid, "");
            if (s.removed_at.beaten(m.ts, m.id)) {
                s.removed = true;
                s.removed_at = .{ .ts = m.ts, .id = m.id };
            }
        } else if (std.mem.eql(u8, act.action, "depend")) {
            const on = act.on orelse continue;
            if (on.len == 0 or std.mem.eql(u8, on, target)) continue; // no self-dependency
            const d = try c.dep(arena, on);
            if (d.at.beaten(m.ts, m.id)) {
                d.off = act.off orelse false;
                d.at = .{ .ts = m.ts, .id = m.id };
            }
        } else if (std.mem.eql(u8, act.action, "log")) {
            const what = act.what orelse continue;
            if (what.len == 0) continue;
            var seen = false;
            for (c.log.items) |e| {
                if (e.ts == m.ts and std.mem.eql(u8, e.who, m.from) and std.mem.eql(u8, e.what, what)) seen = true;
            }
            if (!seen) try c.log.append(arena, .{ .ts = m.ts, .who = m.from, .what = what });
        } else if (std.mem.eql(u8, act.action, "usage")) {
            // Grow-only: each message contributes once, so folding the same log
            // again gives the same total. Saturating because the numbers come
            // from a caller and a wrap here would report a cost of nothing.
            c.prompt_tokens +|= act.prompt_tokens orelse 0;
            c.completion_tokens +|= act.completion_tokens orelse 0;
            if (act.cost) |v| {
                if (std.math.isFinite(v) and v >= 0) c.cost += v;
            }
            if (act.run) |run| {
                if (run.len > 0) {
                    var seen = false;
                    for (c.runs.items) |r| {
                        if (std.mem.eql(u8, r, run)) seen = true;
                    }
                    if (!seen) try c.runs.append(arena, run);
                }
            }
        }
    }

    var live: usize = 0;
    {
        var count_it = by_id.iterator();
        while (count_it.next()) |kv| {
            if (!kv.value_ptr.removed) live += 1;
        }
    }
    const out = try arena.alloc(Card, live);
    var idx: usize = 0;
    var it = by_id.iterator();
    while (it.next()) |kv| {
        const c = kv.value_ptr;
        if (c.removed) continue;

        var subs: std.ArrayListUnmanaged(Subtask) = .empty;
        for (c.subtasks.items) |s| {
            // A subtask only toggled or removed, never added, has no text and
            // is not a subtask; it is the residue of a message about one.
            if (s.removed or s.text.len == 0) continue;
            try subs.append(arena, .{ .id = s.id, .text = s.text, .done = s.done });
        }
        var deps: std.ArrayListUnmanaged([]const u8) = .empty;
        for (c.deps.items) |d| {
            if (!d.off) try deps.append(arena, d.on);
        }
        std.mem.sort(LogEntry, c.log.items, {}, struct {
            fn lt(_: void, a: LogEntry, b: LogEntry) bool {
                return a.ts < b.ts;
            }
        }.lt);

        out[idx] = .{
            .id = c.id,
            .title = c.title,
            .created_by = c.created_by,
            .ts = c.ts,
            .body = c.body,
            .column = c.column,
            .priority = c.priority,
            .assignee = c.assignee,
            .assigned_by = c.assigned_by,
            .deadline = c.deadline,
            .goal = c.goal,
            .subtasks = subs.items,
            .depends_on = deps.items,
            .log = c.log.items,
            .usage = .{
                .prompt_tokens = c.prompt_tokens,
                .completion_tokens = c.completion_tokens,
                .cost = c.cost,
                .runs = c.runs.items,
            },
        };
        idx += 1;
    }
    std.mem.sort(Card, out, {}, struct {
        fn lt(_: void, a: Card, b: Card) bool {
            return wins(a.ts, a.id, b.ts, b.id);
        }
    }.lt);
    return out;
}

pub fn get(cards: []Card, id: []const u8) ?*Card {
    for (cards) |*c| {
        if (std.mem.eql(u8, c.id, id)) return c;
    }
    return null;
}

/// Whether a card is one that `who` should be looking at: theirs, assigned by
/// them, created by them, or claimed by nobody yet.
///
/// A *view*, not a permission. Every clanker subscribed to the room already
/// holds every message in it, so the fold cannot hide a card from someone who
/// can read the log — filtering here narrows what is shown, not what is
/// readable. The boundary that actually holds is the room: a card only certain
/// peers should see belongs in a room only those peers subscribe to.
pub fn concerns(card: *const Card, who: []const u8) bool {
    if (who.len == 0) return true;
    if (card.assignee.len == 0) return true;
    return std.mem.eql(u8, card.assignee, who) or
        std.mem.eql(u8, card.assigned_by, who) or
        std.mem.eql(u8, card.created_by, who);
}

test concerns {
    const mine: Card = .{ .id = "a", .title = "t", .created_by = "x", .ts = 1, .assignee = "me", .assigned_by = "boss" };
    const theirs: Card = .{ .id = "b", .title = "t", .created_by = "x", .ts = 1, .assignee = "them", .assigned_by = "them" };
    const unclaimed: Card = .{ .id = "c", .title = "t", .created_by = "x", .ts = 1 };
    try std.testing.expect(concerns(&mine, "me"));
    try std.testing.expect(concerns(&mine, "boss"));
    try std.testing.expect(!concerns(&theirs, "me"));
    try std.testing.expect(concerns(&unclaimed, "me")); // free work is everyone's
    try std.testing.expect(concerns(&theirs, "")); // no filter asked for
    try std.testing.expect(concerns(&theirs, "x")); // its author still sees it
}

/// Whether every card this one waits on is done. A card whose dependencies are
/// unmet is not blocked from moving — the board reports it rather than refusing,
/// because the log has no transaction in which to refuse.
pub fn blockedBy(cards: []Card, card: *const Card, arena: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (card.depends_on) |dep_id| {
        const d = get(cards, dep_id) orelse continue;
        if (!std.mem.eql(u8, d.column, done_column)) try out.append(arena, dep_id);
    }
    return out.items;
}

// ------------------------------------------------------------------- tests --

const t_alloc = std.testing.allocator;

fn msg(id: []const u8, from: []const u8, ts: i64, text: []const u8) Message {
    return .{ .room = "dev", .from = from, .text = text, .ts = ts, .id = id };
}

test "add + claim + close round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encodeAdd(arena, "ship the \"thing\"");
    const claim = try encodeClaim(arena, "m1");
    const close = try encodeClose(arena, "m1");
    const msgs = [_]Message{
        msg("m1", "alpha", 100, add),
        msg("m2", "beta", 101, claim),
        msg("m3", "beta", 102, close),
        msg("m4", "beta", 103, "plain chat, not a card action"),
    };
    const cards = try derive(arena, &msgs);
    try std.testing.expectEqual(@as(usize, 1), cards.len);
    try std.testing.expectEqualStrings("m1", cards[0].id);
    try std.testing.expectEqualStrings("ship the \"thing\"", cards[0].title);
    try std.testing.expectEqualStrings("alpha", cards[0].created_by);
    try std.testing.expectEqualStrings("beta", cards[0].assignee);
    try std.testing.expectEqualStrings("done", cards[0].column);
    try std.testing.expectEqualStrings("closed", cards[0].status());
}

test "a card can be assigned at creation, and a later assign still wins" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encode(arena, .{ .action = "add", .title = "task", .who = "beta" });
    const one = [_]Message{msg("m1", "alpha", 100, add)};
    const born = try derive(arena, &one);
    try std.testing.expectEqualStrings("beta", born[0].assignee);
    try std.testing.expectEqualStrings("alpha", born[0].assigned_by);
    try std.testing.expectEqualStrings("claimed", born[0].status());

    // The creation assignment is stamped with the add itself, so a later
    // reassign outranks it in either arrival order.
    const re = try encode(arena, .{ .action = "assign", .todo = "m1", .who = "gamma" });
    const order_a = [_]Message{ msg("m1", "alpha", 100, add), msg("m2", "boss", 200, re) };
    const order_b = [_]Message{ msg("m2", "boss", 200, re), msg("m1", "alpha", 100, add) };
    const ca = try derive(arena, &order_a);
    const cb = try derive(arena, &order_b);
    try std.testing.expectEqualStrings("gamma", ca[0].assignee);
    try std.testing.expectEqualStrings("gamma", cb[0].assignee);
    try std.testing.expectEqualStrings("boss", ca[0].assigned_by);
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

    const order1 = [_]Message{ msg("m1", "x", 100, add), a, b };
    const order2 = [_]Message{ msg("m1", "x", 100, add), b, a };
    const t1 = try derive(arena, &order1);
    const t2 = try derive(arena, &order2);
    try std.testing.expectEqualStrings("alpha", t1[0].assignee);
    try std.testing.expectEqualStrings("alpha", t2[0].assignee);
    try std.testing.expectEqualStrings("claimed", t1[0].status());
}

test "claim delivered before its add still applies" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encodeAdd(arena, "task");
    const claim = try encodeClaim(arena, "m1");
    const msgs = [_]Message{
        msg("m2", "beta", 101, claim), // fan-out beat the add to this replica
        msg("m1", "alpha", 100, add),
    };
    const cards = try derive(arena, &msgs);
    try std.testing.expectEqual(@as(usize, 1), cards.len);
    try std.testing.expectEqualStrings("beta", cards[0].assignee);
}

test "a close and a later move converge on the move, in either order" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The old model latched `closed`, so work could never leave done. A board
    // has to be able to pull a card back, and both replicas must agree it did.
    const add = try encodeAdd(arena, "task");
    const close = try encodeClose(arena, "m1");
    const back = try encode(arena, .{ .action = "move", .todo = "m1", .column = "doing" });
    const order_a = [_]Message{ msg("m1", "x", 100, add), msg("m2", "alpha", 200, close), msg("m3", "beta", 300, back) };
    const order_b = [_]Message{ msg("m1", "x", 100, add), msg("m3", "beta", 300, back), msg("m2", "alpha", 200, close) };
    const ca = try derive(arena, &order_a);
    const cb = try derive(arena, &order_b);
    try std.testing.expectEqualStrings("doing", ca[0].column);
    try std.testing.expectEqualStrings("doing", cb[0].column);
    // Nobody claimed it, and leaving done put it back to being unowned work.
    try std.testing.expectEqualStrings("open", cb[0].status());
}

test "archive retains a card and reports it closed" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encodeAdd(arena, "retained goal");
    const archive = try encode(arena, .{ .action = "move", .todo = "m1", .column = "archive" });
    const folded = try derive(arena, &.{ msg("m1", "x", 100, add), msg("m2", "x", 200, archive) });
    try std.testing.expectEqual(@as(usize, 1), folded.len);
    try std.testing.expectEqualStrings("archive", folded[0].column);
    try std.testing.expectEqualStrings("closed", folded[0].status());
}

test "edits converge on the latest writer whatever the arrival order" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encodeAdd(arena, "first");
    const e1 = try encode(arena, .{ .action = "update", .todo = "m1", .title = "second", .priority = "low" });
    const e2 = try encode(arena, .{ .action = "update", .todo = "m1", .title = "third" });
    const order_a = [_]Message{ msg("m1", "x", 100, add), msg("m2", "a", 200, e1), msg("m3", "b", 300, e2) };
    const order_b = [_]Message{ msg("m3", "b", 300, e2), msg("m2", "a", 200, e1), msg("m1", "x", 100, add) };
    const ca = try derive(arena, &order_a);
    const cb = try derive(arena, &order_b);
    try std.testing.expectEqualStrings("third", ca[0].title);
    try std.testing.expectEqualStrings("third", cb[0].title);
    // The older edit still owns the field the newer one said nothing about.
    try std.testing.expectEqualStrings("low", cb[0].priority);
}

test "goal link folds like an edit, in either order" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try encode(arena, .{ .action = "add", .title = "task", .goal = "g1" });
    const relink = try encode(arena, .{ .action = "update", .todo = "m1", .goal = "g2" });
    const order_a = [_]Message{ msg("m1", "x", 100, add), msg("m2", "y", 200, relink) };
    const order_b = [_]Message{ msg("m2", "y", 200, relink), msg("m1", "x", 100, add) };
    const ca = try derive(arena, &order_a);
    const cb = try derive(arena, &order_b);
    try std.testing.expectEqualStrings("g2", ca[0].goal);
    try std.testing.expectEqualStrings("g2", cb[0].goal);

    // "" unlinks, and a card born without a goal has none.
    const unlink = try encode(arena, .{ .action = "update", .todo = "m1", .goal = "" });
    const order_c = [_]Message{ msg("m1", "x", 100, add), msg("m2", "y", 200, relink), msg("m3", "z", 300, unlink) };
    const cc = try derive(arena, &order_c);
    try std.testing.expectEqualStrings("", cc[0].goal);
    const plain = [_]Message{msg("m1", "x", 100, try encodeAdd(arena, "task"))};
    const cp = try derive(arena, &plain);
    try std.testing.expectEqualStrings("", cp[0].goal);
}

test "subtasks, dependencies and cost fold" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{
        msg("m1", "x", 100, try encodeAdd(arena, "parent")),
        msg("m2", "x", 101, try encodeAdd(arena, "blocker")),
        msg("s1", "x", 102, try encode(arena, .{ .action = "subtask_add", .todo = "m1", .text = "write it" })),
        msg("s2", "x", 103, try encode(arena, .{ .action = "subtask_add", .todo = "m1", .text = "test it" })),
        msg("s3", "x", 104, try encode(arena, .{ .action = "subtask_toggle", .todo = "m1", .subtask = "s1", .done = true })),
        msg("s4", "x", 105, try encode(arena, .{ .action = "subtask_remove", .todo = "m1", .subtask = "s2" })),
        msg("d1", "x", 106, try encode(arena, .{ .action = "depend", .todo = "m1", .on = "m2" })),
        msg("u1", "x", 107, try encode(arena, .{ .action = "usage", .todo = "m1", .prompt_tokens = 10, .cost = 0.5, .run = "r1" })),
        msg("u2", "x", 108, try encode(arena, .{ .action = "usage", .todo = "m1", .prompt_tokens = 5, .cost = 0.25, .run = "r1" })),
        msg("l1", "x", 109, try encode(arena, .{ .action = "log", .todo = "m1", .what = "started" })),
    };
    const cards = try derive(arena, &msgs);
    const parent = get(cards, "m1").?;
    try std.testing.expectEqual(@as(usize, 1), parent.subtasks.len);
    try std.testing.expectEqualStrings("write it", parent.subtasks[0].text);
    try std.testing.expect(parent.subtasks[0].done);
    try std.testing.expectEqual(@as(usize, 1), parent.depends_on.len);
    try std.testing.expectEqual(@as(u64, 15), parent.usage.prompt_tokens);
    try std.testing.expectEqual(@as(f64, 0.75), parent.usage.cost);
    try std.testing.expectEqual(@as(usize, 1), parent.usage.runs.len); // same run twice
    try std.testing.expectEqual(@as(usize, 1), parent.log.len);

    const blocked = try blockedBy(cards, parent, arena);
    try std.testing.expectEqual(@as(usize, 1), blocked.len);
}

test "usage cannot be made to wrap or go negative" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big = std.math.maxInt(u64);
    const msgs = [_]Message{
        msg("m1", "x", 100, try encodeAdd(arena, "task")),
        msg("u1", "x", 101, try encode(arena, .{ .action = "usage", .todo = "m1", .prompt_tokens = big })),
        msg("u2", "x", 102, try encode(arena, .{ .action = "usage", .todo = "m1", .prompt_tokens = big })),
        msg("u3", "x", 103, try encode(arena, .{ .action = "usage", .todo = "m1", .cost = -5 })),
    };
    const cards = try derive(arena, &msgs);
    try std.testing.expectEqual(big, cards[0].usage.prompt_tokens);
    try std.testing.expectEqual(@as(f64, 0), cards[0].usage.cost);
}

test "delete is a tombstone that converges from either order" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs_a = [_]Message{
        .{ .from = "x", .ts = 100, .id = "m1", .text = try encodeAdd(arena, "doomed") },
        .{ .from = "x", .ts = 101, .id = "m2", .text = try encodeAdd(arena, "kept") },
        .{ .from = "x", .ts = 102, .id = "d1", .text = try encode(arena, .{ .action = "delete", .todo = "m1" }) },
        .{ .from = "x", .ts = 103, .id = "u1", .text = try encode(arena, .{ .action = "update", .todo = "m1", .title = "back?" }) },
    };
    // The same messages, delivered with the delete last.
    const msgs_b = [_]Message{ msgs_a[0], msgs_a[1], msgs_a[3], msgs_a[2] };
    const ca = try derive(arena, &msgs_a);
    const cb = try derive(arena, &msgs_b);
    try std.testing.expectEqual(@as(usize, 1), ca.len);
    try std.testing.expectEqual(@as(usize, 1), cb.len);
    try std.testing.expectEqualStrings("kept", ca[0].title);
    try std.testing.expectEqualStrings("kept", cb[0].title);
}

test "an action naming a card that does not exist is ignored" {
    var arena_state = std.heap.ArenaAllocator.init(t_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{
        msg("m1", "x", 100, try encode(arena, .{ .action = "move", .todo = "nope", .column = "doing" })),
        msg("m2", "x", 101, try encode(arena, .{ .action = "add", .title = "real" })),
        msg("m3", "x", 102, try encode(arena, .{ .action = "move", .todo = "m2", .column = "nonsense" })),
    };
    const cards = try derive(arena, &msgs);
    try std.testing.expectEqual(@as(usize, 1), cards.len);
    try std.testing.expectEqualStrings("backlog", cards[0].column); // bad column refused
}

test "fuzz: no message text makes the fold panic" {
    // Message text arrives from peers, so the property is that any bytes at all
    // fold to something rather than crashing.
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena_state = std.heap.ArenaAllocator.init(t_alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var buf: [2048]u8 = undefined;
            const len = smith.slice(&buf);
            const msgs = [_]Message{
                msg("m1", "x", 100, try encodeAdd(arena, "task")),
                msg("m2", "y", 101, buf[0..len]),
            };
            _ = derive(arena, &msgs) catch {};
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}
