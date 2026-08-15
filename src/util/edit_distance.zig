//! Bounded Levenshtein-with-transpose used by "did you mean" suggestions.

const std = @import("std");

/// Inputs longer than this are not suggestion candidates.
const max_typo_bytes: usize = 32;
/// Sentinel larger than any real distance in a `max_typo_bytes` window.
const too_long: usize = 99;

/// Bounded byte-wise edit distance used by every operator surface when it
/// offers a "did you mean" spelling. Adjacent transposition counts as one
/// edit (`modle` -> `model`), matching what people usually mean by a typo.
/// Inputs longer than `max_typo_bytes` are deliberately not suggestion candidates.
pub fn typoDistance(a: []const u8, b: []const u8) usize {
    if (a.len > max_typo_bytes or b.len > max_typo_bytes) return too_long;
    if (isAdjacentTransposition(a, b)) return 1;

    var previous: [max_typo_bytes + 1]usize = undefined;
    var current: [max_typo_bytes + 1]usize = undefined;
    for (0..b.len + 1) |i| previous[i] = i;
    for (a, 0..) |ac, ai| {
        current[0] = ai + 1;
        for (b, 0..) |bc, bi| {
            const substitution = previous[bi] + @intFromBool(ac != bc);
            current[bi + 1] = @min(@min(previous[bi + 1] + 1, current[bi] + 1), substitution);
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

fn isAdjacentTransposition(a: []const u8, b: []const u8) bool {
    if (a.len != b.len or a.len < 2) return false;
    var i: usize = 0;
    var swaps: usize = 0;
    while (i < a.len) {
        if (a[i] == b[i]) {
            i += 1;
            continue;
        }
        if (i + 1 < a.len and a[i] == b[i + 1] and a[i + 1] == b[i]) {
            swaps += 1;
            i += 2;
            continue;
        }
        return false;
    }
    return swaps == 1;
}

test "typo distance treats insertion deletion substitution and transpose consistently" {
    try std.testing.expectEqual(@as(usize, 1), typoDistance("model", "models"));
    try std.testing.expectEqual(@as(usize, 1), typoDistance("models", "model"));
    try std.testing.expectEqual(@as(usize, 1), typoDistance("modal", "model"));
    try std.testing.expectEqual(@as(usize, 1), typoDistance("modle", "model"));
    try std.testing.expectEqual(too_long, typoDistance("abcdefghijklmnopqrstuvwxyz1234567", "model"));
}
