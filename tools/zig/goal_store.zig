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

pub const Worktree = enum { leave, set_true, clear };

pub const Patch = struct {
    id: []const u8,
    status: ?[]const u8 = null,
    max_iterations: ?u32 = null,
    worktree: Worktree = .leave,
    remove: bool = false,
};

pub const Error = error{
    NoSuchGoal,
    BadStatus,
    BadBudget,
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
        if (patch.remove) continue;
        var updated = g;
        if (patch.status) |s| updated.status = s;
        if (patch.max_iterations) |n| updated.max_iterations = n;
        switch (patch.worktree) {
            .leave => {},
            .set_true => updated.worktree = "true",
            .clear => updated.worktree = null,
        }
        updated.updated = now;
        try out.append(alloc, updated);
    }
    if (!hit) return error.NoSuchGoal;
    return out.toOwnedSlice(alloc);
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
