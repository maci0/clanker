//! memory — WASM guest tool for the memory layer.
//! Actions: chunk {text,size,overlap}, embed {texts[] or text,dim}, search {query,top_k,threshold,dim,collection_ids,mode}.
//! If action is omitted it is inferred: query -> search, texts -> embed, text -> chunk.

const std = @import("std");
const lib = @import("lib.zig");
const memory_embed = @import("memory_embed.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

const default_dim: usize = 384;
/// Ceiling on `top_k`: it sizes the ranking buffer, so an unbounded request
/// value is an unbounded allocation.
const max_top_k: usize = 100;
/// Longest chunk excerpt a hit carries back.
const max_hit_text: usize = 2000;

/// Cosine similarity of two `hashEmbedInto` vectors. That function
/// L2-normalizes everything it writes, so both norms are 1 and the dot product
/// is the whole answer: recomputing them per chunk tripled the work of the
/// search loop. A text with no tokens embeds to all zeros and still scores 0,
/// which is what the norm-guarded form answered for it.
fn cosine(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len) return 0;
    var dot: f64 = 0;
    for (a, b) |x, y| dot += @as(f64, x) * @as(f64, y);
    return @floatCast(dot);
}

fn keywordScore(query: []const u8, text: []const u8) f32 {
    var hits: f32 = 0;
    var total: f32 = 0;
    var qi: usize = 0;
    var qbuf: [128]u8 = undefined;
    var qlen: usize = 0;
    while (qi <= query.len) : (qi += 1) {
        const c: u8 = if (qi < query.len) query[qi] else 0;
        if (qi < query.len and std.ascii.isAlphanumeric(c)) {
            if (qlen < qbuf.len) {
                qbuf[qlen] = std.ascii.toLower(c);
                qlen += 1;
            }
        } else {
            if (qlen >= 2) {
                total += 1;
                // `indexOfIgnoreCase` is the same case-folded substring search
                // the hand-rolled double loop did, minus the per-position
                // restart: keyword mode runs it once per query token per chunk
                // over the whole store.
                if (std.ascii.indexOfIgnoreCase(text, qbuf[0..qlen]) != null) hits += 1;
            }
            qlen = 0;
        }
    }
    if (total == 0) return 0;
    return hits / total;
}

fn inferAction(obj: std.json.Value) []const u8 {
    if (lib.optStr(obj, "query") != null) return "search";
    if (obj == .object) {
        if (obj.object.get("texts")) |v| {
            if (v == .array) return "embed";
        }
    }
    if (lib.optStr(obj, "text") != null) return "chunk";
    return "search";
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = try lib.object(input);
    const action = lib.optStr(obj, "action") orelse inferAction(obj);
    if (std.mem.eql(u8, action, "chunk")) {
        const text = lib.optStr(obj, "text") orelse "";
        if (text.len == 0) {
            try lib.fail(out, "chunk needs {\"text\": \"...\"}");
            return;
        }
        const size_f: f64 = lib.optNum(obj, "size") orelse 800;
        const overlap_f: f64 = lib.optNum(obj, "overlap") orelse 120;
        const size: usize = @trunc(size_f);
        const overlap: usize = @trunc(overlap_f);
        const cap = @min(size, 800);
        const ov = @min(overlap, 120);
        var chunks: std.ArrayList([]const u8) = .empty;
        var off: usize = 0;
        var count: usize = 0;
        while (off < text.len and count < 20) : (count += 1) {
            const end = @min(text.len, off + cap);
            var slice = text[off..end];
            slice = std.mem.trim(u8, slice, " \t\r\n");
            if (slice.len > 0) try chunks.append(lib.alloc, slice);
            if (end >= text.len) break;
            off = end - @min(ov, cap - 1);
        }
        var w = lib.writer(out);
        var s = lib.json(&w);
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("chunks");
        try s.beginArray();
        for (chunks.items) |ch| try s.write(ch);
        try s.endArray();
        try s.endObject();
        lib.commit(out, &w);
        return;
    }
    if (std.mem.eql(u8, action, "embed")) {
        const dim_f: f64 = lib.optNum(obj, "dim") orelse @as(f64, @floatFromInt(default_dim));
        const d: usize = @trunc(@min(@max(dim_f, 16), 1024));
        var w = lib.writer(out);
        var s = lib.json(&w);
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("dim");
        try s.write(d);
        try s.objectField("embeddings");
        try s.beginArray();
        var wrote = false;
        if (obj.object.get("texts")) |v| {
            if (v == .array) {
                for (v.array.items) |item| {
                    if (item != .string) continue;
                    const vec = try lib.alloc.alloc(f32, d);
                    defer lib.alloc.free(vec);
                    memory_embed.hashEmbedInto(item.string, vec);
                    try s.beginArray();
                    for (vec) |f| try s.write(f);
                    try s.endArray();
                    wrote = true;
                }
            }
        }
        if (!wrote) {
            if (obj.object.get("text")) |v| {
                if (v == .string) {
                    const vec = try lib.alloc.alloc(f32, d);
                    defer lib.alloc.free(vec);
                    memory_embed.hashEmbedInto(v.string, vec);
                    try s.beginArray();
                    for (vec) |f| try s.write(f);
                    try s.endArray();
                    wrote = true;
                }
            }
        }
        if (!wrote) {
            try lib.fail(out, "embed needs {\"texts\": [\"...\"]} or {\"text\": \"...\"}");
            return;
        }
        try s.endArray();
        try s.endObject();
        lib.commit(out, &w);
        return;
    }
    if (std.mem.eql(u8, action, "search")) {
        const query = lib.optStr(obj, "query") orelse "";
        if (query.len == 0) {
            try lib.fail(out, "search needs {\"query\": \"...\"}");
            return;
        }
        // Clamped before the conversion, not after: `@trunc` with an integer
        // destination is illegal behaviour on a negative float, so a request
        // body of {"top_k":-1} used to take the guest down instead of being
        // rejected as the nonsense it is. The upper bound is what the ranking
        // buffer below is sized from.
        const top_k_f: f64 = lib.optNum(obj, "top_k") orelse 5;
        const top_k: usize = @trunc(@min(@max(top_k_f, 0), @as(f64, max_top_k)));
        const threshold: f32 = @as(f32, @floatCast(lib.optNum(obj, "threshold") orelse 0));
        const mode = lib.optStr(obj, "mode") orelse "vector";
        if (!std.mem.eql(u8, mode, "vector") and !std.mem.eql(u8, mode, "keyword"))
            return lib.fail(out, "mode must be \"vector\" or \"keyword\"");
        const use_keyword = std.mem.eql(u8, mode, "keyword");
        const dim_f: f64 = lib.optNum(obj, "dim") orelse @as(f64, @floatFromInt(default_dim));
        const d: usize = @trunc(@min(@max(dim_f, 16), 1024));
        var qvec: ?[]f32 = null;
        // Scratch for the chunk being scored. Every chunk embeds to the same
        // `d` floats, so one buffer serves the whole walk; allocating and
        // freeing it per chunk was an allocator round-trip per record in the
        // store for a buffer whose size never changes.
        var cvec: ?[]f32 = null;
        if (!use_keyword) {
            qvec = try lib.alloc.alloc(f32, d);
            memory_embed.hashEmbedInto(query, qvec.?);
            cvec = try lib.alloc.alloc(f32, d);
        }
        defer if (qvec) |v| lib.alloc.free(v);
        defer if (cvec) |v| lib.alloc.free(v);
        var filter_ids: std.ArrayList([]const u8) = .empty;
        if (obj.object.get("collection_ids")) |v| {
            if (v == .array) for (v.array.items) |it| {
                if (it == .string) try filter_ids.append(lib.alloc, it.string);
            };
        }
        const listing = lib.fsList("state/knowledge") catch |err| {
            var w = lib.writer(out);
            var s2 = lib.json(&w);
            try s2.beginObject();
            try s2.objectField("ok");
            try s2.write(true);
            try s2.objectField("query");
            try s2.write(query);
            try s2.objectField("hits");
            try s2.beginArray();
            try s2.endArray();
            try s2.objectField("note");
            try s2.write(switch (err) {
                error.SandboxDenied => "knowledge directory not accessible",
                error.NotFound => "knowledge directory not found",
                else => "could not list knowledge files",
            });
            try s2.endObject();
            lib.commit(out, &w);
            return;
        };
        const parsed_list = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, listing, .{}) catch null;
        // Only `top_k` hits can ever be returned, so only `top_k` are kept:
        // duping every chunk above the threshold and sorting at the end grew
        // with the size of the knowledge store, and the arena exhaustion that
        // followed dropped hits through a bare `catch continue`.
        const ranked = try lib.alloc.alloc(memory_embed.Hit, top_k);
        defer lib.alloc.free(ranked);
        var ranked_len: usize = 0;
        if (parsed_list) |pl| if (pl == .array) for (pl.array.items) |entry| {
            if (entry != .string) continue;
            const name: []const u8 = entry.string;
            if (!std.mem.endsWith(u8, name, ".chunks.json")) continue;
            if (filter_ids.items.len > 0) {
                const col_id = name[0 .. name.len - ".chunks.json".len];
                var keep = false;
                for (filter_ids.items) |fid| if (std.mem.eql(u8, fid, col_id)) {
                    keep = true;
                    break;
                };
                if (!keep) continue;
            }
            const path = std.fmt.allocPrint(lib.alloc, "state/knowledge/{s}", .{name}) catch continue;
            const raw = lib.fsRead(path) catch continue;
            const arr = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch continue;
            if (arr != .array) continue;
            for (arr.array.items) |item| {
                if (item != .object) continue;
                const text_v = item.object.get("text") orelse continue;
                if (text_v != .string) continue;
                const chunk_id = if (item.object.get("chunk_id")) |v| (if (v == .string) v.string else text_v.string) else text_v.string;
                const sc = if (use_keyword)
                    keywordScore(query, text_v.string)
                else blk: {
                    memory_embed.hashEmbedInto(text_v.string, cvec.?);
                    break :blk cosine(qvec.?, cvec.?);
                };
                if (sc < threshold) continue;
                const slot = memory_embed.rankSlot(ranked, ranked_len, sc) orelse continue;
                const dup_id = lib.alloc.dupe(u8, chunk_id) catch continue;
                // The reply truncates to `max_hit_text` anyway, so copying the
                // rest of a chunk only to throw it away is arena the search
                // does not have.
                const dup_text = lib.alloc.dupe(u8, text_v.string[0..@min(text_v.string.len, max_hit_text)]) catch continue;
                ranked_len = memory_embed.rankInsert(ranked, ranked_len, slot, .{ .id = dup_id, .text = dup_text, .score = sc });
            }
        };
        var w = lib.writer(out);
        var s = lib.json(&w);
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("query");
        try s.write(query);
        try s.objectField("hits");
        try s.beginArray();
        for (ranked[0..ranked_len]) |h| {
            try s.beginObject();
            try s.objectField("chunk_id");
            try s.write(h.id);
            try s.objectField("score");
            try s.write(h.score);
            try s.objectField("text");
            try s.write(h.text);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        lib.commit(out, &w);
        return;
    }
    try lib.fail(out, "unknown action: use chunk | search | embed");
}
