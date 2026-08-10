//! cmd_tools: list registered tools with what each one is for, read from
//! tools/manifests/*.tool.json.
//! Input:  {"args": "..."}
//! Output: {"ok": true, "text": "<name  description, one per line>"}

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

            // A bare list of names says nothing about what any of them do:
            // pull each manifest's own description in, padded into a column.
            const desc = describe(name);
            if (desc.len > 0) {
                const pad = if (base.len < name_col) name_col - base.len else 1;
                try buf.appendNTimes(std.heap.wasm_allocator, ' ', pad);
                // One line per tool: a description with newlines in it would
                // break the column, so only the first line is shown.
                const first = desc[0 .. std.mem.indexOfScalar(u8, desc, '\n') orelse desc.len];
                const clipped = first[0..@min(first.len, desc_max)];
                try buf.appendSlice(std.heap.wasm_allocator, clipped);
                if (clipped.len < first.len) try buf.appendSlice(std.heap.wasm_allocator, "…");
            }
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

/// Column the descriptions start at, and how much of one is shown.
const name_col: usize = 18;
const desc_max: usize = 96;

/// The `description` field of one manifest, or "" when it cannot be read.
fn describe(file_name: []const u8) []const u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tools/manifests/{s}", .{file_name}) catch return "";
    const raw = lib.fsRead(path) catch return "";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, raw, .{}) catch return "";
    if (parsed != .object) return "";
    const d = parsed.object.get("description") orelse return "";
    return if (d == .string) d.string else "";
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
