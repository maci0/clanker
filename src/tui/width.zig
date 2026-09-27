//! Terminal display width of Unicode text.
//!
//! Zig's stdlib ships no wcwidth equivalent, and pulling in a full East Asian
//! Width table is precision this codebase doesn't need yet, the actual
//! requirement is "box borders don't visibly drift for CJK text in tool
//! output," not full Unicode conformance.
//!
//! ponytail: hardcoded ranges for what actually shows up (CJK, Hangul,
//! Hiragana/Katakana, CJK punctuation/fullwidth forms, and the emoji blocks
//! whose East Asian Width is Wide), width 1 for everything else. Not a full
//! UAX #11 table: the long tail of BMP Wide singletons still counts 1 here,
//! except for the two sequences a terminal ligates and no per-codepoint
//! table can express (see `nextCluster`): a VS16 asking for the
//! emoji-presentation glyph, and a U+200D joiner gluing emoji together. The
//! next step up, if that tail is ever reported, is vaxis's gwidth/zg tables,
//! already in the dependency tree — not a second Unicode data source.

const std = @import("std");
const unicode = std.unicode;

const wide_ranges = [_][2]u21{
    .{ 0x1100, 0x115F }, // Hangul Jamo
    .{ 0x231A, 0x231B }, // watch, hourglass (EAW=W emoji singletons follow)
    .{ 0x23E9, 0x23EC }, // play/fast-forward
    .{ 0x23F0, 0x23F0 }, // alarm clock
    .{ 0x23F3, 0x23F3 }, // hourglass with sand
    .{ 0x25FD, 0x25FE }, // small squares
    .{ 0x2614, 0x2615 }, // umbrella, hot beverage
    .{ 0x2648, 0x2653 }, // zodiac
    .{ 0x267F, 0x267F }, // wheelchair
    .{ 0x2693, 0x2693 }, // anchor
    .{ 0x26A1, 0x26A1 }, // high voltage
    .{ 0x26AA, 0x26AB }, // circles
    .{ 0x26BD, 0x26BE }, // soccer, baseball
    .{ 0x26C4, 0x26C5 }, // snowman, sun behind cloud
    .{ 0x26CE, 0x26CE }, // ophiuchus
    .{ 0x26D4, 0x26D4 }, // no entry
    .{ 0x26EA, 0x26EA }, // church
    .{ 0x26F2, 0x26F3 }, // fountain, golf
    .{ 0x26F5, 0x26F5 }, // sailboat
    .{ 0x26FA, 0x26FA }, // tent
    .{ 0x26FD, 0x26FD }, // fuel pump
    .{ 0x2705, 0x2705 }, // check mark button
    .{ 0x270A, 0x270B }, // fists
    .{ 0x2728, 0x2728 }, // sparkles
    .{ 0x274C, 0x274C }, // cross mark
    .{ 0x274E, 0x274E }, // cross mark button
    .{ 0x2753, 0x2755 }, // question/exclamation ornaments
    .{ 0x2757, 0x2757 }, // heavy exclamation
    .{ 0x2795, 0x2797 }, // plus/minus/divide
    .{ 0x27B0, 0x27B0 }, // curly loop
    .{ 0x27BF, 0x27BF }, // double curly loop
    .{ 0x2B1B, 0x2B1C }, // large squares
    .{ 0x2B50, 0x2B50 }, // star
    .{ 0x2B55, 0x2B55 }, // heavy circle
    .{ 0x2E80, 0x303E }, // CJK Radicals, punctuation
    .{ 0x3041, 0x33FF }, // Hiragana .. CJK compat
    .{ 0x3400, 0x4DBF }, // CJK ext A
    .{ 0x4E00, 0x9FFF }, // CJK Unified Ideographs
    .{ 0xA000, 0xA4CF }, // Yi
    .{ 0xAC00, 0xD7A3 }, // Hangul Syllables
    .{ 0xF900, 0xFAFF }, // CJK Compatibility Ideographs
    .{ 0xFF00, 0xFFEF }, // Fullwidth forms
    .{ 0x1F004, 0x1F004 }, // mahjong red dragon
    .{ 0x1F0CF, 0x1F0CF }, // joker
    .{ 0x1F18E, 0x1F18E }, // AB button
    .{ 0x1F191, 0x1F19A }, // squared CL..VS
    .{ 0x1F200, 0x1F2FF }, // enclosed ideographic supplement
    .{ 0x1F300, 0x1F64F }, // misc pictographs, emoticons
    .{ 0x1F680, 0x1F6FF }, // transport & map symbols
    .{ 0x1F900, 0x1F9FF }, // supplemental pictographs
    .{ 0x1FA70, 0x1FAFF }, // pictographs extended-A
    .{ 0x20000, 0x3FFFD }, // CJK ext B+ / supplementary planes
};

/// Combining marks (Mn/Me) occupy no cell of their own; they modify the
/// preceding codepoint. Only the common ranges actually seen in practice.
const zero_width_ranges = [_][2]u21{
    .{ 0x0300, 0x036F }, // Combining Diacritical Marks
    .{ 0x200B, 0x200F }, // zero-width space/joiners/marks
    .{ 0x20D0, 0x20FF }, // Combining Diacritical Marks for Symbols
    .{ 0xFE00, 0xFE0F }, // variation selectors
    .{ 0xFE20, 0xFE2F }, // Combining Half Marks
    .{ 0xFEFF, 0xFEFF }, // BOM / zero-width no-break space
};

fn inRanges(cp: u21, ranges: []const [2]u21) bool {
    for (ranges) |r| {
        if (cp >= r[0] and cp <= r[1]) return true;
    }
    return false;
}

/// Display width of one codepoint: 0, 1, or 2 terminal columns.
pub fn codepointWidth(cp: u21) u2 {
    if (cp == 0) return 0;
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0; // C0/C1 controls
    if (inRanges(cp, &zero_width_ranges)) return 0;
    // Everything below the first wide range is width 1; skips the ~50-entry
    // scan for the ASCII/Latin text that dominates real transcripts.
    if (cp < wide_ranges[0][0]) return 1;
    if (inRanges(cp, &wide_ranges)) return 2;
    return 1;
}

/// One codepoint's bytes from `s` at `i.*`, advancing `i.*` past them.
///
/// A byte that cannot start a sequence, and a sequence the slice cuts short,
/// each yield that one byte — which `utf8Decode` then rejects, so the caller
/// charges it width 1. That is the contract this module documents, and
/// `std.unicode.Utf8Iterator` cannot honour it: `nextCodepointSlice`
/// `catch unreachable`s an invalid start byte and returns
/// `bytes[i - cp_len .. i]` after advancing `i` unchecked, so a truncated
/// tail slices past the end. Both panic (and read out of bounds under
/// `ReleaseFast`) before any `catch` in the loop can run. A tail cut mid
/// codepoint is not exotic: streamed deltas split multi-byte characters
/// routinely, and the live stream buffer is measured on every frame.
pub fn nextCodepoint(s: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= s.len) return null;
    const start = i.*;
    const len = unicode.utf8ByteSequenceLength(s[start]) catch 1;
    const end = if (start + len > s.len) start + 1 else start + len;
    i.* = end;
    return s[start..end];
}

/// `slice`'s codepoint, or null when the bytes are not one.
///
/// Not `unicode.utf8Decode` alone: that returns a one-byte slice's byte
/// verbatim (`switch (bytes.len) { 1 => bytes[0], ... }`), so the malformed
/// bytes `nextCodepoint` hands back one at a time would "decode" into a C1
/// control (width 0) or a Latin-1 letter instead of being counted as the
/// broken bytes they are. Only ASCII is a valid one-byte codepoint.
fn decodeOne(slice: []const u8) ?u21 {
    if (slice.len == 1) return if (slice[0] < 0x80) slice[0] else null;
    return unicode.utf8Decode(slice) catch null;
}

/// One grapheme cluster: a base codepoint, the zero-width marks attached to
/// it, and every base a U+200D joiner glues on after. `width` is the number
/// of terminal columns the cluster occupies, which is not the sum of its
/// codepoints: the terminal ligates the joined ones into the first one's
/// glyph.
pub const Cluster = struct {
    bytes: []const u8,
    width: usize,
};

const zwj: u21 = 0x200D;
const vs16: u21 = 0xFE0F;

/// Display width of one codepoint's bytes, with the two rules that decide
/// how a cluster adds up: a codepoint a joiner glued on contributes nothing
/// of its own, and VS16 asks for the emoji-presentation glyph, which is wide
/// even when the bare codepoint is narrow (`❤` U+2764 is EAW=Neutral).
fn oneWidth(slice: []const u8) usize {
    const cp = decodeOne(slice) orelse return 1;
    return codepointWidth(cp);
}

/// The next grapheme cluster of `s` at `i.*`, advancing `i.*` past it.
///
/// A control byte is its own cluster of one column, so a `'\n'` is never
/// absorbed into the cell before it and never reaches the terminal hidden
/// inside another cell's bytes.
pub fn nextCluster(s: []const u8, i: *usize) ?Cluster {
    if (i.* >= s.len) return null;
    const start = i.*;
    const base = nextCodepoint(s, i).?;
    if (isControl(base)) return .{ .bytes = base, .width = 1 };
    var w = oneWidth(base);
    var joined = false;
    var emoji_presentation = false;
    while (i.* < s.len) {
        var peek = i.*;
        const next = nextCodepoint(s, &peek) orelse break;
        if (isControl(next)) break;
        if (oneWidth(next) != 0) {
            // A base after a joiner is part of this cluster only when the
            // cluster so far is an emoji: the joiner is what makes a
            // terminal ligate 👨‍👩‍👧 into one glyph. A joiner between
            // two ordinary letters is not ligated, so "a‍b" stays two
            // columns and must not collapse into one.
            if (!joined or w < 2) break;
            w = @max(w, oneWidth(next));
        }
        i.* = peek;
        joined = decodeOne(next) == zwj;
        if (decodeOne(next) == vs16) emoji_presentation = true;
    }
    if (emoji_presentation and w == 1) w = 2;
    return .{ .bytes = s[start..i.*], .width = if (w == 0) 1 else w };
}

fn isControl(slice: []const u8) bool {
    return slice.len == 1 and (slice[0] < 0x20 or slice[0] == 0x7F);
}

/// Display width of a UTF-8 string: the sum of its grapheme clusters'
/// widths. Invalid UTF-8 bytes count as width 1 each so a malformed string
/// still lays out deterministically instead of erroring mid-render.
pub fn displayWidth(s: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (nextCluster(s, &i)) |c| total += c.width;
    return total;
}

/// The longest prefix of `s` whose display width is `<= max_cols`, cut only
/// on cluster boundaries. Used to fit plain (no-ANSI) text into a fixed
/// terminal width before it gets wrapped in styling.
pub fn truncateToWidth(s: []const u8, max_cols: usize) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        const c = nextCluster(s, &i) orelse break;
        if (w + c.width > max_cols) return s[0..start];
        w += c.width;
    }
    return s;
}

test "ascii is width 1" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
}

test "cjk ideographs are width 2" {
    try std.testing.expectEqual(@as(u2, 2), codepointWidth(0x4E00)); // 一
    try std.testing.expectEqual(@as(u2, 2), codepointWidth(0x9FFF));
}

test "boundary just below cjk block is width 1" {
    try std.testing.expectEqual(@as(u2, 1), codepointWidth(0x4DFF));
}

test "hangul syllables are width 2" {
    try std.testing.expectEqual(@as(u2, 2), codepointWidth(0xAC00));
    try std.testing.expectEqual(@as(u2, 2), codepointWidth(0xD7A3));
}

test "combining marks are width 0" {
    try std.testing.expectEqual(@as(u2, 0), codepointWidth(0x0301)); // combining acute accent
}

test "BOM (U+FEFF) is zero-width" {
    try std.testing.expectEqual(@as(u2, 0), codepointWidth(0xFEFF));
}

test "control chars are width 0" {
    try std.testing.expectEqual(@as(u2, 0), codepointWidth(0x1B));
}

test "mixed string sums codepoint widths" {
    // "a" (1) + CJK "中" (2) + "b" (1) = 4
    try std.testing.expectEqual(@as(usize, 4), displayWidth("a\xe4\xb8\xadb"));
}

test "wide emoji are width 2" {
    try std.testing.expectEqual(@as(u2, 2), codepointWidth(0x1F680)); // rocket
    try std.testing.expectEqual(@as(u2, 2), codepointWidth(0x2705)); // check mark button
    try std.testing.expectEqual(@as(u2, 2), codepointWidth(0x26A1)); // high voltage
    try std.testing.expectEqual(@as(u2, 2), codepointWidth(0x1FAFF));
}

test "narrow symbols around the emoji singletons stay width 1" {
    try std.testing.expectEqual(@as(u2, 1), codepointWidth(0x2319)); // below watch
    try std.testing.expectEqual(@as(u2, 1), codepointWidth(0x2704)); // scissors variant
    try std.testing.expectEqual(@as(u2, 1), codepointWidth(0x2764)); // heavy heart (EAW=N)
}

test "emoji in a mixed string count 2 columns" {
    // "a" (1) + rocket (2) + "b" (1) = 4
    try std.testing.expectEqual(@as(usize, 4), displayWidth("a\xf0\x9f\x9a\x80b"));
}

test "truncateToWidth returns the whole string when it already fits" {
    try std.testing.expectEqualStrings("hello", truncateToWidth("hello", 10));
}

test "truncateToWidth cuts at the width boundary, not mid-codepoint" {
    try std.testing.expectEqualStrings("hell", truncateToWidth("hello world", 4));
}

test "truncateToWidth never splits a wide codepoint in half" {
    // Each CJK ideograph is 2 columns; a width-3 budget fits only one.
    const s = "\xe4\xb8\xad\xe4\xb8\xad"; // two copies of 中
    try std.testing.expectEqualStrings("\xe4\xb8\xad", truncateToWidth(s, 3));
}

test "a codepoint cut short at the end of the slice is one byte, not a panic" {
    // A streamed delta ends mid-codepoint all the time: 中 is three bytes and
    // an SSE chunk can carry two of them. `std.unicode.Utf8Iterator` slices
    // `bytes[i - 3 .. i]` out of a two-byte slice here and panics.
    var i: usize = 0;
    const first = nextCodepoint("\xe4\xb8", &i).?;
    try std.testing.expectEqualStrings("\xe4", first);
    try std.testing.expectEqual(@as(usize, 1), i);
    const second = nextCodepoint("\xe4\xb8", &i).?;
    try std.testing.expectEqualStrings("\xb8", second);
    try std.testing.expect(nextCodepoint("\xe4\xb8", &i) == null);
}

test "malformed bytes lay out as width 1 each, the way this module documents" {
    // A lone continuation byte cannot start a sequence: the std iterator
    // `catch unreachable`s it.
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\x80"));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xff"));
    // A truncated tail: two bytes of a three-byte 中, one column each.
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe4\xb8"));
    // Valid text around the damage still measures normally: a + b are two
    // columns, the three broken bytes one each.
    try std.testing.expectEqual(@as(usize, 5), displayWidth("a\x80b\xe4\xb8"));
    // And truncation walks the same bytes without panicking or over-cutting.
    try std.testing.expectEqualStrings("a\x80", truncateToWidth("a\x80b", 2));
    try std.testing.expectEqualStrings("\xe4\xb8", truncateToWidth("\xe4\xb8", 5));
}

test "a ZWJ emoji sequence is one cell of two columns, not one per emoji" {
    // 👨‍👩‍👧: three wide codepoints and two joiners. A terminal ligates
    // them into a single two-column glyph; summing the codepoints claimed
    // six, so every row carrying one overran its border by four columns.
    const family = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7";
    try std.testing.expectEqual(@as(usize, 2), displayWidth(family));
    var i: usize = 0;
    const cell = nextCluster(family, &i).?;
    try std.testing.expectEqualStrings(family, cell.bytes);
    try std.testing.expectEqual(family.len, i);
    try std.testing.expectEqualStrings(family, truncateToWidth(family, 2));
    try std.testing.expectEqualStrings("", truncateToWidth(family, 1));
}

test "a rainbow flag ligates through VS16 and ZWJ into two columns" {
    // 🏳️‍🌈 = white flag + VS16 + ZWJ + rainbow. Without the VS16 the
    // bare flag codepoint is Wide anyway; the pair is what proves the
    // rule does not depend on where the width came from.
    const flag = "\xf0\x9f\x8f\xb3\xef\xb8\x8f\xe2\x80\x8d\xf0\x9f\x8c\x88";
    try std.testing.expectEqual(@as(usize, 2), displayWidth(flag));
}

test "VS16 promotes a narrow symbol to the emoji-presentation width" {
    // ❤ alone is EAW=Neutral and one column; ❤ with VS16 is the heart
    // emoji, which every terminal draws two columns wide.
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xe2\x9d\xa4"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe2\x9d\xa4\xef\xb8\x8f"));
    try std.testing.expectEqualStrings("\xe2\x9d\xa4\xef\xb8\x8f", truncateToWidth("\xe2\x9d\xa4\xef\xb8\x8f", 2));
}

test "a joiner between ordinary letters does not collapse them into one cell" {
    // "a‍b" is not a ligature: the two letters stay two columns.
    const joined_letters = "a\xe2\x80\x8db";
    try std.testing.expectEqual(@as(usize, 2), displayWidth(joined_letters));
    try std.testing.expectEqualStrings("a\xe2\x80\x8d", truncateToWidth(joined_letters, 1));
}

test "nextCluster keeps a control byte in a cluster of its own" {
    var i: usize = 0;
    const c = nextCluster("a\nb", &i).?;
    try std.testing.expectEqualStrings("a", c.bytes);
    const nl = nextCluster("a\nb", &i).?;
    try std.testing.expectEqualStrings("\n", nl.bytes);
    try std.testing.expectEqual(@as(usize, 1), nl.width);
    try std.testing.expectEqualStrings("b", (nextCluster("a\nb", &i).?).bytes);
}

test "a family emoji followed by text walks on to the next cluster" {
    const s = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7!";
    try std.testing.expectEqual(@as(usize, 3), displayWidth(s));
    var i: usize = 0;
    _ = nextCluster(s, &i).?;
    try std.testing.expectEqualStrings("!", (nextCluster(s, &i).?).bytes);
}
