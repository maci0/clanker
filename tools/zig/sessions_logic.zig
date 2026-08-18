//! Pure session-listing helpers for tools/zig/sessions.zig.
//! Host-tested; the guest imports this rather than reimplementing the header
//! parse or the HTTP JSON shape. `GET /api/sessions` relays the guest's
//! `format=json` answer, so the picker and the catalog share one listing.

const std = @import("std");
const utf8 = @import("utf8");

pub const Listing = struct {
    id: []const u8,
    title: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    workspace: []const u8 = "",
    archived: bool = false,
    messages: usize = 0,
    bytes: usize = 0,
};

const Header = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    workspace: []const u8 = "",
    archived: bool = false,
    message_count: ?usize = null,
    bytes: ?usize = null,
};

/// Closes a JSON object just before a top-level `,"<field>":` so a prefix
/// that still has the transcript (or a truncated tail) parses as the header
/// fields alone.
pub fn closeJsonBeforeField(arena: std.mem.Allocator, raw: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ",\"{s}\":", .{field}) catch return null;
    const at = std.mem.find(u8, raw, needle) orelse return null;
    const prefix = std.mem.trimEnd(u8, raw[0..at], " \t\r\n");
    if (prefix.len == 0 or prefix[0] != '{') return null;
    return std.fmt.allocPrint(arena, "{s}}}", .{prefix}) catch null;
}

/// Listing fields from the first kilobytes of a session file. Missing
/// `message_count`/`bytes` stay 0 (files written before those counters).
pub fn listingFromPrefix(arena: std.mem.Allocator, prefix: []const u8) ?Listing {
    const src = closeJsonBeforeField(arena, prefix, "messages") orelse blk: {
        const trimmed = std.mem.trimEnd(u8, prefix, " \t\r\n");
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '}') break :blk trimmed;
        return null;
    };
    const h = std.json.parseFromSliceLeaky(Header, arena, src, .{ .ignore_unknown_fields = true }) catch return null;
    if (h.id.len == 0) return null;
    return .{
        .id = h.id,
        .title = h.title,
        .created = h.created,
        .updated = h.updated,
        .workspace = h.workspace,
        .archived = h.archived,
        .messages = h.message_count orelse 0,
        .bytes = h.bytes orelse 0,
    };
}

pub fn sortNewestFirst(items: []Listing) void {
    std.mem.sort(Listing, items, {}, struct {
        fn newer(_: void, a: Listing, b: Listing) bool {
            return a.updated > b.updated;
        }
    }.newer);
}

pub fn sortOldestFirst(items: []Listing) void {
    std.mem.sort(Listing, items, {}, struct {
        fn older(_: void, a: Listing, b: Listing) bool {
            return a.updated < b.updated;
        }
    }.older);
}

/// Same object `sessionListJSON` used to emit, so the web picker keeps its
/// contract when the HTTP handler relays the guest.
pub fn writeJson(w: *std.Io.Writer, items: []const Listing) !void {
    var s = std.json.Stringify{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("sessions");
    try s.beginArray();
    for (items) |m| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(m.id);
        try s.objectField("title");
        try s.write(m.title);
        try s.objectField("created");
        try s.write(m.created);
        try s.objectField("updated");
        try s.write(m.updated);
        try s.objectField("workspace");
        try s.write(m.workspace);
        try s.objectField("archived");
        try s.write(m.archived);
        try s.objectField("messages");
        try s.write(m.messages);
        try s.objectField("bytes");
        try s.write(m.bytes);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

pub fn appendAge(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, delta_s: i64) !void {
    if (delta_s < 60) {
        try buf.appendSlice(alloc, "just now");
        return;
    }
    const d: u64 = @intCast(delta_s);
    var tmp: [32]u8 = undefined;
    const s = if (d < 3600)
        std.fmt.bufPrint(&tmp, "{d}m ago", .{d / 60}) catch unreachable
    else if (d < 86400)
        std.fmt.bufPrint(&tmp, "{d}h ago", .{d / 3600}) catch unreachable
    else
        std.fmt.bufPrint(&tmp, "{d}d ago", .{d / 86400}) catch unreachable;
    try buf.appendSlice(alloc, s);
}

/// One-line catalog listing, newest last. Titles cut on a UTF-8 boundary.
pub fn writeText(alloc: std.mem.Allocator, items: []const Listing, now_s: i64) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var id_w: usize = 0;
    for (items) |m| id_w = @max(id_w, m.id.len);
    for (items) |m| {
        if (buf.items.len > 0) try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, m.id);
        var col: usize = m.id.len;
        while (col < id_w + 2) : (col += 1) try buf.append(alloc, ' ');
        const first_nl = std.mem.findScalar(u8, m.title, '\n') orelse m.title.len;
        const one_line = m.title[0..first_nl];
        const title = utf8.cap(one_line, 60);
        try buf.appendSlice(alloc, title);
        if (one_line.len > 60) try buf.appendSlice(alloc, "...");
        if (m.updated > 0) {
            try buf.appendSlice(alloc, "  ");
            try appendAge(&buf, alloc, now_s - m.updated);
        }
    }
    return buf.toOwnedSlice(alloc);
}

test "listingFromPrefix reads counters in front of messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw =
        \\{"id":"s1","title":"one","created":1,"updated":2,"workspace":"ws","archived":true,"message_count":4,"bytes":13,"messages":[{}
    ;
    const row = listingFromPrefix(arena_state.allocator(), raw).?;
    try std.testing.expectEqualStrings("s1", row.id);
    try std.testing.expectEqualStrings("one", row.title);
    try std.testing.expectEqual(@as(i64, 1), row.created);
    try std.testing.expectEqual(@as(i64, 2), row.updated);
    try std.testing.expectEqualStrings("ws", row.workspace);
    try std.testing.expect(row.archived);
    try std.testing.expectEqual(@as(usize, 4), row.messages);
    try std.testing.expectEqual(@as(usize, 13), row.bytes);
}

test "listingFromPrefix treats missing counters as zero" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw = "{\"id\":\"old\",\"title\":\"t\",\"created\":1,\"updated\":2,\"messages\":[]}";
    const row = listingFromPrefix(arena_state.allocator(), raw).?;
    try std.testing.expectEqualStrings("old", row.id);
    try std.testing.expectEqual(@as(usize, 0), row.messages);
    try std.testing.expectEqual(@as(usize, 0), row.bytes);
    try std.testing.expect(!row.archived);
}

test "listingFromPrefix skips a prefix with no id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(listingFromPrefix(arena, "{\"title\":\"x\",\"messages\":[]}") == null);
    try std.testing.expect(listingFromPrefix(arena, "not json") == null);
}

test "writeJson matches the picker contract" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    const list = [_]Listing{
        .{ .id = "s1", .title = "one", .created = 1, .updated = 2, .messages = 2, .bytes = 13 },
    };
    try writeJson(&out.writer, &list);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const first = parsed.object.get("sessions").?.array.items[0];
    try std.testing.expect(parsed.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 13), first.object.get("bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 2), first.object.get("messages").?.integer);
    try std.testing.expectEqualStrings("s1", first.object.get("id").?.string);
    try std.testing.expect(!first.object.get("archived").?.bool);
}

test "sortNewestFirst puts the latest update first" {
    var items = [_]Listing{
        .{ .id = "old", .updated = 1 },
        .{ .id = "new", .updated = 9 },
        .{ .id = "mid", .updated = 5 },
    };
    sortNewestFirst(&items);
    try std.testing.expectEqualStrings("new", items[0].id);
    try std.testing.expectEqualStrings("mid", items[1].id);
    try std.testing.expectEqualStrings("old", items[2].id);
    sortOldestFirst(&items);
    try std.testing.expectEqualStrings("old", items[0].id);
}

test "writeText columns and age" {
    const list = [_]Listing{
        .{ .id = "a", .title = "hi", .updated = 100 },
        .{ .id = "bb", .title = "there", .updated = 160 },
    };
    const text = try writeText(std.testing.allocator, &list, 160);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "a  ") != null);
    try std.testing.expect(std.mem.find(u8, text, "hi  1m ago") != null);
    try std.testing.expect(std.mem.find(u8, text, "there  just now") != null);
}
