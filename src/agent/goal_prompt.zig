//! goal_prompt: the single source of truth for the "design a goal" task prompt.
//!
//! The CLI (`clanker goal <intent>`) and the TUI's goal submission both built
//! this prompt by hand, and each hardcoded its own copy of the five-field list
//! and the instruction to call the `goal` tool. That was duplicated surface:
//! `skills/write-goal.md` spells the same fields and steps, so three texts could
//! drift apart. This module is the one rendering, and the test block pins the
//! skill to it so a change here or there that breaks the agreement fails the
//! build instead of silently giving the model a stale instruction.
//!
//! Pure — no allocator of its own beyond the caller's arena, no I/O, no std.Io.
//! It is listed in src/main.zig's comptime block so its tests run.

const std = @import("std");

/// The closed field list a well-formed goal carries. Every surface that
/// renders it — this module's template, and skills/write-goal.md — must use
/// exactly this string so reviewers and the model agree on the shape.
pub const field_list = "objective, completion_criterion, proof, boundaries, stop_rule";

/// The directive given to the executing agent: draft via `write_goal`, then
/// persist through the `goal` tool only after the draft is reviewable.
pub const template =
    "Design a structured goal for: {s}\n" ++
    "\n" ++
    "Call write_goal first. Define all five fields ({s}). Present the draft, then call the goal tool to persist it.";

/// Render the full task prompt for an intent. `alloc` is the caller's arena.
pub fn task(alloc: std.mem.Allocator, intent: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, template, .{ intent, field_list });
}

test "template carries the field list and the intent" {
    const out = try task(std.testing.allocator, "a rough idea");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "a rough idea") != null);
    // The five fields appear, comma-separated, exactly once.
    try std.testing.expect(std.mem.count(u8, out, field_list) == 1);
    try std.testing.expect(std.mem.find(u8, out, "Call write_goal first") != null);
    try std.testing.expect(std.mem.find(u8, out, "call the goal tool to persist it") != null);
}

test "skills/write-goal.md stays in agreement with the field list" {
    // The skill is the durable instruction the agent reads each run; if it
    // drifts from the code-rendered field list, the two surfaces disagree on
    // what a goal contains. Pin them together.
    const path = "skills/write-goal.md";
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const skill = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, std.testing.allocator, .limited(1 << 20)) catch
        return error.SkipZigTest; // not present in every cwd; gate runs in-repo
    defer std.testing.allocator.free(skill);
    try std.testing.expect(std.mem.find(u8, skill, field_list) != null);
    try std.testing.expect(std.mem.find(u8, skill, "call the `goal` tool once") != null);
}
