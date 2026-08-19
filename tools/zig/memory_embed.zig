//! Pure deterministic embedding logic for the memory guest.

const std = @import("std");
const max_token_bytes: usize = 128;

fn hashIndex(hash: u64, len: usize) usize {
    // Bucket index uses the low 32 bits of the 64-bit hash (lossy by design).
    const low_bits: u32 = @truncate(hash);
    return @as(usize, low_bits) % len;
}

pub fn hashEmbedInto(text: []const u8, vec: []f32) void {
    @memset(vec, 0);
    if (vec.len == 0) return;
    var token_buf: [max_token_bytes]u8 = undefined;
    var prev_buf: [max_token_bytes]u8 = undefined;
    var tlen: usize = 0;
    var prev_len: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const c: u8 = if (i < text.len) text[i] else 0;
        if (i < text.len and std.ascii.isAlphanumeric(c)) {
            if (tlen < token_buf.len) {
                token_buf[tlen] = std.ascii.toLower(c);
                tlen += 1;
            }
        } else if (tlen > 0) {
            const tok = token_buf[0..tlen];
            vec[hashIndex(std.hash.Wyhash.hash(0, tok), vec.len)] += 1.0;
            if (prev_len > 0) {
                // Maximum token + separator + maximum token is 257 bytes.
                var bigram: [max_token_bytes * 2 + 1]u8 = undefined;
                const prev = prev_buf[0..prev_len];
                @memcpy(bigram[0..prev.len], prev);
                bigram[prev.len] = ' ';
                @memcpy(bigram[prev.len + 1 .. prev.len + 1 + tok.len], tok);
                const span = bigram[0 .. prev.len + 1 + tok.len];
                vec[hashIndex(std.hash.Wyhash.hash(0, span), vec.len)] += 0.5;
            }
            @memcpy(prev_buf[0..tlen], tok);
            prev_len = tlen;
            tlen = 0;
        }
    }
    var sum: f64 = 0;
    for (vec) |v| sum += @as(f64, v) * @as(f64, v);
    if (sum == 0) return;
    const inv = 1.0 / @sqrt(sum);
    for (vec) |*v| v.* = @floatCast(@as(f64, v.*) * inv);
}

test "maximum-length token pair cannot overflow the bigram" {
    const text = ("a" ** max_token_bytes) ++ " " ++ ("b" ** max_token_bytes);
    var vec: [64]f32 = undefined;
    hashEmbedInto(text, &vec);
    var norm: f64 = 0;
    for (vec) |v| norm += @as(f64, v) * @as(f64, v);
    try std.testing.expectApproxEqAbs(@as(f64, 1), norm, 0.000001);
}

test "zero dimensions are safe" {
    // A zero-length vec takes the early return before any hashing; this is a
    // crash-safety check (the old bug was a `% 0` divide on an empty vec).
    hashEmbedInto("anything", &.{});
    // The smallest usable dimension must still hash and normalize to unit
    // length rather than dividing by zero or leaving the vec untouched.
    var one: [1]f32 = undefined;
    hashEmbedInto("a b", &one);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), one[0], 0.000001);
}

// ------------------------------------------------------------------ ranking

/// One scored search hit. `id` and `text` are whatever the caller copied for
/// the hit; nothing here reads them.
pub const Hit = struct {
    id: []const u8 = "",
    text: []const u8 = "",
    score: f32 = 0,
};

/// The slot `score` takes in `ranked` (descending, `len` of `ranked.len` slots
/// filled), or null when it cannot make the cut.
///
/// Asked *before* the caller copies the hit's id and text, so a candidate that
/// will not be returned costs nothing. That is the point: the search used to
/// dupe every chunk scoring above the threshold and sort at the end, which in
/// a guest with a 1 MiB arena means the whole knowledge store, and the
/// allocation failure that follows drops hits with no diagnostic. Only
/// `ranked.len` of them can ever be returned.
pub fn rankSlot(ranked: []const Hit, len: usize, score: f32) ?usize {
    if (ranked.len == 0) return null;
    if (len >= ranked.len and score <= ranked[ranked.len - 1].score) return null;
    var i = @min(len, ranked.len - 1);
    while (i > 0 and ranked[i - 1].score < score) i -= 1;
    return i;
}

/// Writes `hit` at `slot` (from `rankSlot`), shifting the worse entries down
/// and dropping the last one when the ranking is already full. Returns the new
/// filled length.
pub fn rankInsert(ranked: []Hit, len: usize, slot: usize, hit: Hit) usize {
    const new_len = @min(len + 1, ranked.len);
    var i = new_len - 1;
    while (i > slot) : (i -= 1) ranked[i] = ranked[i - 1];
    ranked[slot] = hit;
    return new_len;
}

test "ranking keeps the best hits in descending order" {
    var buf: [3]Hit = undefined;
    var len: usize = 0;
    for ([_]f32{ 0.1, 0.9, 0.5, 0.7, 0.2 }) |s| {
        const slot = rankSlot(&buf, len, s) orelse continue;
        len = rankInsert(&buf, len, slot, .{ .id = "x", .score = s });
    }
    try std.testing.expectEqual(@as(usize, 3), len);
    try std.testing.expectEqual(@as(f32, 0.9), buf[0].score);
    try std.testing.expectEqual(@as(f32, 0.7), buf[1].score);
    try std.testing.expectEqual(@as(f32, 0.5), buf[2].score);
}

test "a full ranking rejects a score that cannot make the cut" {
    var buf: [2]Hit = undefined;
    var len: usize = 0;
    for ([_]f32{ 0.8, 0.6 }) |s| {
        len = rankInsert(&buf, len, rankSlot(&buf, len, s).?, .{ .score = s });
    }
    try std.testing.expect(rankSlot(&buf, len, 0.6) == null);
    try std.testing.expect(rankSlot(&buf, len, 0.1) == null);
    try std.testing.expectEqual(@as(usize, 1), rankSlot(&buf, len, 0.7).?);
}

test "a zero-capacity ranking accepts nothing" {
    var buf: [0]Hit = undefined;
    try std.testing.expect(rankSlot(&buf, 0, 1.0) == null);
}
