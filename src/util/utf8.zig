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
//!
//! `canonicalEqual` is the identity question those two are not: whether two
//! spellings name the same text. See its own comment for why an identity
//! comparison, not a search fold, is what a stored name needs.

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

// Canonical equivalence: whether two spellings name the same text.
//
// "café.md" typed into a form arrives composed (U+00E9); the same filename
// read back off APFS arrives decomposed (`e` + U+0301), because HFS+
// normalizes what it stores. Byte equality calls those two documents, so an
// upsert keyed on the name appends a second copy of one file, both copies
// answer search, and the prune pass deletes whichever one it did not see in a
// listing — the name coming back with a new id every cycle.
//
// NFC is the general answer and a table this codebase has no other use for.
// An identity check needs a narrower one: does the composed spelling and the
// decomposed spelling of the same word answer "yes"? That is one question per
// (base, mark) pair, answered by the table below without rewriting either
// string, so nothing here allocates and an identity comparison costs what
// `mem.eql` costs.
//
// Deliberately not `fold`, which answers a different question. Fold is a
// search convenience and lossy by design: it drops every mark, so "cafe",
// "café" and "café" are one query. A name identifying a stored document is
// not a search box, and folding there would merge two files an operator can
// see. `fold_marks` is shared with it below because the marks a canonical
// decomposition can use are the marks fold already recognizes.
//
// ponytail: Latin-1 Supplement and Latin Extended-A, the blocks a Latin-script
// filename actually carries, generated from the Python `unicodedata` module's
// decompositions and kept only where an NFC round trip confirms the pair
// really does compose (UAX #15 excludes several Latin pairs on class
// grounds, e.g. U+0138 which has no NFC form). A decomposed letter outside
// them still matches itself exactly, so nothing outside these blocks is
// affected; widening this is a table edit. The Unicode data file to generate
// the next blocks from is not in the tree.
const canonical_pairs = [_][3]u21{
    .{ 0x00C0, 0x0041, 0x0300 }, // À
    .{ 0x00C1, 0x0041, 0x0301 }, // Á
    .{ 0x00C2, 0x0041, 0x0302 }, // Â
    .{ 0x00C3, 0x0041, 0x0303 }, // Ã
    .{ 0x00C4, 0x0041, 0x0308 }, // Ä
    .{ 0x00C5, 0x0041, 0x030A }, // Å
    .{ 0x00C7, 0x0043, 0x0327 }, // Ç
    .{ 0x00C8, 0x0045, 0x0300 }, // È
    .{ 0x00C9, 0x0045, 0x0301 }, // É
    .{ 0x00CA, 0x0045, 0x0302 }, // Ê
    .{ 0x00CB, 0x0045, 0x0308 }, // Ë
    .{ 0x00CC, 0x0049, 0x0300 }, // Ì
    .{ 0x00CD, 0x0049, 0x0301 }, // Í
    .{ 0x00CE, 0x0049, 0x0302 }, // Î
    .{ 0x00CF, 0x0049, 0x0308 }, // Ï
    .{ 0x00D1, 0x004E, 0x0303 }, // Ñ
    .{ 0x00D2, 0x004F, 0x0300 }, // Ò
    .{ 0x00D3, 0x004F, 0x0301 }, // Ó
    .{ 0x00D4, 0x004F, 0x0302 }, // Ô
    .{ 0x00D5, 0x004F, 0x0303 }, // Õ
    .{ 0x00D6, 0x004F, 0x0308 }, // Ö
    .{ 0x00D9, 0x0055, 0x0300 }, // Ù
    .{ 0x00DA, 0x0055, 0x0301 }, // Ú
    .{ 0x00DB, 0x0055, 0x0302 }, // Û
    .{ 0x00DC, 0x0055, 0x0308 }, // Ü
    .{ 0x00DD, 0x0059, 0x0301 }, // Ý
    .{ 0x00E0, 0x0061, 0x0300 }, // à
    .{ 0x00E1, 0x0061, 0x0301 }, // á
    .{ 0x00E2, 0x0061, 0x0302 }, // â
    .{ 0x00E3, 0x0061, 0x0303 }, // ã
    .{ 0x00E4, 0x0061, 0x0308 }, // ä
    .{ 0x00E5, 0x0061, 0x030A }, // å
    .{ 0x00E7, 0x0063, 0x0327 }, // ç
    .{ 0x00E8, 0x0065, 0x0300 }, // è
    .{ 0x00E9, 0x0065, 0x0301 }, // é
    .{ 0x00EA, 0x0065, 0x0302 }, // ê
    .{ 0x00EB, 0x0065, 0x0308 }, // ë
    .{ 0x00EC, 0x0069, 0x0300 }, // ì
    .{ 0x00ED, 0x0069, 0x0301 }, // í
    .{ 0x00EE, 0x0069, 0x0302 }, // î
    .{ 0x00EF, 0x0069, 0x0308 }, // ï
    .{ 0x00F1, 0x006E, 0x0303 }, // ñ
    .{ 0x00F2, 0x006F, 0x0300 }, // ò
    .{ 0x00F3, 0x006F, 0x0301 }, // ó
    .{ 0x00F4, 0x006F, 0x0302 }, // ô
    .{ 0x00F5, 0x006F, 0x0303 }, // õ
    .{ 0x00F6, 0x006F, 0x0308 }, // ö
    .{ 0x00F9, 0x0075, 0x0300 }, // ù
    .{ 0x00FA, 0x0075, 0x0301 }, // ú
    .{ 0x00FB, 0x0075, 0x0302 }, // û
    .{ 0x00FC, 0x0075, 0x0308 }, // ü
    .{ 0x00FD, 0x0079, 0x0301 }, // ý
    .{ 0x00FF, 0x0079, 0x0308 }, // ÿ
    .{ 0x0100, 0x0041, 0x0304 }, // Ā
    .{ 0x0101, 0x0061, 0x0304 }, // ā
    .{ 0x0102, 0x0041, 0x0306 }, // Ă
    .{ 0x0103, 0x0061, 0x0306 }, // ă
    .{ 0x0104, 0x0041, 0x0328 }, // Ą
    .{ 0x0105, 0x0061, 0x0328 }, // ą
    .{ 0x0106, 0x0043, 0x0301 }, // Ć
    .{ 0x0107, 0x0063, 0x0301 }, // ć
    .{ 0x0108, 0x0043, 0x0302 }, // Ĉ
    .{ 0x0109, 0x0063, 0x0302 }, // ĉ
    .{ 0x010A, 0x0043, 0x0307 }, // Ċ
    .{ 0x010B, 0x0063, 0x0307 }, // ċ
    .{ 0x010C, 0x0043, 0x030C }, // Č
    .{ 0x010D, 0x0063, 0x030C }, // č
    .{ 0x010E, 0x0044, 0x030C }, // Ď
    .{ 0x010F, 0x0064, 0x030C }, // ď
    .{ 0x0112, 0x0045, 0x0304 }, // Ē
    .{ 0x0113, 0x0065, 0x0304 }, // ē
    .{ 0x0114, 0x0045, 0x0306 }, // Ĕ
    .{ 0x0115, 0x0065, 0x0306 }, // ĕ
    .{ 0x0116, 0x0045, 0x0307 }, // Ė
    .{ 0x0117, 0x0065, 0x0307 }, // ė
    .{ 0x0118, 0x0045, 0x0328 }, // Ę
    .{ 0x0119, 0x0065, 0x0328 }, // ę
    .{ 0x011A, 0x0045, 0x030C }, // Ě
    .{ 0x011B, 0x0065, 0x030C }, // ě
    .{ 0x011C, 0x0047, 0x0302 }, // Ĝ
    .{ 0x011D, 0x0067, 0x0302 }, // ĝ
    .{ 0x011E, 0x0047, 0x0306 }, // Ğ
    .{ 0x011F, 0x0067, 0x0306 }, // ğ
    .{ 0x0120, 0x0047, 0x0307 }, // Ġ
    .{ 0x0121, 0x0067, 0x0307 }, // ġ
    .{ 0x0122, 0x0047, 0x0327 }, // Ģ
    .{ 0x0123, 0x0067, 0x0327 }, // ģ
    .{ 0x0124, 0x0048, 0x0302 }, // Ĥ
    .{ 0x0125, 0x0068, 0x0302 }, // ĥ
    .{ 0x0128, 0x0049, 0x0303 }, // Ĩ
    .{ 0x0129, 0x0069, 0x0303 }, // ĩ
    .{ 0x012A, 0x0049, 0x0304 }, // Ī
    .{ 0x012B, 0x0069, 0x0304 }, // ī
    .{ 0x012C, 0x0049, 0x0306 }, // Ĭ
    .{ 0x012D, 0x0069, 0x0306 }, // ĭ
    .{ 0x012E, 0x0049, 0x0328 }, // Į
    .{ 0x012F, 0x0069, 0x0328 }, // į
    .{ 0x0130, 0x0049, 0x0307 }, // İ
    .{ 0x0134, 0x004A, 0x0302 }, // Ĵ
    .{ 0x0135, 0x006A, 0x0302 }, // ĵ
    .{ 0x0136, 0x004B, 0x0327 }, // Ķ
    .{ 0x0137, 0x006B, 0x0327 }, // ķ
    .{ 0x0139, 0x004C, 0x0301 }, // Ĺ
    .{ 0x013A, 0x006C, 0x0301 }, // ĺ
    .{ 0x013B, 0x004C, 0x0327 }, // Ļ
    .{ 0x013C, 0x006C, 0x0327 }, // ļ
    .{ 0x013D, 0x004C, 0x030C }, // Ľ
    .{ 0x013E, 0x006C, 0x030C }, // ľ
    .{ 0x0143, 0x004E, 0x0301 }, // Ń
    .{ 0x0144, 0x006E, 0x0301 }, // ń
    .{ 0x0145, 0x004E, 0x0327 }, // Ņ
    .{ 0x0146, 0x006E, 0x0327 }, // ņ
    .{ 0x0147, 0x004E, 0x030C }, // Ň
    .{ 0x0148, 0x006E, 0x030C }, // ň
    .{ 0x014C, 0x004F, 0x0304 }, // Ō
    .{ 0x014D, 0x006F, 0x0304 }, // ō
    .{ 0x014E, 0x004F, 0x0306 }, // Ŏ
    .{ 0x014F, 0x006F, 0x0306 }, // ŏ
    .{ 0x0150, 0x004F, 0x030B }, // Ő
    .{ 0x0151, 0x006F, 0x030B }, // ő
    .{ 0x0154, 0x0052, 0x0301 }, // Ŕ
    .{ 0x0155, 0x0072, 0x0301 }, // ŕ
    .{ 0x0156, 0x0052, 0x0327 }, // Ŗ
    .{ 0x0157, 0x0072, 0x0327 }, // ŗ
    .{ 0x0158, 0x0052, 0x030C }, // Ř
    .{ 0x0159, 0x0072, 0x030C }, // ř
    .{ 0x015A, 0x0053, 0x0301 }, // Ś
    .{ 0x015B, 0x0073, 0x0301 }, // ś
    .{ 0x015C, 0x0053, 0x0302 }, // Ŝ
    .{ 0x015D, 0x0073, 0x0302 }, // ŝ
    .{ 0x015E, 0x0053, 0x0327 }, // Ş
    .{ 0x015F, 0x0073, 0x0327 }, // ş
    .{ 0x0160, 0x0053, 0x030C }, // Š
    .{ 0x0161, 0x0073, 0x030C }, // š
    .{ 0x0162, 0x0054, 0x0327 }, // Ţ
    .{ 0x0163, 0x0074, 0x0327 }, // ţ
    .{ 0x0164, 0x0054, 0x030C }, // Ť
    .{ 0x0165, 0x0074, 0x030C }, // ť
    .{ 0x0168, 0x0055, 0x0303 }, // Ũ
    .{ 0x0169, 0x0075, 0x0303 }, // ũ
    .{ 0x016A, 0x0055, 0x0304 }, // Ū
    .{ 0x016B, 0x0075, 0x0304 }, // ū
    .{ 0x016C, 0x0055, 0x0306 }, // Ŭ
    .{ 0x016D, 0x0075, 0x0306 }, // ŭ
    .{ 0x016E, 0x0055, 0x030A }, // Ů
    .{ 0x016F, 0x0075, 0x030A }, // ů
    .{ 0x0170, 0x0055, 0x030B }, // Ű
    .{ 0x0171, 0x0075, 0x030B }, // ű
    .{ 0x0172, 0x0055, 0x0328 }, // Ų
    .{ 0x0173, 0x0075, 0x0328 }, // ų
    .{ 0x0174, 0x0057, 0x0302 }, // Ŵ
    .{ 0x0175, 0x0077, 0x0302 }, // ŵ
    .{ 0x0176, 0x0059, 0x0302 }, // Ŷ
    .{ 0x0177, 0x0079, 0x0302 }, // ŷ
    .{ 0x0178, 0x0059, 0x0308 }, // Ÿ
    .{ 0x0179, 0x005A, 0x0301 }, // Ź
    .{ 0x017A, 0x007A, 0x0301 }, // ź
    .{ 0x017B, 0x005A, 0x0307 }, // Ż
    .{ 0x017C, 0x007A, 0x0307 }, // ż
    .{ 0x017D, 0x005A, 0x030C }, // Ž
    .{ 0x017E, 0x007A, 0x030C }, // ž
};

/// The precomposed codepoint for `base` followed by `mark`, or null when that
/// pair has no canonical composition (which is most pairs, and every ASCII
/// one).
fn compose(base: u21, mark: u21) ?u21 {
    for (canonical_pairs) |p| {
        if (p[1] == base and p[2] == mark) return p[0];
    }
    return null;
}

/// One decoded UTF-8 sequence. `Bad` stands for a byte that is not valid UTF-8,
/// which carries no codepoint: such input compares by bytes, as it always did,
/// rather than being silently rewritten into a replacement character.
const Bad: u21 = std.math.maxInt(u21);

fn nextCp(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    if (i >= s.len) return .{ .cp = 0, .len = 0 };
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = Bad, .len = 1 };
    if (i + len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + len])) return .{ .cp = Bad, .len = 1 };
    return .{ .cp = std.unicode.utf8Decode(s[i .. i + len]) catch Bad, .len = len };
}

const Cp = struct { cp: u21, len: usize };

/// `nextCp(s, i)` with the combining mark following it composed in. `len == 0`
/// when there is no mark that composes, so the caller keeps what it has.
fn composedCp(s: []const u8, i: usize) Cp {
    const cur = nextCp(s, i);
    if (cur.cp == Bad) return .{ .cp = 0, .len = 0 };
    const mark = nextCp(s, i + cur.len);
    if (mark.len == 0 or mark.cp == Bad) return .{ .cp = 0, .len = 0 };
    if (!inRanges(mark.cp, &fold_marks)) return .{ .cp = 0, .len = 0 };
    const composed = compose(cur.cp, mark.cp) orelse return .{ .cp = 0, .len = 0 };
    return .{ .cp = composed, .len = cur.len + mark.len };
}

fn hasHighByte(s: []const u8) bool {
    for (s) |c| {
        if (c >= 0x80) return true;
    }
    return false;
}

/// Whether `a` and `b` name the same text under canonical equivalence: a word's
/// composed and decomposed spellings are one string, not two.
///
/// Both sides are walked in step and each base is composed with the mark that
/// follows it, so `é` and `e` + U+0301 compare equal without either being
/// rewritten. Only a base plus *one* mark composes here, which is what a
/// filename carries; the two sequences a reader sees as the same grapheme
/// (`e` + U+0301 + U+0323, or a stacked mark) fall out of the same walk, since
/// the marks that do not compose are compared as themselves on both sides.
///
/// `mem.eql` first, and an early false for two pure-ASCII operands: a
/// composed/decomposed pair never contains a byte above 0x7F, so ASCII — which
/// is what almost every stored name is — costs exactly what it always cost.
pub fn canonicalEqual(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (!hasHighByte(a) and !hasHighByte(b)) return false;

    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const ca = nextCp(a, i);
        const cb = nextCp(b, j);
        if (ca.len == 0 or cb.len == 0) return ca.len == cb.len;
        if (ca.cp == Bad or cb.cp == Bad) {
            // Invalid bytes carry no codepoint, so the shared `Bad` marker must
            // not be what decides it: compare the bytes those offsets hold, so
            // `a\xffb` and `a\xfeb` stay two different strings rather than
            // every malformed byte collapsing into one.
            if (ca.cp != cb.cp) return false;
            if (!std.mem.eql(u8, a[i .. i + ca.len], b[j .. j + cb.len])) return false;
            i += ca.len;
            j += cb.len;
            continue;
        }
        if (ca.cp == cb.cp) {
            i += ca.len;
            j += cb.len;
            continue;
        }
        // The base on one side takes the mark on the other and becomes the
        // letter the other side already holds. Each comparison is against the
        // *uncomposed* codepoint of the opposite side, so the composed pair is
        // measured against the letter it stands for rather than against itself.
        const ac = composedCp(a, i);
        if (ac.len != 0 and ac.cp == cb.cp) {
            i += ac.len;
            j += cb.len;
            continue;
        }
        const bc = composedCp(b, j);
        if (bc.len != 0 and bc.cp == ca.cp) {
            i += ca.len;
            j += bc.len;
            continue;
        }
        return false;
    }
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

test "canonicalEqual answers yes for the two spellings of one word" {
    // "café.md" composed, then the same name as a filesystem reports it.
    try std.testing.expect(canonicalEqual("caf\xc3\xa9.md", "cafe\xcc\x81.md"));
    try std.testing.expect(canonicalEqual("cafe\xcc\x81.md", "caf\xc3\xa9.md"));
    // Czech, and the Turkish dotted capital I, across the two blocks. Note
    // what is *not* here: "Ł" (U+0141) and "ğ" have no canonical
    // decomposition at all — they are one codepoint in every form — so
    // asserting their decomposed spelling exists would be asserting a table
    // entry Unicode does not have.
    try std.testing.expect(canonicalEqual("\xc4\x8d\x65\xc5\xa1", "\x63\xcc\x8c\x65\x73\xcc\x8c"));
    try std.testing.expect(canonicalEqual("\xc4\xb0", "I\xcc\x87"));
    try std.testing.expect(canonicalEqual("\xc5\x9f", "s\xcc\xa7"));
    // Nor "ﬁ" the other way: it is a *compatibility* decomposition, and NFKC
    // is deliberately not applied here (it would merge "ﬁle.md" into
    // "file.md" as a different document).
    try std.testing.expect(!canonicalEqual("\xef\xac\x81le.md", "file.md"));
    // A mark with no precomposed form still matches itself, byte for byte.
    try std.testing.expect(canonicalEqual("\xe1\x84\x80", "\xe1\x84\x80"));
}

test "canonicalEqual is identity, not fold: different words stay different" {
    // The distinction from `fold`, and the reason this is not `fold`: fold
    // drops every mark, so these three are one search query. A name that
    // identifies a stored document must not merge them.
    try std.testing.expect(!canonicalEqual("cafe.md", "caf\xc3\xa9.md"));
    try std.testing.expect(!canonicalEqual("caf\xc3\xa9.md", "cafe.md"));
    // Acute on e is not cedilla on c, and a letter is not a mark.
    try std.testing.expect(!canonicalEqual("cafe\xcc\x81.md", "cafe\xcc\x88.md"));
    try std.testing.expect(!canonicalEqual("cafe\xcc\x81.md", "cafx\xcc\x81.md"));
    try std.testing.expect(!canonicalEqual("cafe\xcc\x81.md", "cafe\xcc\x81.mdx"));
    try std.testing.expect(!canonicalEqual("cafe\xcc\x81.md", "cafe\xcc\x81"));
    // Case is still case: nothing here folds.
    try std.testing.expect(!canonicalEqual("caf\xc3\xa9.md", "Caf\xc3\xa9.md"));
}

test "canonicalEqual leaves ASCII alone and survives invalid bytes" {
    try std.testing.expect(canonicalEqual("notes.md", "notes.md"));
    try std.testing.expect(!canonicalEqual("notes.md", "notes.txt"));
    try std.testing.expect(!canonicalEqual("", "a"));
    // Invalid UTF-8 carries no codepoint, so it compares by byte rather than
    // becoming a replacement character that could equal anything.
    try std.testing.expect(canonicalEqual("a\xffb", "a\xffb"));
    try std.testing.expect(!canonicalEqual("a\xffb", "a\xfeb"));
    // A truncated sequence at the end is not a shorter name for the same one.
    try std.testing.expect(!canonicalEqual("caf\xc3", "cafe"));
}
