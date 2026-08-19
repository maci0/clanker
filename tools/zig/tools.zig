//! tools: list what is registered, split into what the model can call and
//! what it cannot, read from the configured tools directory.
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
const utf8 = @import("utf8");
const scan = @import("manifest_scan.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    _ = parsed;

    const alloc = lib.alloc;

    const Entry = struct { name: []const u8, meta: Meta };
    var tools: std.ArrayList(Entry) = .empty;
    defer tools.deinit(alloc);
    var plugins: std.ArrayList(Entry) = .empty;
    defer plugins.deinit(alloc);
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (lib.toolsDirs()) |tools_dir| {
        const raw = lib.fsList(tools_dir) catch continue;
        const names = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});
        if (names != .array) continue;
        for (names.array.items) |item| {
            if (item != .string) continue;
            const file = item.string;
            if (!std.mem.endsWith(u8, file, ".tool.json")) continue;
            const base = file[0 .. file.len - ".tool.json".len];
            const meta = describeAt(tools_dir, file);
            const entry = Entry{ .name = base, .meta = meta };
            if (seen.contains(base)) {
                // Later directory wins: drop the earlier listing of this name.
                removeNamed(Entry, &tools, base);
                removeNamed(Entry, &plugins, base);
            } else {
                try seen.put(alloc, base, {});
            }
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

/// Work-first, then instance-ops. Same sequence as the web Tools view
/// (`ui/app/core/labels.js` `toolCategoryOrder`) and the validator set in
/// `src/toolhost/manifest.zig` `categories`.
const category_order = [_][]const u8{ "code", "chat", "kanban", "agent", "knowledge", "web", "media", "compute", "transform", "harness" };

fn categoryRank(name: []const u8) usize {
    if (name.len == 0 or std.mem.eql(u8, name, "other")) return category_order.len + 1;
    for (category_order, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return category_order.len;
}

fn lessCategory(_: void, a: []const u8, b: []const u8) bool {
    const ra = categoryRank(a);
    const rb = categoryRank(b);
    if (ra != rb) return ra < rb;
    return std.mem.lessThan(u8, a, b);
}

/// Writes entries grouped under their category heading, categories in the
/// shared work-first order so the CLI listing matches the Tools view.
fn writeGrouped(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), entries: anytype) !void {
    var cats: std.ArrayList([]const u8) = .empty;
    defer cats.deinit(alloc);
    for (entries) |seed| {
        var seen = false;
        for (cats.items) |d| {
            if (std.mem.eql(u8, d, seed.meta.category)) seen = true;
        }
        if (seen) continue;
        try cats.append(alloc, seed.meta.category);
    }
    std.mem.sort([]const u8, cats.items, {}, lessCategory);

    for (cats.items) |cat| {
        try buf.appendSlice(alloc, "  ");
        try buf.appendSlice(alloc, cat);
        try buf.appendSlice(alloc, "\n");
        for (entries) |e| {
            if (!std.mem.eql(u8, e.meta.category, cat)) continue;
            try buf.appendSlice(alloc, "    ");
            try buf.appendSlice(alloc, e.name);
            const desc = e.meta.description;
            if (desc.len > 0) {
                const pad = if (e.name.len < name_col) name_col - e.name.len else 1;
                try buf.appendNTimes(alloc, ' ', pad);
                const first = desc[0 .. std.mem.findScalar(u8, desc, '\n') orelse desc.len];
                const clipped = utf8.cap(first, desc_max);
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

/// One manifest's description and whether it is a plugin. Scanned, not
/// parsed: a full std.json parse of ~90 manifests (input_schema trees
/// included) under wasm interpretation put `tools list` over a second;
/// manifest_scan reads the four top-level fields in one pass. Borrowing
/// from fsRead's result is safe here — the host arena bump-allocates for
/// the whole call without resetting (lib.zig), so earlier reads survive
/// later ones.
fn removeNamed(comptime T: type, list: *std.ArrayList(T), name: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i].name, name)) {
            _ = list.orderedRemove(i);
            return;
        }
        i += 1;
    }
}

fn describeAt(tools_dir: []const u8, file_name: []const u8) Meta {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tools_dir, file_name }) catch return .{};
    const raw = lib.fsRead(path) catch return .{};
    // One pass for all four. `category`, `internal` and `transform` all sit
    // after `input_schema` in a manifest, so a scan per field walked the whole
    // schema tree three extra times per file.
    const keys = [_][]const u8{ "description", "internal", "category", "transform" };
    var spans: [keys.len]?[]const u8 = undefined;
    scan.topLevelValues(raw, &keys, &spans);
    var meta = Meta{};
    if (spans[0]) |d| meta.description = scan.decodeString(lib.alloc, d) orelse "";
    if (spans[1]) |v| meta.plugin = std.mem.eql(u8, v, "true");
    if (spans[2]) |c| meta.category = scan.decodeString(lib.alloc, c) orelse "";
    if (spans[3] != null) {
        meta.plugin = true;
        if (meta.category.len == 0) meta.category = "transform";
    }
    if (meta.category.len == 0) meta.category = "other";
    return meta;
}
