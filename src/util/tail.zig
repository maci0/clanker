//! Tail a buffer on a line boundary.
//!
//! Three surfaces keep only the end of a longer text: the logs guest opens
//! `state/logs/*`, the autolearn observations feed a rewrite prompt, and the
//! autoresearch ledger carries each harness run's stdout/stderr tails. All
//! three need the same rule, because a window that starts mid-line presents
//! a torn fragment as if it were the beginning of the output. One helper so
//! those sites cannot drift.

const std = @import("std");

/// The last `max_bytes` of `s`, cut forward to the first newline so only
/// whole lines are kept. Text that fits is returned unchanged; a window
/// holding no newline is kept raw rather than inventing content.
pub fn onLineBoundary(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    const window = s[s.len - max_bytes ..];
    if (std.mem.findScalar(u8, window, '\n')) |nl| return window[nl + 1 ..];
    return window;
}

test "onLineBoundary keeps a short buffer whole" {
    try std.testing.expectEqualStrings("abc", onLineBoundary("abc", 64));
    try std.testing.expectEqualStrings("", onLineBoundary("", 64));
}

test "onLineBoundary drops the leading partial line" {
    try std.testing.expectEqualStrings("cd", onLineBoundary("ab\ncd", 4));
    try std.testing.expectEqualStrings("cccc\ndddd\n", onLineBoundary("aaaa\nbbbb\ncccc\ndddd\n", 11));
    // The last `max_bytes`, minus the partial line they start inside. For
    // "a\nb\nc\nd\ne\nf" (11 bytes) the last 3 are "e\nf", whose first line is
    // the partial "e", so only "f" survives; the last 4 are "\ne\nf", where the
    // partial line is empty and "e\nf" survives whole. 5 lands mid-"d" and so
    // keeps the same two lines as 4.
    const lines = "a\nb\nc\nd\ne\nf";
    try std.testing.expectEqualStrings("f", onLineBoundary(lines, 3));
    try std.testing.expectEqualStrings("e\nf", onLineBoundary(lines, 4));
    try std.testing.expectEqualStrings("e\nf", onLineBoundary(lines, 5));
    try std.testing.expectEqualStrings("d\ne\nf", onLineBoundary(lines, 7));
}

test "onLineBoundary keeps a newline-less window raw" {
    try std.testing.expectEqualStrings("bcde", onLineBoundary("abcde", 4));
    try std.testing.expectEqualStrings("yyyy", onLineBoundary("xxxxxyyyy", 4));
}

test "onLineBoundary keeps an exactly-fitting buffer unchanged" {
    const exact = "x" ** 8;
    try std.testing.expectEqualStrings(exact, onLineBoundary(exact, 8));
}
