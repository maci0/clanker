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

/// Returns `s` unchanged when it fits, otherwise a suffix of at most
/// `max_bytes` that begins on a codepoint boundary. The mirror of `cap` for
/// callers that keep the end of the text (a build gate's stderr tail).
pub fn tail(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var start = s.len - max_bytes;
    // Skip forward over any continuation bytes so the cut does not land in
    // the middle of a multi-byte sequence; all-continuation (invalid) input
    // walks to the end and yields an empty slice rather than a dangling one.
    while (start < s.len and (s[start] & 0xC0) == 0x80) start += 1;
    return s[start..];
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

/// Writes `s` into `stringify` as one JSON string, replacing invalid UTF-8
/// bytes with U+FFFD first (`sanitize`). `std.json.Stringify.write` serializes
/// a slice that is not valid UTF-8 as an *array of byte numbers*, so any
/// filesystem name or file body written raw turned that element into an
/// array: one weird-but-legal filename broke every reader expecting a string,
/// from the web UI's `/api/files` listing to guests walking `ck_fs_list`
/// output. The valid fast path is the plain write, no copy.
pub fn writeJsonString(gpa: std.mem.Allocator, stringify: *std.json.Stringify, s: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(s)) return stringify.write(s);
    const clean = try sanitize(gpa, s);
    defer if (clean.ptr != s.ptr) gpa.free(clean);
    return stringify.write(clean);
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

test "tail never splits a codepoint" {
    try std.testing.expectEqualStrings("", tail("", 5));
    try std.testing.expectEqualStrings("hello", tail("hello", 100));
    try std.testing.expectEqualStrings("llo", tail("hello", 3));

    // A tail of "héllo" starting on é's second byte walks forward to the
    // next lead byte instead of emitting a dangling continuation.
    try std.testing.expectEqualStrings("llo", tail("héllo", 4));
    try std.testing.expectEqualStrings("", tail("é", 1));
    try std.testing.expectEqualStrings("é", tail("é", 2));

    // "😀" is 4 bytes: a 3-byte tail cannot hold it whole, so nothing is
    // left; a 4-byte tail keeps the emoji complete.
    try std.testing.expectEqualStrings("", tail("a😀", 3));
    try std.testing.expectEqualStrings("😀", tail("a😀", 4));
}

test "sanitize passes valid UTF-8 through untouched" {
    try std.testing.expectEqualStrings("", try sanitize(std.testing.allocator, ""));
    const clean = "café — déjà vu ✨";
    try std.testing.expectEqualStrings(clean, try sanitize(std.testing.allocator, clean));
}

test "writeJsonString emits a string for invalid bytes, not an array of numbers" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var s = std.json.Stringify{ .writer = &buf.writer, .options = .{} };
    // A latin-1 filename byte: `Stringify.write` alone would emit [195, 169].
    try writeJsonString(std.testing.allocator, &s, "caf\xe9.txt");
    const out = buf.written();
    try std.testing.expect(std.mem.startsWith(u8, out, "\"caf"));
    try std.testing.expect(std.mem.endsWith(u8, out, ".txt\""));
    try std.testing.expect(std.mem.indexOf(u8, out, "[") == null);
    // Parsed back, it is a string carrying the replacement character.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("caf\u{FFFD}.txt", parsed.value.string);
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
