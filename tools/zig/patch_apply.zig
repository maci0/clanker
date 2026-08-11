//! patch_apply: applies a batch of exact-match text changes to files under a
//! sandboxed prefix. Used by the self-improve engine to materialize a
//! proposal into its staging tree (state/staging/<id>/...); path validation
//! and the decision to promote the result both stay in the native engine,
//! this tool only performs the text edits.
//!
//! Input:  {"changes": [{"file": "a.txt", "old": "...", "new": "..."}, ...]}
//!         old == "" means append (or create the file if it does not exist).
//!         old != "" replaces the first occurrence; missing means create.
//! Output: {"ok": true, "applied": N} | {"ok": false, "error": "..."}

const std = @import("std");
const lib = @import("lib.zig");

const Change = struct {
    file: []const u8 = "",
    old: []const u8 = "",
    new: []const u8 = "",
};

const Request = struct {
    changes: []const Change = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const req = std.json.parseFromSliceLeaky(Request, alloc, input, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "input must be {\"changes\": [{\"file\",\"old\",\"new\"}, ...]}");
    if (req.changes.len == 0) return lib.fail(out, "changes must be a non-empty array");

    for (req.changes) |c| {
        if (c.file.len == 0) return lib.fail(out, "each change needs a non-empty \"file\"");
        applyOne(c) catch |err| return lib.failErr(out, err, c.file);
    }

    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"applied\":{d}}}", .{req.changes.len}) catch
        "{\"ok\":true}";
    try out.writeAll(json);
}

fn applyOne(c: Change) !void {
    const current = lib.fsRead(c.file) catch |err| switch (err) {
        error.NotFound => return lib.fsWrite(c.file, c.new),
        else => return err,
    };
    const text = try lib.alloc.dupe(u8, current);
    defer lib.alloc.free(text);

    if (c.old.len == 0) {
        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(lib.alloc);
        try out_buf.appendSlice(lib.alloc, text);
        try out_buf.appendSlice(lib.alloc, c.new);
        return lib.fsWrite(c.file, out_buf.items);
    }

    const idx = std.mem.indexOf(u8, text, c.old) orelse return error.OldTextNotFound;
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(lib.alloc);
    try out_buf.appendSlice(lib.alloc, text[0..idx]);
    try out_buf.appendSlice(lib.alloc, c.new);
    try out_buf.appendSlice(lib.alloc, text[idx + c.old.len ..]);
    return lib.fsWrite(c.file, out_buf.items);
}
