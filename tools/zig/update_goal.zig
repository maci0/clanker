//! goal_update: change or remove one record in state/goals.json.
//! Input:  {"id":"...","status":"...","from":"active","max_iterations":1..1000,
//!          "worktree":true|false|"branch","goal_loop_reason":"...","goal_loop_turns":N,
//!          "remove":bool} | {"action":"list"}
//! Output: {"ok":true,"goals":[...]}
//!
//! Create stays on `goal_add`. This is the only writer for status, budget,
//! worktree, loop outcome, and delete: HTTP, `clanker run`, and the web
//! run-completion hook all come through here. `from` is a compare-and-swap
//! on the current status so a finished run cannot overwrite a hand move.
//! `internal` so the model keeps using the board tools for lane moves.

const std = @import("std");
const lib = @import("lib.zig");
const store = @import("goal_store.zig");

const goals_path = "state/goals.json";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    // The descriptor's schema documents exactly one action value, "list".
    // Anything else used to fall through to the mutation path below, so a
    // typo'd action ("update", "remove") silently patched the goal instead
    // of being refused.
    const action = lib.optStr(req, "action");
    if (action) |a| {
        if (std.mem.eql(u8, a, "list")) return actionList(out);
        return lib.fail(out, "unknown action; use \"list\" to read the store, or omit action and pass id plus the fields to change");
    }
    const id = lib.optStr(req, "id") orelse return lib.fail(out, "goal_update needs an id (get it from goal_add or the kanban)");
    if (id.len == 0) return lib.fail(out, "goal_update needs an id (get it from goal_add or the kanban)");

    var patch = store.Patch{ .id = id };
    if (lib.optStr(req, "from")) |from| patch.from_status = from;
    if (lib.optStr(req, "status")) |s| patch.status = s;
    if (lib.optStr(req, "workspace")) |w| patch.workspace = w;
    if (req.object.get("running")) |v| {
        patch.running = switch (v) {
            .bool => |b| b,
            else => return lib.fail(out, "running must be a boolean"),
        };
    }
    if (lib.optNum(req, "max_iterations")) |n| {
        if (n < 0 or @floor(n) != n)
            return lib.fail(out, "max_iterations must be an integer from 1 to 1000");
        patch.max_iterations = store.clampBudget(@as(u32, @trunc(n)));
    }
    if (req.object.get("worktree")) |w| {
        patch.worktree = switch (w) {
            .bool => |b| if (b) .set_true else .clear,
            .string => |s| .{ .value = s },
            else => return lib.fail(out, "worktree must be a boolean or a string"),
        };
    }
    if (lib.optStr(req, "goal_loop_reason")) |r| patch.goal_loop_reason = r;
    if (lib.optNum(req, "goal_loop_turns")) |n| {
        if (n < 0 or @floor(n) != n)
            return lib.fail(out, "goal_loop_turns must be a non-negative integer");
        patch.goal_loop_turns = @as(u32, @trunc(n));
    }
    patch.remove = lib.optBool(req, "remove", false);

    // Task mutations (RFC 0001): one per call, applied after the field edits.
    if (req.object.get("task_add")) |v| {
        if (v != .object) return lib.fail(out, "task_add must be an object");
        const text = lib.optStr(v, "text") orelse return lib.fail(out, "task_add needs text");
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return lib.fail(out, "task_add text must not be empty");
        const task_id = lib.optStr(v, "id") orelse (std.fmt.allocPrint(lib.alloc, "task-{d}", .{lib.nowNanos()}) catch return lib.fail(out, "alloc"));
        var visible_to: std.ArrayList([]const u8) = .empty;
        if (v.object.get("visible_to")) |vv| {
            if (vv != .array) return lib.fail(out, "visible_to must be an array of instance ids");
            for (vv.array.items) |item| {
                if (item != .string or item.string.len == 0) return lib.fail(out, "visible_to entries must be non-empty strings");
                visible_to.append(lib.alloc, item.string) catch return lib.fail(out, "alloc");
            }
        }
        patch.task = .{ .add = .{ .id = task_id, .text = text, .visible_to = visible_to.items } };
    } else if (req.object.get("task_toggle")) |v| {
        if (v != .object) return lib.fail(out, "task_toggle must be an object");
        const task_toggle_id = lib.optStr(v, "id") orelse return lib.fail(out, "task_toggle needs id");
        patch.task = .{ .toggle = .{ .id = task_toggle_id, .done = lib.optBool(v, "done", true) } };
    } else if (req.object.get("task_remove")) |v| {
        const task_remove_id = switch (v) {
            .string => |s| s,
            else => return lib.fail(out, "task_remove must be a string id"),
        };
        if (task_remove_id.len == 0) return lib.fail(out, "task_remove needs id");
        patch.task = .{ .remove = task_remove_id };
    }

    const now: i64 = @intCast(@divTrunc(lib.nowNanos(), std.time.ns_per_s));
    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        const raw = lib.fsRead(goals_path) catch |err| switch (err) {
            error.NotFound => return lib.fail(out, "no such goal"),
            else => return lib.failErr(out, err, "reading state/goals.json"),
        };
        const seen = try lib.hash(raw);
        const existing = std.json.parseFromSliceLeaky([]store.Goal, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch
            return lib.fail(out, "state/goals.json is not a JSON array");

        const updated = store.apply(lib.alloc, existing, patch, now) catch |err| switch (err) {
            error.NoSuchGoal => return lib.fail(out, "no such goal"),
            error.NoSuchTask => return lib.fail(out, "no such task on that goal"),
            error.BadTask => return lib.fail(out, "task text must not be empty"),
            error.BadStatus => return lib.fail(out, "status must be active, review, done, archived, abandoned or blocked"),
            error.BadBudget => return lib.fail(out, "max_iterations must be an integer from 1 to 1000"),
            // A finished run must not overwrite a hand move. Same body as a
            // successful write so the caller does not treat "already moved"
            // as a failure.
            error.StatusMismatch => return writeGoals(out, raw),
            else => return lib.failErr(out, err, "updating the goal"),
        };

        var enc: std.Io.Writer.Allocating = .init(lib.alloc);
        var es = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
        try es.write(updated);
        lib.fsWriteIf(goals_path, seen, enc.written()) catch |err| switch (err) {
            error.Mismatch => continue,
            else => return lib.failErr(out, err, "saving the goal"),
        };
        return writeUpdated(out, updated);
    }
    return lib.fail(out, "goals file kept changing underneath; try again");
}

fn writeUpdated(out: *lib.Out, updated: []store.Goal) !void {
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

/// `{"action":"list"}` — the goals store's read side. The mutation guests own
/// the file, so the HTTP GET route reads it through this same owner instead of
/// a native copy; the array is passed through verbatim (re-encoding would only
/// add a way for the two to drift) after a shape check.
fn actionList(out: *lib.Out) !void {
    const raw = lib.fsRead(goals_path) catch |err| switch (err) {
        error.NotFound => return writeGoals(out, "[]"),
        else => return lib.failErr(out, err, "reading state/goals.json"),
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    _ = std.json.parseFromSliceLeaky([]store.Goal, lib.alloc, trimmed, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "state/goals.json is not a JSON array");
    return writeGoals(out, trimmed);
}

fn writeGoals(out: *lib.Out, goals_json: []const u8) !void {
    var w = lib.writer(out);
    try store.writeListEnvelope(&w, goals_json);
    lib.commit(out, &w);
}
