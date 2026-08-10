//! roadmap: read the project roadmap (docs/ROADMAP.md), list the planned
//! (unchecked) items so tasks can pick the next one to implement.
//! Input:  {"list": "planned" | "all"}
//! Output: {"ok": true, "text": "<roadmap items>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    var want_all = false;
    if (parsed == .object) {
        if (parsed.object.get("list")) |l| {
            if (l == .string and std.mem.eql(u8, l.string, "all")) want_all = true;
        }
    }
    const md = lib.fsRead("docs/ROADMAP.md") catch return errJson(out, "ROADMAP.md unreadable");

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.heap.wasm_allocator);
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "- [ ]")) {
            if (text.items.len > 0) try text.append(std.heap.wasm_allocator, '\n');
            try text.appendSlice(std.heap.wasm_allocator, trimmed);
        } else if (want_all and std.mem.startsWith(u8, trimmed, "- [x]")) {
            if (text.items.len > 0) try text.append(std.heap.wasm_allocator, '\n');
            try text.appendSlice(std.heap.wasm_allocator, trimmed);
        }
    }
    if (text.items.len == 0) try text.appendSlice(std.heap.wasm_allocator, "(no planned items)");

    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(text.items);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
