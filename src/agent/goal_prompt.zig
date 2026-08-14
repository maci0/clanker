//! goal_prompt: the single source of truth for direct goal execution.
//!
//! The CLI (`clanker goal <intent>`) and the TUI's `/goal` submission both
//! execute a goal from the supplied prompt. Drafting (`write_goal`) and
//! persistence (`add_goal`) are separate, optional capabilities; this prompt
//! makes sure neither entry point turns them into a prerequisite for work.
//!
//! Pure — no allocator of its own beyond the caller's arena, no I/O, no std.Io.
//! It is listed in src/main.zig's comptime block so its tests run.

const std = @import("std");

/// The directive given to the executing agent. It deliberately does not
/// require a draft or a persisted goal before execution begins.
pub const template =
    "Execute this goal directly: {s}\n" ++
    "\n" ++
    "Work toward the requested outcome until its completion condition is met. " ++
    "Do not stop to require a write_goal draft or an add_goal record: those are optional, separate capabilities. " ++
    "Use write_goal only when the user asks to draft or refine a structured goal, and use add_goal only when the user asks to persist one without running it.";

/// Render the full task prompt for an intent. `alloc` is the caller's arena.
pub fn task(alloc: std.mem.Allocator, intent: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, template, .{intent});
}

test "template carries the intent and does not require drafting or persistence" {
    const out = try task(std.testing.allocator, "a rough idea");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "a rough idea") != null);
    try std.testing.expect(std.mem.find(u8, out, "Do not stop to require") != null);
    try std.testing.expect(std.mem.find(u8, out, "optional, separate capabilities") != null);
}
