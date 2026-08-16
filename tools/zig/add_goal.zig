//! goal_add: persist a structured goal to state/goals.json without running it.
//! Input:  {"objective":"...","completion_criterion":"...","proof":"...","boundaries":"...","stop_rule":"...","max_iterations":1..1000,"worktree":"..."}
//! Output: {"ok":true,"goal":{...}}

const std = @import("std");
const lib = @import("lib.zig");

extern fn ck_now() u64;

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

    const completion = switch (obj.get("completion_criterion") orelse return lib.fail(out, "missing completion_criterion")) {
        .string => |s| s,
        else => return lib.fail(out, "completion_criterion must be a string"),
    };
    if (completion.len == 0) return lib.fail(out, "completion_criterion must not be empty");

    const proof = fieldString(obj, "proof") orelse "";
    const boundaries = fieldString(obj, "boundaries") orelse "";
    const stop_rule = fieldString(obj, "stop_rule") orelse "";
    // The git worktree this goal belongs to (branch/path), for worktree runs.
    const worktree = fieldString(obj, "worktree") orelse "";
    const max_iterations: ?u32 = if (lib.optNum(parsed, "max_iterations")) |n| blk: {
        if (n < 1 or n > 1000 or @floor(n) != n) return lib.fail(out, "max_iterations must be an integer from 1 to 1000");
        break :blk @as(u32, @trunc(n));
    } else null;

    const now = ck_now();
    const id = std.fmt.allocPrint(lib.alloc, "{d}", .{now}) catch return lib.fail(out, "alloc");

    var obj_buf: std.ArrayList(u8) = .empty;
    defer obj_buf.deinit(lib.alloc);
    try writeGoalObject(&obj_buf, id, objective, completion, proof, boundaries, stop_rule, max_iterations, worktree, now);

    var existing: []const u8 = "";
    if (lib.fsRead("state/goals.json")) |cur| {
        existing = cur;
    } else |err| {
        switch (err) {
            error.NotFound => existing = "[]",
            else => return lib.failErr(out, err, "saving the goal"),
        }
    }

    const e = std.mem.trim(u8, existing, " \t\r\n");
    if (e.len < 2 or e[0] != '[' or e[e.len - 1] != ']') {
        return lib.fail(out, "state/goals.json is not a JSON array");
    }

    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(lib.alloc);
    const inner = std.mem.trim(u8, e[1 .. e.len - 1], " \t\r\n");
    try new_content.appendSlice(lib.alloc, "[");
    if (inner.len > 0) {
        try new_content.appendSlice(lib.alloc, inner);
        try new_content.appendSlice(lib.alloc, ",");
    }
    try new_content.appendSlice(lib.alloc, obj_buf.items);
    try new_content.appendSlice(lib.alloc, "]");

    lib.fsWrite("state/goals.json", new_content.items) catch |err| {
        return lib.failErr(out, err, "saving the goal");
    };

    try out.writeAll("{\"ok\":true,\"goal\":");
    try out.writeAll(obj_buf.items);
    try out.writeAll("}");
}

fn fieldString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn writeGoalObject(
    buf: *std.ArrayList(u8),
    id: []const u8,
    objective: []const u8,
    completion: []const u8,
    proof: []const u8,
    boundaries: []const u8,
    stop_rule: []const u8,
    max_iterations: ?u32,
    worktree: []const u8,
    now: u64,
) !void {
    const wbuf = try lib.alloc.alloc(u8, 32 * 1024);
    defer lib.alloc.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    try s.objectField("objective");
    try s.write(objective);
    try s.objectField("completion_criterion");
    try s.write(completion);
    try s.objectField("proof");
    try s.write(proof);
    try s.objectField("boundaries");
    try s.write(boundaries);
    try s.objectField("stop_rule");
    try s.write(stop_rule);
    if (max_iterations) |n| {
        try s.objectField("max_iterations");
        try s.print("{d}", .{n});
    }
    if (worktree.len > 0) {
        try s.objectField("worktree");
        try s.write(worktree);
    }
    try s.objectField("status");
    try s.write("active");
    try s.objectField("created");
    try s.print("{d}", .{now});
    try s.objectField("updated");
    try s.print("{d}", .{now});
    try s.endObject();
    try buf.appendSlice(lib.alloc, w.buffer[0..w.end]);
}
