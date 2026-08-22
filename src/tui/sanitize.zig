//! Terminal injection prevention (CWE-150).
//!
//! Everything clanker renders is text it did not generate itself: LLM
//! responses, tool output, peer chat, file contents. A raw ESC byte in any
//! of that would otherwise print straight to the user's terminal.
//!
//! This module owns the single predicate and the two output paths (writer,
//! allocating) so transcript.zig, syntax.zig and repl.zig share one
//! definition instead of three that must stay in sync by comment.

const std = @import("std");

/// True for C0 controls and DEL that must not reach the terminal.
/// \n stays (line structure) and \t stays (layout; cannot start an escape).
pub fn isControl(c: u8) bool {
    return (c < 0x20 and c != '\n' and c != '\t') or c == 0x7F;
}

/// Writes `bytes` with C0 controls (except \n and \t), DEL, and
/// UTF-8-encoded C1 controls (U+0080..U+009F, the two-byte sequence
/// 0xC2 0x80..0x9F) removed. Bare continuation bytes in that range are
/// left alone: they are the tails of legitimate multi-byte codepoints
/// like "\xe2\x82\xac" (U+20AC, Euro sign).
pub fn writeSanitized(w: *std.Io.Writer, bytes: []const u8) void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1B and i + 1 < bytes.len and bytes[i + 1] == 0x5D) {
            // OSC sequence: ESC ] … (BEL | ST); consume the whole thing.
            if (i > start) w.writeAll(bytes[start..i]) catch {};
            var j = i + 2;
            while (j < bytes.len) {
                if (bytes[j] == 0x07) break;
                if (bytes[j] == 0x1B and j + 1 < bytes.len and bytes[j + 1] == 0x5C) {
                    j += 2;
                    break;
                }
                j += 1;
            }
            i = j;
            start = i;
        } else if (bytes[i] == 0x1B and i + 1 < bytes.len and bytes[i + 1] == 0x5B) {
            // CSI sequence: ESC [ params final; consume it whole so the
            // parameter bytes don't leak as visible "[31m" text.
            if (i > start) w.writeAll(bytes[start..i]) catch {};
            i = csiEnd(bytes, i);
            start = i;
        } else if (bytes[i] == 0x1B and i + 1 < bytes.len and bytes[i + 1] >= 0x20 and bytes[i + 1] <= 0x7E) {
            // Other single-byte escape sequences (ESC M, ESC c, ESC 7, ESC (, ...):
            // consume the introducer and its argument so the argument byte does
            // not leak as visible text.
            if (i > start) w.writeAll(bytes[start..i]) catch {};
            i += 2;
            start = i;
        } else if (isControl(bytes[i])) {
            if (i > start) w.writeAll(bytes[start..i]) catch {};
            i += 1;
            start = i;
        } else if (bytes[i] == 0xC2 and i + 1 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9F) {
            if (i > start) w.writeAll(bytes[start..i]) catch {};
            i += 2;
            start = i;
        } else {
            i += 1;
        }
    }
    if (start < bytes.len) w.writeAll(bytes[start..]) catch {};
}

/// Allocating variant: returns `bytes` unchanged when nothing needs
/// stripping (common case, no allocation), or a freshly allocated copy
/// with controls removed.
pub fn sanitizeAlloc(gpa: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (isControl(bytes[i]) or
            (bytes[i] == 0x1B and i + 1 < bytes.len and (bytes[i + 1] == 0x5D or bytes[i + 1] == 0x5B)) or
            (bytes[i] == 0xC2 and i + 1 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9F))
        {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            try out.ensureTotalCapacity(gpa, bytes.len);
            var j: usize = 0;
            while (j < bytes.len) {
                if (bytes[j] == 0x1B and j + 1 < bytes.len and bytes[j + 1] == 0x5D) {
                    var k = j + 2;
                    while (k < bytes.len) {
                        if (bytes[k] == 0x07) break;
                        if (bytes[k] == 0x1B and k + 1 < bytes.len and bytes[k + 1] == 0x5C) {
                            k += 2;
                            break;
                        }
                        k += 1;
                    }
                    j = k;
                } else if (bytes[j] == 0x1B and j + 1 < bytes.len and bytes[j + 1] == 0x5B) {
                    j = csiEnd(bytes, j);
                } else if (bytes[j] == 0x1B and j + 1 < bytes.len and bytes[j + 1] >= 0x20 and bytes[j + 1] <= 0x7E) {
                    j += 2;
                } else if (isControl(bytes[j])) {
                    j += 1;
                } else if (bytes[j] == 0xC2 and j + 1 < bytes.len and bytes[j + 1] >= 0x80 and bytes[j + 1] <= 0x9F) {
                    j += 2;
                } else {
                    out.appendAssumeCapacity(bytes[j]);
                    j += 1;
                }
            }
            return out.toOwnedSlice(gpa);
        }
    }
    return bytes;
}

/// End (exclusive) of the CSI sequence starting at `bytes[i]`, which must be
/// ESC '[' (0x1B 0x5B). Per ECMA-48 a CSI sequence is the introducer, then
/// parameter bytes (0x30-0x3F) and intermediate bytes (0x20-0x2F), terminated
/// by a final byte in 0x40-0x7E. A sequence with no final byte before end of
/// input — or before a byte in none of those classes — is consumed through
/// that point: what is left is escape machinery or malformed input, not text
/// worth showing.
pub fn csiEnd(bytes: []const u8, i: usize) usize {
    var j = i + 2;
    while (j < bytes.len) {
        const c = bytes[j];
        if (c >= 0x40 and c <= 0x7E) return j + 1; // final byte
        if (c >= 0x20 and c <= 0x3F) { // parameter or intermediate
            j += 1;
        } else {
            break;
        }
    }
    return j;
}

// ------------------------------------------------------------------- tests --

test "isControl flags C0 and DEL, keeps newline and tab" {
    try std.testing.expect(isControl(0x1B)); // ESC
    try std.testing.expect(isControl(0x00)); // NUL
    try std.testing.expect(isControl(0x7F)); // DEL
    try std.testing.expect(!isControl('\n'));
    try std.testing.expect(!isControl('\t'));
    try std.testing.expect(!isControl('A'));
}

test "writeSanitized strips ESC, CSI and C1 but keeps text and multi-byte codepoints" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeSanitized(&w, "hello\x1b[31mworld"); // CSI sequence consumed whole
    try std.testing.expectEqualStrings("helloworld", buf[0..w.end]);

    w = .fixed(&buf);
    writeSanitized(&w, "\xc2\x85safe"); // C1 NEL stripped
    try std.testing.expectEqualStrings("safe", buf[0..w.end]);

    w = .fixed(&buf);
    writeSanitized(&w, "\xe2\x82\xac"); // Euro sign kept
    try std.testing.expectEqualStrings("\xe2\x82\xac", buf[0..w.end]);
}

test "writeSanitized strips CSI sequences whole, not just the ESC byte" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeSanitized(&w, "a\x1b[31;1mb\x1b[?25l");
    try std.testing.expectEqualStrings("ab", buf[0..w.end]);
    // A sequence truncated at end of input (no final byte) is consumed too.
    w = .fixed(&buf);
    writeSanitized(&w, "x\x1b[31m");
    try std.testing.expectEqualStrings("x", buf[0..w.end]);
}

test "sanitizeAlloc returns input unchanged when clean" {
    const clean = "hello world\n";
    const result = try sanitizeAlloc(std.testing.allocator, clean);
    try std.testing.expectEqual(clean.ptr, result.ptr);
}

test "sanitizeAlloc strips controls and allocates a copy" {
    const dirty = "a\x00b\xc2\x85c";
    const result = try sanitizeAlloc(std.testing.allocator, dirty);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("abc", result);
}

test "writeSanitized strips single-byte escape sequences" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeSanitized(&w, "a\x1bMb\x1b7c"); // ESC M (reverse index) and ESC 7 (save cursor)
    try std.testing.expectEqualStrings("abc", buf[0..w.end]);
}

test "sanitizeAlloc strips CSI sequences whole" {
    const dirty = "a\x1b[2Jb\xc2\x85c";
    const result = try sanitizeAlloc(std.testing.allocator, dirty);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("abc", result);
}

test "writeSanitized strips OSC sequences (BEL-terminated)" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeSanitized(&w, "before\x1b]38;2;255;0;0\x07after");
    try std.testing.expectEqualStrings("beforeafter", buf[0..w.end]);
}

test "writeSanitized strips OSC sequences (ST-terminated)" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeSanitized(&w, "before\x1b]0;1\x1b\\after");
    try std.testing.expectEqualStrings("beforeafter", buf[0..w.end]);
}

test "sanitizeAlloc strips OSC sequences" {
    const dirty = "a\x1b]38;5;9\x07b";
    const result = try sanitizeAlloc(std.testing.allocator, dirty);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ab", result);
}

test "writeSanitized consumes an unterminated OSC sequence whole" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeSanitized(&w, "pre\x1b]38;2;255;0;0");
    try std.testing.expectEqualStrings("pre", buf[0..w.end]);
}

test "sanitizeAlloc consumes an unterminated OSC sequence whole" {
    const dirty = "pre\x1b]38;2;255;0;0";
    const result = try sanitizeAlloc(std.testing.allocator, dirty);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("pre", result);
}
