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
    goal_loop_reason: []const u8 = "",
    goal_loop_turns: u32 = 0,
    max_iterations: ?u32 = null,
    worktree: ?[]const u8 = null,
    created: i64 = 0,
    updated: i64 = 0,
};

pub const Worktree = union(enum) { leave, set_true, clear, value: []const u8 };

pub const Patch = struct {
    id: []const u8,
    /// When set, the write is a no-op unless the goal currently holds this
    /// status. Run-completion uses `from = "active"` so a hand move or a
    /// deleted goal is left alone.
    from_status: ?[]const u8 = null,
    status: ?[]const u8 = null,
    max_iterations: ?u32 = null,
    worktree: Worktree = .leave,
    goal_loop_reason: ?[]const u8 = null,
    goal_loop_turns: ?u32 = null,
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
        if (patch.max_iterations) |n| updated.max_iterations = n;
        switch (patch.worktree) {
            .leave => {},
            .set_true => updated.worktree = "true",
            .clear => updated.worktree = null,
            .value => |v| updated.worktree = v,
        }
        if (patch.goal_loop_reason) |r| updated.goal_loop_reason = r;
        if (patch.goal_loop_turns) |n| updated.goal_loop_turns = n;
        updated.updated = now;
        try out.append(alloc, updated);
    }
    if (!hit) return error.NoSuchGoal;
    return out.toOwnedSlice(alloc);
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
