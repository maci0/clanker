//! update_goal: change or remove one record in state/goals.json.
//! Input:  {"id":"...","status":"...","max_iterations":1..1000,"worktree":bool,"remove":bool}
//! Output: {"ok":true,"goals":[...]}
//!
//! Create stays on `add_goal`. This is the update half the HTTP board used
//! to do natively: one writer for status, budget, the worktree flag, and
//! delete. `internal` so the model keeps using the board tools for lane
//! moves; the harness (and the page through `/api/goals`) is the caller.

const std = @import("std");
const lib = @import("lib.zig");
const store = @import("goal_store.zig");

const goals_path = "state/goals.json";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const id = lib.optStr(req, "id") orelse return lib.fail(out, "update_goal needs an id (get it from add_goal or the board)");
    if (id.len == 0) return lib.fail(out, "update_goal needs an id (get it from add_goal or the board)");

    var patch = store.Patch{ .id = id };
    if (lib.optStr(req, "status")) |s| patch.status = s;
    if (lib.optNum(req, "max_iterations")) |n| {
        if (n < 0 or @floor(n) != n)
            return lib.fail(out, "max_iterations must be an integer from 1 to 1000");
        patch.max_iterations = store.clampBudget(@as(u32, @trunc(n)));
    }
    if (req.object.get("worktree")) |w| {
        if (w != .bool) return lib.fail(out, "worktree must be a boolean");
        patch.worktree = if (w.bool) .set_true else .clear;
    }
    patch.remove = lib.optBool(req, "remove", false);

    const raw = lib.fsRead(goals_path) catch |err| switch (err) {
        error.NotFound => return lib.fail(out, "no such goal"),
        else => return lib.failErr(out, err, "reading state/goals.json"),
    };
    const existing = std.json.parseFromSliceLeaky([]store.Goal, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "state/goals.json is not a JSON array");

    const now: i64 = @intCast(@divTrunc(lib.nowNanos(), std.time.ns_per_s));
    const updated = store.apply(lib.alloc, existing, patch, now) catch |err| switch (err) {
        error.NoSuchGoal => return lib.fail(out, "no such goal"),
        error.BadStatus => return lib.fail(out, "status must be active, review, done, archived or abandoned"),
        error.BadBudget => return lib.fail(out, "max_iterations must be an integer from 1 to 1000"),
        else => return lib.failErr(out, err, "updating the goal"),
    };

    var enc: std.Io.Writer.Allocating = .init(lib.alloc);
    var es = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    try es.write(updated);
    lib.fsWrite(goals_path, enc.written()) catch |err| return lib.failErr(out, err, "saving the goal");

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("goals");
    try s.write(updated);
    try s.endObject();
    lib.commit(out, &w);
}
