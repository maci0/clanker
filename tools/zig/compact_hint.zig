//! Compact-prompt concat for /compact [hint] (ADR 0043 / PRD 0054).

const std = @import("std");

pub const base =
    "Summarize the following conversation excerpt in 3-5 concise bullet points. " ++
    "Focus on: decisions made, facts established, tool results, and any pending tasks. " ++
    "Be specific: include names, numbers, and key values. Do NOT add commentary.";

/// Operator hint is appended only when non-empty after trim. Transcript is last.
pub fn formatPrompt(alloc: std.mem.Allocator, transcript: []const u8, hint: []const u8) ![]u8 {
    const h = std.mem.trim(u8, hint, " \t\r\n");
    if (h.len == 0) {
        return std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ base, transcript });
    }
    return std.fmt.allocPrint(alloc, "{s} The operator asked to preserve: {s}\n\n{s}", .{ base, h, transcript });
}

test "formatPrompt without a hint is the base plus transcript" {
    const got = try formatPrompt(std.testing.allocator, "hello", "");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, base));
    try std.testing.expect(std.mem.endsWith(u8, got, "hello"));
    try std.testing.expect(std.mem.find(u8, got, "preserve:") == null);
}

test "formatPrompt with a hint names what to preserve" {
    const got = try formatPrompt(std.testing.allocator, "body", "  Keep the migrations  ");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.find(u8, got, "The operator asked to preserve: Keep the migrations") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "body"));
}
