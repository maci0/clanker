//! cmd_tools: list what is registered, split into what the model can call and
//! what it cannot, read from tools/manifests/*.tool.json.
//!
//! A tool is callable: the model picks it by name and gets its result. A
//! plugin backs the harness itself — the web UI, the markdown formatter, the
//! slash commands, the transform chain — and never appears in the model's
//! catalog. Listing them in one flat column implied the model could call the
//! web UI.
//!
//! Input:  {"args": "..."}
//! Output: {"ok": true, "text": "<sections of name  description>"}

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
    var plugins: std.ArrayList(u8) = .empty;
    defer plugins.deinit(std.heap.wasm_allocator);
    var count: usize = 0;
    var plugin_count: usize = 0;
    try buf.appendSlice(std.heap.wasm_allocator, "tools (the model can call these)\n");
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            const name = item.string;
            // strip the .tool.json suffix
            if (!std.mem.endsWith(u8, name, ".tool.json")) continue;
            const base = name[0 .. name.len - ".tool.json".len];
            const meta = describeFull(name);
            var target = &buf;
            if (meta.plugin) {
                target = &plugins;
                plugin_count += 1;
            } else count += 1;
            try target.appendSlice(std.heap.wasm_allocator, "  ");
            try target.appendSlice(std.heap.wasm_allocator, base);
            // A bare list of names says nothing about what any of them do:
            // pull each manifest's own description in, padded into a column.
            const desc = meta.description;
            if (desc.len > 0) {
                const pad = if (base.len < name_col) name_col - base.len else 1;
                try target.appendNTimes(std.heap.wasm_allocator, ' ', pad);
                // One line per entry: a description with newlines in it would
                // break the column, so only the first line is shown.
                const first = desc[0 .. std.mem.indexOfScalar(u8, desc, '\n') orelse desc.len];
                const clipped = first[0..@min(first.len, desc_max)];
                try target.appendSlice(std.heap.wasm_allocator, clipped);
                if (clipped.len < first.len) try target.appendSlice(std.heap.wasm_allocator, "…");
            }
            try target.append(std.heap.wasm_allocator, '\n');
        }
    }
    if (plugin_count > 0) {
        try buf.appendSlice(std.heap.wasm_allocator, "\nplugins (harness-side, not callable by the model)\n");
        try buf.appendSlice(std.heap.wasm_allocator, plugins.items);
    }
    const summary = try std.fmt.allocPrint(std.heap.wasm_allocator, "\n{d} tool(s), {d} plugin(s)", .{ count, plugin_count });
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

const Meta = struct {
    description: []const u8 = "",
    /// Internal entries and transforms back the harness rather than answering
    /// the model, so they are plugins, not tools.
    plugin: bool = false,
};

/// One manifest's description and whether it is a plugin.
fn describeFull(file_name: []const u8) Meta {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tools/manifests/{s}", .{file_name}) catch return .{};
    const raw = lib.fsRead(path) catch return .{};
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, raw, .{}) catch return .{};
    if (parsed != .object) return .{};
    var meta = Meta{};
    if (parsed.object.get("description")) |d| {
        if (d == .string) meta.description = d.string;
    }
    if (parsed.object.get("internal")) |i| {
        if (i == .bool and i.bool) meta.plugin = true;
    }
    if (parsed.object.get("transform") != null) meta.plugin = true;
    return meta;
}

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
