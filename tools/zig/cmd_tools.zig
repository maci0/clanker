//! cmd_tools: list registered tools (tool names from tools/manifests/*.tool.json).
//! Input:  {"args": "..."}
//! Output: {"ok": true, "text": "<tool names, one per line>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    _ = parsed;

    const raw = lib.fsList("tools/manifests") catch |err| return errJson(out, @errorName(err));
    const names = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, raw, .{});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.wasm_allocator);
    var count: usize = 0;
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            const name = item.string;
            // strip the .tool.json suffix
            if (!std.mem.endsWith(u8, name, ".tool.json")) continue;
            const base = name[0 .. name.len - ".tool.json".len];
            count += 1;
            try buf.appendSlice(std.heap.wasm_allocator, base);
            try buf.append(std.heap.wasm_allocator, '\n');
        }
    }
    const summary = try std.fmt.allocPrint(std.heap.wasm_allocator, "{d} tool(s) registered", .{count});
    try buf.appendSlice(std.heap.wasm_allocator, summary);

    var rbuf: [8192]u8 = undefined;
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
