//! Pure validation for Code Mode v1: a bounded list of {tool, args} steps.

const std = @import("std");

pub const max_steps_default: usize = 12;
pub const max_steps_ceiling: usize = 16;

pub const Step = struct {
    tool: []const u8,
    args: []const u8 = "{}",
};

pub const Error = error{
    EmptySteps,
    TooManySteps,
    EmptyTool,
    NestedPlan,
};

pub fn clampMax(n: usize) usize {
    if (n == 0) return max_steps_default;
    return @min(n, max_steps_ceiling);
}

/// One actionable sentence for a failed `ck_tool` step. The raw Zig error
/// name ("SandboxDenied", "NotFound") reaches the model as the step's error
/// field and gives it nothing to do; these say which way to move instead.
pub fn stepErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.SandboxDenied => "this plan is not allowed to call that tool (its tool_call/tool_allow policy refuses it)",
        error.NotFound => "no tool by that name is loaded",
        error.TooLarge => "the tool call or its result exceeded a size cap",
        error.NetworkError => "the tool call did not complete",
        error.InvalidArg => "the tool rejected the step's args",
        else => "the tool call failed",
    };
}

pub fn validate(steps: []const Step, max_steps: usize) Error!void {
    if (steps.len == 0) return error.EmptySteps;
    if (steps.len > clampMax(max_steps)) return error.TooManySteps;
    for (steps) |s| {
        if (s.tool.len == 0) return error.EmptyTool;
        if (std.mem.eql(u8, s.tool, "run_plan") or std.mem.eql(u8, s.tool, "chain"))
            return error.NestedPlan;
    }
}

test "step errors name the fix, not the zig error" {
    try std.testing.expectEqualStrings("no tool by that name is loaded", stepErrorMessage(error.NotFound));
    try std.testing.expect(std.mem.find(u8, stepErrorMessage(error.SandboxDenied), "not allowed") != null);
    try std.testing.expectEqualStrings("the tool rejected the step's args", stepErrorMessage(error.InvalidArg));
}

test "validate refuses empty, overflow, and nested plans" {
    try std.testing.expectError(error.EmptySteps, validate(&.{}, 12));
    const one = [_]Step{.{ .tool = "read_file", .args = "{}" }};
    try validate(&one, 12);
    try std.testing.expectError(error.EmptyTool, validate(&.{.{ .tool = "" }}, 12));
    try std.testing.expectError(error.NestedPlan, validate(&.{.{ .tool = "run_plan" }}, 12));
    try std.testing.expectError(error.NestedPlan, validate(&.{.{ .tool = "chain" }}, 12));

    // The length ceiling is the clamped max, checked at both edges: exactly
    // max_steps steps pass, one more is TooManySteps, and a plan past the
    // ceiling is refused even when the caller asked for more.
    const twelve = [_]Step{.{ .tool = "read_file" }} ** 12;
    try validate(&twelve, 12);
    try std.testing.expectError(error.TooManySteps, validate(&(twelve ++ [_]Step{.{ .tool = "read_file" }}), 12));
    const sixteen = [_]Step{.{ .tool = "read_file" }} ** 16;
    try validate(&sixteen, 99);
    try std.testing.expectError(error.TooManySteps, validate(&(sixteen ++ [_]Step{.{ .tool = "read_file" }}), 99));
    try std.testing.expectEqual(@as(usize, 16), clampMax(99));
    try std.testing.expectEqual(@as(usize, 16), clampMax(std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 12), clampMax(0));
    try std.testing.expectEqual(@as(usize, 12), clampMax(12));
}

/// The error a step's callee reported, when that callee answered
/// `{"ok":false,...}`. A guest failure is a *successful* ck_tool call whose
/// body carries the failure, so the host return code alone cannot tell a step
/// that worked from one that refused; this reads the inner envelope. Returns
/// null for a success, for a non-JSON body (a raw exec envelope), and for JSON
/// that is not an object, so only a real `ok:false` flips a step.
pub fn innerError(alloc: std.mem.Allocator, result: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, result, .{}) catch return null;
    if (parsed != .object) return null;
    const flag = parsed.object.get("ok") orelse return null;
    if (flag != .bool or flag.bool) return null;
    const msg = parsed.object.get("error") orelse return "the tool reported ok:false";
    if (msg != .string or msg.string.len == 0) return "the tool reported ok:false";
    return msg.string;
}

test "innerError reads the callee's own envelope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "unknown todo id 7",
        innerError(alloc, "{\"ok\":false,\"error\":\"unknown todo id 7\"}") orelse unreachable,
    );
    // A step that worked, a non-object body, a body with no ok, an
    // ok:false with no usable message, and a non-JSON exec envelope all
    // leave the step reporting the host return code.
    try std.testing.expectEqual(@as(?[]const u8, null), innerError(alloc, "{\"ok\":true}"));
    try std.testing.expectEqual(@as(?[]const u8, null), innerError(alloc, "[1,2]"));
    try std.testing.expectEqual(@as(?[]const u8, null), innerError(alloc, "{\"code\":0}"));
    try std.testing.expectEqual(
        @as(?[]const u8, "the tool reported ok:false"),
        innerError(alloc, "{\"ok\":false}"),
    );
    try std.testing.expectEqual(
        @as(?[]const u8, "the tool reported ok:false"),
        innerError(alloc, "{\"ok\":false,\"error\":\"\"}"),
    );
    try std.testing.expectEqual(@as(?[]const u8, null), innerError(alloc, "not json at all"));
}
