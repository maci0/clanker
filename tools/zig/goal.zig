//! goal: design and persist a structured goal to state/goals.json
//! Input:  {"objective":"...","completion_criterion":"...","proof":"...","boundaries":"...","stop_rule":"..."}
//! Output: {"ok":true,"goal":{...}}

const std = @import("std");
const lib = @import("lib.zig");

extern fn ck_now() u64;

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;

    const objective = switch (obj.get("objective") orelse return errJson(out, "missing objective")) {
        .string => |s| s,
        else => return errJson(out, "objective must be a string"),
    };
    if (objective.len == 0) return errJson(out, "objective must not be empty");

    const completion = switch (obj.get("completion_criterion") orelse return errJson(out, "missing completion_criterion")) {
        .string => |s| s,
        else => return errJson(out, "completion_criterion must be a string"),
    };
    if (completion.len == 0) return errJson(out, "completion_criterion must not be empty");

    const proof = fieldString(obj, "proof") orelse "";
    const boundaries = fieldString(obj, "boundaries") orelse "";
    const stop_rule = fieldString(obj, "stop_rule") orelse "";

    const now = ck_now();
    const id = std.fmt.allocPrint(std.heap.wasm_allocator, "{d}", .{now}) catch return errJson(out, "alloc");

    var obj_buf: std.ArrayList(u8) = .empty;
    defer obj_buf.deinit(std.heap.wasm_allocator);
    try writeGoalObject(&obj_buf, id, objective, completion, proof, boundaries, stop_rule, now);

    var existing: []const u8 = "";
    if (lib.fsRead("state/goals.json")) |cur| {
        existing = cur;
    } else |err| {
        switch (err) {
            error.NotFound => existing = "[]",
            else => return errJson(out, @errorName(err)),
        }
    }

    const e = std.mem.trim(u8, existing, " \t\r\n");
    if (e.len < 2 or e[0] != '[' or e[e.len - 1] != ']') {
        return errJson(out, "state/goals.json is not a JSON array");
    }

    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(std.heap.wasm_allocator);
    const inner = std.mem.trim(u8, e[1 .. e.len - 1], " \t\r\n");
    try new_content.appendSlice(std.heap.wasm_allocator, "[");
    if (inner.len > 0) {
        try new_content.appendSlice(std.heap.wasm_allocator, inner);
        try new_content.appendSlice(std.heap.wasm_allocator, ",");
    }
    try new_content.appendSlice(std.heap.wasm_allocator, obj_buf.items);
    try new_content.appendSlice(std.heap.wasm_allocator, "]");

    lib.fsWrite("state/goals.json", new_content.items) catch |err| {
        return errJson(out, @errorName(err));
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
    now: u64,
) !void {
    const wbuf = try std.heap.wasm_allocator.alloc(u8, 32 * 1024);
    defer std.heap.wasm_allocator.free(wbuf);
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
    try s.objectField("status");
    try s.write("active");
    try s.objectField("created");
    try s.print("{d}", .{now});
    try s.objectField("updated");
    try s.print("{d}", .{now});
    try s.endObject();
    try buf.appendSlice(std.heap.wasm_allocator, w.buffer[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var b: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&b, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
