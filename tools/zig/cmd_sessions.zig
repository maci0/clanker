//! cmd_sessions: list saved sessions (state/sessions/*.json).
//! Input:  {"args": "..."}
//! Output: {"ok": true, "text": "<id>\t<title>\t<updated>  per line, newest last>"}

const std = @import("std");
const lib = @import("lib.zig");

const SessionMeta = struct {
    id: []const u8,
    title: []const u8 = "",
    updated: i64 = 0,
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    _ = parsed;

    const raw = lib.fsList("state/sessions") catch |err| return lib.fail(out, @errorName(err));
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
            const content = lib.fsRead(path) catch continue;
            const meta = std.json.parseFromSliceLeaky(SessionMeta, lib.alloc, content, .{ .ignore_unknown_fields = true }) catch continue;
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
    for (metas.items) |m| {
        if (buf.items.len > 0) try buf.append(lib.alloc, '\n');
        try buf.appendSlice(lib.alloc, m.id);
        try buf.append(lib.alloc, '\t');
        try buf.appendSlice(lib.alloc, m.title);
        try buf.append(lib.alloc, '\t');
        const ts = try std.fmt.allocPrint(lib.alloc, "{d}", .{m.updated});
        defer lib.alloc.free(ts);
        try buf.appendSlice(lib.alloc, ts);
    }
    if (metas.items.len == 0) try buf.appendSlice(lib.alloc, "(no sessions yet)");

    return lib.okText(out, buf.items);
}
