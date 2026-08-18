//! Shared goal-record mutation for the add/update guests. Host-tested so the
//! status alphabet and the patch rules stay pinned without a wasm runtime.

const std = @import("std");

pub const Goal = struct {
    id: []const u8,
    objective: []const u8,
    completion_criterion: []const u8 = "",
    proof: []const u8 = "",
    boundaries: []const u8 = "",
    stop_rule: []const u8 = "",
    status: []const u8 = "active",
    /// Whether a goal loop is in flight. Set true when a run starts and false
    /// at its terminal outcome; a process that dies mid-loop leaves this true,
    /// which is what lets `clanker serve` resume the goal on restart.
    running: bool = false,
    /// Workspace (project) id this goal belongs to (RFC 0001). "" is the
    /// default workspace (the serve cwd).
    workspace: []const u8 = "",
    goal_loop_reason: []const u8 = "",
    goal_loop_turns: u32 = 0,
    max_iterations: ?u32 = null,
    worktree: ?[]const u8 = null,
    /// First-class tasks under this goal (RFC 0001). Public tasks
    /// (`visible_to` empty) may project onto the board card checklist; private
    /// tasks name the `instance.id`s that may see them and never reach the
    /// project's `#general` fold.
    tasks: []const GoalTask = &.{},
    created: i64 = 0,
    updated: i64 = 0,
};

/// One task under a goal. The store is `state/goals.json`; the board card
/// checklist is a projection of the public tasks only, never the store.
pub const GoalTask = struct {
    id: []const u8,
    text: []const u8,
    done: bool = false,
    /// Empty = public (every project member). Non-empty = private to exactly
    /// the named instance ids.
    visible_to: []const []const u8 = &.{},
    created: i64 = 0,
    updated: i64 = 0,
};

/// Whether `instance_id` may see `task`: public tasks are visible to every
/// member, private tasks only to the ids they name. An empty caller id sees
/// public tasks only, so a caller that has not named itself never leaks a
/// private task.
pub fn taskVisibleTo(task: GoalTask, instance_id: []const u8) bool {
    if (task.visible_to.len == 0) return true;
    if (instance_id.len == 0) return false;
    for (task.visible_to) |id| {
        if (std.mem.eql(u8, id, instance_id)) return true;
    }
    return false;
}

/// Open (not done) tasks `instance_id` can see. This is the q14 Done-blocking
/// shape: a member cannot mark the goal Done while it still has *that member's*
/// open tasks; other members' private tasks do not block it.
pub fn openTasksVisibleTo(goal: Goal, instance_id: []const u8) usize {
    var n: usize = 0;
    for (goal.tasks) |t| {
        if (!t.done and taskVisibleTo(t, instance_id)) n += 1;
    }
    return n;
}

pub const TaskAdd = struct {
    id: []const u8,
    text: []const u8,
    visible_to: []const []const u8 = &.{},
};

pub const TaskToggle = struct {
    id: []const u8,
    done: bool,
};

pub const TaskPatch = union(enum) {
    add: TaskAdd,
    toggle: TaskToggle,
    remove: []const u8,
};

pub const Worktree = union(enum) { leave, set_true, clear, value: []const u8 };

pub const Patch = struct {
    id: []const u8,
    /// When set, the write is a no-op unless the goal currently holds this
    /// status. Run-completion uses `from = "active"` so a hand move or a
    /// deleted goal is left alone.
    from_status: ?[]const u8 = null,
    status: ?[]const u8 = null,
    /// Re-points the goal's workspace (RFC 0001). Null leaves it; "" moves it
    /// to the default workspace.
    workspace: ?[]const u8 = null,
    /// Sets/clears the in-flight flag (auto-resume marker). Null leaves it.
    running: ?bool = null,
    max_iterations: ?u32 = null,
    worktree: Worktree = .leave,
    goal_loop_reason: ?[]const u8 = null,
    goal_loop_turns: ?u32 = null,
    /// One task mutation, applied to the named goal after the field updates.
    task: ?TaskPatch = null,
    remove: bool = false,
};

/// Workflow words a goal may hold. Anything else is refused rather than
/// written, so the file cannot grow states nothing knows how to read.
pub fn validStatus(s: []const u8) bool {
    return std.mem.eql(u8, s, "active") or std.mem.eql(u8, s, "done") or
        std.mem.eql(u8, s, "archived") or std.mem.eql(u8, s, "abandoned") or
        std.mem.eql(u8, s, "review") or std.mem.eql(u8, s, "blocked");
}

pub fn clampBudget(n: u32) u32 {
    if (n == 0) return 1;
    return @min(n, 1000);
}

/// The project's default (`#general`) room name for a workspace (RFC 0001).
/// Empty workspace keeps the legacy `board` room so today's log does not move.
pub fn generalRoomName(arena: std.mem.Allocator, workspace_id: []const u8) ![]const u8 {
    if (workspace_id.len == 0) return std.fmt.allocPrint(arena, "board", .{});
    return std.fmt.allocPrint(arena, "ws:{s}", .{workspace_id});
}

/// The project's per-goal output room name (RFC 0001): a goal's model output
/// goes here so it does not flood `#general`. The session stays the canonical
/// transcript; this room is a lossy feed, never a store. For the default
/// workspace there is no project prefix, so the room is `goal:<goal-id>`.
pub fn goalRoomName(arena: std.mem.Allocator, workspace_id: []const u8, goal_id: []const u8) ![]const u8 {
    if (workspace_id.len == 0) return std.fmt.allocPrint(arena, "goal:{s}", .{goal_id});
    return std.fmt.allocPrint(arena, "ws:{s}:goal:{s}", .{ workspace_id, goal_id });
}

/// Applies `patch` to a copy of `goals`. Missing id is an error; a status
/// that is not a workflow word is an error. `now` is the updated timestamp.
pub fn apply(alloc: std.mem.Allocator, goals: []const Goal, patch: Patch, now: i64) ![]Goal {
    if (patch.status) |s| {
        if (!validStatus(s)) return error.BadStatus;
    }
    if (patch.max_iterations) |n| {
        if (n < 1 or n > 1000) return error.BadBudget;
    }

    var out: std.ArrayList(Goal) = .empty;
    errdefer out.deinit(alloc);
    var hit = false;
    for (goals) |g| {
        if (!std.mem.eql(u8, g.id, patch.id)) {
            try out.append(alloc, g);
            continue;
        }
        hit = true;
        if (patch.from_status) |from| {
            if (!std.mem.eql(u8, g.status, from)) return error.StatusMismatch;
        }
        if (patch.remove) continue;
        var updated = g;
        if (patch.status) |s| updated.status = s;
        if (patch.workspace) |w| updated.workspace = w;
        if (patch.running) |r| updated.running = r;
        if (patch.max_iterations) |n| updated.max_iterations = n;
        switch (patch.worktree) {
            .leave => {},
            .set_true => updated.worktree = "true",
            .clear => updated.worktree = null,
            .value => |v| updated.worktree = v,
        }
        if (patch.goal_loop_reason) |r| updated.goal_loop_reason = r;
        if (patch.goal_loop_turns) |n| updated.goal_loop_turns = n;
        if (patch.task) |tp| updated.tasks = try applyTaskPatch(alloc, updated.tasks, tp, now);
        updated.updated = now;
        try out.append(alloc, updated);
    }
    if (!hit) return error.NoSuchGoal;
    return out.toOwnedSlice(alloc);
}

/// Applies one task mutation to a copy of the goal's task list.
fn applyTaskPatch(alloc: std.mem.Allocator, tasks: []const GoalTask, patch: TaskPatch, now: i64) ![]GoalTask {
    switch (patch) {
        .add => |add| {
            if (add.text.len == 0) return error.BadTask;
            var out: std.ArrayList(GoalTask) = .empty;
            errdefer out.deinit(alloc);
            try out.appendSlice(alloc, tasks);
            try out.append(alloc, .{
                .id = add.id,
                .text = add.text,
                .visible_to = add.visible_to,
                .created = now,
                .updated = now,
            });
            return out.toOwnedSlice(alloc);
        },
        .toggle => |toggle| {
            var out: std.ArrayList(GoalTask) = .empty;
            errdefer out.deinit(alloc);
            var found = false;
            for (tasks) |t| {
                var updated = t;
                if (std.mem.eql(u8, t.id, toggle.id)) {
                    updated.done = toggle.done;
                    updated.updated = now;
                    found = true;
                }
                try out.append(alloc, updated);
            }
            if (!found) return error.NoSuchTask;
            return out.toOwnedSlice(alloc);
        },
        .remove => |id| {
            var out: std.ArrayList(GoalTask) = .empty;
            errdefer out.deinit(alloc);
            var found = false;
            for (tasks) |t| {
                if (std.mem.eql(u8, t.id, id)) {
                    found = true;
                    continue;
                }
                try out.append(alloc, t);
            }
            if (!found) return error.NoSuchTask;
            return out.toOwnedSlice(alloc);
        },
    }
}

/// `{"ok":true,"goals":<array bytes>}`. The array is already JSON, so it
/// is written raw; `objectField` only emits the key, and `beginWriteRaw`
/// is what writes the colon. A bare `writer.writeAll` after the field
/// produced `{"ok":true,"goals"[...]}` and GET /api/goals 500'd.
pub fn writeListEnvelope(w: *std.Io.Writer, goals_json: []const u8) !void {
    var s = std.json.Stringify{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("goals");
    try s.beginWriteRaw();
    try s.writer.writeAll(goals_json);
    s.endWriteRaw();
    try s.endObject();
}

test writeListEnvelope {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeListEnvelope(&w, "[1,2]");
    try std.testing.expectEqualStrings("{\"ok\":true,\"goals\":[1,2]}", buf[0..w.end]);
    w.end = 0;
    try writeListEnvelope(&w, "[]");
    try std.testing.expectEqualStrings("{\"ok\":true,\"goals\":[]}", buf[0..w.end]);
}

test validStatus {
    try std.testing.expect(validStatus("active"));
    try std.testing.expect(validStatus("done"));
    try std.testing.expect(validStatus("abandoned"));
    try std.testing.expect(validStatus("archived"));
    try std.testing.expect(validStatus("review"));
    try std.testing.expect(validStatus("blocked"));
    try std.testing.expect(!validStatus("Active"));
    try std.testing.expect(!validStatus(""));
    try std.testing.expect(!validStatus("deleted; drop table"));
}

test "apply updates only the named fields and refuses a missing id" {
    const gpa = std.testing.allocator;
    const goals = [_]Goal{
        .{ .id = "g1", .objective = "a", .status = "active", .created = 1, .updated = 1 },
        .{ .id = "g2", .objective = "c", .status = "done", .created = 1, .updated = 1 },
    };

    const patched = try apply(gpa, &goals, .{ .id = "g1", .status = "review" }, 9);
    defer gpa.free(patched);
    try std.testing.expectEqual(@as(usize, 2), patched.len);
    try std.testing.expectEqualStrings("review", patched[0].status);
    try std.testing.expectEqual(@as(i64, 9), patched[0].updated);
    try std.testing.expectEqualStrings("done", patched[1].status);
    try std.testing.expectEqual(@as(i64, 1), patched[1].updated);

    try std.testing.expectError(error.NoSuchGoal, apply(gpa, &goals, .{ .id = "missing", .status = "review" }, 9));
    try std.testing.expectError(error.BadStatus, apply(gpa, &goals, .{ .id = "g1", .status = "nope" }, 9));
}

test "apply from_status is a compare-and-swap, and a loop outcome records reason and turns" {
    const gpa = std.testing.allocator;
    const goals = [_]Goal{
        .{ .id = "g1", .objective = "a", .status = "active", .created = 1, .updated = 1 },
        .{ .id = "g2", .objective = "c", .status = "done", .created = 1, .updated = 1 },
    };

    // A finished run only moves active -> review. A goal already done, or an
    // id nobody has heard of, is left exactly as it was.
    const moved = try apply(gpa, &goals, .{ .id = "g1", .from_status = "active", .status = "review" }, 9);
    defer gpa.free(moved);
    try std.testing.expectEqualStrings("review", moved[0].status);
    try std.testing.expectEqual(@as(i64, 9), moved[0].updated);
    try std.testing.expectEqualStrings("done", moved[1].status);

    try std.testing.expectError(error.StatusMismatch, apply(gpa, &goals, .{ .id = "g2", .from_status = "active", .status = "review" }, 9));
    try std.testing.expectError(error.NoSuchGoal, apply(gpa, &goals, .{ .id = "missing", .from_status = "active", .status = "review" }, 9));

    const blocked = try apply(gpa, &goals, .{
        .id = "g1",
        .from_status = "active",
        .status = "blocked",
        .goal_loop_reason = "waiting on credentials",
        .goal_loop_turns = 3,
    }, 4);
    defer gpa.free(blocked);
    try std.testing.expectEqualStrings("blocked", blocked[0].status);
    try std.testing.expectEqualStrings("waiting on credentials", blocked[0].goal_loop_reason);
    try std.testing.expectEqual(@as(u32, 3), blocked[0].goal_loop_turns);
    try std.testing.expectEqual(@as(i64, 4), blocked[0].updated);
}

test "apply of two different ids composes so neither write is dropped" {
    const gpa = std.testing.allocator;
    const goals = [_]Goal{
        .{ .id = "g1", .objective = "a", .status = "active", .created = 1, .updated = 1 },
        .{ .id = "g2", .objective = "c", .status = "active", .created = 1, .updated = 1 },
    };

    // Two run-completion writes finishing at once used to each read the same
    // file, flip one goal, and let the second write drop the first. The
    // guest retries a mismatched hash; this pins that two applies in
    // sequence keep both flips.
    const after_g1 = try apply(gpa, &goals, .{ .id = "g1", .from_status = "active", .status = "review" }, 2);
    defer gpa.free(after_g1);
    const after_both = try apply(gpa, after_g1, .{ .id = "g2", .from_status = "active", .status = "review" }, 3);
    defer gpa.free(after_both);
    try std.testing.expectEqualStrings("review", after_both[0].status);
    try std.testing.expectEqualStrings("review", after_both[1].status);
    try std.testing.expectEqual(@as(i64, 2), after_both[0].updated);
    try std.testing.expectEqual(@as(i64, 3), after_both[1].updated);
}

test "apply sets a worktree branch string" {
    const gpa = std.testing.allocator;
    const goals = [_]Goal{
        .{ .id = "g1", .objective = "a", .created = 1, .updated = 1 },
    };
    const patched = try apply(gpa, &goals, .{ .id = "g1", .worktree = .{ .value = "clanker/webui-1" } }, 5);
    defer gpa.free(patched);
    try std.testing.expectEqualStrings("clanker/webui-1", patched[0].worktree.?);
    try std.testing.expectEqual(@as(i64, 5), patched[0].updated);
}

test "apply re-points a goal's workspace and leaves it when absent" {
    const gpa = std.testing.allocator;
    const goals = [_]Goal{
        .{ .id = "g1", .objective = "a", .workspace = "relumea", .created = 1, .updated = 1 },
        .{ .id = "g2", .objective = "b", .created = 1, .updated = 1 },
    };
    const moved = try apply(gpa, &goals, .{ .id = "g1", .workspace = "7dtd" }, 4);
    defer gpa.free(moved);
    try std.testing.expectEqualStrings("7dtd", moved[0].workspace);
    try std.testing.expectEqualStrings("", moved[1].workspace);

    // A patch that says nothing about workspace keeps the current value.
    const untouched = try apply(gpa, &goals, .{ .id = "g1", .status = "review" }, 5);
    defer gpa.free(untouched);
    try std.testing.expectEqualStrings("relumea", untouched[0].workspace);
}

test "apply sets and clears the in-flight flag" {
    const gpa = std.testing.allocator;
    const goals = [_]Goal{
        .{ .id = "g1", .objective = "a", .created = 1, .updated = 1 },
    };
    const started = try apply(gpa, &goals, .{ .id = "g1", .running = true }, 2);
    defer gpa.free(started);
    try std.testing.expect(started[0].running);

    const stopped = try apply(gpa, started, .{ .id = "g1", .running = false, .status = "review" }, 3);
    defer gpa.free(stopped);
    try std.testing.expect(!stopped[0].running);
    try std.testing.expectEqualStrings("review", stopped[0].status);
}

test "task visibility splits public from private-by-instance" {
    const public_task: GoalTask = .{ .id = "t1", .text = "merge the PR" };
    const private_task: GoalTask = .{ .id = "t2", .text = "draft the commit msg", .visible_to = &.{"main"} };
    try std.testing.expect(taskVisibleTo(public_task, "main"));
    try std.testing.expect(taskVisibleTo(public_task, "side"));
    try std.testing.expect(taskVisibleTo(public_task, ""));
    try std.testing.expect(taskVisibleTo(private_task, "main"));
    try std.testing.expect(!taskVisibleTo(private_task, "side"));
    try std.testing.expect(!taskVisibleTo(private_task, ""));

    const goal: Goal = .{ .id = "g", .objective = "o", .tasks = &.{ public_task, private_task } };
    try std.testing.expectEqual(@as(usize, 2), openTasksVisibleTo(goal, "main"));
    try std.testing.expectEqual(@as(usize, 1), openTasksVisibleTo(goal, "side"));
    try std.testing.expectEqual(@as(usize, 1), openTasksVisibleTo(goal, ""));
}

test "apply task add toggle and remove" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const goals = [_]Goal{
        .{ .id = "g1", .objective = "a", .created = 1, .updated = 1 },
    };

    const added = try apply(gpa, &goals, .{ .id = "g1", .task = .{ .add = .{ .id = "t1", .text = "merge the PR" } } }, 2);
    try std.testing.expectEqual(@as(usize, 1), added[0].tasks.len);
    try std.testing.expectEqualStrings("merge the PR", added[0].tasks[0].text);
    try std.testing.expect(!added[0].tasks[0].done);

    const toggled = try apply(gpa, added, .{ .id = "g1", .task = .{ .toggle = .{ .id = "t1", .done = true } } }, 3);
    try std.testing.expect(toggled[0].tasks[0].done);

    const removed = try apply(gpa, toggled, .{ .id = "g1", .task = .{ .remove = "t1" } }, 4);
    try std.testing.expectEqual(@as(usize, 0), removed[0].tasks.len);

    try std.testing.expectError(error.NoSuchTask, apply(gpa, added, .{ .id = "g1", .task = .{ .toggle = .{ .id = "missing", .done = true } } }, 5));
}

test "apply removes a goal and clears a worktree flag" {
    const gpa = std.testing.allocator;
    const goals = [_]Goal{
        .{ .id = "g1", .objective = "a", .worktree = "true", .created = 1, .updated = 1 },
        .{ .id = "g2", .objective = "c", .created = 1, .updated = 1 },
    };

    const cleared = try apply(gpa, &goals, .{ .id = "g1", .worktree = .clear }, 3);
    defer gpa.free(cleared);
    try std.testing.expect(cleared[0].worktree == null);
    try std.testing.expectEqual(@as(i64, 3), cleared[0].updated);

    const removed = try apply(gpa, &goals, .{ .id = "g1", .remove = true }, 3);
    defer gpa.free(removed);
    try std.testing.expectEqual(@as(usize, 1), removed.len);
    try std.testing.expectEqualStrings("g2", removed[0].id);
}

test clampBudget {
    try std.testing.expectEqual(@as(u32, 1), clampBudget(0));
    try std.testing.expectEqual(@as(u32, 1), clampBudget(1));
    try std.testing.expectEqual(@as(u32, 1000), clampBudget(1000));
    try std.testing.expectEqual(@as(u32, 1000), clampBudget(5000));
}

test "general and goal room names keep board for the default workspace" {
    const gpa = std.testing.allocator;
    const gen = try generalRoomName(gpa, "relumea");
    defer gpa.free(gen);
    try std.testing.expectEqualStrings("ws:relumea", gen);

    const board = try generalRoomName(gpa, "");
    defer gpa.free(board);
    try std.testing.expectEqualStrings("board", board);

    const goal_room = try goalRoomName(gpa, "relumea", "g1");
    defer gpa.free(goal_room);
    try std.testing.expectEqualStrings("ws:relumea:goal:g1", goal_room);

    const default_goal_room = try goalRoomName(gpa, "", "g1");
    defer gpa.free(default_goal_room);
    try std.testing.expectEqualStrings("goal:g1", default_goal_room);
}
