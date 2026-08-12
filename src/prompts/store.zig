//! Prompts store — OpenWebUI parity single-user (state/prompts.json).

const std = @import("std");
const json = std.json;
const atomic_write = @import("../util/atomic_write.zig");

const store_path = "state/prompts.json";

pub const Prompt = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    created: i64 = 0,
    updated: i64 = 0,
};

const StoredPrompt = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    created: i64 = 0,
    updated: i64 = 0,
};

fn nowSec(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
}

fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}
pub fn validPromptId(id: []const u8) bool {
    return isSlug(id);
}

fn newId(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var seed: u64 = @as(u64, @intCast(nowSec(io))) *% 0x9e3779b97f4a7c15;
    seed +%= @as(u64, @intCast(std.c.getpid()));
    var prng = std.Random.DefaultPrng.init(seed);
    var buf: [16]u8 = undefined;
    prng.random().bytes(&buf);
    const hex = std.fmt.bytesToHex(buf, .lower);
    return std.fmt.allocPrint(arena, "pr-{s}", .{hex[0..12]});
}

pub fn loadAll(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) ![]Prompt {
    const raw = base.readFileAlloc(io, store_path, arena, .limited(1 << 20)) catch return try arena.alloc(Prompt, 0);
    const arr = json.parseFromSliceLeaky([]StoredPrompt, arena, raw, .{ .ignore_unknown_fields = true }) catch return try arena.alloc(Prompt, 0);
    var out: std.ArrayList(Prompt) = .empty;
    for (arr) |sp| try out.append(arena, .{ .id = sp.id, .title = sp.title, .content = sp.content, .created = sp.created, .updated = sp.updated });
    return out.toOwnedSlice(arena);
}

pub fn saveAll(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, prompts: []const Prompt) !void {
    try base.createDirPath(io, "state");
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var s = json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginArray();
    for (prompts) |p| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(p.id);
        try s.objectField("title");
        try s.write(p.title);
        try s.objectField("content");
        try s.write(p.content);
        try s.objectField("created");
        try s.write(p.created);
        try s.objectField("updated");
        try s.write(p.updated);
        try s.endObject();
    }
    try s.endArray();
    try atomic_write.writeFile(io, base, store_path, out.written());
}

pub fn create(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, title: []const u8, content: []const u8) !Prompt {
    const all = try loadAll(io, arena, base);
    const p = Prompt{ .id = try newId(arena, io), .title = title, .content = content, .created = nowSec(io), .updated = nowSec(io) };
    var list: std.ArrayList(Prompt) = .empty;
    try list.appendSlice(arena, all);
    try list.append(arena, p);
    try saveAll(io, arena, base, list.items);
    return p;
}

pub fn update(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8, title: ?[]const u8, content: ?[]const u8) !Prompt {
    const all = try loadAll(io, arena, base);
    for (all) |*p| if (std.mem.eql(u8, p.id, id)) {
        if (title) |t| p.title = t;
        if (content) |c| p.content = c;
        p.updated = nowSec(io);
        try saveAll(io, arena, base, all);
        return p.*;
    };
    return error.FileNotFound;
}

pub fn remove(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) !void {
    const all = try loadAll(io, arena, base);
    var out: std.ArrayList(Prompt) = .empty;
    var found = false;
    for (all) |p| if (std.mem.eql(u8, p.id, id)) {
        found = true;
    } else try out.append(arena, p);
    if (!found) return error.FileNotFound;
    try saveAll(io, arena, base, out.items);
}

test "prompts round trip" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try create(io, arena, tmp.dir, "hello", "content here");
    try std.testing.expect(validPromptId(p.id));
    var all = try loadAll(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), all.len);
    _ = try update(io, arena, tmp.dir, p.id, "hi2", null);
    all = try loadAll(io, arena, tmp.dir);
    try std.testing.expectEqualStrings("hi2", all[0].title);
    try remove(io, arena, tmp.dir, p.id);
    all = try loadAll(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 0), all.len);
}
