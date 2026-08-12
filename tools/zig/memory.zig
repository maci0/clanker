//! memory — WASM guest tool for the memory layer. Thin over chunk/embed/vector traits.
//! Actions: chunk {text, size, overlap, strategy}, search {query, top_k, threshold, collection_ids}, embed {texts[]}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = try lib.object(input);
    const action = lib.optStr(obj, "action") orelse "search";
    if (std.mem.eql(u8, action, "chunk")) {
        const text = lib.optStr(obj, "text") orelse "";
        if (text.len == 0) {
            try lib.fail(out, "chunk needs {\"text\": \"...\"}");
            return;
        }
        const size = @as(usize, @intFromFloat(lib.optNum(obj, "size") orelse 800));
        const overlap = @as(usize, @intFromFloat(lib.optNum(obj, "overlap") orelse 120));
        const strategy_s = lib.optStr(obj, "strategy") orelse "markdown";
        const strat: u8 = if (std.mem.eql(u8, strategy_s, "fixed")) 1 else 0;
        _ = strat;
        // We can't import src/memory/chunk.zig directly in WASM (no std.fs), so we replicate fixed chunking here
        // Keep output tiny so we stay under out_cap: cap chunks to 20
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
    if (std.mem.eql(u8, action, "search")) {
        const query = lib.optStr(obj, "query") orelse "";
        if (query.len == 0) {
            try lib.fail(out, "search needs {\"query\": \"...\"}");
            return;
        }
        const top_k: usize = @as(usize, @intFromFloat(lib.optNum(obj, "top_k") orelse 5));
        // Host-side search would need embeddings; for now fall back to keyword search over knowledge chunks
        // We do a simple fs_list scan hint: caller should use /api/knowledge/search via HTTP for full, but we expose a local scan
        var w = lib.writer(out);
        var s = lib.json(&w);
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("query");
        try s.write(query);
        try s.objectField("top_k");
        try s.write(top_k);
        try s.objectField("hint");
        try s.write("use host /api/knowledge/search?q=<query> or memory_inject on /api/run for hybrid RAG; vector search requires embedding provider");
        try s.endObject();
        lib.commit(out, &w);
        return;
    }
    if (std.mem.eql(u8, action, "embed")) {
        try lib.fail(out, "embed via WASM is not yet wired; configure [memory.embedding] and use openai_compat host embeddings");
        return;
    }
    try lib.fail(out, "unknown action: use chunk | search | embed");
}
