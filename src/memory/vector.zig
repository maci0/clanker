//! VectorStore trait — builtin brute-force cosine, swappable to muninndb/sqlite-vec.

const std = @import("std");

pub const Hit = struct {
    chunk_id: []const u8,
    score: f32,
};

pub const Backend = enum { builtin, muninndb, sqlite_vec };

pub fn cosine(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len or a.len == 0) return 0;
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * @as(f64, y);
        na += @as(f64, x) * @as(f64, x);
        nb += @as(f64, y) * @as(f64, y);
    }
    if (na == 0 or nb == 0) return 0;
    return @as(f32, @floatCast(dot / (@sqrt(na) * @sqrt(nb))));
}

/// Brute-force top-k by cosine. Caller owns `vectors`+`ids` alignment.
/// `threshold` filters below score; 0 means no threshold.
pub fn topK(
    arena: std.mem.Allocator,
    query: []const f32,
    ids: []const []const u8,
    vectors: []const []const f32,
    k: usize,
    threshold: f32,
) ![]Hit {
    if (query.len == 0 or ids.len == 0 or vectors.len == 0) return try arena.alloc(Hit, 0);
    const n = @min(ids.len, vectors.len);
    var hits: std.ArrayList(Hit) = .empty;
    for (0..n) |i| {
        const s = cosine(query, vectors[i]);
        if (s < threshold) continue;
        try hits.append(arena, .{ .chunk_id = ids[i], .score = s });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn gt(_: void, a: Hit, b: Hit) bool {
            return a.score > b.score;
        }
    }.gt);
    if (hits.items.len > k) hits.shrinkRetainingCapacity(k);
    return hits.toOwnedSlice(arena);
}

test "cosine topK" {
    const q = [_]f32{ 1, 0 };
    const v0 = [_]f32{ 1, 0 };
    const v1 = [_]f32{ 0, 1 };
    const ids = [_][]const u8{ "a", "b" };
    const vecs = [_][]const f32{ &v0, &v1 };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const hits = try topK(arena_state.allocator(), &q, &ids, &vecs, 1, 0);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("a", hits[0].chunk_id);
    try std.testing.expect(hits[0].score > 0.99);
}

test "topK threshold filters" {
    const q = [_]f32{ 1, 0 };
    const v0 = [_]f32{ 0, 1 };
    const ids = [_][]const u8{"a"};
    const vecs = [_][]const f32{&v0};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const hits = try topK(arena_state.allocator(), &q, &ids, &vecs, 5, 0.5);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}
