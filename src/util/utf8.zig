//! Truncate a byte slice on a UTF-8 codepoint boundary.
//!
//! Several surfaces (graph previews, autolearn JSONL, confirm prompts,
//! stream events, schedule tables, board/goal titles and reason logs, memory
//! and repo_search hit text, session-search snippets) cap untrusted or long
//! text before it is re-encoded or stored. A mid-codepoint cut is not a
//! shorter string: it is invalid UTF-8. One helper so those sites cannot
//! drift.

const std = @import("std");

/// Returns `s` unchanged when it fits, otherwise a prefix of at most
/// `max_bytes` that ends on a codepoint boundary.
pub fn cap(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var end = max_bytes;
    // gated on s.len > max_bytes, so end < s.len: the read is in bounds.
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// Returns `s` unchanged when it is valid UTF-8, otherwise a copy with every
/// invalid byte replaced by U+FFFD. Storage boundaries use this so a file the
/// reader will parse as UTF-8 JSON is never written with the arbitrary bytes
/// that arrive on a text path (subprocess output, argv, pasted input): the
/// writer passing them through verbatim made the file unparseable at load
/// (`std.json` rejects invalid UTF-8 in strings), bricking the whole record.
/// The valid fast path is a single validation pass, no copy.
pub fn sanitize(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    // Worst case: every byte is invalid, each replaced by a 3-byte U+FFFD.
    var out = try gpa.alloc(u8, s.len * 3);
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            @memcpy(out[o..][0..3], "\u{FFFD}");
            o += 3;
            i += 1;
            continue;
        };
        if (i + seq_len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + seq_len])) {
            @memcpy(out[o..][0..3], "\u{FFFD}");
            o += 3;
            i += 1;
            continue;
        }
        @memcpy(out[o..][0..seq_len], s[i .. i + seq_len]);
        o += seq_len;
        i += seq_len;
    }
    return gpa.realloc(out, o);
}

test "cap never splits a codepoint" {
    try std.testing.expectEqualStrings("", cap("", 5));
    try std.testing.expectEqualStrings("hello", cap("hello", 100));
    try std.testing.expectEqualStrings("hel", cap("hello", 3));

    // "é" is 2 bytes (0xC3 0xA9). A cap of 2 lands mid-é; the cut backs up
    // to the "h" so no dangling continuation byte is emitted.
    try std.testing.expectEqualStrings("h", cap("héllo", 2));
    try std.testing.expectEqualStrings("hé", cap("héllo", 3));
    try std.testing.expectEqualStrings("", cap("é", 1));
    try std.testing.expectEqualStrings("é", cap("é", 2));

    // Mixed: "aéé" is 5 bytes; a cap of 3 ("a" + complete first "é") leaves
    // the second "é" untouched rather than half of it.
    try std.testing.expectEqualStrings("aé", cap("aéé", 3));
}

test "sanitize passes valid UTF-8 through untouched" {
    try std.testing.expectEqualStrings("", try sanitize(std.testing.allocator, ""));
    const clean = "café — déjà vu ✨";
    try std.testing.expectEqualStrings(clean, try sanitize(std.testing.allocator, clean));
}

test "sanitize replaces invalid bytes without splitting valid sequences" {
    // A lone latin-1 é byte, a valid é, a truncated é (lead byte with a
    // non-continuation next), and a truncated emoji sequence; the valid
    // multi-byte sequences must survive whole.
    const dirty = [_]u8{ 'c', 'a', 'f', 0xE9, ' ', 0xC3, 0xA9, ' ', 0xC3, ' ', 0xF0, 0x9F, 0x98, 0x80, 0x80 };
    const out = try sanitize(std.testing.allocator, &dirty);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    // The valid "é" (2 bytes) stays intact, each broken unit became one U+FFFD.
    try std.testing.expectEqualStrings("caf\u{FFFD} \u{E9} \u{FFFD} \u{1F600}\u{FFFD}", out);
}
