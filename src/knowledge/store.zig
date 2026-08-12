//! Knowledge base store — OpenWebUI parity single-user. Collections of documents, stored as state/knowledge/<id>.json. Keyword search only (no embeddings), suitable for single-user local.

const std = @import("std");
const json = std.json;
const atomic_write = @import("../util/atomic_write.zig");

pub const store_dir = "state/knowledge";

pub const Doc = struct {
    id: []const u8,
    name: []const u8,
    content: []const u8,
    bytes: usize = 0,
    created: i64 = 0,
};

pub const Collection = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    docs: []const Doc = &.{},
};

const StoredDoc = struct {
    id: []const u8,
    name: []const u8,
    content: []const u8,
    bytes: usize = 0,
    created: i64 = 0,
};

const StoredCollection = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    docs: []const StoredDoc = &.{},
};

pub const CollectionMeta = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    doc_count: usize = 0,
    bytes: usize = 0,
};

fn nowSec(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
}

fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}
pub fn validCollectionId(id: []const u8) bool {
    return isSlug(id);
}

fn newId(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var seed: u64 = @as(u64, @intCast(nowSec(io))) *% 0x9e3779b97f4a7c15;
    seed +%= @as(u64, @intCast(std.c.getpid()));
    var prng = std.Random.DefaultPrng.init(seed);
    var buf: [16]u8 = undefined;
    prng.random().bytes(&buf);
    const hex = std.fmt.bytesToHex(buf, .lower);
    return std.fmt.allocPrint(arena, "kb-{s}", .{hex[0..12]});
}

pub fn saveCollection(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, col: Collection) !void {
    _ = gpa;
    try base.createDirPath(io, store_dir);
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var s = json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
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
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_dir, col.id });
    try atomic_write.writeFile(io, base, path, out.written());
}

pub fn loadCollection(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) !Collection {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_dir, id });
    const raw = try base.readFileAlloc(io, path, arena, .limited(4 << 20));
    const stored = try json.parseFromSliceLeaky(StoredCollection, arena, raw, .{ .ignore_unknown_fields = true });
    var docs: std.ArrayList(Doc) = .empty;
    for (stored.docs) |sd| try docs.append(arena, .{ .id = sd.id, .name = sd.name, .content = sd.content, .bytes = sd.bytes, .created = sd.created });
    return .{ .id = stored.id, .title = stored.title, .description = stored.description, .created = stored.created, .updated = stored.updated, .docs = try docs.toOwnedSlice(arena) };
}

pub fn deleteCollection(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_dir, id });
    try base.deleteFile(io, path);
}

pub fn listCollections(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) ![]CollectionMeta {
    var out: std.ArrayList(CollectionMeta) = .empty;
    var dir = base.openDir(io, store_dir, .{ .iterate = true }) catch return out.toOwnedSlice(arena);
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ store_dir, entry.name }) catch continue;
        const raw = base.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
        const stored = json.parseFromSliceLeaky(StoredCollection, arena, raw, .{ .ignore_unknown_fields = true }) catch continue;
        var bytes: usize = 0;
        for (stored.docs) |d| bytes += d.content.len;
        out.append(arena, .{ .id = stored.id, .title = stored.title, .description = stored.description, .created = stored.created, .updated = stored.updated, .doc_count = stored.docs.len, .bytes = bytes }) catch continue;
    }
    std.mem.sort(CollectionMeta, out.items, {}, struct {
        fn newest(_: void, a: CollectionMeta, b: CollectionMeta) bool {
            return a.updated > b.updated;
        }
    }.newest);
    return out.toOwnedSlice(arena);
}

pub fn createCollection(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, title: []const u8, description: []const u8) !Collection {
    const id = try newId(arena, io);
    const t = nowSec(io);
    const col = Collection{ .id = id, .title = title, .description = description, .created = t, .updated = t, .docs = &.{} };
    try saveCollection(io, std.heap.page_allocator, arena, base, col);
    return col;
}

pub fn addDoc(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, col_id: []const u8, name: []const u8, content: []const u8) !Doc {
    var col = try loadCollection(io, arena, base, col_id);
    const doc_id = try newId(arena, io);
    const doc = Doc{ .id = doc_id, .name = name, .content = content, .bytes = content.len, .created = nowSec(io) };
    var docs: std.ArrayList(Doc) = .empty;
    try docs.appendSlice(arena, col.docs);
    try docs.append(arena, doc);
    col.docs = docs.items;
    col.updated = nowSec(io);
    try saveCollection(io, gpa, arena, base, col);
    // Derive chunk cache for memory layer (best-effort, stays under 2 MiB per doc via 800/120)
    deriveChunksForDoc(arena, io, base, col.id, doc) catch {};
    return doc;
}

pub fn deleteDoc(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, col_id: []const u8, doc_id: []const u8) !void {
    var col = try loadCollection(io, arena, base, col_id);
    var docs: std.ArrayList(Doc) = .empty;
    var found = false;
    for (col.docs) |d| if (std.mem.eql(u8, d.id, doc_id)) {
        found = true;
    } else try docs.append(arena, d);
    if (!found) return error.FileNotFound;
    col.docs = try docs.toOwnedSlice(arena);
    col.updated = nowSec(io);
    try saveCollection(io, gpa, arena, base, col);
    // Best-effort: invalidate chunk cache for deleted doc (delete its chunk file slice)
    invalidateChunksForDoc(arena, io, base, col.id, doc_id) catch {};
}

fn deriveChunksForDoc(arena: std.mem.Allocator, io: std.Io, base: std.Io.Dir, col_id: []const u8, doc: Doc) !void {
    const mem_chunk = @import("../memory/chunk.zig");
    const mem_store_path = try std.fmt.allocPrint(arena, "{s}/{s}.chunks.json", .{ store_dir, col_id });
    // Read existing chunk file if any
    const existing_raw = base.readFileAlloc(io, mem_store_path, arena, .limited(4 << 20)) catch null;
    var all_chunks: std.ArrayList(json.Value) = .empty;
    if (existing_raw) |raw| {
        if (std.json.parseFromSliceLeaky(json.Value, arena, raw, .{}) catch null) |v| {
            if (v == .array) for (v.array.items) |item| try all_chunks.append(arena, item);
        }
    }
    // Remove stale chunks for this doc
    var filtered: std.ArrayList(json.Value) = .empty;
    for (all_chunks.items) |item| {
        if (item != .object) continue;
        const did = if (item.object.get("doc_id")) |vv| (if (vv == .string) vv.string else "") else "";
        if (!std.mem.eql(u8, did, doc.id)) try filtered.append(arena, item);
    }
    const new_chunks = try mem_chunk.chunkText(arena, doc.id, doc.content, 800, 120, .markdown);
    for (new_chunks) |ch| {
        var obj: json.ObjectMap = .empty;
        // Use stored doc id chunk hash as stable chunk_id
        const cid = try std.fmt.allocPrint(arena, "{s}:{d}:{s}", .{ ch.doc_id, ch.idx, ch.hash[0..8] });
        try obj.put(arena, "chunk_id", .{ .string = cid });
        try obj.put(arena, "doc_id", .{ .string = ch.doc_id });
        try obj.put(arena, "idx", .{ .integer = @as(i64, @intCast(ch.idx)) });
        try obj.put(arena, "text", .{ .string = ch.text });
        try obj.put(arena, "hash", .{ .string = ch.hash });
        try filtered.append(arena, .{ .object = obj });
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try std.json.Stringify.value(.{ .array = try filtered.toOwnedSlice(arena) }, .{}, &out.writer);
    try atomic_write.writeFile(io, base, mem_store_path, out.written());
}

fn invalidateChunksForDoc(arena: std.mem.Allocator, io: std.Io, base: std.Io.Dir, col_id: []const u8, doc_id: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.chunks.json", .{ store_dir, col_id });
    const raw = base.readFileAlloc(io, path, arena, .limited(4 << 20)) catch return;
    const parsed = try std.json.parseFromSliceLeaky(json.Value, arena, raw, .{});
    if (parsed != .array) return;
    var kept: std.ArrayList(json.Value) = .empty;
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const did = if (item.object.get("doc_id")) |vv| (if (vv == .string) vv.string else "") else "";
        if (!std.mem.eql(u8, did, doc_id)) try kept.append(arena, item);
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try std.json.Stringify.value(.{ .array = try kept.toOwnedSlice(arena) }, .{}, &out.writer);
    try atomic_write.writeFile(io, base, path, out.written());
}

pub const SearchHit = struct {
    collection_id: []const u8,
    collection_title: []const u8,
    doc_id: []const u8,
    doc_name: []const u8,
    snippet: []const u8,
};

pub fn search(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, query: []const u8, collection_ids: []const []const u8, max_hits: usize) ![]SearchHit {
    if (query.len == 0) return &.{};
    var out: std.ArrayList(SearchHit) = .empty;
    const q_lower = try arena.alloc(u8, query.len);
    for (query, 0..) |c, i| q_lower[i] = std.ascii.toLower(c);
    var targets: std.ArrayList(Collection) = .empty;
    if (collection_ids.len == 0) {
        const metas = try listCollections(io, arena, base);
        for (metas) |m| {
            const col = loadCollection(io, arena, base, m.id) catch continue;
            try targets.append(arena, col);
        }
    } else for (collection_ids) |cid| {
        const col = loadCollection(io, arena, base, cid) catch continue;
        try targets.append(arena, col);
    }
    for (targets.items) |col| for (col.docs) |doc| {
        const lower_buf = try arena.alloc(u8, doc.content.len);
        for (doc.content, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        if (std.mem.indexOf(u8, lower_buf, q_lower)) |pos| {
            const start = if (pos > 120) pos - 120 else 0;
            const end = @min(doc.content.len, pos + q_lower.len + 120);
            try out.append(arena, .{ .collection_id = col.id, .collection_title = col.title, .doc_id = doc.id, .doc_name = doc.name, .snippet = doc.content[start..end] });
            if (out.items.len >= max_hits) return out.toOwnedSlice(arena);
        }
    };
    return out.toOwnedSlice(arena);
}

test "knowledge round trip" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const col = try createCollection(io, arena, tmp.dir, "My KB", "test");
    try std.testing.expect(validCollectionId(col.id));
    _ = try addDoc(io, std.testing.allocator, arena, tmp.dir, col.id, "hello.txt", "hello world content");
    const loaded = try loadCollection(io, arena, tmp.dir, col.id);
    try std.testing.expectEqual(@as(usize, 1), loaded.docs.len);
    try std.testing.expectEqualStrings("hello world content", loaded.docs[0].content);
    const metas = try listCollections(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), metas.len);
    const hits = try search(io, arena, tmp.dir, "world", &.{}, 10);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("hello.txt", hits[0].doc_name);
    try deleteDoc(io, std.testing.allocator, arena, tmp.dir, col.id, loaded.docs[0].id);
    const after = try loadCollection(io, arena, tmp.dir, col.id);
    try std.testing.expectEqual(@as(usize, 0), after.docs.len);
    try deleteCollection(io, arena, tmp.dir, col.id);
    try std.testing.expectError(error.FileNotFound, loadCollection(io, arena, tmp.dir, col.id));
}

test "validCollectionId" {
    try std.testing.expect(validCollectionId("kb-abc123"));
    try std.testing.expect(!validCollectionId("../../etc"));
    try std.testing.expect(!validCollectionId(""));
}
