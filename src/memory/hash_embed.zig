//! Pure hash embedder — host + WASM, zero deps, deterministic.
//! Token bag hashed into `dim` dims, L2-normalized. Offline, free, good enough for single-user recall;
//! openai_compat remains the quality path.

const std = @import("std");

pub const default_dim: usize = 384;

pub fn normalize(vec: []f32) void {
    var sum: f64 = 0;
    for (vec) |v| sum += @as(f64, v) * @as(f64, v);
    if (sum == 0) return;
    const inv = 1.0 / @sqrt(sum);
    for (vec) |*v| v.* = @floatCast(@as(f64, v.*) * inv);
}

fn hashIndex(hash: u64, len: usize) usize {
    // Wyhash distributes entropy across all bits, so intentionally retain the
    // low 32 bits before reducing to the embedding dimension.
    const low_bits: u32 = @truncate(hash);
    return @as(usize, low_bits) % len;
}

fn addToken(vec: []f32, token: []const u8, weight: f32) void {
    if (token.len == 0) return;
    const h = std.hash.Wyhash.hash(0, token);
    const idx = hashIndex(h, vec.len);
    vec[idx] += weight;
}

pub fn embed(arena: std.mem.Allocator, text: []const u8, dim: usize) ![]f32 {
    const d = if (dim == 0) default_dim else dim;
    const vec = try arena.alloc(f32, d);
    @memset(vec, 0);
    var token_buf: [128]u8 = undefined;
    var tlen: usize = 0;
    var prev_buf: [128]u8 = undefined;
    var prev_len: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const c: u8 = if (i < text.len) text[i] else 0;
        const is_alnum = i < text.len and std.ascii.isAlphanumeric(c);
        if (is_alnum) {
            if (tlen < token_buf.len) {
                token_buf[tlen] = std.ascii.toLower(c);
                tlen += 1;
            }
        } else {
            if (tlen > 0) {
                const tok = token_buf[0..tlen];
                addToken(vec, tok, 1.0);
                if (prev_len > 0) {
                    var bigram: [256]u8 = undefined;
                    const a = prev_buf[0..prev_len];
                    @memcpy(bigram[0..a.len], a);
                    bigram[a.len] = ' ';
                    @memcpy(bigram[a.len + 1 .. a.len + 1 + tok.len], tok);
                    addToken(vec, bigram[0 .. a.len + 1 + tok.len], 0.5);
                }
                @memcpy(prev_buf[0..tlen], tok);
                prev_len = tlen;
                tlen = 0;
            }
        }
    }
    normalize(vec);
    return vec;
}

pub fn embedBatch(arena: std.mem.Allocator, texts: []const []const u8, dim: usize) ![][]f32 {
    var out: std.ArrayList([]f32) = .empty;
    for (texts) |t| {
        const v = try embed(arena, t, dim);
        try out.append(arena, v);
    }
    return out.toOwnedSlice(arena);
}

test "hash embed deterministic and normalized" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try embed(arena, "hello world", 16);
    const b = try embed(arena, "hello world", 16);
    try std.testing.expectEqualSlices(f32, a, b);
    var sum: f64 = 0;
    for (a) |v| sum += @as(f64, v) * @as(f64, v);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-5);
}

test "hash embed similar closer than dissimilar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const q = try embed(arena, "zig programming language", 32);
    const close = try embed(arena, "zig language programming", 32);
    const far = try embed(arena, "cooking recipe for soup", 32);
    const vector = @import("vector.zig");
    const s_close = vector.cosine(q, close);
    const s_far = vector.cosine(q, far);
    try std.testing.expect(s_close > s_far);
}
