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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    var want_all = false;
    if (parsed == .object) {
        if (parsed.object.get("list")) |l| {
            if (l == .string and std.mem.eql(u8, l.string, "all")) want_all = true;
        }
    }
    const md = lib.fsRead("docs/ROADMAP.md") catch return lib.fail(out, "ROADMAP.md unreadable");

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(lib.alloc);
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "- [ ]")) {
            if (text.items.len > 0) try text.append(lib.alloc, '\n');
            try text.appendSlice(lib.alloc, trimmed);
        } else if (want_all and std.mem.startsWith(u8, trimmed, "- [x]")) {
            if (text.items.len > 0) try text.append(lib.alloc, '\n');
            try text.appendSlice(lib.alloc, trimmed);
        }
    }
    if (text.items.len == 0) try text.appendSlice(lib.alloc, "(no planned items)");

    return lib.okText(out, text.items);
}
