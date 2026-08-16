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

pub fn validate(steps: []const Step, max_steps: usize) Error!void {
    if (steps.len == 0) return error.EmptySteps;
    if (steps.len > clampMax(max_steps)) return error.TooManySteps;
    for (steps) |s| {
        if (s.tool.len == 0) return error.EmptyTool;
        if (std.mem.eql(u8, s.tool, "run_plan") or std.mem.eql(u8, s.tool, "chain"))
            return error.NestedPlan;
    }
}

test "validate refuses empty, overflow, and nested plans" {
    try std.testing.expectError(error.EmptySteps, validate(&.{}, 12));
    const one = [_]Step{.{ .tool = "read_file", .args = "{}" }};
    try validate(&one, 12);
    try std.testing.expectError(error.EmptyTool, validate(&.{.{ .tool = "" }}, 12));
    try std.testing.expectError(error.NestedPlan, validate(&.{.{ .tool = "run_plan" }}, 12));
    try std.testing.expectError(error.NestedPlan, validate(&.{.{ .tool = "chain" }}, 12));
    try std.testing.expectEqual(@as(usize, 16), clampMax(99));
    try std.testing.expectEqual(@as(usize, 12), clampMax(0));
}
