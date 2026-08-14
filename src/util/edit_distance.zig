const std = @import("std");

/// Bounded byte-wise edit distance used by every operator surface when it
/// offers a "did you mean" spelling. Adjacent transposition counts as one
/// edit (`modle` -> `model`), matching what people usually mean by a typo.
/// Inputs longer than 32 bytes are deliberately not suggestion candidates.
pub fn typoDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 32 or b.len > 32) return 99;
    if (isAdjacentTransposition(a, b)) return 1;

    var previous: [33]usize = undefined;
    var current: [33]usize = undefined;
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
    try std.testing.expectEqual(@as(usize, 99), typoDistance("abcdefghijklmnopqrstuvwxyz1234567", "model"));
}
