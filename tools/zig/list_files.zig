//! list_files: what is in a directory.
//!
//! An agent could read a file and search text, but had no way to ask what
//! exists: every "which files are there" question had to be guessed at, or
//! answered by grepping for a pattern that might not appear in the filename.
//!
//! Input:  {"path": "src/agent"}
//!         {"path": "src", "recursive": true, "suffix": ".zig", "max": 200}
//! Output: {"ok": true, "path": "src", "entries": ["src/agent/loop.zig", ...],
//!          "count": 12, "truncated": false}

const std = @import("std");
const lib = @import("lib.zig");
// The same skip table the host's ck_fs_find walk uses, so the two answer the
// same about a tree rather than drifting apart.
const fs_skip = @import("fs_skip");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

const default_max = 500;
/// Deep enough for this project's tree, shallow enough that a symlink loop or
/// a vendored dependency cannot spin the sandbox.
const max_depth = 8;

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{}) catch
        return lib.fail(out, "input must be a JSON object");
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;

    const path = str(obj, "path") orelse ".";
    const suffix = str(obj, "suffix") orelse "";
    const recursive = switch (obj.get("recursive") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    const max = switch (obj.get("max") orelse std.json.Value{ .integer = default_max }) {
        .integer => |i| if (i <= 0) default_max else @as(usize, @intCast(i)),
        else => default_max,
    };

    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(alloc);
    var truncated = false;
    walk(alloc, path, suffix, recursive, max, 0, &entries, &truncated) catch |err| return lib.failErr(out, err, path);

    var w = out.writer();
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("path");
    try s.write(path);
    try s.objectField("entries");
    try s.beginArray();
    for (entries.items) |e| try s.write(e);
    try s.endArray();
    try s.objectField("count");
    try s.write(entries.items.len);
    // Saying so beats a list that looks complete: a caller that sees 500 of
    // 4000 files and no marker concludes the other 3500 do not exist.
    if (truncated) {
        try s.objectField("truncated");
        try s.write(true);
        try s.objectField("note");
        try s.write("stopped at max; raise max, narrow the path, or set a suffix");
    }
    try s.endObject();
    out.len = w.end;
}

/// Appends every matching entry under `dir`, descending when asked.
/// Directories are listed with a trailing slash so a caller can tell them from
/// files without a second call.
fn walk(
    alloc: std.mem.Allocator,
    dir: []const u8,
    suffix: []const u8,
    recursive: bool,
    max: usize,
    depth: usize,
    entries: *std.ArrayList([]const u8),
    truncated: *bool,
) !void {
    if (depth > max_depth) return;
    const raw = try lib.fsList(dir);

    // The host answers with a JSON array of names and no kinds, so each entry
    // is stated to find out which it is. This used to list every entry
    // instead: reading a whole directory to answer a yes/no question, and
    // spending host-arena space on the contents each time. The arena does not
    // reset within a call, so a directory with many subdirectories could
    // exhaust it partway through and truncate its own listing.
    const names = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch return;
    if (names != .array) return;

    // Copy every name out of the arena before making another host call. The
    // host writes results into a bump arena it never resets during a call, so
    // a name still pointing there turns to garbage as soon as anything else is
    // read: the first probe below corrupted every remaining entry, and the
    // directories simply vanished from the listing.
    var owned: std.ArrayList([]const u8) = .empty;
    defer owned.deinit(alloc);
    for (names.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        try owned.append(alloc, try alloc.dupe(u8, item.string));
    }

    for (owned.items) |listed| {
        const is_dir = std.mem.endsWith(u8, listed, "/");
        const name = if (is_dir) listed[0 .. listed.len - 1] else listed;
        if (name.len == 0) continue;

        const full = if (dir.len == 0 or std.mem.eql(u8, dir, "."))
            try alloc.dupe(u8, name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });

        // The same directories the host's name search skips: a recursive
        // listing of the project should not be mostly build output and copies
        // of itself.
        if (is_dir and recursive and fs_skip.skipDir(name)) continue;

        if (is_dir) {
            if (entries.items.len >= max) {
                truncated.* = true;
                return;
            }
            try entries.append(alloc, try std.fmt.allocPrint(alloc, "{s}/", .{full}));
            if (recursive) try walk(alloc, full, suffix, recursive, max, depth + 1, entries, truncated);
            continue;
        }
        if (suffix.len > 0 and !std.mem.endsWith(u8, name, suffix)) continue;
        if (entries.items.len >= max) {
            truncated.* = true;
            return;
        }
        try entries.append(alloc, full);
    }
}

const str = lib.strFieldRequired;
