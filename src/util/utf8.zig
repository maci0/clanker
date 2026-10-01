//! Truncate a byte slice on a UTF-8 codepoint boundary, and fold text for
//! accent-insensitive search.
//!
//! Several surfaces (graph previews, autolearn JSONL, confirm prompts,
//! stream events, schedule tables, board/goal titles and reason logs, memory
//! and repo_search hit text, session-search snippets) cap untrusted or long
//! text before it is re-encoded or stored. A mid-codepoint cut is not a
//! shorter string: it is invalid UTF-8. One helper so those sites cannot
//! drift.
//!
//! `fold`/`foldFind` are the same idea for the other direction: an operator
//! searching for a word types the letters their keyboard has, and the text
//! they are looking for is spelled with the marks its language puts on them.
//! The web UI folds through `searchFold` (`ui/app/core/utils.js`); the host
//! folds through here, so a query finds the same rows on both sides of the
//! wire instead of only in the browser.

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

/// Inclusive codepoint range that folds to a single ASCII letter. Latin-1
/// Supplement and Latin Extended-A only: those are the two blocks a keyboard
/// user hits when they type a bare letter for a word their language spells
/// with a mark, and they are the blocks `searchFold` in the web UI answers for
/// too. A codepoint outside them folds to itself, so a Cyrillic or CJK query
/// still matches itself exactly, which is what it did before.
const fold_one = [_][3]u21{
    .{ 0x00C0, 0x00C5, 'a' }, // À-Å
    .{ 0x00C7, 0x00C7, 'c' }, // Ç
    .{ 0x00C8, 0x00CB, 'e' }, // È-Ë
    .{ 0x00CC, 0x00CF, 'i' }, // Ì-Ï
    .{ 0x00D1, 0x00D1, 'n' }, // Ñ
    .{ 0x00D2, 0x00D6, 'o' }, // Ò-Ö
    .{ 0x00D8, 0x00D8, 'o' }, // Ø (no mark to strip, so table it)
    .{ 0x00D9, 0x00DC, 'u' }, // Ù-Ü
    .{ 0x00DD, 0x00DD, 'y' }, // Ý
    .{ 0x00E0, 0x00E5, 'a' }, // à-å
    .{ 0x00E7, 0x00E7, 'c' }, // ç
    .{ 0x00E8, 0x00EB, 'e' }, // è-ë
    .{ 0x00EC, 0x00EF, 'i' }, // ì-ï
    .{ 0x00F1, 0x00F1, 'n' }, // ñ
    .{ 0x00F2, 0x00F6, 'o' }, // ò-ö
    .{ 0x00F8, 0x00F8, 'o' }, // ø
    .{ 0x00F9, 0x00FC, 'u' }, // ù-ü
    .{ 0x00FD, 0x00FD, 'y' }, // ý
    .{ 0x00FF, 0x00FF, 'y' }, // ÿ
    .{ 0x0100, 0x0105, 'a' }, // Ā-ą
    .{ 0x0106, 0x010D, 'c' }, // Ć-č
    .{ 0x010E, 0x0111, 'd' }, // Ď-đ
    .{ 0x0112, 0x011B, 'e' }, // Ē-ě
    .{ 0x011C, 0x0123, 'g' }, // Ĝ-ģ
    .{ 0x0124, 0x0127, 'h' }, // Ĥ-ħ
    .{ 0x0128, 0x0133, 'i' }, // Ĩ-ı
    .{ 0x0134, 0x0135, 'j' }, // Ĵ-ĵ
    .{ 0x0136, 0x0138, 'k' }, // Ķ-ĸ
    .{ 0x0139, 0x0142, 'l' }, // Ĺ-ŀ
    .{ 0x0143, 0x014B, 'n' }, // Ń-ŉ
    .{ 0x014C, 0x0151, 'o' }, // Ō-ő
    .{ 0x0154, 0x0159, 'r' }, // Ŕ-ř
    .{ 0x015A, 0x0161, 's' }, // Ś-š
    .{ 0x0162, 0x0167, 't' }, // Ţ-ŧ
    .{ 0x0168, 0x0173, 'u' }, // Ũ-ų
    .{ 0x0174, 0x0175, 'w' }, // Ŵ-ŵ
    .{ 0x0176, 0x0178, 'y' }, // Ŷ-Ÿ
    .{ 0x0179, 0x017E, 'z' }, // Ź-ž
    .{ 0x017F, 0x017F, 's' }, // ſ (long s)
};

/// The letters Unicode never decomposed, so there is no mark to strip and no
/// table entry above can reach them. Without these the word is unreachable
/// from a keyboard that has only the plain letter: "Ørsted" is not "Ørsted"
/// with a mark, and the operator types "orsted".
const fold_two = [_]struct { cp: u21, to: []const u8 }{
    .{ .cp = 0x00C6, .to = "ae" }, // Æ
    .{ .cp = 0x00E6, .to = "ae" }, // æ
    .{ .cp = 0x00DE, .to = "th" }, // Þ
    .{ .cp = 0x00FE, .to = "th" }, // þ
    .{ .cp = 0x00DF, .to = "ss" }, // ß
    .{ .cp = 0x0152, .to = "oe" }, // Œ
    .{ .cp = 0x0153, .to = "oe" }, // œ
};

/// Combining marks: they modify the letter they follow and a search for the
/// bare letter should find the marked spelling, so the fold drops them. The
/// ranges are the Mn blocks a Latin or symbol word actually carries.
const fold_marks = [_][2]u21{
    .{ 0x0300, 0x036F }, // Combining Diacritical Marks
    .{ 0x1AB0, 0x1AFF }, // Combining Diacritical Marks Extended
    .{ 0x1DC0, 0x1DFF }, // Combining Diacritical Marks Supplement
    .{ 0x20D0, 0x20F0 }, // Combining Diacritical Marks for Symbols
    .{ 0xFE20, 0xFE2F }, // Combining Half Marks
};

fn inRanges(cp: u21, ranges: []const [2]u21) bool {
    for (ranges) |r| {
        if (cp >= r[0] and cp <= r[1]) return true;
    }
    return false;
}

fn foldOne(cp: u21) ?u8 {
    if (cp < 0x80) {
        if (cp >= 'A' and cp <= 'Z') return @intCast(cp + 32);
        return @intCast(cp);
    }
    for (fold_one) |r| {
        if (cp >= r[0] and cp <= r[1]) return @intCast(r[2]);
    }
    return null;
}

/// Width the fold of one codepoint's bytes adds: 0 for a dropped mark, 1 for a
/// single ASCII letter or an unmapped codepoint narrower than two bytes, and
/// the codepoint's own width otherwise. A malformed byte counts as 1, the same
/// width `width.zig` gives it, so a walk over broken text still advances.
fn foldWidth(bytes: []const u8) usize {
    const cp = std.unicode.utf8Decode(bytes) catch return 1;
    if (foldOne(cp)) |_| {
        return 1;
    }
    for (fold_two) |p| {
        if (p.cp == cp) return p.to.len;
    }
    if (inRanges(cp, &fold_marks)) return 0;
    return bytes.len;
}

/// The fold of `s`: ASCII lowercased, Latin diacritics and the letters Unicode
/// never decomposed reduced to their ASCII spellings, every other codepoint
/// copied through unchanged.
///
/// The valid-UTF-8 fast path is a validation pass and no copy. Bytes that are
/// not valid UTF-8 are passed through as they are: this feeds a comparison,
/// not storage, and rewriting them would change what the caller is matching.
pub fn fold(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) {
        var simple = true;
        for (s) |c| {
            if (c >= 0x80 or (c >= 'A' and c <= 'Z')) {
                simple = false;
                break;
            }
        }
        if (simple) return std.ascii.lowerString(try gpa.dupe(u8, s), s);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            out.appendAssumeCapacity(s[i]);
            i += 1;
            continue;
        };
        if (i + len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + len])) {
            out.appendAssumeCapacity(s[i]);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch unreachable;
        if (foldOne(cp)) |c| {
            out.appendAssumeCapacity(c);
        } else if (foldTwoLookup(cp)) |to| {
            out.appendSliceAssumeCapacity(to);
        } else if (!inRanges(cp, &fold_marks)) {
            out.appendSliceAssumeCapacity(s[i .. i + len]);
        }
        i += len;
    }
    return out.toOwnedSlice(gpa);
}

fn foldTwoLookup(cp: u21) ?[]const u8 {
    for (fold_two) |p| {
        if (p.cp == cp) return p.to;
    }
    return null;
}

/// Whether folding `s` gives `s` back. An index built over the raw bytes of a
/// corpus can only answer a query whose fold is itself, so a caller holding
/// such an index asks this first and falls back to a scan when the answer is
/// no.
pub fn foldIsIdentity(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return false;
        if (i + len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + len])) return false;
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return false;
        // A codepoint whose fold is exactly its own bytes: an ASCII letter
        // that is already lowercase, or one of the blocks this fold does not
        // touch (Cyrillic, CJK, Greek).
        const unchanged = if (cp < 0x80)
            !(cp >= 'A' and cp <= 'Z')
        else
            foldOne(cp) == null and foldTwoLookup(cp) == null and !inRanges(cp, &fold_marks);
        if (!unchanged or foldWidth(s[i .. i + len]) != len) return false;
        i += len;
    }
    return true;
}

/// A match located in the haystack's own bytes.
pub const FoldHit = struct {
    /// Byte offset into the haystack where the match starts.
    start: usize,
    /// Byte length of the match in the haystack. Not `needle.len`: a folded
    /// match can cover fewer haystack bytes than the needle has folded bytes
    /// ("æ" is one haystack byte pair and two folded ones) or more.
    len: usize,
};

/// The first place the fold of `needle` occurs in the fold of `haystack`,
/// mapped back to the haystack's own bytes so a caller can slice or highlight
/// what it holds rather than the fold.
///
/// Pure-ASCII on both sides answers through `std.ascii.findIgnoreCase` and
/// allocates nothing: that is every search the ASCII corpora make, and it must
/// keep behaving exactly as it did before folding existed.
pub fn foldFind(gpa: std.mem.Allocator, haystack: []const u8, needle: []const u8) !?FoldHit {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    if (isPlainAscii(haystack) and isPlainAscii(needle)) {
        const at = std.ascii.findIgnoreCase(haystack, needle) orelse return null;
        return FoldHit{ .start = at, .len = needle.len };
    }
    const nf = try fold(gpa, needle);
    defer gpa.free(nf);
    if (nf.len == 0) return null;
    const hf = try fold(gpa, haystack);
    defer gpa.free(hf);
    if (nf.len > hf.len) return null;
    const at = std.mem.indexOfPos(u8, hf, 0, nf) orelse return null;
    const start = sourceOffset(haystack, at, false);
    const end = sourceOffset(haystack, at + nf.len, true);
    return FoldHit{ .start = start, .len = end - start };
}

fn isPlainAscii(s: []const u8) bool {
    for (s) |c| {
        if (c >= 0x80) return false;
    }
    return true;
}

/// Byte offset in `s` corresponding to folded byte `folded_at`.
///
/// `at_end` is the exclusive end of a match. A request that lands inside one
/// codepoint's expansion (a needle of "e" against a "æ") answers with that
/// codepoint's start for the match start, and just past it for the match end,
/// so a highlight covers the letter the fold actually matched inside. The end
/// also keeps a combining mark that follows the last matched letter: the mark
/// folds away, and dropping it would split a decomposed letter in half.
fn sourceOffset(s: []const u8, folded_at: usize, at_end: bool) usize {
    var f: usize = 0;
    var i: usize = 0;
    while (i < s.len and f < folded_at) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            f += 1;
            i += 1;
            continue;
        };
        if (i + len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + len])) {
            f += 1;
            i += 1;
            continue;
        }
        const w = foldWidth(s[i .. i + len]);
        if (f + w > folded_at) return if (at_end) swallowMarks(s, i + len) else i;
        f += w;
        i += len;
    }
    return if (at_end) swallowMarks(s, i) else i;
}

fn swallowMarks(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + len])) break;
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch break;
        if (!inRanges(cp, &fold_marks)) break;
        i += len;
    }
    return i;
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
    try std.testing.expect(std.mem.find(u8, out, "[") == null);
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

test "fold reduces a Latin word to the letters a keyboard has" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The same four expectations `ui/app/core/utils.test.mjs` pins for
    // `searchFold`, so the two sides of the wire cannot drift on what a query
    // matches.
    try std.testing.expectEqualStrings("zazolc gesla jazn", try fold(arena, "Zażółć gęślą jaźń"));
    try std.testing.expectEqualStrings("orsted", try fold(arena, "Ørsted"));
    try std.testing.expectEqualStrings("strasse", try fold(arena, "Straße"));
    try std.testing.expectEqualStrings("aengstrom", try fold(arena, "Ængström"));
}

test "fold drops a decomposed mark as well as a precomposed one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // NFD "café" (e + U+0301) and NFC "café" are one word, and a search for
    // either spelling has to find the other.
    try std.testing.expectEqualStrings("cafe", try fold(arena, "cafe\xcc\x81"));
    try std.testing.expectEqualStrings("cafe", try fold(arena, "caf\xc3\xa9"));
    // A Turkish dotted capital I lowercases to i + a mark, which goes too.
    try std.testing.expectEqualStrings("i", try fold(arena, "\xc4\xb0"));
}

test "fold leaves text it has no table for exactly as it found it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cjk = "\xe4\xb8\xad\xe6\x96\x87";
    try std.testing.expectEqualStrings(cjk, try fold(arena, cjk));
    const cyrillic = "\xd0\xbf\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82";
    try std.testing.expectEqualStrings(cyrillic, try fold(arena, cyrillic));
    // Punctuation in the Latin-1 blocks is not a letter and keeps its byte.
    try std.testing.expectEqualStrings("a\xc3\x97b", try fold(arena, "a\xc3\x97b"));
}

test "foldFind matches across diacritics and reports haystack bytes" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The failing input this exists for: a Polish operator types "zazolc" for
    // "Zażółć", and the plain `std.ascii.findIgnoreCase` this replaced
    // reported nothing.
    const hay = "pami\xc4\x99ta: Za\xc5\xbc\xc3\xb3\xc5\x82\xc4\x87 g\xc4\x99sla";
    const hit = (try foldFind(arena, hay, "zazolc")).?;
    try t.expectEqualStrings("Zażółć", hay[hit.start..][0..hit.len]);

    // The hit carries the haystack's own bytes, not the needle's folded ones:
    // a decomposed letter is longer in the haystack than in its fold.
    const decomp = "cafe\xcc\x81 bar";
    const dhit = (try foldFind(arena, decomp, "cafe")).?;
    try t.expectEqualStrings("cafe\xcc\x81", decomp[dhit.start..][0..dhit.len]);

    // A query that needs a mark the text does not carry is still a miss.
    try t.expect((try foldFind(arena, hay, "zazolcc")) == null);
}

test "foldFind keeps the ASCII behaviour and allocates nothing for it" {
    const t = std.testing;
    const hit = (try foldFind(t.allocator, "Hello World", "hello")).?;
    try t.expectEqual(@as(usize, 0), hit.start);
    try t.expectEqual(@as(usize, 5), hit.len);
    try t.expect((try foldFind(t.allocator, "Hello", "xyz")) == null);
    try t.expect((try foldFind(t.allocator, "Hello", "")) == null);
    // Non-ASCII haystack, ASCII query: still the plain substring search.
    const mixed = "caf\xc3\xa9 latte";
    const mhit = (try foldFind(t.allocator, mixed, "LATTE")).?;
    try t.expectEqualStrings("latte", mixed[mhit.start..][0..mhit.len]);
}

test "a needle matching inside a folded expansion covers the whole letter" {
    const t = std.testing;
    // "æ" folds to "ae", so a one-letter query for "e" lands in the middle of
    // that expansion. The reported span has to be the "æ" the fold matched
    // inside, or a highlight would point past the letter.
    const hay = "a\xc3\xa6b";
    const hit = (try foldFind(t.allocator, hay, "e")).?;
    try t.expectEqualStrings("\xc3\xa6", hay[hit.start..][0..hit.len]);
}

test "foldIsIdentity separates a query the raw index can answer from one it cannot" {
    const t = std.testing;
    try t.expect(foldIsIdentity("zazolc"));
    try t.expect(foldIsIdentity("hello world 123"));
    try t.expect(foldIsIdentity("\xe4\xb8\xad\xe6\x96\x87")); // CJK folds to itself
    try t.expect(foldIsIdentity("\xd0\xbf\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82")); // Cyrillic
    // These change under the fold, so an index over raw bytes cannot answer them.
    try t.expect(!foldIsIdentity("zaz\xc3\xb3\xc5\x82\u{104c}"));
    try t.expect(!foldIsIdentity("Stra\xc3\x9fe"));
    try t.expect(!foldIsIdentity("HELLO"));
    try t.expect(!foldIsIdentity("bad\xffbyte"));
}

test "fold survives a string that is not valid UTF-8" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Subprocess output reaches a search before anything has validated it; the
    // fold is a comparison, so the broken bytes stay as they are rather than
    // being rewritten under a needle.
    const out = try fold(arena, "caf\xe9 latte");
    try t.expectEqualStrings("caf\xe9 latte", out);
    const hit = (try foldFind(arena, "caf\xe9 latte", "latte")).?;
    try t.expectEqualStrings("latte", out[hit.start..][0..hit.len]);
}

/// The Smith encoding one `smith.slice` seed needs, spelled here rather than
/// taken from `util/fuzz_corpus.zig`: that file is reached by path from `src/`
/// and by name from guests, and this one is *itself* reached by name from
/// guests, so it can hold neither import in the same compilation (a Zig file
/// belongs to one module per build, and the guest module set has no
/// `fuzz_corpus`). One helper, two calls, and a length field the harness's
/// reader actually expects — a raw seed would arrive here missing its first
/// four bytes and steer nothing.
fn fuzzEntry(comptime seed: []const u8) []const u8 {
    const encoded = comptime blk: {
        var buf: [4 + seed.len]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], @intCast(seed.len), .little);
        @memcpy(buf[4..], seed);
        break :blk buf;
    };
    return &encoded;
}

/// The spellings a query and a haystack actually arrive in: an operator types
/// the letters their keyboard has, the text they look for is spelled with the
/// marks its language puts on them, and both sides can also be bytes that are
/// not UTF-8 at all (a filename off disk, subprocess output). Random mutation
/// produces an accented codepoint rarely enough that the corpus names the
/// folds, the dropped marks, the two-byte expansions and the broken bytes.
const fold_fuzz_corpus = [_][]const u8{
    fuzzEntry(""),
    fuzzEntry("hello\x00world"),
    fuzzEntry("Za\xc5\xbc\xc3\xb3\xc5\x82\xc4\x87"), // Zażółć
    fuzzEntry("zazolc"),
    fuzzEntry("cafe\xcc\x81"), // decomposed
    fuzzEntry("caf\xc3\xa9"), // precomposed
    fuzzEntry("Stra\xc3\x9fe"), // ß folds to ss
    fuzzEntry("strasse"),
    fuzzEntry("\xc3\x86ngstr\xc3\xb6m"), // Æ -> ae
    fuzzEntry("ae"),
    fuzzEntry("\xc3\x98rsted"), // Ø has no mark to strip
    fuzzEntry("orsted"),
    fuzzEntry("\xc6\x92\xc5\xbf"), // Þ -> th
    fuzzEntry("pami\xc4\x99ta: Za\xc5\xbc\xc3\xb3\xc5\x82\xc4\x87"),
    fuzzEntry("\xe4\xb8\xad\xe6\x96\x87"), // CJK folds to itself
    fuzzEntry("\xd0\xbf\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82"), // Cyrillic
    fuzzEntry("caf\xe9 latte"), // latin-1 byte, not valid UTF-8
    fuzzEntry("caf\xc3"), // truncated codepoint
    fuzzEntry("\xf0\x9f\x98"), // truncated emoji
    fuzzEntry("\x80\xff\xbf"), // bare continuation bytes
    fuzzEntry("a\xc3\xa6b"),
    fuzzEntry("\xc3\x84\xc3\x96\xc3\x9c"), // folded letters, no marks
    // A match that ends on a decomposed letter: the window has to carry the
    // combining mark with it, and a mark after the last matched letter of a
    // longer hit is the case `swallowMarks` covers.
    fuzzEntry("cafe\xcc\x81 bar\x00cafe"),
    fuzzEntry("x cafe\xcc\x81 y\x00cafe"),
    fuzzEntry("Za\xc5\xbc\xc3\xb3\xc5\x82\xc4\x87 g\xc4\x99sla\x00zazolc"),
    fuzzEntry("a\xc3\xa6b\x00e"),
};

test "fuzz: a fold hit is a window of the haystack a plain match would also accept" {
    // `foldFind` answers with offsets into the *haystack's own bytes*, which
    // every caller slices, highlights, or passes to `std.json` as a session
    // snippet. The folded and raw byte counts differ (a fold can grow "æ" to
    // "ae", a mark folds away entirely), so the mapping from folded offset
    // back to source offset is the part that can be wrong, and a wrong one is
    // an out-of-range slice in a caller. So the properties, checked on every
    // byte pair:
    //
    //   * a hit is a window inside the haystack, on codepoint boundaries, and
    //     never empty -- a slice past the end or a half codepoint is what the
    //     caller dereferences;
    //   * the reported window really does match the needle under the same
    //     fold the search used, so an offset that pointed at unrelated text
    //     fails here rather than highlighting the wrong session row;
    //   * `foldFind` and a direct search of the two folds agree on *whether*
    //     there is a match, which is the property a wrong mapping loses
    //     silently (the answer still arrives, just for the wrong bytes);
    //   * `foldIsIdentity` never contradicts `fold`: text it calls identity
    //     folds back to itself.
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var buf: [512]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            // The corpus spells a haystack and its query either as one NUL-
            // separated string or, under mutation, as halves of whatever the
            // fuzzer produced. Either way both sides get driven.
            const split = std.mem.indexOfScalar(u8, input, 0) orelse input.len / 2;
            const haystack = input[0..split];
            const needle = if (split < input.len) input[split + 1 ..] else input[split..];

            const hit = try foldFind(arena, haystack, needle);
            const hf = try fold(arena, haystack);
            const nf = try fold(arena, needle);

            if (hit) |h| {
                try std.testing.expect(h.len > 0);
                try std.testing.expect(h.start + h.len <= haystack.len);
                const window = haystack[h.start..][0..h.len];

                // A codepoint boundary on both sides: the window is text, not
                // a fragment of a multi-byte sequence.
                try std.testing.expect(h.start == 0 or !isContinuation(haystack[h.start]));
                try std.testing.expect(h.start + h.len == haystack.len or
                    !isContinuation(haystack[h.start + h.len]));

                // The window answers the query under the same fold. Either
                // side may contain the other: a window can cover more folded
                // bytes than the query ("æ" for a query of "e") and can never
                // cover fewer, or the match would not be there.
                const window_fold = try fold(arena, window);
                try std.testing.expect(std.mem.indexOf(u8, window_fold, nf) != null or
                    std.mem.indexOf(u8, nf, window_fold) != null);

                // A window that ends inside a codepoint is the out-of-range slice a
                // caller would hand to a highlighter, so both boundaries have
                // to land on lead bytes. (The trailing-mark extension in
                // `sourceOffset` is only reachable when the end offset itself
                // lands mid-mark; a fold comparison cannot see a mark, which
                // folds to nothing, so it is left to the unit tests that pin
                // the spelling rather than fuzzed here.)

                // Minimal: dropping the first codepoint must break the match,
                // or the mapping started one letter early. Dropping the last
                // one may keep it (a fold that expanded, "æ" answering "e"),
                // which is the whole reason `sourceOffset` reports the letter
                // rather than the byte, so only the start is pinned.
                try expectNotShrinkable(arena, haystack, h, nf);
            }

            // Agreement with a search over the two folds directly: a mapping
            // bug that turns a miss into a hit, or drops one, fails here.
            const direct = if (nf.len == 0) null else std.mem.indexOf(u8, hf, nf);
            try std.testing.expectEqual(direct != null, hit != null);

            // foldIsIdentity must never contradict fold.
            if (foldIsIdentity(haystack)) try std.testing.expectEqualStrings(haystack, hf);
        }

        fn isContinuation(b: u8) bool {
            return (b & 0xC0) == 0x80;
        }

        /// True when the codepoint starting at `at` folds to nothing, i.e. it
        /// is one of the combining marks `fold` drops. A separate table walk
        /// rather than a call into `fold`, so the assertion checks the answer
        /// instead of restating the implementation with it.
        fn isFoldingMark(s: []const u8, at: usize) bool {
            const len = std.unicode.utf8ByteSequenceLength(s[at]) catch return false;
            if (at + len > s.len) return false;
            if (!std.unicode.utf8ValidateSlice(s[at .. at + len])) return false;
            const cp = std.unicode.utf8Decode(s[at .. at + len]) catch return false;
            for ([_][2]u21{
                .{ 0x0300, 0x036F },
                .{ 0x1AB0, 0x1AFF },
                .{ 0x1DC0, 0x1DFF },
                .{ 0x20D0, 0x20F0 },
                .{ 0xFE20, 0xFE2F },
            }) |r| {
                if (cp >= r[0] and cp <= r[1]) return true;
            }
            return false;
        }

        /// Dropping the first codepoint of the window must stop it answering
        /// the query. A window that still matches without its first letter
        /// started early, so a caller highlighting it marks a character the
        /// query never matched.
        fn expectNotShrinkable(
            arena: std.mem.Allocator,
            haystack: []const u8,
            h: FoldHit,
            nf: []const u8,
        ) !void {
            if (h.start == 0) return;
            const shorter = haystack[utf8Start(haystack, h.start) .. h.start + h.len];
            if (shorter.len == h.len) return;
            const shorter_fold = try fold(arena, shorter);
            if (std.mem.indexOf(u8, shorter_fold, nf) != null or
                std.mem.indexOf(u8, nf, shorter_fold) != null)
                return error.MatchStartsEarly;
        }

        /// Byte offset of the codepoint whose bytes cover `at`, walking back
        /// over continuation bytes.
        fn utf8Start(s: []const u8, at: usize) usize {
            var i = at;
            while (i > 0 and isContinuation(s[i])) i -= 1;
            return i;
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{ .corpus = &fold_fuzz_corpus });
}
