//! goal_prompt: the first-turn prompt for a continuing goal loop.
//!
//! The CLI (`clanker goal <intent>`) and the TUI's `/goal` submission both
//! start a goal loop from the supplied prompt. Drafting (`goal_write`) and
//! persistence (`goal_add`) are separate, optional capabilities; this prompt
//! makes sure neither entry point turns them into a prerequisite for work.
//!
//! Pure — no allocator of its own beyond the caller's arena, no I/O, no std.Io.
//! It is listed in src/main.zig's comptime block so its tests run.

const std = @import("std");

/// The directive given to the first agent turn. It deliberately does not
/// require a draft or a persisted goal before work begins. `goal_loop.zig`
/// schedules and evaluates later turns.
pub const template =
    "Start working on this goal now: {s}\n" ++
    "\n" ++
    "This is the first turn of a continuing goal loop. Work toward the requested outcome and verify what you can; " ++
    "after this turn an evaluator will decide whether more turns are needed. " ++
    "Do not stop to require a goal_write draft or a goal_add record: those are optional, separate capabilities. " ++
    "Use goal_write only when the user asks to draft or refine a structured goal, and use goal_add only when the user asks to persist one without running it.\n" ++
    "\n" ++
    "Acceptance criteria: if the goal above does not already state a measurable completion criterion, draft one before working — something a script can check, such as time elapsed, a score reached, an eval passing, a file present, or a command exiting zero. Then write a test script at `scripts/verify-goal.sh` that checks that criterion and exits 0 only when it is met. If the goal already states a measurable criterion, use it verbatim and still write the same script. State the criterion plainly in your first message so the evaluator can judge it.";

/// Render the full task prompt for an intent. `alloc` is the caller's arena.
pub fn task(alloc: std.mem.Allocator, intent: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, template, .{intent});
}

test "template carries the intent and starts a loop without a draft or record" {
    const out = try task(std.testing.allocator, "a rough idea");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "a rough idea") != null);
    try std.testing.expect(std.mem.find(u8, out, "continuing goal loop") != null);
    try std.testing.expect(std.mem.find(u8, out, "Do not stop to require") != null);
    try std.testing.expect(std.mem.find(u8, out, "optional, separate capabilities") != null);
    try std.testing.expect(std.mem.find(u8, out, "goal_write") != null);
    try std.testing.expect(std.mem.find(u8, out, "goal_add") != null);
}

test "template asks the agent to draft measurable criteria and a test script" {
    const out = try task(std.testing.allocator, "make it fast");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "measurable completion criterion") != null);
    try std.testing.expect(std.mem.find(u8, out, "scripts/verify-goal.sh") != null);
    try std.testing.expect(std.mem.find(u8, out, "exits 0 only when it is met") != null);
}
