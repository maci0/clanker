//! Embedder trait — pluggable: openai_compat (live) + local_onnx (stub).

const std = @import("std");

pub const Provider = enum { openai_compat, local_onnx };

/// Embeds `texts` via openai_compat. Caller must provide base_url + optional bearer token.
/// Hits POST {base_url}/embeddings (or {base_url} if it already ends with /embeddings).
pub fn embedOpenAICompat(
    arena: std.mem.Allocator,
    io: std.Io,
    httpFn: *const fn (std.mem.Allocator, std.Io, []const u8, []const u8, []const u8) anyerror![]const u8,
    base_url: []const u8,
    api_key: ?[]const u8,
    model: []const u8,
    texts: []const []const u8,
) ![][]f32 {
    if (texts.len == 0) return try arena.alloc([]f32, 0);
    const url = if (std.mem.endsWith(u8, base_url, "/embeddings")) try arena.dupe(u8, base_url) else try std.fmt.allocPrint(arena, "{s}/embeddings", .{std.mem.trimEnd(u8, base_url, "/")});
    // Build JSON body
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("model");
    try s.write(model);
    try s.objectField("input");
    try s.beginArray();
    for (texts) |t| try s.write(t);
    try s.endArray();
    try s.endObject();
    const body = out.written();
    const auth = if (api_key) |k| try std.fmt.allocPrint(arena, "Bearer {s}", .{k}) else "";
    // httpFn is expected to do POST with JSON and return raw response body
    const resp_raw = try httpFn(arena, io, url, body, auth);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, resp_raw, .{});
    // Expect {data:[{embedding:[...]}, ...]}  or {data:[{embedding:[...]}]} — OpenAI compat
    const data_val = if (parsed == .object) parsed.object.get("data") else null;
    if (data_val == null or data_val.? != .array) return error.InvalidResponse;
    const arr = data_val.?.array.items;
    var out_vecs: std.ArrayList([]f32) = .empty;
    for (arr) |item| {
        if (item != .object) continue;
        const emb_val = item.object.get("embedding") orelse continue;
        if (emb_val != .array) continue;
        var vec: std.ArrayList(f32) = .empty;
        for (emb_val.array.items) |v| {
            const f: f32 = switch (v) {
                .float => |ff| @floatCast(ff),
                .integer => |ii| @floatFromInt(ii),
                else => continue,
            };
            try vec.append(arena, f);
        }
        try out_vecs.append(arena, try vec.toOwnedSlice(arena));
    }
    return out_vecs.toOwnedSlice(arena);
}

test "embedOpenAICompat parses mock response" {
    const MockHttp = struct {
        fn post(arena: std.mem.Allocator, io: std.Io, url: []const u8, body: []const u8, auth: []const u8) anyerror![]const u8 {
            _ = io;
            _ = url;
            _ = body;
            _ = auth;
            _ = arena;
            return "{\"data\":[{\"embedding\":[0.1,0.2,0.3]},{\"embedding\":[0.4,0.5,0.6]}]}";
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const texts = [_][]const u8{ "hello", "world" };
    const vecs = try embedOpenAICompat(arena, threaded.io(), &MockHttp.post, "https://example.test/v1", null, "text-embedding-3-small", &texts);
    try std.testing.expectEqual(@as(usize, 2), vecs.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), vecs[0][0], 1e-5);
}
