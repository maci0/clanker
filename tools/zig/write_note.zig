//! write_note: append a line to the persistent learnings file
//! (state/learnings.md via sandbox fs prefix "state/").
//! Input:  {"note": "..."}
//! Output: {"ok": true}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const note = switch (obj.get("note") orelse return lib.fail(out, "missing note")) {
        .string => |s| s,
        else => return lib.fail(out, "note must be a string"),
    };

    const path = "state/learnings.md";
    var existing: []const u8 = "";
    if (lib.fsRead(path)) |cur| {
        existing = cur;
    } else |_| {}

    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(lib.alloc);
    try new_content.appendSlice(lib.alloc, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') {
        try new_content.append(lib.alloc, '\n');
    }
    try new_content.appendSlice(lib.alloc, "- ");
    try new_content.appendSlice(lib.alloc, note);
    try new_content.append(lib.alloc, '\n');

    lib.fsWrite(path, new_content.items) catch |err| {
        return lib.fail(out, @errorName(err));
    };

    try out.writeAll("{\"ok\":true}");
}
