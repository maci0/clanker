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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const note = switch (obj.get("note") orelse return errJson(out, "missing note")) {
        .string => |s| s,
        else => return errJson(out, "note must be a string"),
    };

    const path = "state/learnings.md";
    var existing: []const u8 = "";
    if (lib.fsRead(path)) |cur| {
        existing = cur;
    } else |_| {}

    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(std.heap.wasm_allocator);
    try new_content.appendSlice(std.heap.wasm_allocator, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') {
        try new_content.append(std.heap.wasm_allocator, '\n');
    }
    try new_content.appendSlice(std.heap.wasm_allocator, "- ");
    try new_content.appendSlice(std.heap.wasm_allocator, note);
    try new_content.append(std.heap.wasm_allocator, '\n');

    lib.fsWrite(path, new_content.items) catch |err| {
        return errJson(out, @errorName(err));
    };

    try out.writeAll("{\"ok\":true}");
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
