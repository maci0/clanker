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
//! UAX #11 table: the long tail of BMP Wide singletons and VS16-driven
//! presentation (text-style vs emoji-style ☀) still count 1 here. The next
//! step up, if that tail is ever reported, is vaxis's gwidth/zg tables,
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

/// Display width of a UTF-8 string: sum of each codepoint's width. Invalid
/// UTF-8 bytes count as width 1 each so a malformed string still lays out
/// deterministically instead of erroring mid-render.
pub fn displayWidth(s: []const u8) usize {
    var total: usize = 0;
    var it = unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepointSlice()) |slice| {
        const cp = unicode.utf8Decode(slice) catch {
            total += 1;
            continue;
        };
        total += codepointWidth(cp);
    }
    return total;
}

/// The longest prefix of `s` whose display width is `<= max_cols`, cut only
/// on codepoint boundaries. Used to fit plain (no-ANSI) text into a fixed
/// terminal width before it gets wrapped in styling.
pub fn truncateToWidth(s: []const u8, max_cols: usize) []const u8 {
    var w: usize = 0;
    var it = unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.i < s.len) {
        const start = it.i;
        const slice = it.nextCodepointSlice() orelse break;
        const cp = unicode.utf8Decode(slice) catch {
            w += 1;
            if (w > max_cols) return s[0..start];
            continue;
        };
        const cw = codepointWidth(cp);
        if (w + cw > max_cols) return s[0..start];
        w += cw;
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
