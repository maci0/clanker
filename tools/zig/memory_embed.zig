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
    hashEmbedInto("anything", &.{});
}
