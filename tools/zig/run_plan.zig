//! run_plan: Code Mode v1. One call runs a bounded list of existing tools.
//! Input: {"steps":[{"tool":"read_file","args":{...}}, ...]}
//! Output: {"ok":true,"steps":[{"tool":"...","ok":true,"text":"..."}]}

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("run_plan_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const steps_v = switch (req) {
        .object => |o| o.get("steps") orelse return lib.fail(out, "missing steps"),
        else => return lib.fail(out, "input must be a JSON object"),
    };
    if (steps_v != .array) return lib.fail(out, "steps must be an array");

    var max_steps: usize = logic.max_steps_default;
    if (lib.optNum(req, "max_steps")) |n| {
        if (n > 0) max_steps = @intFromFloat(n);
    }
    max_steps = logic.clampMax(max_steps);

    var steps: std.ArrayList(logic.Step) = .empty;
    for (steps_v.array.items) |item| {
        if (item != .object) return lib.fail(out, "each step must be an object");
        const tool = switch (item.object.get("tool") orelse return lib.fail(out, "step missing tool")) {
            .string => |s| s,
            else => return lib.fail(out, "tool must be a string"),
        };
        var args_json: []const u8 = "{}";
        if (item.object.get("args")) |av| {
            if (av == .string) {
                args_json = av.string;
            } else {
                var aw = std.Io.Writer.Allocating.init(lib.alloc);
                var js = std.json.Stringify{ .writer = &aw.writer, .options = .{} };
                js.write(av) catch return lib.fail(out, "could not encode args");
                args_json = aw.written();
            }
        }
        try steps.append(lib.alloc, .{ .tool = tool, .args = args_json });
    }

    logic.validate(steps.items, max_steps) catch |err| return switch (err) {
        error.EmptySteps => lib.fail(out, "steps must not be empty"),
        error.TooManySteps => lib.fail(out, "too many steps"),
        error.EmptyTool => lib.fail(out, "step tool must not be empty"),
        error.NestedPlan => lib.fail(out, "run_plan cannot call run_plan or chain"),
    };

    var w = lib.writer(out);
    try w.writeAll("{\"ok\":true,\"steps\":[");
    for (steps.items, 0..) |step, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"tool\":");
        try std.json.Stringify.value(step.tool, .{}, &w);
        const result = lib.toolCall(step.tool, step.args) catch |err| {
            try w.writeAll(",\"ok\":false,\"error\":");
            try std.json.Stringify.value(@errorName(err), .{}, &w);
            try w.writeByte('}');
            continue;
        };
        try w.writeAll(",\"ok\":true,\"text\":");
        try std.json.Stringify.value(result, .{}, &w);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    lib.commit(out, &w);
}
