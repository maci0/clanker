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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    _ = parsed;

    const alloc = lib.alloc;
    const raw = lib.fsList("tools/manifests") catch |err| return lib.fail(out, @errorName(err));
    const names = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});

    const Entry = struct { name: []const u8, meta: Meta };
    var tools: std.ArrayList(Entry) = .empty;
    defer tools.deinit(alloc);
    var plugins: std.ArrayList(Entry) = .empty;
    defer plugins.deinit(alloc);

    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            const file = item.string;
            if (!std.mem.endsWith(u8, file, ".tool.json")) continue;
            const base = file[0 .. file.len - ".tool.json".len];
            const meta = describeFull(file);
            const entry = Entry{ .name = base, .meta = meta };
            if (meta.plugin) try plugins.append(alloc, entry) else try tools.append(alloc, entry);
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "tools (the model can call these)\n");
    try writeGrouped(alloc, &buf, tools.items);
    if (plugins.items.len > 0) {
        try buf.appendSlice(alloc, "\nplugins (harness-side, not callable by the model)\n");
        try writeGrouped(alloc, &buf, plugins.items);
    }
    const summary = try std.fmt.allocPrint(alloc, "\n{d} tool(s), {d} plugin(s)", .{ tools.items.len, plugins.items.len });
    defer alloc.free(summary);
    try buf.appendSlice(alloc, summary);

    return lib.okText(out, buf.items);
}

/// Writes entries grouped under their category heading, categories in first-
/// seen order so related tools read together instead of scattered by name.
fn writeGrouped(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), entries: anytype) !void {
    var done: std.ArrayList([]const u8) = .empty;
    defer done.deinit(alloc);
    for (entries) |seed| {
        var seen = false;
        for (done.items) |d| {
            if (std.mem.eql(u8, d, seed.meta.category)) seen = true;
        }
        if (seen) continue;
        try done.append(alloc, seed.meta.category);

        try buf.appendSlice(alloc, "  ");
        try buf.appendSlice(alloc, seed.meta.category);
        try buf.appendSlice(alloc, "\n");
        for (entries) |e| {
            if (!std.mem.eql(u8, e.meta.category, seed.meta.category)) continue;
            try buf.appendSlice(alloc, "    ");
            try buf.appendSlice(alloc, e.name);
            const desc = e.meta.description;
            if (desc.len > 0) {
                const pad = if (e.name.len < name_col) name_col - e.name.len else 1;
                try buf.appendNTimes(alloc, ' ', pad);
                const first = desc[0 .. std.mem.indexOfScalar(u8, desc, '\n') orelse desc.len];
                const clipped = first[0..@min(first.len, desc_max)];
                try buf.appendSlice(alloc, clipped);
                if (clipped.len < first.len) try buf.appendSlice(alloc, "\u{2026}");
            }
            try buf.append(alloc, '\n');
        }
    }
}

const name_col: usize = 18;
const desc_max: usize = 96;

const Meta = struct {
    description: []const u8 = "",
    /// Groups related entries in the listing: a flat column of forty names is
    /// a wall, and which ones belong together is not guessable from the names.
    category: []const u8 = "",
    /// Internal entries and transforms back the harness rather than answering
    /// the model, so they are plugins, not tools.
    plugin: bool = false,
};

/// One manifest's description and whether it is a plugin.
fn describeFull(file_name: []const u8) Meta {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tools/manifests/{s}", .{file_name}) catch return .{};
    const raw = lib.fsRead(path) catch return .{};
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return .{};
    if (parsed != .object) return .{};
    var meta = Meta{};
    if (parsed.object.get("description")) |d| {
        if (d == .string) meta.description = d.string;
    }
    if (parsed.object.get("internal")) |i| {
        if (i == .bool and i.bool) meta.plugin = true;
    }
    if (parsed.object.get("category")) |c| {
        if (c == .string) meta.category = c.string;
    }
    if (parsed.object.get("transform") != null) {
        meta.plugin = true;
        if (meta.category.len == 0) meta.category = "transform";
    }
    if (meta.category.len == 0) meta.category = "other";
    return meta;
}

/// The `description` field of one manifest, or "" when it cannot be read.
fn describe(file_name: []const u8) []const u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "tools/manifests/{s}", .{file_name}) catch return "";
    const raw = lib.fsRead(path) catch return "";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return "";
    if (parsed != .object) return "";
    const d = parsed.object.get("description") orelse return "";
    return if (d == .string) d.string else "";
}
