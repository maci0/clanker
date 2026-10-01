//! Character (not byte) length, for the guards whose floor is about how much
//! text a person typed.
//!
//! A byte count is wrong wherever a floor exists to stop a short value being
//! *used*: the search minimum refuses a query that would match everything, and
//! `note_forget` refuses a `match` that could wipe the memory file. Both read
//! as "at least N characters" and both are applied to a substring match, so a
//! two-character CJK query (six bytes) or a one-character emoji (four bytes)
//! sails past a byte guard and then matches broadly. Counting codepoints is
//! the unit the trigram FTS tokenizer and the model both mean.
//!
//! Invalid UTF-8 counts its bytes rather than refusing: a caller handed a
//! truncated paste should not have its guard turn into a refusal, and one bad
//! byte inside a query does not make the rest of it unusable.

const std = @import("std");

/// Codepoints in `s`, falling back to its byte length when `s` is not valid
/// UTF-8.
pub fn count(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Whether `s` is shorter than `min` characters. Every floor a tool states in
/// characters routes through here, so two guards with the same stated minimum
/// cannot disagree about what it counts.
pub fn shorterThan(s: []const u8, min: usize) bool {
    return count(s) < min;
}

test "count counts codepoints, so a multi-byte character is one" {
    try std.testing.expectEqual(@as(usize, 0), count(""));
    try std.testing.expectEqual(@as(usize, 3), count("abc"));
    try std.testing.expectEqual(@as(usize, 1), count("\u{65e5}"));
    try std.testing.expectEqual(@as(usize, 2), count("\u{65e5}\u{672c}"));
    try std.testing.expectEqual(@as(usize, 3), count("\u{1f600}\u{1f600}\u{1f600}"));
    // Combining marks are their own codepoints, which is what a byte count
    // would have hidden and what a grapheme count would disagree with.
    try std.testing.expectEqual(@as(usize, 2), count("e\u{0301}"));
}

test "count falls back to bytes for invalid UTF-8 rather than failing the guard" {
    try std.testing.expectEqual(@as(usize, 3), count("\xff\xfe\xfd"));
    // A single invalid byte inside otherwise valid text: counted as one byte,
    // so a long query stays long instead of collapsing to nothing.
    try std.testing.expectEqual(@as(usize, 4), count("ab\xffc"));
}

test "shorterThan compares characters" {
    try std.testing.expect(shorterThan("", 3));
    try std.testing.expect(shorterThan("ab", 3));
    try std.testing.expect(!shorterThan("abc", 3));
    // Three bytes, one character: refused, where a byte count let it through.
    try std.testing.expect(shorterThan("\u{65e5}", 3));
    try std.testing.expect(shorterThan("\u{65e5}\u{672c}", 3));
    try std.testing.expect(!shorterThan("\u{65e5}\u{672c}\u{8a9e}", 3));
    // The `note_forget` floor.
    try std.testing.expect(!shorterThan("abcd", 4));
    try std.testing.expect(shorterThan("abc", 4));
    try std.testing.expect(!shorterThan("\u{65e5}\u{672c}\u{8a9e}\u{306f}", 4));
}
