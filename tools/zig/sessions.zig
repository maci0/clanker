//! sessions: list saved conversations (state/sessions/*.json).
//! Input:  {"args": "..."}
//! Output: {"ok": true, "text": "<id>\t<title>\t<updated>  per line, newest last>"}

const std = @import("std");
const lib = @import("lib.zig");
const utf8 = @import("utf8");

const SessionMeta = struct {
    id: []const u8,
    title: []const u8 = "",
    updated: i64 = 0,
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn closeJsonBeforeField(raw: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ",\"{s}\":", .{field}) catch return null;
    const at = std.mem.find(u8, raw, needle) orelse return null;
    const prefix = std.mem.trimEnd(u8, raw[0..at], " \t\r\n");
    if (prefix.len == 0 or prefix[0] != '{') return null;
    return std.fmt.allocPrint(lib.alloc, "{s}}}", .{prefix}) catch null;
}

fn appendAge(buf: *std.ArrayList(u8), delta_s: i64) !void {
    if (delta_s < 0) {
        try buf.appendSlice(lib.alloc, "just now");
        return;
    }
    const d: u64 = @intCast(delta_s);
    if (d < 60) {
        try buf.appendSlice(lib.alloc, "just now");
    } else if (d < 3600) {
        const m = d / 60;
        const s = try std.fmt.allocPrint(lib.alloc, "{d}m ago", .{m});
        try buf.appendSlice(lib.alloc, s);
    } else if (d < 86400) {
        const h = d / 3600;
        const s = try std.fmt.allocPrint(lib.alloc, "{d}h ago", .{h});
        try buf.appendSlice(lib.alloc, s);
    } else {
        const days = d / 86400;
        const s = try std.fmt.allocPrint(lib.alloc, "{d}d ago", .{days});
        try buf.appendSlice(lib.alloc, s);
    }
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    _ = parsed;

    // state/ is gitignored and every directory under it is created lazily on
    // first write, so a checkout that has never saved a session has no
    // state/sessions at all. That is zero sessions, not a failure — fall
    // through to the empty-list message below.
    const raw: []const u8 = lib.fsList("state/sessions") catch |err| switch (err) {
        error.NotFound => "[]",
        else => return lib.failErr(out, err, "listing state/sessions"),
    };
    const names = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{});

    var metas: std.ArrayList(SessionMeta) = .empty;
    defer metas.deinit(lib.alloc);
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            const fname = item.string;
            if (!std.mem.endsWith(u8, fname, ".json")) continue;
            const id = fname[0 .. fname.len - 5];
            const path = try std.fmt.allocPrint(lib.alloc, "state/sessions/{s}", .{fname});
            defer lib.alloc.free(path);
            // Title/updated sit in front of the transcript. A full ck_fs_read
            // of every file both costs up to 16 MiB apiece and burns the 1 MiB
            // host arena, so later sessions vanished from the list.
            const content = lib.fsReadRange(path, 0, 4096) catch continue;
            const trimmed = std.mem.trimEnd(u8, content, " \t\r\n");
            const src = if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '}')
                trimmed
            else
                closeJsonBeforeField(content, "messages") orelse content;
            const meta = std.json.parseFromSliceLeaky(SessionMeta, lib.alloc, src, .{ .ignore_unknown_fields = true }) catch continue;
            try metas.append(lib.alloc, .{
                .id = try lib.alloc.dupe(u8, id),
                .title = try lib.alloc.dupe(u8, meta.title),
                .updated = meta.updated,
            });
        }
    }
    std.mem.sort(SessionMeta, metas.items, {}, struct {
        fn lt(_: void, a: SessionMeta, b: SessionMeta) bool {
            return a.updated < b.updated;
        }
    }.lt);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(lib.alloc);
    if (metas.items.len == 0) {
        try buf.appendSlice(lib.alloc, "No saved conversations yet. Start one with `clanker repl` or `clanker run \"<task>\"`.");
        return lib.okText(out, buf.items);
    }

    const now_s: i64 = @trunc(lib.nowSeconds());

    var id_w: usize = 0;
    for (metas.items) |m| id_w = @max(id_w, m.id.len);

    for (metas.items) |m| {
        if (buf.items.len > 0) try buf.append(lib.alloc, '\n');
        try buf.appendSlice(lib.alloc, m.id);
        var col: usize = m.id.len;
        while (col < id_w + 2) : (col += 1) try buf.append(lib.alloc, ' ');
        const first_nl = std.mem.findScalar(u8, m.title, '\n') orelse m.title.len;
        const one_line = m.title[0..first_nl];
        const title = utf8.cap(one_line, 60);
        try buf.appendSlice(lib.alloc, title);
        if (one_line.len > 60) try buf.appendSlice(lib.alloc, "...");
        if (m.updated > 0) {
            try buf.appendSlice(lib.alloc, "  ");
            try appendAge(&buf, now_s - m.updated);
        }
    }

    return lib.okText(out, buf.items);
}
