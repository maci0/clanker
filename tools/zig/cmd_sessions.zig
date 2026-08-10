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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    _ = parsed;

    const raw = lib.fsList("state/sessions") catch |err| return errJson(out, @errorName(err));
    const names = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, raw, .{});

    var metas: std.ArrayList(SessionMeta) = .empty;
    defer metas.deinit(std.heap.wasm_allocator);
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            const fname = item.string;
            if (!std.mem.endsWith(u8, fname, ".json")) continue;
            const id = fname[0 .. fname.len - 5];
            const path = try std.fmt.allocPrint(std.heap.wasm_allocator, "state/sessions/{s}", .{fname});
            defer std.heap.wasm_allocator.free(path);
            const content = lib.fsRead(path) catch continue;
            const meta = std.json.parseFromSliceLeaky(SessionMeta, std.heap.wasm_allocator, content, .{ .ignore_unknown_fields = true }) catch continue;
            try metas.append(std.heap.wasm_allocator, .{
                .id = try std.heap.wasm_allocator.dupe(u8, id),
                .title = try std.heap.wasm_allocator.dupe(u8, meta.title),
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
    defer buf.deinit(std.heap.wasm_allocator);
    for (metas.items) |m| {
        if (buf.items.len > 0) try buf.append(std.heap.wasm_allocator, '\n');
        try buf.appendSlice(std.heap.wasm_allocator, m.id);
        try buf.append(std.heap.wasm_allocator, '\t');
        try buf.appendSlice(std.heap.wasm_allocator, m.title);
        try buf.append(std.heap.wasm_allocator, '\t');
        const ts = try std.fmt.allocPrint(std.heap.wasm_allocator, "{d}", .{m.updated});
        defer std.heap.wasm_allocator.free(ts);
        try buf.appendSlice(std.heap.wasm_allocator, ts);
    }
    if (metas.items.len == 0) try buf.appendSlice(std.heap.wasm_allocator, "(no sessions yet)");

    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(buf.items);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
