//! goal_add: persist a structured goal to state/goals.json without running it.
//!
//! The board card is the goal's visible work surface; the web UI mirrors the
//! goal onto the board through the board tool (see ui/app/features/goals.js
//! mirrorGoalsToBoard). This tool only appends the durable record; it never
//! creates the card itself, so the mirror stays the single card writer.
//! `completion_criterion` is optional: a raw goal without one is allowed and
//! the goal loop's first turn drafts it (PRD 0035 Goal 5).
//!
//! Add is idempotent: a live goal with the same objective in the same
//! workspace already counts as the goal, so a double-click, a retried HTTP
//! POST, or a re-run of the same command returns that record instead of
//! appending a second row (which would mirror a second board card and give
//! goal_update/remove by id two rows to hit). The write is a compare-and-swap
//! retried on mismatch, the same shape as goal_update, so two racing adds
//! converge on one row too.
//!
//! Input:  {"objective":"...","completion_criterion":"...","proof":"...","boundaries":"...","stop_rule":"...","max_iterations":1..1000,"worktree":"..."}
//! Output: {"ok":true,"goal":{...}} | {"ok":true,"goal":{...},"duplicate":true}

const std = @import("std");
const lib = @import("lib.zig");
const store = @import("goal_store.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;

    const objective = switch (obj.get("objective") orelse return lib.fail(out, "missing objective")) {
        .string => |s| s,
        else => return lib.fail(out, "objective must be a string"),
    };
    if (objective.len == 0) return lib.fail(out, "objective must not be empty");

    // Optional: the goal loop drafts a measurable criterion on its first turn
    // when none is supplied.
    const completion: []const u8 = if (obj.get("completion_criterion")) |v| switch (v) {
        .string => |s| s,
        else => return lib.fail(out, "completion_criterion must be a string"),
    } else "";

    const proof = fieldString(obj, "proof") orelse "";
    const boundaries = fieldString(obj, "boundaries") orelse "";
    const stop_rule = fieldString(obj, "stop_rule") orelse "";
    // The git worktree this goal belongs to (branch/path), for worktree runs.
    const worktree = fieldString(obj, "worktree") orelse "";
    // Workspace (project) id this goal belongs to (RFC 0001); "" is the default.
    const workspace = fieldString(obj, "workspace") orelse "";
    const max_iterations: ?u32 = if (lib.optNum(parsed, "max_iterations")) |n| blk: {
        if (n < 1 or n > 1000 or @floor(n) != n) return lib.fail(out, "max_iterations must be an integer from 1 to 1000");
        break :blk @as(u32, @trunc(n));
    } else null;

    // The id is the nanosecond clock, unique per add; the stored timestamps
    // are seconds since the Unix epoch, the unit every other store uses and
    // the unit goal_update writes. Mixing the two is what made a goal's
    // `updated` (seconds) sort below its `created` (nanoseconds) and read as
    // the oldest goal in the web UI (state/goals.json carried both next to
    // each other for weeks).
    const now_ns: u64 = lib.nowNanos();
    const now_s: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));

    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var store_missing = false;
        const raw: []const u8 = if (lib.fsRead("state/goals.json")) |cur| cur else |err| switch (err) {
            error.NotFound => blk: {
                store_missing = true;
                break :blk "[]";
            },
            else => return lib.failErr(out, err, "saving the goal"),
        };
        // A store that does not exist yet is matched by the empty expected
        // hash; hashing the "[]" stand-in would match nothing on disk and
        // every write would retry into "goals file kept changing".
        const seen = if (store_missing) "" else try lib.hash(raw);
        const existing = std.json.parseFromSliceLeaky([]store.Goal, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch
            return lib.fail(out, "state/goals.json is not a JSON array");

        // Idempotent add: a live goal with this objective already exists in
        // this workspace, so a double-submit returns it instead of appending
        // a second row. Checked on every CAS retry, so two racing adds read
        // each other's row and converge too.
        if (store.findAddDuplicate(existing, objective, workspace)) |dup| {
            return replyGoal(out, dup, true);
        }

        const goal = store.Goal{
            .id = try std.fmt.allocPrint(lib.alloc, "{d}", .{now_ns}),
            .objective = objective,
            .completion_criterion = completion,
            .proof = proof,
            .boundaries = boundaries,
            .stop_rule = stop_rule,
            .max_iterations = max_iterations,
            .worktree = if (worktree.len > 0) worktree else null,
            .workspace = workspace,
            .status = "active",
            .created = now_s,
            .updated = now_s,
        };

        var goal_buf: std.ArrayList(u8) = .empty;
        defer goal_buf.deinit(lib.alloc);
        try encodeGoal(&goal_buf, goal);

        var new_content: std.ArrayList(u8) = .empty;
        defer new_content.deinit(lib.alloc);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
            return lib.fail(out, "state/goals.json is not a JSON array");
        }
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        try new_content.appendSlice(lib.alloc, "[");
        if (inner.len > 0) {
            try new_content.appendSlice(lib.alloc, inner);
            try new_content.appendSlice(lib.alloc, ",");
        }
        try new_content.appendSlice(lib.alloc, goal_buf.items);
        try new_content.appendSlice(lib.alloc, "]");

        lib.fsWriteIf("state/goals.json", seen, new_content.items) catch |err| switch (err) {
            error.Mismatch => continue,
            else => return lib.failErr(out, err, "saving the goal"),
        };
        return replyGoal(out, goal, false);
    }
    return lib.fail(out, "goals file kept changing underneath; try again");
}

fn fieldString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

/// Encodes one goal the way the stored array expects it: nulls omitted, so
/// an empty `worktree`/`workspace`/`max_iterations` leaves no key at all.
fn encodeGoal(buf: *std.ArrayList(u8), goal: store.Goal) !void {
    const wbuf = try lib.alloc.alloc(u8, 32 * 1024);
    defer lib.alloc.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.write(goal);
    try buf.appendSlice(lib.alloc, w.buffer[0..w.end]);
}

/// The reply for both a created goal and a duplicate of one. `duplicate`
/// distinguishes the idempotent replay ("this goal already exists, here it
/// is") from a fresh add without breaking callers that only read `goal.id`.
fn replyGoal(out: *lib.Out, goal: store.Goal, duplicate: bool) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("goal");
    try s.write(goal);
    if (duplicate) {
        try s.objectField("duplicate");
        try s.write(true);
    }
    try s.endObject();
    lib.commit(out, &w);
}
