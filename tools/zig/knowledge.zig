//! knowledge: CRUD and search over state/knowledge/ collections.
//! Moved from src/knowledge/store.zig to the WASM sandbox so the harness
//! enforces fs_prefixes rather than granting whole-process access.
//!
//! Actions:
//!   list                         -> {ok, collections:[{id,title,description,doc_count,bytes,created,updated}]}
//!   get    {id}                  -> {ok, id, title, description, docs:[{id,name,bytes,created,content}]}
//!   create {title, description?} -> {ok, id, title}
//!   delete {id}                  -> {ok}
//!   add_doc {collection_id, name, content} -> {ok, id}
//!   delete_doc {collection_id, doc_id}     -> {ok}
//!   search {query, collections?} -> {ok, hits:[{collection_id,collection_title,doc_id,doc_name,snippet}]}

const std = @import("std");
const lib = @import("lib.zig");

const store_dir = "state/knowledge";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = try lib.object(input);
    const action = lib.optStr(obj, "action") orelse "list";

    if (std.mem.eql(u8, action, "list")) return actionList(out);
    if (std.mem.eql(u8, action, "get")) return actionGet(obj, out);
    if (std.mem.eql(u8, action, "create")) return actionCreate(obj, out);
    if (std.mem.eql(u8, action, "delete")) return actionDelete(obj, out);
    if (std.mem.eql(u8, action, "add_doc")) return actionAddDoc(obj, out);
    if (std.mem.eql(u8, action, "delete_doc")) return actionDeleteDoc(obj, out);
    if (std.mem.eql(u8, action, "search")) return actionSearch(obj, out);
    try lib.fail(out, "unknown action");
}

// ----------------------------------------------------------------- helpers ---

fn newId() []const u8 {
    // Time-mixed: with agent.seed pinned (default 0), lib.random() alone
    // draws the same value in every fresh invocation of this tool, so every
    // collection and document got the same id — and delete_doc, matching by
    // id, then removed all of them at once.
    const r = lib.random() ^ lib.nowNanos();
    return std.fmt.allocPrint(lib.alloc, "kb-{x}", .{r & 0xffffffffffff}) catch "kb-0";
}

fn nowSec() i64 {
    return @trunc(lib.nowSeconds());
}

fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

fn colPath(id: []const u8) []const u8 {
    return std.fmt.allocPrint(lib.alloc, "{s}/{s}.json", .{ store_dir, id }) catch "";
}

fn chunksPath(id: []const u8) []const u8 {
    return std.fmt.allocPrint(lib.alloc, "{s}/{s}.chunks.json", .{ store_dir, id }) catch "";
}

const StoredDoc = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    content: []const u8 = "",
    bytes: usize = 0,
    created: i64 = 0,
};

const StoredCollection = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    docs: []const StoredDoc = &.{},
};

fn loadCollection(id: []const u8) ?StoredCollection {
    const raw = lib.fsRead(colPath(id)) catch return null;
    return std.json.parseFromSliceLeaky(StoredCollection, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch null;
}

fn saveCollection(col: StoredCollection) !void {
    lib.fsMkdir(store_dir) catch {};
    var buf: std.Io.Writer.Allocating = .init(lib.alloc);
    defer buf.deinit();
    var s = std.json.Stringify{ .writer = &buf.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("id");
    try s.write(col.id);
    try s.objectField("title");
    try s.write(col.title);
    try s.objectField("description");
    try s.write(col.description);
    try s.objectField("created");
    try s.write(col.created);
    try s.objectField("updated");
    try s.write(col.updated);
    try s.objectField("docs");
    try s.beginArray();
    for (col.docs) |d| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(d.id);
        try s.objectField("name");
        try s.write(d.name);
        try s.objectField("content");
        try s.write(d.content);
        try s.objectField("bytes");
        try s.write(d.bytes);
        try s.objectField("created");
        try s.write(d.created);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try lib.fsWrite(colPath(col.id), buf.written());
}

// ----------------------------------------------------------------- actions ---

fn actionList(out: *lib.Out) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("collections");
    try s.beginArray();

    const listing = lib.fsList(store_dir) catch {
        try s.endArray();
        try s.endObject();
        lib.commit(out, &w);
        return;
    };
    const entries = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, listing, .{}) catch null;
    if (entries) |e| if (e == .array) {
        var names: std.ArrayList([]const u8) = .empty;
        for (e.array.items) |item| {
            if (item != .string) continue;
            const name = item.string;
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            if (std.mem.endsWith(u8, name, ".chunks.json")) continue;
            names.append(lib.alloc, name) catch continue;
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |name| {
            const path = std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ store_dir, name }) catch continue;
            const raw = lib.fsRead(path) catch continue;
            const col = std.json.parseFromSliceLeaky(StoredCollection, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch continue;
            var bytes: usize = 0;
            for (col.docs) |d| bytes += d.content.len;
            try s.beginObject();
            try s.objectField("id");
            try s.write(col.id);
            try s.objectField("title");
            try s.write(col.title);
            try s.objectField("description");
            try s.write(col.description);
            try s.objectField("doc_count");
            try s.write(col.docs.len);
            try s.objectField("bytes");
            try s.write(bytes);
            try s.objectField("created");
            try s.write(col.created);
            try s.objectField("updated");
            try s.write(col.updated);
            try s.endObject();
        }
    };

    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn actionGet(obj: std.json.Value, out: *lib.Out) !void {
    const id = lib.optStr(obj, "id") orelse return lib.fail(out, "get needs {\"id\": \"...\"}");
    if (!isSlug(id)) return lib.fail(out, "bad collection id");
    const col = loadCollection(id) orelse return lib.fail(out, "no such collection");
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("id");
    try s.write(col.id);
    try s.objectField("title");
    try s.write(col.title);
    try s.objectField("description");
    try s.write(col.description);
    try s.objectField("docs");
    try s.beginArray();
    for (col.docs) |d| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(d.id);
        try s.objectField("name");
        try s.write(d.name);
        try s.objectField("bytes");
        try s.write(d.bytes);
        try s.objectField("created");
        try s.write(d.created);
        try s.objectField("content");
        try s.write(d.content);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn actionCreate(obj: std.json.Value, out: *lib.Out) !void {
    const title = lib.optStr(obj, "title") orelse return lib.fail(out, "create needs {\"title\": \"...\"}");
    if (title.len == 0 or title.len > 200) return lib.fail(out, "title required (1-200)");
    const description = lib.optStr(obj, "description") orelse "";
    if (description.len > 1000) return lib.fail(out, "description too long");
    const id = newId();
    const t = nowSec();
    saveCollection(.{ .id = id, .title = title, .description = description, .created = t, .updated = t }) catch
        return lib.fail(out, "create failed");
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("id");
    try s.write(id);
    try s.objectField("title");
    try s.write(title);
    try s.endObject();
    lib.commit(out, &w);
}

fn actionDelete(obj: std.json.Value, out: *lib.Out) !void {
    const id = lib.optStr(obj, "id") orelse return lib.fail(out, "delete needs {\"id\": \"...\"}");
    if (!isSlug(id)) return lib.fail(out, "bad collection id");
    lib.fsDelete(colPath(id)) catch return lib.fail(out, "no such collection");
    lib.fsDelete(chunksPath(id)) catch {};
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.endObject();
    lib.commit(out, &w);
}

fn actionAddDoc(obj: std.json.Value, out: *lib.Out) !void {
    const col_id = lib.optStr(obj, "collection_id") orelse return lib.fail(out, "add_doc needs collection_id");
    const name = lib.optStr(obj, "name") orelse return lib.fail(out, "add_doc needs name");
    const content = lib.optStr(obj, "content") orelse return lib.fail(out, "add_doc needs content");
    if (!isSlug(col_id)) return lib.fail(out, "bad collection id");
    if (name.len == 0 or name.len > 200) return lib.fail(out, "name required (1-200)");
    if (content.len == 0 or content.len > 500_000) return lib.fail(out, "content required, max 500KB");

    var col = loadCollection(col_id) orelse return lib.fail(out, "no such collection");
    const doc_id = newId();
    const doc = StoredDoc{ .id = doc_id, .name = name, .content = content, .bytes = content.len, .created = nowSec() };

    var docs: std.ArrayList(StoredDoc) = .empty;
    docs.appendSlice(lib.alloc, col.docs) catch return lib.fail(out, "alloc");
    docs.append(lib.alloc, doc) catch return lib.fail(out, "alloc");
    col.docs = docs.items;
    col.updated = nowSec();
    saveCollection(col) catch return lib.fail(out, "save failed");

    deriveChunks(col.id, doc) catch {};

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("id");
    try s.write(doc_id);
    try s.endObject();
    lib.commit(out, &w);
}

fn actionDeleteDoc(obj: std.json.Value, out: *lib.Out) !void {
    const col_id = lib.optStr(obj, "collection_id") orelse return lib.fail(out, "delete_doc needs collection_id");
    const doc_id = lib.optStr(obj, "doc_id") orelse return lib.fail(out, "delete_doc needs doc_id");
    if (!isSlug(col_id)) return lib.fail(out, "bad collection id");

    var col = loadCollection(col_id) orelse return lib.fail(out, "no such collection");
    var docs: std.ArrayList(StoredDoc) = .empty;
    var found = false;
    for (col.docs) |d| {
        if (std.mem.eql(u8, d.id, doc_id)) {
            found = true;
        } else {
            docs.append(lib.alloc, d) catch continue;
        }
    }
    if (!found) return lib.fail(out, "not found");
    col.docs = docs.items;
    col.updated = nowSec();
    saveCollection(col) catch return lib.fail(out, "save failed");

    invalidateChunks(col.id, doc_id) catch {};

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.endObject();
    lib.commit(out, &w);
}

fn actionSearch(obj: std.json.Value, out: *lib.Out) !void {
    const query = lib.optStr(obj, "query") orelse return lib.fail(out, "search needs {\"query\": \"...\"}");
    if (query.len == 0) return lib.fail(out, "query must not be empty");
    const max_hits: usize = 20;

    var filter_ids: std.ArrayList([]const u8) = .empty;
    if (obj.object.get("collections")) |v| {
        if (v == .array) for (v.array.items) |it| {
            if (it == .string) filter_ids.append(lib.alloc, it.string) catch continue;
        };
    }

    const q_lower = lib.alloc.alloc(u8, query.len) catch return lib.fail(out, "alloc");
    for (query, 0..) |c, i| q_lower[i] = std.ascii.toLower(c);

    var hits: std.ArrayList(SearchHit) = .empty;

    const listing = lib.fsList(store_dir) catch {
        return writeSearchResult(out, &hits, query);
    };
    const entries = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, listing, .{}) catch
        return writeSearchResult(out, &hits, query);
    if (entries != .array) return writeSearchResult(out, &hits, query);

    for (entries.array.items) |item| {
        if (item != .string) continue;
        const name = item.string;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (std.mem.endsWith(u8, name, ".chunks.json")) continue;
        const col_id = name[0 .. name.len - ".json".len];
        if (filter_ids.items.len > 0) {
            var keep = false;
            for (filter_ids.items) |fid| if (std.mem.eql(u8, fid, col_id)) {
                keep = true;
                break;
            };
            if (!keep) continue;
        }
        const col = loadCollection(col_id) orelse continue;
        for (col.docs) |doc| {
            const lower_buf = lib.alloc.alloc(u8, doc.content.len) catch continue;
            for (doc.content, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
            if (std.mem.find(u8, lower_buf, q_lower)) |pos| {
                const start = if (pos > 120) pos - 120 else 0;
                const end = @min(doc.content.len, pos + q_lower.len + 120);
                hits.append(lib.alloc, .{
                    .col_id = col.id,
                    .col_title = col.title,
                    .doc_id = doc.id,
                    .doc_name = doc.name,
                    .snippet = doc.content[start..end],
                }) catch continue;
                if (hits.items.len >= max_hits) return writeSearchResult(out, &hits, query);
            }
        }
    }
    return writeSearchResult(out, &hits, query);
}

fn writeSearchResult(out: *lib.Out, hits: *std.ArrayList(SearchHit), query: []const u8) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("query");
    try s.write(query);
    try s.objectField("hits");
    try s.beginArray();
    for (hits.items) |h| {
        try s.beginObject();
        try s.objectField("collection_id");
        try s.write(h.col_id);
        try s.objectField("collection_title");
        try s.write(h.col_title);
        try s.objectField("doc_id");
        try s.write(h.doc_id);
        try s.objectField("doc_name");
        try s.write(h.doc_name);
        try s.objectField("snippet");
        try s.write(h.snippet);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

// -------------------------------------------------------------- chunking ---

fn deriveChunks(col_id: []const u8, doc: StoredDoc) !void {
    const path = chunksPath(col_id);
    var all_chunks: std.ArrayList(std.json.Value) = .empty;
    if (lib.fsRead(path)) |raw| {
        if (std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{})) |v| {
            if (v == .array) for (v.array.items) |item| try all_chunks.append(lib.alloc, item);
        } else |_| {}
    } else |_| {}

    var filtered: std.ArrayList(std.json.Value) = .empty;
    for (all_chunks.items) |item| {
        if (item != .object) continue;
        const did = if (item.object.get("doc_id")) |vv| (if (vv == .string) vv.string else "") else "";
        if (!std.mem.eql(u8, did, doc.id)) try filtered.append(lib.alloc, item);
    }

    const chunks = chunkMarkdown(doc.id, doc.content, 800, 120);
    for (chunks) |ch| {
        var obj: std.json.ObjectMap = .empty;
        const cid = std.fmt.allocPrint(lib.alloc, "{s}:{d}:{s}", .{ ch.doc_id, ch.idx, ch.hash_hex[0..8] }) catch continue;
        obj.put(lib.alloc, "chunk_id", .{ .string = cid }) catch continue;
        obj.put(lib.alloc, "doc_id", .{ .string = ch.doc_id }) catch continue;
        obj.put(lib.alloc, "idx", .{ .integer = @intCast(ch.idx) }) catch continue;
        obj.put(lib.alloc, "text", .{ .string = ch.text }) catch continue;
        obj.put(lib.alloc, "hash", .{ .string = ch.hash_hex }) catch continue;
        filtered.append(lib.alloc, .{ .object = obj }) catch continue;
    }

    var buf: std.Io.Writer.Allocating = .init(lib.alloc);
    defer buf.deinit();
    std.json.Stringify.value(.{ .array = filtered.toOwnedSlice(lib.alloc) catch &.{} }, .{}, &buf.writer) catch return;
    lib.fsWrite(path, buf.written()) catch {};
}

fn invalidateChunks(col_id: []const u8, doc_id: []const u8) !void {
    const path = chunksPath(col_id);
    const raw = lib.fsRead(path) catch return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return;
    if (parsed != .array) return;
    var kept: std.ArrayList(std.json.Value) = .empty;
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const did = if (item.object.get("doc_id")) |vv| (if (vv == .string) vv.string else "") else "";
        if (!std.mem.eql(u8, did, doc_id)) kept.append(lib.alloc, item) catch continue;
    }
    var buf: std.Io.Writer.Allocating = .init(lib.alloc);
    defer buf.deinit();
    std.json.Stringify.value(.{ .array = kept.toOwnedSlice(lib.alloc) catch &.{} }, .{}, &buf.writer) catch return;
    lib.fsWrite(path, buf.written()) catch {};
}

const SearchHit = struct {
    col_id: []const u8,
    col_title: []const u8,
    doc_id: []const u8,
    doc_name: []const u8,
    snippet: []const u8,
};

const ChunkResult = struct {
    doc_id: []const u8,
    idx: usize,
    text: []const u8,
    hash_hex: []const u8,
};

fn chunkMarkdown(doc_id: []const u8, content: []const u8, size: usize, overlap: usize) []ChunkResult {
    const eff_overlap = @min(overlap, size - 1);
    var out: std.ArrayList(ChunkResult) = .empty;

    var sections: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        const is_heading = content[i] == '#' and (i == 0 or content[i - 1] == '\n');
        const is_sep = i + 2 < content.len and content[i] == '\n' and content[i + 1] == '\n' and content[i + 2] == '\n';
        if (is_heading and i != start) {
            sections.append(lib.alloc, content[start..i]) catch {};
            start = i;
        } else if (is_sep and i != start) {
            sections.append(lib.alloc, content[start..i]) catch {};
            start = i + 1;
        }
        i += 1;
    }
    if (start < content.len) sections.append(lib.alloc, content[start..]) catch {};
    if (sections.items.len == 0) sections.append(lib.alloc, content) catch {};

    var idx: usize = 0;
    for (sections.items) |sec| {
        var off: usize = 0;
        const s = std.mem.trim(u8, sec, " \t\r\n");
        if (s.len == 0) continue;
        while (off < s.len) {
            const end = @min(s.len, off + size);
            var slice = s[off..end];
            slice = std.mem.trim(u8, slice, " \t\r\n");
            if (slice.len > 0) {
                const h = lib.hash(slice) catch "";
                const owned = lib.alloc.dupe(u8, slice) catch "";
                out.append(lib.alloc, .{ .doc_id = doc_id, .idx = idx, .text = owned, .hash_hex = h }) catch {};
                idx += 1;
            }
            if (end >= s.len) break;
            off = end - eff_overlap;
        }
    }
    return out.toOwnedSlice(lib.alloc) catch &.{};
}
